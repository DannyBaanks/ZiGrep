#!/usr/bin/env python3
"""Diferencial texto <-> JSON de `--json` (M1 del plan agent-native).

Para cada caso corre la MISMA busqueda dos veces: en modo texto y con `--json`.
Después:

  1. cada evento JSON declara el schema `zgrep/1` (si no, el evento es inválido);
  2. el conjunto ORDENADO de (path, line, text) de los eventos reproduce exactamente
     las líneas de la salida de texto (mismo orden, mismos datos);
  3. los eventos con span se verifican contra el FICHERO real: los bytes
     `data[byte_start..byte_end]` son exactamente el `match` declarado. Un offset
     inventado no sobrevive a esta prueba.

Uso:  python3 evidence/feature-corpus/json_conformance.py [--zgrep RUTA]
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*m")
LINE_RE = re.compile(r"^(?P<path>.+?)(?P<sep>[:-])(?P<num>\d+)(?P=sep)(?P<text>.*)$", re.S)
# `--heading` consume el path en su propia linea: las de match quedan "N:TEXT".
NOPATH_RE = re.compile(r"^(?P<num>\d+)(?P<sep>[:-])(?P<text>.*)$", re.S)
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIX = Path(__file__).resolve().parent

# Un fichero del corpus congelado que exista de verdad (el corpus no tiene
# f00001.txt: se elige uno con el needle plantado, no un nombre adivinado).
def _corpus_file() -> str:
    out = subprocess.run(
        ["grep", "-rl", "ZGREP_PLANTED_TOKEN", str(ROOT / "bench-corpus" / "corpus_1000")],
        cwd=ROOT, capture_output=True, text=True,
    ).stdout.splitlines()
    assert out, "el corpus no tiene el needle plantado"
    return out[0]

CORPUS_FILE = _corpus_file()

# Casos: (nombre, argv sin el binario). `-H` fuerza el path para que la salida de
# texto tenga una forma única y parseable; `-n` fija el número de línea.
CASES = [
    # --- lo básico ---
    ("basica",              ["-n", "-H", "HIT", "a.txt"]),
    ("ignore-case",         ["-n", "-H", "-i", "hit", "a.txt"]),
    ("word-regexp",         ["-n", "-H", "-w", "HIT", "a.txt"]),
    ("fixed",               ["-n", "-H", "-F", "HIT", "a.txt"]),
    ("line-regexp",         ["-n", "-H", "-x", "HIT", "a.txt"]),
    ("invert",              ["-n", "-H", "-v", "HIT", "a.txt"]),
    ("dos_patrones",        ["-n", "-H", "-e", "HIT", "-e", "one", "a.txt"]),
    ("patrones_de_fichero", ["-n", "-H", "-f", "pats", "a.txt"]),
    ("multi_fichero",       ["-n", "-H", "HIT", "a.txt", "b.txt"]),
    ("recursivo",           ["-n", "-H", "--sort", "-r", "HIT", "."]),
    ("stdin",               ["-n", "-H", "HIT"]),          # se alimenta con a.txt
    ("stdin_pipe",          ["-n", "-H", "zzz"]),          # sin match: rc 1
    ("inexistente",         ["-n", "-H", "-s", "HIT", "no.txt"]),
    # --- contexto ---
    ("A1B1",                ["-n", "-H", "-A1", "-B1", "HIT", "a.txt"]),
    ("A2B2_dos_ficheros",   ["-n", "-H", "--sort", "-A2", "-B2", "HIT", "a.txt", "b.txt"]),
    ("C2",                  ["-n", "-H", "-C2", "HIT", "a.txt"]),
    ("context_largo",       ["-n", "-H", "--context=1", "HIT", "a.txt"]),
    ("m1_A2",               ["-n", "-H", "-m1", "-A2", "HIT", "a.txt"]),
    ("A999_borde",          ["-n", "-H", "-A999", "HIT", "a.txt"]),
    ("B999_borde",          ["-n", "-H", "-B999", "HIT", "a.txt"]),
    # --- modos de fichero y recuento ---
    ("files_with",          ["-l", "-H", "HIT", "a.txt", "b.txt"]),
    ("files_without",       ["-L", "-H", "zzz", "a.txt", "b.txt"]),
    ("count_lineas",        ["-c", "-H", "HIT", "a.txt", "b.txt"]),
    ("count_matches",       ["--count-matches", "-H", "-o", "HIT", "o.txt"]),
    ("quiet",               ["-q", "HIT", "a.txt"]),
    # --- spans ---
    ("only_matching",       ["-n", "-H", "-o", "HIT", "a.txt"]),
    ("column",              ["-n", "-H", "--column", "HIT", "a.txt"]),
    ("color_always",        ["-n", "-H", "--color=always", "HIT", "a.txt"]),
    ("replace",             ["-n", "-H", "--replace=X", "HIT", "a.txt"]),
    ("replace_con_o",       ["-n", "-H", "-o", "--replace=X", "HIT", "a.txt"]),
    ("passthru",            ["-n", "-H", "--passthru", "HIT", "a.txt"]),
    ("multiline",           ["-n", "-H", "-U", "HIT", "a.txt"]),
    ("crlf",                ["-n", "-H", "--crlf", "HIT", "a.txt"]),
    ("null_data",           ["-n", "-H", "-z", "HIT", "a.txt"]),
    ("vimgrep",             ["-H", "--vimgrep", "HIT", "a.txt"]),
    ("heading",             ["-n", "-H", "--heading", "HIT", "a.txt", "b.txt"]),
    # --- corpus congelado (offsets verificados contra el fichero real) ---
    ("corpus_listado",      ["-l", "--sort", "ZGREP_PLANTED_TOKEN", str(ROOT / "bench-corpus" / "corpus_1000")]),
    ("corpus_contexto",     ["-n", "-A2", "-B2", "--sort", "ZGREP_RARE_TOKEN", str(ROOT / "bench-corpus" / "corpus_1000")]),
    ("corpus_un_fichero",    ["-n", "-H", "ZGREP_PLANTED_TOKEN", CORPUS_FILE]),
    ("corpus_o",            ["-o", "-n", "-H", "-m5", "ZGREP_PLANTED_TOKEN", CORPUS_FILE]),
    ("corpus_contexto_un",  ["-n", "-H", "-C1", "ZGREP_PLANTED_TOKEN", CORPUS_FILE]),
    ("corpus_count",        ["-c", "-H", "ZGREP_PLANTED_TOKEN", CORPUS_FILE]),
    ("corpus_bre",          ["-n", "-H", "-G", "ZGREP_\\(PLANTED\\)\\?_TOKEN", CORPUS_FILE]),
    ("corpus_vimgrep",      ["-H", "--vimgrep", "-m3", "ZGREP_PLANTED_TOKEN", CORPUS_FILE]),
    ("tipo_txt",            ["-n", "-H", "-t", "txt", "HIT", "a.txt"]),
]


def run(argv: list[str], stdin_bytes: bytes | None = None) -> tuple[bytes, int]:
    p = subprocess.run(argv, cwd=FIX, input=stdin_bytes, capture_output=True)
    return p.stdout, p.returncode


def text_records(out: bytes, mode: str, sep_nul: bool = False, column_mode: bool = False) -> list[tuple]:
    """Convierte la salida de texto en tuplas comparables con los eventos JSON."""
    recs = []
    texto = ANSI.sub("", out.decode("utf-8", "replace"))
    # `-z`: los registros van separados por NUL (un registro puede contener
    # \n), asi que se parten por NUL y NO por \n.
    registros = texto.split("\x00") if sep_nul else texto.splitlines()
    for raw in registros:
        if raw == "" or raw == "--":
            continue  # decoración: separador de contexto
        if mode == "files":
            recs.append((raw,))
            continue
        if mode == "count":
            path, _, n = raw.rpartition(":")
            recs.append((path, int(n)))
            continue
        # líneas: [path<sep>N<sep>text]; el separador es ':' salvo en contexto,
        # que es '-'. Regex con retro-referencia: el MISMO separador aparece dos
        # veces, y el path es no-codicioso. (La version anterior trufailed aqui:
        # "bench-corpus" tiene un guion y el partition('-') partia el path.)
        m = LINE_RE.match(raw) or NOPATH_RE.match(raw)
        if not m:
            continue  # cabecera de --heading u otra decoración
        path = m.groupdict().get("path", "")
        num, text = m.group("num"), m.group("text")
        if column_mode:
            # path:N:COL:text
            col, sep3, text2 = text.partition(":")
            if sep3 and col.isdigit():
                text = text2
        recs.append((path, int(num), text))
    return recs


def json_events(out: bytes) -> list[dict]:
    evs = []
    for line in out.decode("utf-8", "replace").splitlines():
        if not line.strip():
            continue
        ev = json.loads(line)
        assert ev.get("schema") == "zgrep/1", f"schema inválido: {ev.get('schema')!r}"
        evs.append(ev)
    return evs


def event_records(evs: list[dict]) -> list[tuple]:
    recs = []
    for ev in evs:
        if ev["type"] == "file":
            recs.append((ev["path"],))
        elif ev["type"] == "count":
            recs.append((ev["path"], ev.get("lines") if ev.get("lines") is not None else ev.get("matches")))
        else:
            recs.append((ev["path"], ev["line"], ev["text"]))
    return recs


COLUMN_CASES = {"column", "vimgrep", "column_mode", "corpus_vimgrep"}
NUL_CASES = {"null_data"}
PATHLESS_CASES = {"heading"}

MODE_OF = {
    "files_with": "files", "files_without": "files", "corpus_listado": "files",
    "count_lineas": "count", "count_matches": "count", "corpus_count": "count",
}
DEFAULT_MODE = "lines"


def check_offsets(evs: list[dict]) -> list[str]:
    """Los eventos con span se verifican contra el fichero real."""
    bad = []
    for ev in evs:
        if ev.get("byte_start") is None:
            continue
        path = Path(FIX / ev["path"])
        if not path.is_file():
            continue  # stdin o ruta no local: sin verificación posible
        data = path.read_bytes()
        b0, b1 = ev["byte_start"], ev["byte_end"]
        if data[b0:b1] != ev["match"].encode():
            bad.append(f"{ev['path']}: bytes {b0}..{b1} = {data[b0:b1]!r}, match declarado {ev['match']!r}")
    return bad


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zgrep", default=str(ROOT / "zig-out" / "bin" / "zgrep"))
    args = ap.parse_args()
    Z = args.zgrep

    stdin_data = (FIX / "a.txt").read_bytes()
    npass = nfail = 0
    for name, argv in CASES:
        feed = stdin_data if name.startswith("stdin") else None
        mode = MODE_OF.get(name, DEFAULT_MODE)
        text_out, text_rc = run([Z] + argv, feed)
        json_out, json_rc = run([Z] + argv + ["--json"], feed)
        try:
            evs = json_events(json_out)
        except (json.JSONDecodeError, AssertionError) as e:
            print(f"FAIL {name:<22} JSON inválido: {e}")
            nfail += 1
            continue
        trecs = text_records(text_out, mode, name in NUL_CASES, name in COLUMN_CASES)
        jrecs = event_records(evs)
        if name in PATHLESS_CASES:
            trecs = [r[1:] if len(r) > 1 else r for r in trecs]
            jrecs = [r[1:] if len(r) > 1 else r for r in jrecs]
        bad = check_offsets(evs)
        ok_order = trecs == jrecs
        ok_sorted = sorted(map(repr, trecs)) == sorted(map(repr, jrecs))
        if ok_order and not bad and text_rc == json_rc:
            npass += 1
            print(f"PASS {name:<22} ({len(evs)} eventos)")
        else:
            nfail += 1
            print(f"FAIL {name:<22}")
            if not ok_order:
                print(f"     texto : {trecs[:6]}{'...' if len(trecs) > 6 else ''}")
                print(f"     json  : {jrecs[:6]}{'...' if len(jrecs) > 6 else ''}")
                print(f"     mismo conjunto, otro orden: {ok_sorted}")
            for b in bad[:3]:
                print(f"     offset: {b}")
            if text_rc != json_rc:
                print(f"     rc: texto={text_rc} json={json_rc}")
    print(f"\nTOTAL {npass} pass / {nfail} fail")
    return 1 if nfail else 0


if __name__ == "__main__":
    sys.exit(main())
