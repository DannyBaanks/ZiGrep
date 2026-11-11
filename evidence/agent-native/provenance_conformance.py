#!/usr/bin/env python3
"""Diferencial de procedencia por fichero (M4 del plan agent-native).

Para cada caso corre la misma búsqueda con y sin `--provenance` y comprueba:

  1. ADITIVO: quitando los eventos `provenance`, el stream es byte a byte el
     mismo que sin la bandera (no cambia ni un evento existente).
  2. UNO POR FICHERO Y ANTES: cada fichero con algún evento tiene exactamente un
     evento `provenance`, y aparece antes del primer evento de ese fichero.
     Ningún fichero sin eventos lleva `provenance` (no se hashea en vano).
  3. VERIFICABLE: `sha256` == sha256 de los bytes del fichero (hashlib),
     `size` == su tamaño, `mtime_ns` == `os.stat().st_mtime_ns`. Para stdin,
     el hash es el de los bytes enviados y `mtime_ns` es null.

Se cubren los caminos de lectura: micro path, enjambre (--force-swarm), camino
ordenado (--sort), io_uring (--io-engine=uring), stdin y lote (--queries-file).
Los recuentos NO están escritos aquí: salen de la ejecución.

Uso:  python3 evidence/agent-native/provenance_conformance.py [--zgrep RUTA]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CORPUS = "bench-corpus/corpus_50"
FIX = "evidence/feature-corpus"

CASES = [
    ("micro_dir", ["ZGREP_RARE_TOKEN", CORPUS], None),
    ("swarm_dir", ["--force-swarm", "ZGREP_RARE_TOKEN", CORPUS], None),
    ("sorted_dir", ["--sort", "ZGREP_PLANTED_TOKEN", CORPUS], None),
    ("uring_dir", ["--io-engine=uring", "ZGREP_RARE_TOKEN", CORPUS], None),
    ("files_l", ["-l", "ZGREP_PLANTED_TOKEN", CORPUS], None),
    ("count_c", ["--sort", "-c", "ZGREP_RARE_TOKEN", CORPUS], None),
    ("without_L", ["-L", "HIT", f"{FIX}/a.txt", f"{FIX}/x.txt", f"{FIX}/b.txt"], None),
    ("only_o", ["-o", "[A-Z]+", f"{FIX}/a.txt", f"{FIX}/b.txt"], None),
    ("context", ["--sort", "-C", "2", "ZGREP_RARE_TOKEN", CORPUS], None),
    ("passthru", ["--passthru", "HIT", f"{FIX}/a.txt"], None),
    ("no_match", ["ZGREP_ABSENT_TOKEN", CORPUS], None),
    ("src_tree", ["--sort", "-w", "Searcher", "src"], None),
    ("stdin", ["HIT"], f"{FIX}/a.txt"),
]


def run(argv: list[str], stdin: bytes | None = None) -> tuple[bytes, int]:
    p = subprocess.run(argv, cwd=ROOT, input=stdin, capture_output=True)
    return p.stdout, p.returncode


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zgrep", default=str(ROOT / "zig-out" / "bin" / "zgrep"))
    z = ap.parse_args().zgrep
    passed = failed = 0
    checked_files = 0

    def check(ok: bool, name: str, detail: str = "") -> None:
        nonlocal passed, failed
        if ok:
            passed += 1
            print(f"PASS {name}")
        else:
            failed += 1
            print(f"FAIL {name}" + (f": {detail}" if detail else ""))

    def verify_stream(name: str, plain: bytes, prov: bytes, stdin_bytes: bytes | None, ordered: bool) -> None:
        nonlocal checked_files
        plines = plain.decode().splitlines()
        vlines = prov.decode().splitlines()
        evs = [json.loads(l) for l in vlines]
        stripped = [l for l, e in zip(vlines, evs) if e["type"] != "provenance"]
        if ordered:
            same = stripped == plines
        else:
            # El enjambre no promete orden ENTRE ficheros (como rg): dos
            # ejecuciones pueden intercalar distinto. Dentro de un fichero el
            # orden si es fijo, asi que se compara agrupado por fichero.
            def by_file(ls: list[str]) -> dict:
                g: dict[str, list[str]] = {}
                for l in ls:
                    g.setdefault(json.loads(l).get("path"), []).append(l)
                return g
            same = by_file(stripped) == by_file(plines)
        check(same, f"{name}: aditivo (sin provenance = stream de siempre)",
              f"{len(stripped)} vs {len(plines)} lineas")
        seen_prov: dict[str, dict] = {}
        first_event: dict[str, int] = {}
        order_ok = True
        dup = []
        for i, e in enumerate(evs):
            path = e.get("path")
            if e["type"] == "provenance":
                if path in seen_prov:
                    dup.append(path)
                seen_prov[path] = e
                if path in first_event:
                    order_ok = False
            elif path is not None and e["type"] not in ("summary", "query_end"):
                first_event.setdefault(path, i)
                if path not in seen_prov:
                    order_ok = False
        check(not dup and order_ok and set(seen_prov) == set(first_event),
              f"{name}: un provenance por fichero con eventos, antes de ellos ({len(seen_prov)} ficheros)",
              f"dup={dup[:3]} order_ok={order_ok} sin_prov={sorted(set(first_event) - set(seen_prov))[:3]} "
              f"de_mas={sorted(set(seen_prov) - set(first_event))[:3]}")
        bad = []
        for path, e in seen_prov.items():
            if stdin_bytes is not None:
                data, mtime = stdin_bytes, None
                want_source = "stdin"
            else:
                fp = ROOT / path
                data, mtime = fp.read_bytes(), os.stat(fp).st_mtime_ns
                want_source = "file"
            ok = (e["sha256"] == hashlib.sha256(data).hexdigest() and e["size"] == len(data)
                  and e["mtime_ns"] == mtime and e["source"] == want_source)
            checked_files += 1
            if not ok:
                bad.append((path, e))
        check(not bad, f"{name}: sha256/size/mtime_ns == hashlib/os.stat", f"{bad[:2]}")

    for name, args, stdin_file in CASES:
        stdin_bytes = (ROOT / stdin_file).read_bytes() if stdin_file else None
        plain, rc1 = run([z, "--json", *args], stdin_bytes)
        prov, rc2 = run([z, "--json", "--provenance", *args], stdin_bytes)
        check(rc1 == rc2, f"{name}: mismo rc ({rc1})", f"{rc1} vs {rc2}")
        # Orden fijo: --sort, stdin, o varios FICHEROS explicitos (M2). Un
        # directorio sin --sort va por el enjambre.
        ordered = "--sort" in args or stdin_file is not None or not any(
            (ROOT / a).is_dir() for a in args if not a.startswith("-"))
        verify_stream(name, plain, prov, stdin_bytes, ordered)

    # Lote: --provenance global vale para todas las consultas; el evento lleva
    # query_id como cualquier otro, y no cuenta como resultado.
    q = (b'{"id":"a","pattern":"ZGREP_RARE_TOKEN","paths":["' + CORPUS.encode() + b'"]}\n'
         b'{"id":"b","pattern":"HIT","paths":["' + FIX.encode() + b'/a.txt"]}\n')
    plain, _ = run([z, "--queries-file", "-"], q)
    prov, _ = run([z, "--queries-file", "-", "--provenance"], q)
    pe = [json.loads(l) for l in prov.decode().splitlines()]
    ple = [json.loads(l) for l in plain.decode().splitlines()]
    # summary.output_bytes cambia (los eventos provenance pesan): se compara el resto.
    strip = [e for e in pe if e["type"] != "provenance"]
    for e in (strip[-1], ple[-1]):
        e.pop("output_bytes", None)
    check(strip == ple, "lote: aditivo salvo output_bytes del summary")
    check(all("query_id" in e for e in pe if e["type"] == "provenance") and
          strip[-1]["returned"] == ple[-1]["returned"], "lote: provenance con query_id y sin contar como resultado")
    for qid in ("a", "b"):
        sub_plain = "\n".join(json.dumps(e) for e in ple if e.get("query_id") == qid)
        sub = [e for e in pe if e.get("query_id") == qid]
        ok = True
        for e in sub:
            if e["type"] == "provenance":
                data = (ROOT / e["path"]).read_bytes()
                ok &= e["sha256"] == hashlib.sha256(data).hexdigest() and e["size"] == len(data)
                checked_files += 1
        check(ok and sub_plain != "", f"lote: provenance verificado en la consulta {qid}")

    # Arreglo de M4: stdin con --json -c / --count-matches emitia texto ("1")
    # o nada, rompiendo la regla de que en --json solo salen eventos.
    a_txt = (ROOT / FIX / "a.txt").read_bytes()
    for flag, field in (("-c", "lines"), ("--count-matches", "matches")):
        out, rc = run([z, "--json", flag, "HIT"], a_txt)
        evs = [json.loads(l) for l in out.decode().splitlines()]
        txt, _ = run([z, flag, "HIT"], a_txt)
        check(rc == 0 and len(evs) == 1 and evs[0]["type"] == "count" and str(evs[0][field]) == txt.decode().strip(),
              f"stdin --json {flag}: evento count igual al recuento de texto", f"{out!r} vs {txt!r}")

    # Regresion (bug de M1 cazado en M5): en el enjambre, el separador "--" de
    # los grupos de contexto se colaba en el stream JSON. En --json TODA linea
    # debe ser un evento, en todos los caminos de lectura.
    for path_flag in ([], ["--force-swarm"], ["--sort"], ["--io-engine=uring"]):
        for ctx in (["-C2"], ["-A1"], ["-B3"]):
            out, _ = run([z, "--json", *path_flag, *ctx, "ZGREP_RARE_TOKEN", CORPUS])
            bad = [l for l in out.decode().splitlines() if not l.startswith('{"schema":"zgrep/1",')]
            check(not bad and out, f"stream JSON puro {' '.join(path_flag + ctx)}", f"{bad[:3]}")

    # Fallar cerrado: sin --json no hay sitio para el hash.
    out, rc = run([z, "--provenance", "HIT", f"{FIX}/a.txt"])
    check(rc == 2 and out == b"", "cerrado: --provenance sin --json")

    print(f"ficheros verificados contra hashlib/os.stat: {checked_files}")
    print(f"TOTAL {passed} pass / {failed} fail")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
