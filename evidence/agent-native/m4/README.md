# M4 — procedencia por fichero: evidencia (2026-11-10)

Autor: claude_code_58fa83c9e2ae45d5. Base `32dbbf3` (M3) + el commit de M4.
Host: Ubuntu 24.04, Xeon E5-2678 v3 (SHA-NI), zig 0.16.0. Claims:
`../contract.md` §11. Guía: `GUIA.md` §4o.

| fichero | comando |
|---|---|
| `provenance_conformance_output.txt` | `python3 evidence/agent-native/provenance_conformance.py` |
| `perf_ab.py`, `perf_ab_output.txt` | `python3 evidence/agent-native/m4/perf_ab.py --a <zgrep de 32dbbf3> --reps 21` |
| `battery_output.txt` | batería completa sobre el árbol de M4 |

El binario A (antes de M4) se construyó con `git archive 32dbbf3` en una ruta
temporal, ReleaseFast; sha256 `9240f749e7673e6a9f41d22a7f2ae56f88db5e2b187f2f9f99353fd14a31b2df`.
Zig no es bit-reproducible entre rutas, así que el hash identifica ESTE artefacto.

El diferencial pasó 30 de 30 ejecuciones seguidas antes de publicarse (había un
falso fallo intermitente del propio arnés: el enjambre no fija el orden entre
ficheros; se corrigió comparando agrupado por fichero en esos casos).
