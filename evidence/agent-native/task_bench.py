#!/usr/bin/env python3
"""M0 del plan agent-native: benchmark TASK-LEVEL (control, sin tocar el motor).

La metrica no es GB/s. Es la del plan:

    cuanto trabajo correcto completa un agente, con cuantos comandos,
    cuanto tiempo de pared y cuantos bytes de salida (proxy de tokens).

Corpus CONGELADO y versionado: bench-corpus/corpus_1000 (1000 ficheros,
32.795.967 bytes, semilla 20261108) con su .truth al lado. La correccion se
comprueba contra el .truth cuando el truth fija el numero, y contra grep
como implementacion de referencia cuando no (marcado ref=grep en la tabla).

Uso:  python3 evidence/agent-native/task_bench.py [--tool all|zgrep|grep|rg]
      [--reps 3] [--out evidence/agent-native/baseline]
"""
from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CORPUS = "bench-corpus/corpus_1000"
NEEDLE = "ZGREP_PLANTED_TOKEN"
RARE = "ZGREP_RARE_TOKEN"
ABSENT = "ZGREP_ABSENT_TOKEN"

ZGREP = str(ROOT / "zig-out" / "bin" / "zgrep")

# Configuraciones medibles. "zgrep_nn" es el MISMO binario con --no-line-number:
# existe para cuantificar, en el baseline, lo que la decision de M2 cambiaria.
CONFIGS = {
    "zgrep": lambda c: [ZGREP] + c,
    "zgrep_nn": lambda c: [ZGREP, "--no-line-number"] + c,
    "grep": lambda c: ["grep"] + c,
    "rg": lambda c: ["rg", "--no-ignore"] + c,
}

# Cada tarea = lo que un agente escribiria para resolverla. "calls" = numero de
# comandos que emite (un pipeline cuenta como una linea del agente).
# ref = ("truth", valor) cuando el .truth lo fija, o ("grep", [comandos])
# cuando la referencia es la salida de GNU grep.
TASKS = {
    "files_with_needle": {
        "help": "listar los ficheros que contienen el token plantado",
        "zgrep": [["-l", NEEDLE, CORPUS]],
        "grep": [["-rl", NEEDLE, CORPUS]],
        "rg": [["--no-ignore", "-l", NEEDLE, CORPUS]],
        "ref": ("truth", 1000),
        "normalize": "lines",
    },
    "count_matching_lines": {
        "help": "contar lineas coincidentes por fichero y sumar",
        "zgrep": [["-c", NEEDLE, CORPUS]],
        "grep": [["-rc", NEEDLE, CORPUS]],
        "rg": [["--no-ignore", "-c", NEEDLE, CORPUS]],
        "ref": ("truth", 48907),
        "normalize": "sum_counts",
    },
    "rare_files": {
        "help": "los 3 ficheros con el token raro",
        "zgrep": [["-l", RARE, CORPUS]],
        "grep": [["-rl", RARE, CORPUS]],
        "rg": [["--no-ignore", "-l", RARE, CORPUS]],
        "ref": ("truth", 3),
        "normalize": "lines",
    },
    "rare_call_sites": {
        "help": "donde esta el token raro, con numero de linea",
        "zgrep": [["-n", RARE, CORPUS]],
        "grep": [["-rn", RARE, CORPUS]],
        "rg": [["--no-ignore", "-n", RARE, CORPUS]],
        "ref": ("grep", [["grep", "-rn", RARE, CORPUS]]),
        "normalize": "sorted_lines_no_numbers",
    },
    "absent_token": {
        "help": "confirmar que el token ausente no aparece (rc debe ser 1)",
        "zgrep": [[ABSENT, CORPUS]],
        "grep": [["-r", ABSENT, CORPUS]],
        "rg": [["--no-ignore", ABSENT, CORPUS]],
        "ref": ("truth", 0),
        "normalize": "lines",
    },
    "context_audit": {
        "help": "auditar un sitio: 2 lineas de contexto arriba y abajo",
        "zgrep": [["-n", "-A2", "-B2", RARE, CORPUS]],
        "grep": [["-rn", "-A2", "-B2", RARE, CORPUS]],
        "rg": [["--no-ignore", "-n", "-A2", "-B2", RARE, CORPUS]],
        "ref": ("grep", [["grep", "-rn", "-A2", "-B2", RARE, CORPUS]]),
        "normalize": "sorted_context",
    },
    "two_patterns": {
        "help": "dos patrones en una pasada (union)",
        "zgrep": [["-e", NEEDLE, "-e", RARE, "-l", CORPUS]],
        "grep": [["-rl", "-e", NEEDLE, "-e", RARE, CORPUS]],
        "rg": [["--no-ignore", "-e", NEEDLE, "-e", RARE, "-l", CORPUS]],
        "ref": ("truth", 1000),
        "normalize": "lines",
    },
    "word_boundary_occurrences": {
        "help": "ocurrencias exactas de palabra con -o",
        "zgrep": [["-o", "-E", r"\b" + NEEDLE + r"\b", CORPUS]],
        "grep": [["-roE", r"\b" + NEEDLE + r"\b", CORPUS]],
        "rg": [["--no-ignore", "-o", r"\b" + NEEDLE + r"\b", CORPUS]],
        "ref": ("grep", [["grep", "-roE", r"\b" + NEEDLE + r"\b", CORPUS]]),
        "normalize": "count_lines",
    },
}


