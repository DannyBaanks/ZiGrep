#!/usr/bin/env python3
"""`--json=compact` (zgrep/1c) es zgrep/1 sin pérdida (M5).

Para cada caso corre la misma búsqueda con `--json` y con `--json=compact`,
decodifica el compacto con el decodificador DE REFERENCIA de abajo (el que la
GUIA documenta) y exige exactamente los mismos registros, en el mismo orden,
incluida la procedencia y, en lote, el query_id de cada registro y los
query_end. Cubre todos los modos de salida y los caminos de lectura.

Además: cada línea compacta es JSON válido; el compacto pesa menos que el
completo en cada caso (bytes); y con `--max-results` el lote compacto devuelve
los mismos resultados que el completo.

Los recuentos NO están escritos aquí: salen de la ejecución.
Uso:  python3 evidence/agent-native/compact_conformance.py [--zgrep RUTA]
"""
from __future__ import annotations

import argparse
import base64
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CORPUS = "bench-corpus/corpus_50"
FIX = "evidence/feature-corpus"

FIELDS = ("query_id", "type", "path", "line", "column", "byte_start", "byte_end", "match", "text",
          "inverted", "lines", "matches", "mode", "sha256", "size", "mtime_ns", "source")
ROW_TYPE = {"m": "match", "c": "context", "o": "occurrence", "p": "passthru"}


def canon_full(evs: list[dict]) -> list[tuple]:
    out = []
    for e in evs:
        if e["type"] in ("summary", "query_end"):
            continue
        out.append(tuple(e.get(k) for k in FIELDS))
    return out


def decode_compact(lines: list[str]) -> tuple[list[dict], list[dict]]:
    """Decodificador de referencia de zgrep/1c -> registros zgrep/1.
    Devuelve (registros, eventos de control zgrep/1 que pasan tal cual)."""
    recs, ctrl = [], []
    if not lines:
        return recs, ctrl  # busqueda vacia: stdout vacio, como cualquier grep
    assert json.loads(lines[0]).get("schema") == "zgrep/1c", "falta la cabecera de stream"
    path = qid = None
    for l in lines[1:]:
        d = json.loads(l)
        if isinstance(d, dict):
            if d.get("schema") == "zgrep/1":
                ctrl.append(d)
            elif "query_id" in d and len(d) == 1:
                qid, path = d["query_id"], None
            elif "path" in d:
                path = d["path"]
                if "sha256_b64u" in d:
                    # zgrep/1c lleva el hash en base64url; zgrep/1 en hex.
                    raw = base64.urlsafe_b64decode(d.pop("sha256_b64u") + "=")
                    assert len(raw) == 32, "sha256_b64u no son 32 bytes"
                    recs.append({"query_id": qid, "type": "provenance", "sha256": raw.hex(), **d})
            else:
                raise ValueError(f"objeto desconocido: {l[:80]}")
            continue
        tag = d[0]
        if tag in ("l", "L"):
            recs.append({"query_id": qid, "type": "file", "path": d[1], "mode": "with-match" if tag == "l" else "without-match"})
        elif tag in ("#", "#m"):
            recs.append({"query_id": qid, "type": "count", "path": d[1],
                         "lines": d[2] if tag == "#" else None, "matches": d[2] if tag == "#m" else None})
        else:
            r = {"query_id": qid, "type": ROW_TYPE[tag[0]], "path": path, "line": d[1], "inverted": tag.endswith("v")}
            if len(d) == 3:
                r.update({"text": d[2], "column": None, "byte_start": None, "byte_end": None, "match": None})
            else:
                col, bs, n, text = d[2:6]
                m = d[6] if len(d) == 7 else text.encode()[col - 1:col - 1 + n].decode()
                r.update({"column": col, "byte_start": bs, "byte_end": bs + n, "text": text, "match": m})
            recs.append(r)
    return recs, ctrl


