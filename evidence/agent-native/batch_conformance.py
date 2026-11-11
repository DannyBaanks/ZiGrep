#!/usr/bin/env python3
"""Diferencial lote <-> N procesos y pruebas de truncado (M3 del plan agent-native).

1. EQUIVALENCIA. Para cada consulta del conjunto fijo, la misma búsqueda se corre
   como proceso separado (`zgrep --json --sort <flags> -e PAT -- PATHS`) y dentro
   de UN lote (`--queries-file`). Los eventos de esa consulta en el lote deben ser
   byte a byte los del proceso separado con `"query_id"` insertado, en el mismo
   orden, seguidos de un `query_end` cuyo `rc` es el del proceso separado y cuyo
   `returned` es su número de resultados. El `summary` final debe sumar lo mismo.
2. TRUNCADO. Con `--max-results K` y `--max-output-tokens T` sobre el mismo
   lote: cada línea es JSON válido, `summary` es la última, los resultados
   emitidos son un PREFIJO de los del lote sin presupuesto, `returned + omitted`
   es el total sin presupuesto, `truncated`/`reason` dicen la verdad y, con
   tokens, los bytes de eventos de búsqueda no pasan de T*4.
3. Casos de error que deben fallar cerrado (rc 2, sin ejecutar nada a medias).

Los recuentos NO están escritos en este fichero: salen de la ejecución.

Uso:  python3 evidence/agent-native/batch_conformance.py [--zgrep RUTA]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import zgrep_estimate  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
CORPUS = "bench-corpus/corpus_50"
FIX = "evidence/feature-corpus"

# (id, pattern, flags, paths) — rutas relativas a ROOT. Mezcla de modos de
# salida (match, occurrence, context, passthru, file, count) y de caminos
# (un fichero, varios ficheros, directorio).
QUERIES = [
    ("needle", "ZGREP_PLANTED_TOKEN", [], [CORPUS]),
    ("rare_n", "ZGREP_RARE_TOKEN", ["-n"], [CORPUS]),
    ("absent", "ZGREP_ABSENT_TOKEN", [], [CORPUS]),
    ("rare_ctx", "ZGREP_RARE_TOKEN", ["-C", "2"], [CORPUS]),
    ("files", "ZGREP_PLANTED_TOKEN", ["-l"], [CORPUS]),
    ("count", "ZGREP_PLANTED_TOKEN", ["-c"], [CORPUS]),
    ("count_m", "HIT", ["--count-matches"], [f"{FIX}/a.txt", f"{FIX}/b.txt"]),
    ("only", "[A-Z]+", ["-o"], [f"{FIX}/a.txt"]),
    ("icase", "hit", ["-i"], [f"{FIX}/a.txt", f"{FIX}/b.txt"]),
    ("word", "HIT", ["-w"], [f"{FIX}/wb.txt"]),
    ("invert", "HIT", ["-v"], [f"{FIX}/a.txt"]),
    ("passthru", "HIT", ["--passthru"], [f"{FIX}/a.txt"]),
    ("fixed_dot", "a.b", ["-F"], [f"{FIX}/a.txt", f"{FIX}/x.txt"]),
    ("src_fn", r"pub fn \w+", [], ["src/batch.zig", "src/out_json.zig"]),
    ("src_dir", "Searcher", ["-w"], ["src"]),
    ("missing", "HIT", [], [f"{FIX}/zz_no_such_file.txt"]),
]


def run(argv: list[str], stdin: bytes | None = None) -> tuple[bytes, bytes, int]:
    p = subprocess.run(argv, cwd=ROOT, input=stdin, capture_output=True)
    return p.stdout, p.stderr, p.returncode


def events(out: bytes) -> list[dict]:
    return [json.loads(l) for l in out.decode().split("\n")[:-1]]


def inject_id(line: str, qid: str) -> str:
    pre = '{"schema":"zgrep/1",'
    assert line.startswith(pre), line
    return pre + '"query_id":' + json.dumps(qid) + "," + line[len(pre):]


RESULT_TYPES = {"match", "occurrence", "file", "count"}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zgrep", default=str(ROOT / "zig-out" / "bin" / "zgrep"))
    z = ap.parse_args().zgrep
    passed = failed = 0

    def check(ok: bool, name: str, detail: str = "") -> None:
        nonlocal passed, failed
        if ok:
            passed += 1
            print(f"PASS {name}")
        else:
            failed += 1
            print(f"FAIL {name}" + (f": {detail}" if detail else ""))

    qtext = "".join(
        json.dumps({"id": i, "pattern": p, "flags": f, "paths": ps}) + "\n"
        for i, p, f, ps in QUERIES
    )
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as fh:
        fh.write(qtext)
        qfile = fh.name

    # --- 1. equivalencia -------------------------------------------------
    separate: dict[str, tuple[list[str], int]] = {}
    for qid, pat, flags, paths in QUERIES:
        out, _, rc = run([z, "--json", "--sort", *flags, "-e", pat, "--", *paths])
        separate[qid] = (out.decode().split("\n")[:-1], rc)

    bout, _, brc = run([z, "--queries-file", qfile])
    lines = bout.decode().split("\n")[:-1]
    try:
        evs = [json.loads(l) for l in lines]
        check(True, "lote: todas las lineas son JSON")
    except json.JSONDecodeError as e:
        check(False, "lote: todas las lineas son JSON", str(e))
        return 1
    check(all(e.get("schema") == "zgrep/1" for e in evs), "lote: schema zgrep/1 en cada evento")
    check(bool(evs) and evs[-1]["type"] == "summary", "lote: summary es el ultimo evento")

    by_q: dict[str, list[str]] = {}
    ends: dict[str, dict] = {}
    order: list[str] = []
    for line, ev in zip(lines, evs):
        if ev["type"] == "summary":
            continue
        qid = ev["query_id"]
        if qid not in order:
            order.append(qid)
        if ev["type"] == "query_end":
            ends[qid] = ev
        else:
            by_q.setdefault(qid, []).append(line)
    check(order == [q[0] for q in QUERIES], "lote: consultas en el orden del fichero", f"{order}")

    total_results = 0
    any_err = any_match = False
    for qid, *_ in QUERIES:
        sep_lines, sep_rc = separate[qid]
        want = [inject_id(l, qid) for l in sep_lines]
        got = by_q.get(qid, [])
        nres = sum(1 for l in sep_lines if json.loads(l)["type"] in RESULT_TYPES)
        total_results += nres
        any_err |= sep_rc == 2
        any_match |= sep_rc == 0
        end = ends.get(qid, {})
        ok = got == want and end.get("rc") == sep_rc and end.get("returned") == nres and end.get("omitted") == 0
        check(ok, f"equivalencia {qid} ({len(sep_lines)} eventos, {nres} resultados, rc {sep_rc})",
              f"got {len(got)} want {len(want)} end={end}")
    s = evs[-1]
    check(s["queries"] == len(QUERIES) and s["returned"] == total_results and s["omitted"] == 0
          and s["truncated"] is False, "summary: suma de resultados", f"{s}")
    want_rc = 2 if any_err else (0 if any_match else 1)
    check(brc == want_rc, f"rc del lote = {want_rc}", f"got {brc}")

    # Resultados del lote sin presupuesto, en orden: la referencia del truncado.
    full_results = [l for l, e in zip(lines, evs) if e["type"] in RESULT_TYPES]

    def budget_case(name: str, extra: list[str], max_results: int | None, max_tokens: int | None) -> None:
        out, _, _ = run([z, "--queries-file", qfile, *extra])
        ls = out.decode().split("\n")[:-1]
        try:
            es = [json.loads(l) for l in ls]
        except json.JSONDecodeError as e:
            check(False, f"{name}: JSON valido", str(e))
            return
        res = [l for l, e in zip(ls, es) if e["type"] in RESULT_TYPES]
        summ = es[-1] if es else {}
        search_lines = [l for l, e in zip(ls, es) if e["type"] not in ("query_end", "summary")]
        # M7: el presupuesto se mide con el estimador de zgrep (port exacto en
        # zgrep_estimate.py), no con bytes/4; la cota con tokens REALES esta en
        # m7/budget_real_tokens.py (necesita el tokenizador, no corre en CI).
        search_est = sum(zgrep_estimate.estimate((l + "\n").encode()) for l in search_lines)
        limit_hit = (max_results is not None and max_results < len(full_results)) or (
            max_tokens is not None and len(res) < len(full_results))
        ok = (
            summ.get("type") == "summary"
            and res == full_results[: len(res)]
            and summ["returned"] == len(res)
            and summ["returned"] + summ["omitted"] == len(full_results)
            and summ["truncated"] == (summ["omitted"] > 0)
            and summ["truncated"] == limit_hit
            and (max_results is None or len(res) <= max_results)
            and (max_tokens is None or search_est <= max_tokens + 1e-6)
            and summ.get("token_estimate") == "zgrep-classes-v1"
            and abs(summ.get("output_tokens_est", 0) - search_est) <= 1.0
            and sum(e["omitted"] for e in es if e["type"] == "query_end") == summ["omitted"]
        )
        check(ok, f"{name}: returned={summ.get('returned')} omitted={summ.get('omitted')} reason={summ.get('reason')}",
              f"res={len(res)} full={len(full_results)} est={search_est:.1f} summary={summ}")

    n = len(full_results)
    for k in sorted({0, 1, 7, n // 2, n - 1, n, n + 10}):
        if k >= 0:
            budget_case(f"--max-results {k}", ["--max-results", str(k)], k, None)
    for t in (1, 50, 500, 5000):
        budget_case(f"--max-output-tokens {t}", ["--max-output-tokens", str(t)], None, t)
    budget_case("los dos presupuestos", ["--max-results", "5", "--max-output-tokens", "100000"], 5, 100000)

    # --- 3. fallar cerrado ---------------------------------------------
    def closed(name: str, argv: list[str], stdin: bytes | None = None) -> None:
        out, err, rc = run(argv, stdin)
        check(rc == 2 and out == b"", f"cerrado: {name}", f"rc={rc} out={out[:80]!r} err={err[:120]!r}")

    closed("id duplicado", [z, "--queries-file", "-", FIX],
           b'{"id":"a","pattern":"x"}\n{"id":"a","pattern":"y"}\n')
    closed("campo desconocido", [z, "--queries-file", "-", FIX], b'{"id":"a","pattern":"x","path":["typo"]}\n')
    closed("JSON roto", [z, "--queries-file", "-", FIX], b'{"id":"a",\n')
    closed("-e global con lote", [z, "--queries-file", qfile, "-e", "x"])
    closed("presupuesto sin --json", [z, "--max-results", "1", "HIT", f"{FIX}/a.txt"])
    closed("fichero de consultas inexistente", [z, "--queries-file", "zz_no_such_queries.jsonl"])

    # Una consulta inválida falla SOLA: las demás corren y el lote da rc 2.
    out, _, rc = run([z, "--queries-file", "-", FIX + "/a.txt"],
                     b'{"id":"ok","pattern":"HIT"}\n{"id":"bad","pattern":"x","flags":["--exec","echo"]}\n')
    es = events(out)
    ends2 = {e["query_id"]: e for e in es if e["type"] == "query_end"}
    check(rc == 2 and ends2["ok"]["rc"] == 0 and ends2["bad"]["rc"] == 2 and ends2["bad"]["error"],
          "consulta invalida falla sola", f"rc={rc} ends={ends2}")

    Path(qfile).unlink()
    print(f"TOTAL {passed} pass / {failed} fail")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
