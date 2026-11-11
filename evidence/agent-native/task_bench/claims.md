# M5 — veredicto de la tesis agent-native (generado desde el crudo)

Crudo: `task_bench.json` (reps=5). Tokenizador: BPE Qwen (vocab 151936) via isyinfer-zig tokenize; BOS descontado por trozo (`DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf`). Versiones: zgrep=`zgrep 0.4.0-dev`, grep=`grep (GNU grep) 3.11`, rg=`ripgrep 14.1.0`.

Tokens por tarea, relativos al MEJOR control de texto (grep/rg) de esa tarea. <1 = zgrep gasta menos.

| tarea | llamadas (control → lote) | mejor control (tokens) | zgrep | zgrep_json | zgrep_compact | zgrep_json_prov | zgrep_compact_prov | zgrep_batch | zgrep_batch_compact |
|---|---|---|---|---|---|---|---|---|---|
| files_with_needle | 1 → — | 25125 (grep) | 1.00 | 1.76 | 1.12 | 7.27 | 5.30 | — | — |
| count_matching_lines | 1 → — | 28125 (grep) | 1.00 | 1.71 | 1.11 | 6.64 | 4.84 | — | — |
| rare_files | 1 → — | 78 (grep) | 1.00 | 1.73 | 1.23 | 7.12 | 5.29 | — | — |
| rare_call_sites | 1 → — | 124 (grep) | 1.00 | 2.19 | 1.44 | 5.57 | 3.29 | — | — |
| absent_token | 1 → — | 0 (grep) | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | — | — |
| context_audit | 1 → — | 339 (grep) | 1.00 | 2.17 | 0.76 | 3.41 | 1.44 | — | — |
| two_patterns | 1 → — | 25125 (grep) | 1.00 | 1.76 | 1.12 | 7.27 | 5.30 | — | — |
| word_boundary_occurrences | 1 → — | 1571140 (grep) | 1.00 | 2.84 | 1.03 | 2.93 | 1.08 | — | — |
| phrase_survey | 16 → 1 | 1597 (grep) | 1.00 | 2.35 | 1.54 | 6.03 | 3.61 | 3.01 | 2.04 |

Total sobre las tareas que cubre cada config (todas, salvo el lote, que solo agrupa phrase_survey): zgrep = 1.00x, zgrep_json = 2.79x, zgrep_compact = 1.03x, zgrep_json_prov = 3.13x, zgrep_compact_prov = 1.27x (control = 1651653 tokens).

## Claims

| claim | estado | dato |
|---|---|---|
| menos llamadas | DEMOSTRADO | phrase_survey: 16 → 1 (lote; en tareas de una sola llamada no hay nada que agrupar) |
| igual o mejor corrección | DEMOSTRADO | todas las configs de zgrep correctas en 9/9 tareas contra el .truth o GNU grep |
| menos tokens que el texto (zgrep_json) | REFUTADO | total 2.79x el mejor control; gana en 0/9 tareas |
| menos tokens que el texto (zgrep_compact) | PARCIAL | total 1.03x el mejor control; gana en 1/9 tareas (context_audit) |
| `--json=compact` gasta menos que `--json` sin perder información | DEMOSTRADO | 0.37x los tokens de zgrep/1 en estas tareas; sin pérdida: `compact_conformance.py` |
| menos pared (zgrep texto vs mejor control) | PARCIAL | más rápido fuera del ruido en 7/9; más lento fuera del ruido en 1/9 (word_boundary_occurrences vs rg) |

## NOT_DEMONSTRATED

- Tokens del modelo que de verdad lee la salida: el BPE usado es uno real y el mismo para todos, no el de ese modelo.
- Coste de tarea completo de un agente (razonamiento entre llamadas, reintentos): el arnés mide la salida de las herramientas, no la conversación.
- Corpus real grande y diverso: corpus sintético congelado (`corpus_1000`) + el árbol `src/` en el estudio de formatos.
- Una sola máquina, árbol en page cache.
