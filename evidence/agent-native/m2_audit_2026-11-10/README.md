# Auditoría e2e de M2 — 2026-11-10

Auditor: claude_code_58fa83c9e2ae45d5, a pedido de Danny. Host: Ubuntu 24.04,
Xeon E5-2678 v3, zig 0.16.0, GNU grep 3.11 (`/usr/bin/grep`), ripgrep 14.1.0.
Base auditada: `7c625c2` (M2). Hallazgos y correcciones: `../contract.md` §9 y
`GUIA.md` §4m.

## Ficheros

| fichero | qué es |
|---|---|
| `probe.sh` | sonda diferencial (stdout + rc) zgrep vs grep/rg, 17 filas |
| `probe_output.txt` | la sonda contra el binario arreglado: **17/17** |
| `probe_output_control_7c625c2.txt` | **control negativo**: la misma sonda contra `7c625c2`: **6/17** (11 fallos, los bugs) |
| `battery_output.txt` | batería completa sobre el árbol arreglado |

## Comandos exactos

```sh
zig build test --summary all                 # 115 pass, 1 skip (116)
zig build oracle                             # 32/32 (2 casos nuevos)
zig build -Doptimize=ReleaseFast             # el oracle deja un Debug en zig-out: recompilar
bash evidence/feature-corpus/conformance.sh  # 40/40
bash evidence/feature-corpus/parity.sh       # 25/25
python3 evidence/feature-corpus/bre_conformance.py   # 15/15
bash evidence/feature-corpus/wb_conformance.sh       # 12/12
python3 evidence/feature-corpus/json_conformance.py  # 45/45
bash evidence/agent-native/m2_audit_2026-11-10/probe.sh                             # 17/17
bash evidence/agent-native/m2_audit_2026-11-10/probe.sh <binario de 7c625c2>        # 6/17 (control)
```

## Binarios (ReleaseFast; Zig no es bit-reproducible entre rutas, ver provenance)

- arreglado (`zig-out/bin/zgrep`, 0.4.0-dev): `1dfb85a21fff5d52ef2f4bef7d43e43de3729330ee7f2c93aa86ce8d282f4ae7`
- control `7c625c2` (construido desde `git archive` en una ruta temporal): `fe138a936a8d7e92817731249bc5fb4b56c3677f01ede3af6b33925254a8b199`

## NOT_DEMONSTRATED

- El orden con **directorios** entre los operandos sigue siendo el de
  terminación del enjambre (igual que rg); no se cambió ni se midió su
  estabilidad.
- `--json` con `--version`/`--type-list` sigue emitiendo texto (acciones
  informativas): documentado, no cambiado.
- No se repitió el benchmark task-level completo después de los arreglos: el
  camino ordenado para varios ficheros sueltos no aparece en sus 8 tareas (todas
  son de un directorio).
