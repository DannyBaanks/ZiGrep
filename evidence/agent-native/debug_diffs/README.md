# Diferenciales agent-native contra un binario Debug (2026-11-11)

Despues del fix de M9 (`m9/oob_fix/`): ReleaseFast escondia una lectura fuera
del slice que en Debug abortaba. Pregunta: ¿esconden algo parecido los demas
diferenciales, que hasta hoy solo corrian contra ReleaseFast?

Comando (Linux, zig 0.16.0, commit f71325b, corpus_50 de la semilla 20261108):

    zig build -Doptimize=Debug --prefix <dir>
    python3 evidence/agent-native/<t>_conformance.py --zgrep <dir>/bin/zgrep

| diferencial | Debug |
|---|---|
| batch (M3) | 41 pass / 0 fail |
| provenance (M4) | 71 pass / 0 fail |
| compact (M5) | 45 pass / 0 fail |
| spill (M8) | 66 pass / 0 fail |
| m9 | 446 pass / 0 fail (`m9/oob_fix/m9_conformance_debug_AFTER.txt`) |

Resultado: ningun panic ni fallo. Ninguno escondia un bug de limites en lo que
cubren. Desde ahora el CI de Linux corre los cinco contra Debug en un paso.

NOT_DEMONSTRATED: Debug solo detecta lo que los casos ejercitan. No es una
prueba de ausencia de UB fuera de esos caminos. El fuzz y el cell-fuzz no se
corrieron en Debug.
