#!/usr/bin/env python3
"""A/B intercalado de M4: el binario ANTES de M4 (A) contra el de M4 (B), en los
modos que M4 no debe encarecer (texto y --json sin --provenance), y el coste de
--provenance en B. Cada repeticion corre A y B alternados (ABAB...) para que la
carga del host caiga igual en los dos. Se publica mediana e IQR por config; la
lectura "dentro del ruido" la decide el solapamiento de IQR, no un umbral fijo.
Uso: python3 evidence/agent-native/m4/perf_ab.py --a BIN_PRE_M4 [--b BIN] [--reps 21]"""
import argparse, statistics, subprocess, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]
C1000 = "bench-corpus/corpus_1000"
WORK = {
    "texto -l needle": ["-l", "ZGREP_PLANTED_TOKEN", C1000],
    "texto -n rare": ["-n", "ZGREP_RARE_TOKEN", C1000],
    "texto -c needle": ["-c", "ZGREP_PLANTED_TOKEN", C1000],
    "json needle (todos los ficheros)": ["--json", "ZGREP_PLANTED_TOKEN", C1000],
    "json rare (3 ficheros)": ["--json", "ZGREP_RARE_TOKEN", C1000],
}
PROV = {
    "json+provenance needle (todos)": ["--json", "--provenance", "ZGREP_PLANTED_TOKEN", C1000],
    "json+provenance rare (3)": ["--json", "--provenance", "ZGREP_RARE_TOKEN", C1000],
}
def t(cmd):
    t0 = time.perf_counter(); subprocess.run(cmd, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); return time.perf_counter() - t0
def q(xs):
    xs = sorted(xs); n = len(xs)
    return statistics.median(xs), xs[n // 4], xs[(3 * n) // 4]
ap = argparse.ArgumentParser(); ap.add_argument("--a", required=True); ap.add_argument("--b", default=str(ROOT / "zig-out/bin/zgrep")); ap.add_argument("--reps", type=int, default=21)
a = ap.parse_args()
ver = lambda b: subprocess.run([b, "--version"], capture_output=True, text=True).stdout.strip()
print(f"A={a.a} ({ver(a.a)})\nB={a.b} ({ver(a.b)})\nreps={a.reps}, A/B intercalados, 3 de calentamiento")
print(f"{'config':<34} {'A mediana [IQR] ms':>26} {'B mediana [IQR] ms':>26}  B/A   IQR solapan")
for name, args in WORK.items():
    for _ in range(3): t([a.a] + args); t([a.b] + args)
    A, B = [], []
    for _ in range(a.reps):
        A.append(t([a.a] + args)); B.append(t([a.b] + args))
    (ma, la, ha), (mb, lb, hb) = q(A), q(B)
    overlap = not (hb < la or lb > ha)
    print(f"{name:<34} {ma*1e3:8.2f} [{la*1e3:6.2f},{ha*1e3:6.2f}] {mb*1e3:8.2f} [{lb*1e3:6.2f},{hb*1e3:6.2f}]  {mb/ma:4.2f}  {'si' if overlap else 'NO'}")
print("\ncoste de --provenance en B (misma busqueda sin la bandera = base):")
for name, args in PROV.items():
    base = [x for x in args if x != "--provenance"]
    for _ in range(3): t([a.b] + base); t([a.b] + args)
    X, Y = [], []
    for _ in range(a.reps):
        X.append(t([a.b] + base)); Y.append(t([a.b] + args))
    (mx, lx, hx), (my, ly, hy) = q(X), q(Y)
    print(f"{name:<34} sin {mx*1e3:7.2f} ms  con {my*1e3:7.2f} ms  x{my/mx:4.2f}")
