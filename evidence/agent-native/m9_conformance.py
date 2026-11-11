#!/usr/bin/env python3
"""M9: `--max-columns N` recorta la línea larga y NO pierde nada (GUIA §4s).

El recorte es una VENTANA sobre el texto de la fila: a lo sumo N bytes
alrededor del match. Este diferencial comprueba el contrato contra el FICHERO
EN DISCO (no contra la propia salida), para cada combinación de dialecto
(`--json`, `--json=compact`), W (40, 200, 400 y uno descomunal que no recorta),
camino (sueltas, con contexto, passthru, `--replace`, lote) y `--provenance`:

  1. VENTANA REAL: la ventana son bytes REALES de la línea
     `fichero[line_start + win_start .. +len(ventana)]`;
  2. COORDENADAS ENTERAS: `line_start = byte_start - (col - 1)` cayó dentro del
     fichero, `line_len` es la longitud real de la línea y el match sigue en
     `línea[col-1 .. col-1+len]` (nunca se corta);
  3. NO SE RECORTA lo que no debe: líneas que caben en N, filas sin span
     (contexto, `-v`, passthru) y filas de `--replace`;
  4. NUNCA un carácter partido: la ventana decodifica como UTF-8;
  5. RECUPERABLE: con `--provenance`, el sha256 de la cabecera es el del
     fichero real, así que la línea entera se re-lee y se verifica por hash;
  6. W DESCOMUNAL == sin la bandera, byte a byte;
  7. USO: sin `--json` es error rc 2; 0 y valores no numéricos también; en lote
     es de la llamada (una consulta que lo pide en "flags" se rechaza).

No se auditan aquí las filas `-o` (su texto ES el match, no la línea): las
comprueba `compact_conformance.py` por paridad de dialectos.

Los recuentos NO están escritos aquí: salen de la ejecución.
Uso: python3 evidence/agent-native/m9_conformance.py [--zgrep RUTA]
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from compact_conformance import decode_compact  # noqa: E402

FIX = "evidence/agent-native/m9/fix"
HUGE = 100000  # W que no recorta nada: la salida debe ser la de siempre

LONG = f"{FIX}/long.txt"
MULTI = f"{FIX}/multi.txt"
SHORT = f"{FIX}/short.txt"
TYPES = ("match", "context", "passthru", "occurrence")


def run(argv: list[str], stdin: bytes | None = None) -> tuple[bytes, int]:
    p = subprocess.run(argv, cwd=ROOT, input=stdin, capture_output=True)
    return p.stdout, p.returncode


def data_of(path: str) -> bytes:
    return (ROOT / path).read_bytes()


def records_of(out: bytes, compact: bool) -> list[dict]:
    """Registros de cualquiera de los dos dialectos, con las mismas claves.

    En compacto se usa el decodificador DE REFERENCIA de la GUIA (el mismo con
    el que `compact_conformance.py` exige paridad); en `--json` los eventos ya
    son diccionarios. En ambos casos `win_start`/`line_len` valen None salvo en
    una fila recortada.
    """
    lines = out.decode().split("\n")[:-1]
    if compact:
        recs, _ = decode_compact(lines)
        recs = [r for r in recs if r.get("type") in TYPES]
    else:
        recs = [d for d in map(json.loads, lines) if d.get("type") in TYPES]

    def get(r: dict, k: str):
        return r.get(k)

    return [{
        "type": r["type"],
        "line": r["line"],
        "column": get(r, "column"),
        "byte_start": get(r, "byte_start"),
        "match": get(r, "match") or "",
        "text": get(r, "text"),
        "win_start": get(r, "win_start"),
        "line_len": get(r, "line_len"),
    } for r in recs]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zgrep", default=str(ROOT / "zig-out" / "bin" / "zgrep"))
    z = ap.parse_args().zgrep
    passed = failed = 0
    def check(ok: bool, name: str, detail: str = "") -> None:
        nonlocal passed, failed
        passed += bool(ok)
        failed += not ok
        print(("PASS " if ok else "FAIL ") + name + ("" if ok or not detail else f": {detail}"))

    # (nombre, fichero, argv, W, el texto emitido ES la línea, se esperan cortes)
    CASES = [
        ("ventana 40", LONG, ["--max-columns", "40", "HIT", LONG], 40, True, True),
        ("ventana 200", LONG, ["--max-columns", "200", "HIT", LONG], 200, True, True),
        ("ventana 400", LONG, ["--sort", "--max-columns", "400", "HIT", LONG], 400, True, True),
        ("ventana + contexto", MULTI, ["--max-columns", "40", "-C1", "HIT", MULTI], 40, True, True),
        ("ventana + passthru", MULTI, ["--max-columns", "40", "--passthru", "HIT", MULTI], 40, True, True),
        ("ventana + replace", MULTI, ["--max-columns", "40", "--replace=ZZ", "HIT", MULTI], 40, False, False),
        ("ventana + provenance", LONG, ["--provenance", "--max-columns", "40", "HIT", LONG], 40, True, True),
        ("match solo no cabe", LONG, ["--max-columns", "40", "m+", LONG], 40, True, True),
        ("líneas que caben", SHORT, ["--max-columns", "40", "HIT", SHORT], 40, True, False),
    ]

    def audit(name: str, out: bytes, data: bytes, w: int, text_is_line: bool, expect_any: bool) -> None:
        try:
            rows = records_of(out, name.startswith("1c"))
        except (ValueError, AssertionError, json.JSONDecodeError, KeyError, IndexError) as e:
            check(False, f"{name}: decodifica", repr(e))
            return
        n_win = 0
        for r in rows:
            where = f"{name} línea {r['line']}"
            # `line` del registro y la línea real del fichero (0-based).
            whole = data.split(b"\n")[r["line"] - 1]
            if r["column"] is None:
                # Sin span: jamás se recorta; el texto es la línea tal cual.
                if text_is_line:
                    check(r["win_start"] is None and r["text"].encode() == whole,
                          f"{where}: sin span no se recorta", f"{r['text']!r} vs {whole!r}")
                else:
                    check(r["win_start"] is None, f"{where}: sin span no se recorta")
                continue
            col, bs, n = r["column"], r["byte_start"], len(r["match"].encode())
            line_start = bs - (col - 1)
            # 2. las coordenadas apuntan a la línea real del fichero.
            check(0 <= line_start and data[line_start:line_start + len(whole)] == whole
                  and (line_start + len(whole) == len(data) or data[line_start + len(whole)] == 0x0A),
                  f"{where}: line_start reconstruye la línea en el fichero")
            check(r["line_len"] is None or r["line_len"] == len(whole),
                  f"{where}: line_len es la longitud real", f"{r['line_len']} vs {len(whole)}")
            # 2b. el match NUNCA se corta y sigue apuntando a la línea entera.
            check(whole[col - 1:col - 1 + n] == r["match"].encode(),
                  f"{where}: el match intacto en la línea entera")
            if r["win_start"] is None:
                if text_is_line:
                    check(r["text"].encode() == whole, f"{where}: fila entera",
                          f"{r['text']!r} vs {whole!r}")
                continue
            n_win += 1
            win = r["text"].encode()
            # 0 < ventana <= N, SALVO cuando el match solo ya no cabe en N: la
            # ventana es entonces el match (nunca se corta, así que no hay
            # nada más que hacer).
            check(len(win) > 0 and (len(win) <= w or win == r["match"].encode()),
                  f"{where}: 0 < ventana <= N (o la ventana ES el match)",
                  f"{len(win)} bytes, N={w}, match={len(r['match'])}")
            # 1. la ventana son bytes REALES de la línea.
            check(whole[r["win_start"]:r["win_start"] + len(win)] == win,
                  f"{where}: la ventana son bytes reales de la línea")
            # 2c. el match cae dentro de la ventana, en su offset desplazado.
            check(0 <= col - 1 - r["win_start"] and win[col - 1 - r["win_start"]:col - 1 - r["win_start"] + n] == r["match"].encode(),
                  f"{where}: el match está dentro de la ventana")
            # 3. una línea que cabe en N no debió recortarse.
            check(len(whole) > w, f"{where}: solo se recorta lo que no cabe")
            # 4. nunca un carácter partido.
            try:
                win.decode()
                check(True, f"{where}: la ventana decodifica como UTF-8")
            except UnicodeDecodeError as e:
                check(False, f"{where}: la ventana decodifica como UTF-8", repr(e))
        if expect_any:
            check(n_win > 0, f"{name}: hay filas recortadas (no es vacuo)", f"{n_win} de {len(rows)}")

    for name, path, args, w, text_is_line, expect_any in CASES:
        data = data_of(path)
        out, rc = run([z, "--json", *args])
        check(rc in (0, 1), f"json {name}: rc {rc}")
        audit(f"json {name}", out, data, w, text_is_line, expect_any)
        out, rc = run([z, "--json=compact", *args])
        check(rc in (0, 1), f"1c {name}: rc {rc}")
        audit(f"1c {name}", out, data, w, text_is_line, expect_any)

    # --- 5. recuperable: el hash de la cabecera es el del fichero real -------
    out, _ = run([z, "--json=compact", "--provenance", "--max-columns", "40", "HIT", LONG])
    digest = base64.urlsafe_b64encode(hashlib.sha256(data_of(LONG)).digest()).decode().rstrip("=")
    hdr = [json.loads(l) for l in out.decode().split("\n")[:-1] if '"sha256_b64u"' in l]
    check(len(hdr) == 1 and hdr[0]["sha256_b64u"] == digest,
          "provenance: el sha256 de la cabecera es el del fichero real",
          f"{hdr[0]['sha256_b64u'] if hdr else None} vs {digest}")

    # --- 6. W descomunal == sin la bandera, byte a byte ----------------------
    for path, args in ((LONG, ["HIT", LONG]), (MULTI, ["-C1", "HIT", MULTI])):
        a, _ = run([z, "--json=compact", "--sort", *args])
        b, _ = run([z, "--json=compact", "--sort", "--max-columns", str(HUGE), *args])
        check(a == b, f"W descomunal == sin bandera ({path})", f"{len(a)} vs {len(b)} bytes")
        check(b"win_start" not in a, f"sin bandera no aparece win_start ({path})")

    # --- 7. uso: solo con JSON, valor positivo, y es de la llamada -----------
    out, rc = run([z, "--max-columns", "40", "HIT", LONG])
    check(rc == 2 and out == b"", "uso: --max-columns sin --json es error rc 2")
    for bad in ("0", "xx", "-1", ""):
        out, rc = run([z, "--json", f"--max-columns={bad}", "HIT", LONG])
        check(rc == 2 and out == b"", f"uso: --max-columns={bad!r} es error rc 2")
    out, rc = run([z, "--json", "--max-columns=40", "HIT", LONG])
    check(rc in (0, 1) and out != b"", "uso: --max-columns=40 con --json funciona")

    # En lote: de la llamada funciona; dentro de "flags" se rechaza.
    q_call = (json.dumps({"id": "long", "pattern": "HIT", "paths": [LONG], "flags": ["-C1"]}) + "\n").encode()
    out, rc = run([z, "--json=compact", "--sort", "--max-columns", "40", "--queries-file", "-"], q_call)
    recs, _ = decode_compact(out.decode().split("\n")[:-1])
    check(any(r["win_start"] is not None for r in recs if r["type"] in TYPES),
          "lote: la ventana de la llamada se aplica a las consultas")
    q_flag = (json.dumps({"id": "long", "pattern": "HIT", "paths": [LONG], "flags": ["--max-columns=40"]}) + "\n").encode()
    out, rc = run([z, "--json=compact", "--sort", "--queries-file", "-"], q_flag)
    end = [json.loads(l) for l in out.decode().split("\n")[:-1] if '"query_end"' in l]
    check(rc == 2 and end and end[0]["rc"] == 2 and "per call" in end[0]["error"],
          "lote: una consulta no puede pedir la ventana en flags")

    # --- ahorro real de bytes con el recorte (invariante, no claim de tokens) -
    plain, _ = run([z, "--json=compact", "--sort", "HIT", LONG])
    cut, _ = run([z, "--json=compact", "--sort", "--max-columns", "40", "HIT", LONG])
    check(len(cut) < len(plain), f"recorte: la salida pesa menos ({len(plain)} -> {len(cut)} bytes)")

    print(f"TOTAL {passed} pass / {failed} fail")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
