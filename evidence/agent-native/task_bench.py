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

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tokcount  # noqa: E402

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
    # M3: el mismo binario en modo lote. Solo corre las tareas que definen
    # una variante "zgrep_batch"; las demas no tienen nada que agrupar.
    "zgrep_batch": lambda c: [ZGREP] + c,
    # M5: el estado final como lo usaria un agente. Mismas tareas que "zgrep",
    # salida estructurada; "_prov" ademas con la procedencia verificable (M4).
    "zgrep_json": lambda c: [ZGREP, "--json"] + c,
    "zgrep_json_prov": lambda c: [ZGREP, "--json", "--provenance"] + c,
    # M5b: el dialecto compacto (zgrep/1c), misma informacion que zgrep/1.
    "zgrep_compact": lambda c: [ZGREP, "--json=compact"] + c,
    "zgrep_compact_prov": lambda c: [ZGREP, "--json=compact", "--provenance"] + c,
    "zgrep_batch_compact": lambda c: [ZGREP, "--json=compact"] + c,
}

# Cada tarea = lo que un agente escribiria para resolverla. "calls" = numero de
# comandos que emite (un pipeline cuenta como una linea del agente).
# ref = ("truth", valor) cuando el .truth lo fija, o ("grep", [comandos])
# cuando la referencia es la salida de GNU grep.
# M3: el MISMO fichero que lee `zgrep_batch`, para que las tres herramientas y el
# lote busquen exactamente las mismas frases.
SURVEY_FILE = "evidence/agent-native/queries/phrase_survey.jsonl"
SURVEY = [json.loads(l)["pattern"] for l in (ROOT / SURVEY_FILE).read_text().splitlines() if l.strip()]

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
    # M3: un agente que audita N frases. Sin lote son N llamadas; con
    # --queries-file es una. La evidencia debe ser la misma: el conjunto de
    # (consulta, fichero, linea), comparado contra GNU grep.
    "phrase_survey": {
        "help": "donde aparece cada una de N frases (N consultas)",
        "zgrep": [["-n", "-F", p, CORPUS] for p in SURVEY],
        "zgrep_batch": [["--queries-file", SURVEY_FILE, CORPUS]],
        "grep": [["-rnF", p, CORPUS] for p in SURVEY],
        "rg": [["--no-ignore", "-n", "-F", p, CORPUS] for p in SURVEY],
        "ref": ("grep_calls", [["grep", "-rnF", p, CORPUS] for p in SURVEY]),
        "normalize": "survey",
    },
}


def run(cmd: list[str]) -> tuple[bytes, int]:
    p = subprocess.run(cmd, cwd=ROOT, capture_output=True)
    return p.stdout, p.returncode


class InvalidJsonStream(Exception):
    pass


def json_events(out: bytes) -> list[dict]:
    """Eventos de busqueda de una salida JSON, en cualquiera de los dos
    dialectos: zgrep/1 tal cual, o zgrep/1c decodificado con el decodificador
    de referencia de compact_conformance.py. Una linea invalida = fallo."""
    lines = out.decode("utf-8", "replace").splitlines()
    try:
        if lines and json.loads(lines[0]) == {"schema": "zgrep/1c"}:
            import compact_conformance
            recs, _ = compact_conformance.decode_compact(lines)
            return recs
        return [json.loads(l) for l in lines]
    except (json.JSONDecodeError, ValueError, KeyError, IndexError, AssertionError) as e:
        raise InvalidJsonStream(repr(e)[:80])


def json_as_text(out: bytes) -> bytes:
    """M5: los eventos zgrep/1 como las lineas de texto que les corresponden
    (las que imprimiria `grep -n`), para medir la correccion del modo JSON con
    la MISMA referencia que las herramientas de texto. Los eventos de control
    (provenance, query_end, summary) no son respuesta y no aparecen."""
    lines = []
    # Una linea que no es evento en modo JSON es un FALLO de contrato, nunca
    # algo que se tolera o se descarta (un "--" colado asi paso desapercibido
    # hasta M5): json_events lanza InvalidJsonStream.
    for e in json_events(out):
        t = e["type"]
        if t == "file":
            lines.append(e["path"])
        elif t == "count":
            lines.append(f"{e['path']}:{e['lines'] if e['lines'] is not None else e['matches']}")
        elif t in ("match", "passthru"):
            lines.append(f"{e['path']}:{e['line']}:{e['text']}")
        elif t == "context":
            lines.append(f"{e['path']}-{e['line']}-{e['text']}")
        elif t == "occurrence":
            lines.append(f"{e['path']}:{e['line']}:{e['match']}")
    return ("\n".join(lines) + ("\n" if lines else "")).encode()


def normalize_calls(outs: list[bytes], how: str, json_mode: bool = False) -> object:
    """Normaliza la salida de TODAS las llamadas de la tarea (antes solo se
    miraba la ultima, que con tareas de una llamada daba igual)."""
    if how == "survey":
        found = set()
        for i, out in enumerate(outs):
            if json_mode:
                try:
                    evs = json_events(out)
                except InvalidJsonStream as ex:
                    return ("INVALID_JSON_STREAM", str(ex))
                for e in evs:
                    if e["type"] == "match":
                        qid = e.get("query_id")
                        found.add((int(qid if qid is not None else i), e["path"], e["line"]))
                continue
            for l in out.decode("utf-8", "replace").splitlines():
                if False:
                    pass
                else:
                    path, num, _ = l.split(":", 2)
                    found.add((i, path, int(num)))
        return sorted(found)
    if json_mode:
        try:
            return normalize(b"".join(json_as_text(o) for o in outs), how)
        except InvalidJsonStream as e:
            return ("INVALID_JSON_STREAM", str(e))  # nunca igual a la referencia
    return normalize(b"".join(outs), how)


