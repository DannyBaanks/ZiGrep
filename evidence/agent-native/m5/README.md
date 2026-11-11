# M5 — estudios que cambiaron el diseño (2026-11-11)

| fichero | qué decidió |
|---|---|
| `format_study.py`, `format_study_output.txt` | `--json=compact`: 4 formatos candidatos sin pérdida (cada uno se decodifica a zgrep/1 o queda descalificado) + el texto de grep como vara; ganó F (agrupado por fichero, filas posicionales, emitible en streaming) |
| `hash_encoding.py`, `hash_encoding_output.txt` | `sha256_b64u` en zgrep/1c: el mismo hash en base64url tokeniza ~44 % menos que en hex; base85 apenas mejor y no estándar |
| `fair_compare*` (de M3, en `../m3/`) | — |

Comandos: `python3 evidence/agent-native/m5/format_study.py` y
`python3 evidence/agent-native/m5/hash_encoding.py` (semilla fija). Ambos usan
`../tokcount.py`. El diferencial que prueba que lo implementado es sin pérdida es
`../compact_conformance.py` (en CI).
