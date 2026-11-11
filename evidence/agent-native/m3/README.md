# M3 — lote y presupuesto: evidencia (2026-11-10)

Autor: claude_code_58fa83c9e2ae45d5. Base `736810b` + el commit de M3. Host:
Ubuntu 24.04, Xeon E5-2678 v3, zig 0.16.0, GNU grep 3.11, ripgrep 14.1.0.
Claims: `../contract.md` §10. Guía: `GUIA.md` §4n.

| fichero | comando que lo produce |
|---|---|
| `battery_output.txt` | tests, oráculo, conformance, paridad, BRE, `\b`, json, sonda M2 y diferencial del lote, en este orden |
| `batch_conformance_output.txt` | `python3 evidence/agent-native/batch_conformance.py` |
| `task_bench_output.txt`, `task_bench.json` | `python3 evidence/agent-native/task_bench.py --tool all --reps 3 --out evidence/agent-native/m3` |
| `fair_compare.py`, `fair_compare_output.txt` | `python3 evidence/agent-native/m3/fair_compare.py --reps 5` |

Las consultas de `phrase_survey` son las de `../queries/phrase_survey.jsonl`, que
también lee el lote: las cuatro herramientas buscan exactamente las mismas frases.

El corpus `bench-corpus/corpus_50` no está versionado: se regenera byte a byte con
`zig run scripts/gen_corpus.zig -- --out=bench-corpus/corpus_50 --files=50 --size=32768 --seed=20261108`
(verificado contra el local, ficheros y `.truth` idénticos). El CI lo hace antes
del diferencial.
