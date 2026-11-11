# M5 — el experimento task-level (2026-11-11)

Autor: claude_code_58fa83c9e2ae45d5. Base `297be94` (M4) + el commit de M5.
Host: Ubuntu 24.04, Xeon E5-2678 v3, zig 0.16.0, GNU grep 3.11, ripgrep 14.1.0.
Binario medido: sha256 en `zgrep_sha256.txt` (el mismo en toda la corrida, verificado).

**El veredicto está en `claims.md`, generado por `make_claims.py` desde
`task_bench.json`: ningún número se escribió a mano.** Método y decisiones:
`../contract.md` §12.

| fichero | comando |
|---|---|
| `task_bench.json`, `task_bench_output.txt` | `python3 evidence/agent-native/task_bench.py --final` |
| `claims.md` | `python3 evidence/agent-native/task_bench/make_claims.py` |
| `battery_output.txt` | batería completa sobre el binario medido |

Tokens: `evidence/agent-native/tokcount.py` (BPE Qwen vía `isyinfer-zig tokenize`,
GGUF `DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf`, sha256
`f3bdf9cf31dee4b57ae4e455a1cb0d01b5c2c1b50d72d3112141c195506c2840`).
Reproducir necesita ese binario y ese modelo (configurables por entorno).

**Redacción (2026-11-11):** en `task_bench.json`, el campo `tokenizer.bin` llevaba
la ruta local absoluta del binario (nombraba un repo privado) y
`tokenizer.model` la ruta del GGUF. Se sustituyeron por el nombre del binario
con la marca `<ruta local redactada 2026-11-11>` y el nombre del fichero del
modelo. Ningún dato medido cambió (`claims.md` se regeneró idéntico); el
`SHA256SUMS.txt` se recalculó por esa edición. El original sigue en el historial
de git (commit `404fd0d`). Para reproducir: `ZGREP_TOKENIZER_BIN=<ruta a
isyinfer-zig>` (o tenerlo en el PATH).