CASES = [
    ("lineas", ["HIT", f"{FIX}/a.txt", f"{FIX}/b.txt"]),
    ("dir_micro", ["ZGREP_RARE_TOKEN", CORPUS]),
    ("dir_enjambre", ["--force-swarm", "--sort", "ZGREP_RARE_TOKEN", CORPUS]),
    ("needle_ordenado", ["--sort", "ZGREP_PLANTED_TOKEN", CORPUS]),
    ("uring", ["--io-engine=uring", "--sort", "ZGREP_RARE_TOKEN", CORPUS]),
    ("contexto", ["--sort", "-C", "2", "ZGREP_RARE_TOKEN", CORPUS]),
    ("invert", ["-v", "HIT", f"{FIX}/a.txt"]),
    ("invert_ctx", ["-v", "-A1", "HIT", f"{FIX}/a.txt"]),
    ("passthru", ["--passthru", "HIT", f"{FIX}/a.txt"]),
    ("only_o", ["-o", "[A-Z]+", f"{FIX}/a.txt", f"{FIX}/b.txt"]),
    ("vimgrep", ["--vimgrep", "HIT", f"{FIX}/a.txt"]),
    ("replace", ["--replace=XX", "HIT", f"{FIX}/a.txt", f"{FIX}/b.txt"]),
    ("files_l", ["--sort", "-l", "ZGREP_PLANTED_TOKEN", CORPUS]),
    ("without_L", ["-L", "HIT", f"{FIX}/a.txt", f"{FIX}/x.txt"]),
    ("count_c", ["--sort", "-c", "ZGREP_RARE_TOKEN", CORPUS]),
    ("count_matches", ["--count-matches", "HIT", f"{FIX}/a.txt", f"{FIX}/b.txt"]),
    ("word", ["--sort", "-w", "Searcher", "src"]),
    ("icase_fixed", ["-i", "-F", "hit", f"{FIX}/a.txt", f"{FIX}/b.txt"]),
    ("unicode", ["--sort", "ñ|é|→", "GUIA.md"]),
    ("no_match", ["ZGREP_ABSENT_TOKEN", CORPUS]),
    ("prov_lineas", ["--provenance", "--sort", "ZGREP_RARE_TOKEN", CORPUS]),
    ("prov_l", ["--provenance", "-l", "HIT", f"{FIX}/a.txt", f"{FIX}/b.txt"]),
    ("prov_c", ["--provenance", "-c", "HIT", f"{FIX}/a.txt", f"{FIX}/x.txt"]),
]


