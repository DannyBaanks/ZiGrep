#!/usr/bin/env python3
"""M5: genera claims.md DESDE el crudo (task_bench.json). Ningún número de la
tabla está escrito a mano: si el crudo cambia, el veredicto cambia con él.

Regla de cada claim (fija ANTES de mirar los datos, la del plan):
  * "menos llamadas": la mejor config de zgrep usa menos llamadas que la mejor
    de grep/rg en alguna tarea, con respuesta correcta.
  * "menos tokens": por tarea, tokens de la config de zgrep frente al MÍNIMO de
    grep/rg (que emiten texto). Se informa por tarea y en total.
  * "menos pared": mediana de zgrep frente al mínimo de grep/rg; "dentro del
    ruido" si los IQR se solapan.
  * "igual o mejor corrección": todas las configs de zgrep correctas en todas
    las tareas.
Uso: python3 evidence/agent-native/task_bench/make_claims.py
"""
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
d = json.loads((HERE / "task_bench.json").read_text())
R = d["results"]
TASKS = list(R["grep"]["tasks"])
CONTROLS = ["grep", "rg"]
ZG = ["zgrep", "zgrep_json", "zgrep_compact", "zgrep_json_prov", "zgrep_compact_prov", "zgrep_batch", "zgrep_batch_compact"]


def t(tool, task):
    return R.get(tool, {}).get("tasks", {}).get(task)


def best_control(task, key):
    vals = [(t(c, task)[key], c) for c in CONTROLS if t(c, task)]
    return min(vals)


lines = []
w = lines.append
w("# M5 — veredicto de la tesis agent-native (generado desde el crudo)")
w("")
w(f"Crudo: `task_bench.json` (reps={d['reps']}). Tokenizador: {d['tokenizer']['note']} "
  f"(`{Path(d['tokenizer']['model']).name}`). Versiones: " +
  ", ".join(f"{k}=`{v['version']}`" for k, v in R.items() if k in ("zgrep", "grep", "rg")) + ".")
w("")
w("Tokens por tarea, relativos al MEJOR control de texto (grep/rg) de esa tarea. <1 = zgrep gasta menos.")
w("")
hdr = "| tarea | llamadas (control → lote) | mejor control (tokens) | " + " | ".join(ZG) + " |"
w(hdr)
w("|" + "---|" * (3 + len(ZG)))
tot = {z: 0 for z in ZG}
tot_ctrl = 0
cover = {z: True for z in ZG}
for task in TASKS:
    ctrl_tok, ctrl_name = best_control(task, "tokens_per_rep")
    calls_ctrl = t(ctrl_name, task)["calls"]
    calls_b = min((t(z, task)["calls"] for z in ("zgrep_batch", "zgrep_batch_compact") if t(z, task)), default=None)
    cells = []
    for z in ZG:
        m = t(z, task)
        if not m:
            cells.append("—")
            if z not in ("zgrep_batch", "zgrep_batch_compact"):
                cover[z] = False
            continue
        r = m["tokens_per_rep"] / ctrl_tok if ctrl_tok else (1.0 if m["tokens_per_rep"] == 0 else float("inf"))
        cells.append(f"{r:.2f}" + ("" if m["correct"] else " ✗"))
    w(f"| {task} | {calls_ctrl} → {calls_b if calls_b else '—'} | {ctrl_tok} ({ctrl_name}) | " + " | ".join(cells) + " |")
    tot_ctrl += ctrl_tok
    for z in ZG:
        if t(z, task):
            tot[z] += t(z, task)["tokens_per_rep"]
w("")
single = [z for z in ZG if cover[z] and not z.startswith("zgrep_batch")]
w("Total sobre las tareas que cubre cada config (todas, salvo el lote, que solo agrupa phrase_survey): " +
  ", ".join(f"{z} = {tot[z] / tot_ctrl:.2f}x" for z in single) + f" (control = {tot_ctrl} tokens).")
w("")

# --- claims ------------------------------------------------------------
all_ok = all(t(z, task)["correct"] for z in ZG for task in TASKS if t(z, task))
fewer_calls = [(task, t(CONTROLS[0], task)["calls"], min(t(z, task)["calls"] for z in ("zgrep_batch", "zgrep_batch_compact") if t(z, task)))
               for task in TASKS if t("zgrep_batch", task) or t("zgrep_batch_compact", task)]
wins_tok = {z: [task for task in TASKS if t(z, task) and t(z, task)["tokens_per_rep"] < best_control(task, "tokens_per_rep")[0]] for z in ZG}
wall = []
for task in TASKS:
    cm = min((t(c, task)["wall_s_median"], c) for c in CONTROLS)
    c = t(cm[1], task)
    z = t("zgrep", task)
    overlap = not (z["wall_s_p75"] < c["wall_s_p25"] or z["wall_s_p25"] > c["wall_s_p75"])
    wall.append((task, z["wall_s_median"], cm[0], cm[1], z["wall_s_median"] < cm[0] and not overlap, overlap))

w("## Claims")
w("")
w("| claim | estado | dato |")
w("|---|---|---|")
w(f"| menos llamadas | {'DEMOSTRADO' if fewer_calls and all(b < a for _, a, b in fewer_calls) else 'NO_DEMONSTRATED'} | " +
  "; ".join(f"{task}: {a} → {b}" for task, a, b in fewer_calls) + " (lote; en tareas de una sola llamada no hay nada que agrupar) |")
w(f"| igual o mejor corrección | {'DEMOSTRADO' if all_ok else 'REFUTADO'} | todas las configs de zgrep correctas en {len(TASKS)}/{len(TASKS)} tareas contra el .truth o GNU grep |")
for z in ("zgrep_json", "zgrep_compact"):
    ratio = tot[z] / tot_ctrl
    state = "DEMOSTRADO" if ratio < 1 else ("REFUTADO" if not wins_tok[z] else "PARCIAL")
    w(f"| menos tokens que el texto ({z}) | {state} | total {ratio:.2f}x el mejor control; gana en {len(wins_tok[z])}/{len(TASKS)} tareas"
      + (f" ({', '.join(wins_tok[z])})" if wins_tok[z] else "") + " |")
zc, zj = tot["zgrep_compact"], tot["zgrep_json"]
w(f"| `--json=compact` gasta menos que `--json` sin perder información | {'DEMOSTRADO' if zc < zj else 'REFUTADO'} | {zc / zj:.2f}x los tokens de zgrep/1 en estas tareas; sin pérdida: `compact_conformance.py` |")
faster = [x for x in wall if x[4]]
slower = [x for x in wall if not x[5] and x[1] > x[2]]
w(f"| menos pared (zgrep texto vs mejor control) | {'PARCIAL' if faster and slower else ('DEMOSTRADO' if faster and not slower else 'REFUTADO')} | más rápido fuera del ruido en {len(faster)}/{len(wall)}; más lento fuera del ruido en {len(slower)}/{len(wall)}"
  + (f" ({', '.join(f'{x[0]} vs {x[3]}' for x in slower)})" if slower else "") + " |")
w("")
w("## NOT_DEMONSTRATED")
w("")
w("- Tokens del modelo que de verdad lee la salida: el BPE usado es uno real y el mismo para todos, no el de ese modelo.")
w("- Coste de tarea completo de un agente (razonamiento entre llamadas, reintentos): el arnés mide la salida de las herramientas, no la conversación.")
w("- Corpus real grande y diverso: corpus sintético congelado (`corpus_1000`) + el árbol `src/` en el estudio de formatos.")
w("- Una sola máquina, árbol en page cache.")
(HERE / "claims.md").write_text("\n".join(lines) + "\n")
print("\n".join(lines))
