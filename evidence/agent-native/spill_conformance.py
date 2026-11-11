#!/usr/bin/env python3
"""M8: `--spill` es verificable y completa lo truncado sin pérdida.

Para cada caso (lote y búsqueda suelta ordenada; `--json` y `--json=compact`;
con y sin `--provenance`; presupuesto por resultados y por tokens):

  1. RECONSTRUCCIÓN: eventos de búsqueda emitidos ++ spill == salida SIN
     presupuesto. En `--json`, byte a byte; en compacto, como registros
     decodificados (el spill es un stream zgrep/1c propio, con su cabecera y sus
     marcadores de consulta).
  2. VERIFICABLE: `summary.spill.sha256`/`bytes` == el fichero real; modo 0600.
  3. CONTADORES: `summary.omitted` == resultados que hay en el spill.
  4. PEREZOSO: sin truncado no se crea fichero (`spill: null`).
  5. NUNCA SILENCIOSO: directorio no escribible -> `summary.spill.error`, rc y
     stdout intactos; truncado sin `--spill` -> `spill: null`.

Los recuentos no están escritos aquí: salen de la ejecución.
Uso: python3 evidence/agent-native/spill_conformance.py [--zgrep RUTA]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from compact_conformance import decode_compact  # noqa: E402

CORPUS = "bench-corpus/corpus_50"
FIX = "evidence/feature-corpus"
RES = {"match", "occurrence", "file", "count"}
QUERIES = (
    json.dumps({"id": "rare", "pattern": "ZGREP_RARE_TOKEN", "paths": [CORPUS], "flags": ["-C1"]}) + "\n" +
    json.dumps({"id": 2, "pattern": "HIT", "paths": [f"{FIX}/a.txt", f"{FIX}/b.txt"]}) + "\n" +
    json.dumps({"id": "needle", "pattern": "ZGREP_PLANTED_TOKEN", "paths": [CORPUS], "flags": ["-l"]}) + "\n"
).encode()


def run(argv, stdin=None):
    p = subprocess.run(argv, cwd=ROOT, input=stdin, capture_output=True)
    return p.stdout, p.returncode


def control(d: dict) -> bool:
    return d.get("type") in ("query_end", "summary") or d == {"schema": "zgrep/1c"} or list(d) == ["query_id"]


def full_search_lines(out: bytes) -> list[str]:
    return [l for l in out.decode().split("\n")[:-1] if not control(json.loads(l))]


def records(lines: list[str]) -> list[dict]:
    recs, _ = decode_compact(lines)
    return recs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zgrep", default=str(ROOT / "zig-out" / "bin" / "zgrep"))
    z = ap.parse_args().zgrep
    passed = failed = 0

    def check(ok, name, detail=""):
        nonlocal passed, failed
        passed += bool(ok)
        failed += not ok
        print(("PASS " if ok else "FAIL ") + name + ("" if ok or not detail else f": {detail}"))

    tmp = Path(tempfile.mkdtemp(prefix="zgrep-spill-test-"))
    CASES = []
    for dialect in ("--json", "--json=compact"):
        for prov in ([], ["--provenance"]):
            for budget in (["--max-results", "0"], ["--max-results", "3"], ["--max-results", "60"],
                           ["--max-output-tokens", "40"], ["--max-output-tokens", "2000"]):
                CASES.append((f"lote {dialect} {' '.join(prov + budget)}", [dialect, *prov, "--queries-file", "-", *budget], QUERIES))
            CASES.append((f"suelta {dialect} {' '.join(prov)} -C2 --max-results 2",
                          [dialect, *prov, "--sort", "-C2", "--max-results", "2", "ZGREP_RARE_TOKEN", CORPUS], None))

    for name, args, stdin in CASES:
        unbudgeted = [a for i, a in enumerate(args)
                      if a not in ("--max-results", "--max-output-tokens")
                      and not (i > 0 and args[i - 1] in ("--max-results", "--max-output-tokens"))]
        ref, _ = run([z, *unbudgeted], stdin)
        sdir = tmp / name.replace(" ", "_").replace("/", "")
        out, rc = run([z, *args, f"--spill={sdir}"], stdin)
        lines = out.decode().split("\n")[:-1]
        summ = json.loads(lines[-1])
        sp = summ["spill"]
        if summ["omitted"] == 0 and summ["truncated"] is False:
            check(sp is None and not sdir.exists(), f"{name}: sin truncado no crea fichero")
            continue
        if not sp or "path" not in sp:
            check(False, f"{name}: hay spill", f"{sp}")
            continue
        data = Path(sp["path"]).read_bytes()
        mode = stat.S_IMODE(os.stat(sp["path"]).st_mode)
        check(sp["sha256"] == hashlib.sha256(data).hexdigest() and sp["bytes"] == len(data) and mode == 0o600,
              f"{name}: sha256/bytes/0600 del spill", f"{sp} real={hashlib.sha256(data).hexdigest()} {len(data)} {oct(mode)}")
        slines = data.decode().split("\n")[:-1]
        if "--json=compact" in args:
            got = records(lines) + records(slines)
            want = records(ref.decode().split("\n")[:-1])
            spill_res = sum(1 for r in records(slines) if r["type"] in RES)
        else:
            got = full_search_lines(out) + slines
            want = full_search_lines(ref)
            spill_res = sum(1 for l in slines if json.loads(l)["type"] in RES)
        check(got == want, f"{name}: emitido ++ spill == sin presupuesto ({len(want)} registros)",
              f"{len(got)} vs {len(want)}; primero distinto: {next(((a, b) for a, b in zip(got, want) if a != b), None)}")
        check(summ["omitted"] == spill_res, f"{name}: omitted == resultados del spill ({spill_res})",
              f"omitted={summ['omitted']} spill={spill_res}")

    # Nunca silencioso.
    ro = tmp / "solo_lectura"
    ro.mkdir()
    ro.chmod(0o500)
    out, rc = run([z, "--json", "--max-results", "1", f"--spill={ro}/x", "ZGREP_RARE_TOKEN", CORPUS])
    s = json.loads(out.decode().split("\n")[:-1][-1])
    check(rc == 0 and s["truncated"] and isinstance(s["spill"], dict) and "error" in s["spill"]
          and len(full_search_lines(out)) == 1,
          "directorio no escribible: summary.spill.error, rc y stdout intactos", f"rc={rc} {s.get('spill')}")
    ro.chmod(0o700)
    out, _ = run([z, "--json", "--max-results", "1", "ZGREP_RARE_TOKEN", CORPUS])
    s = json.loads(out.decode().split("\n")[:-1][-1])
    check(s["omitted"] > 0 and s["spill"] is None, "truncado sin --spill: spill null (el agente sabe que debe re-ejecutar)")
    out, rc = run([z, "--json", "--spill", "HIT", f"{FIX}/a.txt"])
    check(rc == 2 and out == b"", "cerrado: --spill sin presupuesto")
    out, rc = run([z, "--queries-file", "-", "--max-results", "1", f"{FIX}/a.txt"],
                  b'{"id":"x","pattern":"HIT","flags":["--spill"]}\n')
    e = [json.loads(l) for l in out.decode().split("\n")[:-1] if '"query_end"' in l]
    check(rc == 2 and e and e[0]["rc"] == 2 and "spill" in e[0]["error"], "cerrado: --spill dentro de una consulta")

    print(f"TOTAL {passed} pass / {failed} fail")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
