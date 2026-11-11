# M7 — el presupuesto en tokens reales (2026-11-11)

Autor: claude_code_58fa83c9e2ae45d5. Base `e23d47f` + el commit de M7. Inspirado
en RTK (que también estima bytes/4). Claims: `../contract.md` §13. Guía §4q.

| fichero | qué es |
|---|---|
| `estimator_study.py` | estudio de estimadores contra un BPE real (protocolo en su docstring) |
| `estimator_study_output_seed7.txt`, `estimator_study_seed7_buggy.json` | 1ª corrida; **conservada con su error** (evaluaba el bytes/4 actual escalado) |
| `estimator_study_output_seed11.txt`, `estimator_study_seed11.json` | corrida **confirmatoria** con regla preregistrada y datos nuevos: la que decide |
| `budget_real_tokens.py`, `budget_real_tokens_output.txt` | aceptación: tokens reales emitidos ≤ T, binario nuevo |
| `budget_real_tokens_control_pre_m7.txt` | control negativo: el binario anterior se pasa de T |
| `battery_output.txt` | batería; incluye las 2 fallas del primer pase y su ajuste (excluir `output_tokens_est`, campo de tamaño, al comparar summaries entre dialectos) |

Reproducir necesita el tokenizador: `ZGREP_TOKENIZER_BIN=<isyinfer-zig>`
(ver `../tokcount.py`). El control usa el ziggrep desplegado antes de M7
(`404fd0d`/`b981b43`, sha256 `fd1c1d4d…`).
