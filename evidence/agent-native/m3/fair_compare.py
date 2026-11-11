#!/usr/bin/env python3
"""Comparacion justa del lote: la MISMA salida (JSON ordenado) como N procesos
separados frente a UNA llamada con --queries-file, y como referencia N procesos
de texto en streaming (lo que hace el arnes task-level). Mediana de --reps.
Uso: python3 evidence/agent-native/m3/fair_compare.py [--reps 5]"""
import argparse, json, statistics, subprocess, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]
Z = str(ROOT / "zig-out" / "bin" / "zgrep")
CORPUS = "bench-corpus/corpus_1000"
QF = "evidence/agent-native/queries/phrase_survey.jsonl"
PH = [json.loads(l)["pattern"] for l in (ROOT / QF).read_text().splitlines() if l.strip()]
CONFIGS = {
    "N x texto streaming (-n -F)": [[Z, "-n", "-F", p, CORPUS] for p in PH],
    "N x --json (streaming)": [[Z, "--json", "-F", "-e", p, "--", CORPUS] for p in PH],
    "N x --json --sort (= salida del lote)": [[Z, "--json", "--sort", "-F", "-e", p, "--", CORPUS] for p in PH],
    "1 x --queries-file": [[Z, "--queries-file", QF, CORPUS]],
}
ap = argparse.ArgumentParser(); ap.add_argument("--reps", type=int, default=5); reps = ap.parse_args().reps
print(f"zgrep: {subprocess.run([Z, '--version'], capture_output=True, text=True).stdout.strip()}  consultas={len(PH)}  reps={reps}")
for name, cmds in CONFIGS.items():
    walls, nbytes = [], 0
    for _ in range(reps):
        t0 = time.perf_counter(); nbytes = 0
        for c in cmds:
            nbytes += len(subprocess.run(c, cwd=ROOT, capture_output=True).stdout)
        walls.append(time.perf_counter() - t0)
    print(f"{name:<40} procesos={len(cmds):>3}  muro_mediana_s={statistics.median(walls):.4f}  bytes={nbytes}")