def normalize(out: bytes, how: str) -> object:
    lines = out.decode("utf-8", "replace").splitlines()
    if how == "lines":
        return sorted(lines)
    if how == "sorted_lines_no_numbers":
        return sorted(l.split(":", 2)[-1] if ":" in l else l for l in lines)
    if how == "sorted_context":
        # Los separadores "--" son decoracion de texto, no evidencia (y en JSON
        # no existen): fuera de la comparacion en las dos partes.
        return sorted(l for l in lines if l != "--")
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
    if kind == "grep_calls":
        return normalize_calls([run(c)[0] for c in val], task["normalize"])
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
TASK_KEY = {"zgrep": "zgrep", "zgrep_nn": "zgrep", "grep": "grep", "rg": "rg", "zgrep_batch": "zgrep_batch",
            "zgrep_json": "zgrep", "zgrep_json_prov": "zgrep",
            "zgrep_compact": "zgrep", "zgrep_compact_prov": "zgrep", "zgrep_batch_compact": "zgrep_batch"}


def measure(task: dict, tool: str, reps: int, tokens: bool = False) -> dict:
    cmds = [CONFIGS[tool](c) for c in task[TASK_KEY[tool]]]
    ref = reference(task)
    walls, answers, bytses, rcs = [], [], [], []
    for _ in range(reps):
        t0 = time.perf_counter()
        outs = []
        for c in cmds:
            out, rc = run(c)
            bytses.append(len(out))
            rcs.append(rc)
            outs.append(out)
        walls.append(time.perf_counter() - t0)
        json_mode = any(x in ("--json", "--json=compact", "--queries-file") for x in cmds[0])
        got = normalize_calls(outs, task["normalize"], json_mode)
        answers.append(got)
        last_outs = outs
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
        # out_bytes_total suma TODAS las repeticiones (reps x llamadas); el
        # proxy de tokens de UNA ejecucion de la tarea es out_bytes_per_rep.
        "out_bytes_total": sum(bytses),
        "out_bytes_per_rep": sum(bytses) // reps,
        "correct": ok,
        "rc_set": sorted(set(rcs)),
        # M5: dispersion del muro, para leer "dentro del ruido" sin umbrales fijos.
        "wall_s_p25": round(sorted(walls)[len(walls) // 4], 4),
        "wall_s_p75": round(sorted(walls)[(3 * len(walls)) // 4], 4),
        # M5: tokens REALES de una ejecucion (BPE, tokcount.py), si se pidieron.
        "tokens_per_rep": sum(tokcount.count(o) for o in last_outs) if tokens else None,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tool", default="all")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--out", default="evidence/agent-native/baseline")
    ap.add_argument("--tokens", action="store_true", help="contar tokens reales (tokcount.py)")
    ap.add_argument("--final", action="store_true",
                    help="M5: todas las configuraciones, tokens reales, 5 reps, publica en evidence/agent-native/task_bench")
    args = ap.parse_args()
    if args.final:
        args.tool, args.tokens = "all", True
        if args.reps == 3:
            args.reps = 5
        if args.out == "evidence/agent-native/baseline":
            args.out = "evidence/agent-native/task_bench"
    if args.tokens and not tokcount.available():
        print(f"tokenizador no disponible: {tokcount.describe()}", file=sys.stderr)
        return 2

    all_tools = ["zgrep", "zgrep_nn", "grep", "rg", "zgrep_batch", "zgrep_json", "zgrep_json_prov",
                 "zgrep_compact", "zgrep_compact_prov", "zgrep_batch_compact"]
    tools = all_tools if args.tool == "all" else [args.tool]
    results = {}
    for tool in tools:
        probe = CONFIGS[tool](["--version"])
        ver = subprocess.run(
            probe, cwd=ROOT, capture_output=True, text=True,
        ).stdout.strip().splitlines()[:1]
        results[tool] = {"version": ver[0] if ver else "?", "tasks": {}}
        for name, task in TASKS.items():
            if TASK_KEY[tool] not in task:
                continue
            m = measure(task, tool, args.reps, args.tokens)
            m["ref_kind"] = task["ref"][0]
            results[tool]["tasks"][name] = m

    outdir = ROOT / args.out
    outdir.mkdir(parents=True, exist_ok=True)
    payload = {
        "plan": "zigrep-agent-native M0 (control)",
        "corpus": CORPUS,
        "corpus_truth": (ROOT / (CORPUS + ".truth")).read_text().splitlines(),
        "reps": args.reps,
        "tokenizer": tokcount.describe() if args.tokens else None,
        "note": ("wall = mediana del muro de la tarea completa; calls = comandos que "
                 "emite el agente; out_bytes_total = bytes de stdout sumados sobre TODAS las reps; out_bytes_per_rep = los de una ejecucion (proxy de tokens); "
                 "correct = respuesta igual a la referencia (truth o grep)."),
        "results": results,
    }
    (outdir / "task_bench.json").write_text(json.dumps(payload, indent=2) + "\n")

    print(f"{'tarea':<26} {'herramienta':<15} {'llam':>4} {'muro s [p25,p75]':>22} {'bytes/rep':>9} {'tokens':>8}  ok")
    for name in TASKS:
        for tool in tools:
            t = results[tool]["tasks"].get(name)
            if t is None:
                continue
            tok = "-" if t["tokens_per_rep"] is None else str(t["tokens_per_rep"])
            print(f"{name:<26} {tool:<15} {t['calls']:>4} {t['wall_s_median']:>7.3f} [{t['wall_s_p25']:.3f},{t['wall_s_p75']:.3f}] "
                  f"{t['out_bytes_per_rep']:>9} {tok:>8}  {'SI' if t['correct'] else 'NO'}")
    print(f"\ncrudo: {outdir / 'task_bench.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