def run(argv: list[str], stdin: bytes | None = None) -> tuple[bytes, int]:
    p = subprocess.run(argv, cwd=ROOT, input=stdin, capture_output=True)
    return p.stdout, p.returncode


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zgrep", default=str(ROOT / "zig-out" / "bin" / "zgrep"))
    z = ap.parse_args().zgrep
    passed = failed = 0
    full_bytes = compact_bytes = 0

    def check(ok: bool, name: str, detail: str = "") -> None:
        nonlocal passed, failed
        if ok:
            passed += 1
            print(f"PASS {name}")
        else:
            failed += 1
            print(f"FAIL {name}" + (f": {detail}" if detail else ""))

    def compare(name: str, full: bytes, comp: bytes, rc1: int, rc2: int) -> None:
        nonlocal full_bytes, compact_bytes
        fl, cl = full.decode().splitlines(), comp.decode().splitlines()
        try:
            recs, ctrl = decode_compact(cl)
        except (ValueError, AssertionError, json.JSONDecodeError, KeyError, IndexError) as e:
            check(False, f"{name}: decodifica", repr(e))
            return
        want = canon_full([json.loads(l) for l in fl])
        got = [tuple(r.get(k) for k in FIELDS) for r in recs]
        full_bytes += len(full)
        compact_bytes += len(comp)
        lighter = len(comp) < len(full) or not want
        check(got == want and rc1 == rc2 and lighter,
              f"{name}: sin perdida ({len(want)} registros, {len(full)}->{len(comp)} bytes, rc {rc1})",
              f"rc {rc1}/{rc2} primero distinto: {next(((a, b) for a, b in zip(want, got) if a != b), (len(want), len(got)))}")

    for name, args in CASES:
        full, rc1 = run([z, "--json", *args])
        comp, rc2 = run([z, "--json=compact", *args])
        compare(name, full, comp, rc1, rc2)

    a_txt = (ROOT / FIX / "a.txt").read_bytes()
    for flags in (["HIT"], ["-c", "HIT"], ["--provenance", "HIT"]):
        full, rc1 = run([z, "--json", *flags], a_txt)
        comp, rc2 = run([z, "--json=compact", *flags], a_txt)
        compare(f"stdin {' '.join(flags)}", full, comp, rc1, rc2)

    # Lote: mismos registros con su query_id, y los mismos query_end.
    q = (json.dumps({"id": "rare", "pattern": "ZGREP_RARE_TOKEN", "paths": [CORPUS], "flags": ["-C1"]}) + "\n" +
         json.dumps({"id": 2, "pattern": "HIT", "paths": [f"{FIX}/a.txt", f"{FIX}/b.txt"], "flags": ["-c"]}) + "\n" +
         json.dumps({"id": "none", "pattern": "ZZZ_NOPE", "paths": [f"{FIX}/a.txt"]}) + "\n").encode()
    for extra in ([], ["--provenance"]):
        full, rc1 = run([z, "--json", "--queries-file", "-", *extra], q)
        comp, rc2 = run([z, "--json=compact", "--queries-file", "-", *extra], q)
        compare(f"lote {' '.join(extra)}", full, comp, rc1, rc2)
        fe = [json.loads(l) for l in full.decode().splitlines()]
        _, ctrl = decode_compact(comp.decode().splitlines())
        fq = [e for e in fe if e["type"] in ("query_end", "summary")]
        for e in fq + ctrl:
            e.pop("output_bytes", None)
        check(fq == ctrl, f"lote {' '.join(extra)}: query_end y summary identicos (salvo output_bytes)")

    # Presupuesto por resultados: los mismos resultados en los dos dialectos.
    for k in (0, 1, 4):
        full, _ = run([z, "--json", "--queries-file", "-", "--max-results", str(k)], q)
        comp, _ = run([z, "--json=compact", "--queries-file", "-", "--max-results", str(k)], q)
        fe = [json.loads(l) for l in full.decode().splitlines()]
        recs, ctrl = decode_compact(comp.decode().splitlines())
        fs, cs = fe[-1], ctrl[-1]
        RES = ("match", "occurrence", "file", "count")
        fr = [tuple(e.get(f) for f in FIELDS) for e in fe if e["type"] in RES]
        cr = [tuple(r.get(f) for f in FIELDS) for r in recs if r["type"] in RES]
        check(fr == cr and fs["returned"] == cs["returned"] and fs["omitted"] == cs["omitted"],
              f"--max-results {k}: mismos resultados y contadores en compacto", f"{fs} vs {cs}")

    # La cabecera es perezosa: busqueda vacia = stdout vacio; con presupuesto,
    # el summary sale siempre y la cabecera va delante.
    out, rc = run([z, "--json=compact", "ZZZ_NOPE", f"{FIX}/a.txt"])
    check(out == b"" and rc == 1, "vacio: stdout vacio y rc 1 (sin cabecera)")
    out, rc = run([z, "--json=compact", "--max-results", "1", "ZZZ_NOPE", f"{FIX}/a.txt"])
    ls = out.decode().splitlines()
    check(rc == 1 and len(ls) == 2 and ls[0] == '{"schema":"zgrep/1c"}' and json.loads(ls[1])["type"] == "summary",
          "vacio con presupuesto: cabecera + summary")

    # Fallar cerrado.
    out, rc = run([z, "--json=raro", "HIT", f"{FIX}/a.txt"])
    check(rc == 2 and out == b"", "cerrado: --json=<desconocido>")
    out, rc = run([z, "--json=compact", "--queries-file", "-", f"{FIX}/a.txt"],
                  b'{"id":"x","pattern":"HIT","flags":["--json"]}\n')
    end = [json.loads(l) for l in out.decode().splitlines() if '"query_end"' in l]
    check(rc == 2 and end and end[0]["rc"] == 2 and "dialect" in end[0]["error"],
          "cerrado: cambiar de dialecto dentro de una consulta")

    print(f"bytes en los casos: completo={full_bytes} compacto={compact_bytes} "
          f"(x{compact_bytes / full_bytes:.2f})")
    print(f"TOTAL {passed} pass / {failed} fail")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
