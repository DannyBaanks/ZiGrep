#!/usr/bin/env python3
"""M8: lo que cuesta --spill, para decidir si va por defecto. A/B intercalado
(con/sin --spill) sobre la MISMA busqueda truncada; mediana e IQR. Sin truncado
el coste es cero por construccion (el fichero se crea al primer omitido) y se
mide igual como control. Uso: python3 evidence/agent-native/m8/spill_cost.py [--reps 15]"""
import argparse, shutil, statistics, subprocess, tempfile, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]
Z = str(ROOT / "zig-out/bin/zgrep")
C = "bench-corpus/corpus_1000"
CASES = {
    "trunca fuerte: -o needle (~11 MB omitidos), --max-results 10": ["--json", "-o", "-E", r"\bZGREP_PLANTED_TOKEN\b", C, "--max-results", "10"],
    "trunca compacto: -o needle, --max-results 10": ["--json=compact", "-o", "-E", r"\bZGREP_PLANTED_TOKEN\b", C, "--max-results", "10"],
    "sin truncado (control): rare, --max-results 100": ["--json", "ZGREP_RARE_TOKEN", C, "--max-results", "100"],
}
def t(cmd):
    t0 = time.perf_counter(); subprocess.run(cmd, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); return time.perf_counter() - t0
def q(xs):
    xs = sorted(xs); return statistics.median(xs), xs[len(xs)//4], xs[(3*len(xs))//4]
ap = argparse.ArgumentParser(); ap.add_argument("--reps", type=int, default=15); a = ap.parse_args()
print(f"zgrep: {subprocess.run([Z,'--version'],capture_output=True,text=True).stdout.strip()}; reps={a.reps}, A/B intercalados")
for name, args in CASES.items():
    d = Path(tempfile.mkdtemp(prefix="spillcost-"))
    A, B = [], []
    for i in range(3 + a.reps):
        x = t([Z, *args]); y = t([Z, *args, f"--spill={d}"])
        if i >= 3: A.append(x); B.append(y)
    size = sum(f.stat().st_size for f in d.iterdir()) // max(1, len(list(d.iterdir())))
    shutil.rmtree(d)
    (ma, la, ha), (mb, lb, hb) = q(A), q(B)
    print(f"{name}\n   sin --spill {ma*1e3:7.2f} ms [{la*1e3:.2f},{ha*1e3:.2f}]   con --spill {mb*1e3:7.2f} ms [{lb*1e3:.2f},{hb*1e3:.2f}]   x{mb/ma:.2f}   spill medio {size} bytes")
