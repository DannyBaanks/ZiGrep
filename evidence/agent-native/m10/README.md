# M10 — hook PreToolUse que reescribe grep/rg a ziggrep: estudio previo

Estado: **estudio, sin implementar** (2026-11-11). Nada instalado en ningun
harness.

## Pregunta

Antes de instalar un hook que cambia como trabajan TODOS los agentes del host:
¿cuanto podria ahorrar como mucho?

Un hook sobre la herramienta Bash solo tiene dos palancas:
1. **El formato.** Ya medido: `zgrep/1c` gasta 1,03x los tokens del mejor
   control de texto (`task_bench/claims.md`). Reescribir a JSON no ahorra.
2. **El recorte de lineas largas** (`--max-columns`, M9). Su techo son los bytes
   que caen mas alla de la columna W en la salida real de los grep/rg de los
   agentes. Eso es lo que mide `hook_ceiling_study.py`.

## Resultado (sesiones locales reales, solo agregados)

`hook_ceiling_study_output.txt`, W = 400:

| harness | parte de la salida que viene de grep/rg en Bash | techo del recorte, sobre toda la salida |
|---|---|---|
| Claude Code (4300 llamadas Bash) | 34,2 % | **0,9 %** |
| opencode (1160 llamadas bash) | grep/rg en el 4,9 % de las llamadas | **0,3 %** |

La herramienta `grep` propia de opencode (otro 0,8 %) queda fuera del alcance
de un hook sobre Bash. Es un techo en bytes, optimista. Los tokens no se
midieron con BPE; con un techo del 0,9 % no cambian el veredicto.

## Veredicto

Con la regla de M9 (>= 20 % de ahorro con el match intacto): **NO IMPLEMENTAR
el hook de reescritura.** El techo es al menos 20 veces menor que el umbral.
Ademas, reescribir comandos compuestos de Bash tiene un riesgo de correccion que
este ahorro no paga.

Nota honesta: la regla del 20 % no se pre-registro para M10. Es la de M9,
aplicada aqui despues de medir.

## Reproduccion

```bash
python3 hook_ceiling_study.py --claude-dir ~/.claude/projects \
  --opencode-db ~/.local/share/opencode/opencode.db
```

Lectura de las sesiones en solo lectura (SQLite `mode=ro`). Solo se imprimen
agregados: ninguna ruta, comando ni salida de sesion.

## NOT_DEMONSTRATED

- Otros harness del host (13 CLIs) y otras maquinas: no medidos.
- Un uso futuro distinto (p. ej. busquedas en arboles con mucho minificado)
  podria mover el techo; este estudio mide el uso real hasta hoy.