def run(cmd: list[str]) -> tuple[bytes, int]:
    p = subprocess.run(cmd, cwd=ROOT, capture_output=True)
    return p.stdout, p.returncode


def normalize(out: bytes, how: str) -> object:
    lines = out.decode("utf-8", "replace").splitlines()
    if how == "lines":
        return sorted(lines)
    if how == "sorted_lines_no_numbers":
        return sorted(l.split(":", 2)[-1] if ":" in l else l for l in lines)
    if how == "sorted_context":
        return sorted(lines)
    if how == "count_lines":
        return len(lines)
    if how == "sum_counts":
        total = 0
        for l in lines:
            total += int(l.rsplit(":", 1)[-1] or 0)
        return total
    raise ValueError(how)


def reference(task: dict) -> object:
    kind, val = task["ref"]
    if kind == "truth":
        return val
    out, _ = run(val[0])
    return normalize(out, task["normalize"])


def metric(ans: object, task: dict) -> object:
    """El truth fija un NUMERO; si la respuesta es una lista, su metrica es el
    numero de elementos (para counts/sum_count el normalizador ya devuelve el
    numero). Comparar lista contra entero fue el bug de la primera corrida:
    las 4 tareas con ref truth daban NO para las tres herramientas."""
    if isinstance(ans, list):
        return len(ans)
    return ans


# "zgrep_nn" no redefine tareas: usa las de "zgrep" y les añade el flag.
TASK_KEY = {"zgrep": "zgrep", "zgrep_nn": "zgrep", "grep": "grep", "rg": "rg"}


def measure(task: dict, tool: str, reps: int) -> dict:
    cmds = [CONFIGS[tool](c) for c in task[TASK_KEY[tool]]]
    ref = reference(task)
    walls, answers, bytses, rcs = [], [], [], []
    for _ in range(reps):
        t0 = time.perf_counter()
        got = []
        for c in cmds:
            out, rc = run(c)
            bytses.append(len(out))
            rcs.append(rc)
            got = normalize(out, task["normalize"])
        walls.append(time.perf_counter() - t0)
        answers.append(got)
    # Ref truth -> se compara la METRICA (un numero). Ref grep -> se compara la
    # respuesta normalizada completa (lista). Aplicar metric() a las dos era el
    # bug: comparaba un entero contra una lista y fallaba hasta grep.
    ref_kind = task["ref"][0]
    if ref_kind == "truth":
        ok = all(metric(a, task) == ref for a in answers)
    else:
        ok = all(a == ref for a in answers)
    return {
        "calls": len(cmds),
        "wall_s_median": round(statistics.median(walls), 4),
        "out_bytes_total": sum(bytses),
        "correct": ok,
        "rc_set": sorted(set(rcs)),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tool", default="all")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--out", default="evidence/agent-native/baseline")
    args = ap.parse_args()

    tools = ["zgrep", "zgrep_nn", "grep", "rg"] if args.tool == "all" else [args.tool]
    results = {}
    for tool in tools:
        probe = CONFIGS[tool](["--version"])
        ver = subprocess.run(
            probe, cwd=ROOT, capture_output=True, text=True,
        ).stdout.strip().splitlines()[:1]
        results[tool] = {"version": ver[0] if ver else "?", "tasks": {}}
        for name, task in TASKS.items():
            m = measure(task, tool, args.reps)
            m["ref_kind"] = task["ref"][0]
            results[tool]["tasks"][name] = m

    outdir = ROOT / args.out
    outdir.mkdir(parents=True, exist_ok=True)
    payload = {
        "plan": "zigrep-agent-native M0 (control)",
        "corpus": CORPUS,
        "corpus_truth": (ROOT / (CORPUS + ".truth")).read_text().splitlines(),
        "reps": args.reps,
        "note": ("wall = mediana del muro de la tarea completa; calls = comandos que "
                 "emite el agente; out_bytes = bytes de stdout (proxy de tokens); "
                 "correct = respuesta igual a la referencia (truth o grep)."),
        "results": results,
    }
    (outdir / "task_bench.json").write_text(json.dumps(payload, indent=2) + "\n")

    print(f"{'tarea':<28} {'herramienta':<8} {'llam':>4} {'muro s':>8} {'bytes':>9}  ok")
    for name in TASKS:
        for tool in tools:
            t = results[tool]["tasks"][name]
            print(f"{name:<28} {tool:<8} {t['calls']:>4} {t['wall_s_median']:>8.3f} "
                  f"{t['out_bytes_total']:>9}  {'SI' if t['correct'] else 'NO'}")
    print(f"\ncrudo: {outdir / 'task_bench.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
