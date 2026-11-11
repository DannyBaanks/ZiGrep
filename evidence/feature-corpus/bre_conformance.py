#!/usr/bin/env python3
"""Conformance de BRE (-G) contra GNU grep: la prueba pasa argv limpio, sin
los escapes del shell."""
import subprocess, pathlib, shutil

B = pathlib.Path("/tmp/opencode/bre_conf")
if B.exists():
    shutil.rmtree(B)
B.mkdir(parents=True)

import os
Z = os.environ.get("ZGREP_BIN", str(pathlib.Path(__file__).resolve().parents[2] / "zig-out" / "bin" / "zgrep"))
data = "cat\ncot\ncat dog\ncat|dog\nca+t\nab123\nab12+\nfoo_bar\n(bar)\na(b)c\nx{2}y\nxx{2}y\n"
(B / "t.txt").write_text(data)

def run(argv):
    r = subprocess.run(argv, capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr

cases = [
    r"cat\|dog",      # alternacion (en ERE seria una barra literal)
    r"ca\+",          # uno o mas (en ERE un mas literal)
    r"cat)\?x",      # parentesis literal + ? (en ERE error de grupo)
    r"a(b)c",         # parentesis LITERALES
    r"\(ab\)",        # grupo
    r"a\{2\}",        # exactamente 2
    r"[[:digit:]]\+", # clase POSIX + mas literal
    r"[[:digit:]]\{2\}",
    r"x\{2\}y",
    r"foo_bar",
    r"a*",            # a cero o mas
    r"^cat",          # ancla
    r"dog$",          # ancla final
    r"cat dog",
    r"\(cat\)\|dog",
]

ok = bad = 0
for pat in cases:
    g = run(["grep", "-G", pat, str(B / "t.txt")])
    z = run([Z, "-G", pat, str(B / "t.txt")])
    # grep numero de linea por defecto? No: -n off. zgrep imprime numero
    # siempre: comparar el TEXTO sin el prefijo "N:"
    z_lines = [l.split(":", 1)[1] if ":" in l else l for l in z[1].splitlines()]
    g_lines = g[1].splitlines()
    if z_lines == g_lines and g[0] == z[0]:
        ok += 1
        print(f"PASS {pat!r}")
    else:
        bad += 1
        print(f"FAIL {pat!r}")
        print("  grep  :", g[0], g_lines, g[2].strip()[:60])
        print("  zgrep :", z[0], z_lines, z[2].strip()[:60])

print(f"\nTOTAL {ok} pass / {bad} fail")
