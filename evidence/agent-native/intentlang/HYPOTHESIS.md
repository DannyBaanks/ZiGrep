# M6 — IntentLang × ZigGrep: hipótesis falsable (diseño, sin ejecutar)

Estado: **[CONCEPTUAL] / NOT_DEMONSTRATED**. Fecha: 2026-11-11. Autor:
claude_code_58fa83c9e2ae45d5.

**Arista de código: AUSENTE.** Buscado el 2026-11-11 en
`~/Development/ISyCo Git/IntentLang/src` (`ziggrep -l -i -w -e grep -e zgrep
-e ziggrep -e ripgrep`): ninguna referencia. IntentLang (`7b3d342`) es un motor
de traducción semántica con Meaning IR (agente, paciente, negación, tiempo,
modalidad, cuantificadores) que prefiere `UNKNOWN` a inventar. La composición
"IntentLang estructura → ZigGrep localiza → ISyInfer interpreta → oráculo
verifica" es inspiración, no un sistema. Este documento define cómo
**refutarla**; no afirma nada.

## La pregunta

¿Representar el **significado** de un pedido de búsqueda antes de generar la
búsqueda reduce las búsquedas semánticamente equivocadas, frente a un modelo que
escribe el comando directamente?

Por qué es plausible (y por qué podría no serlo): los errores que IntentLang
existe para detectar son los mismos que rompen una búsqueda sin que nadie lo note.

| pedido | error típico | el comando "suena bien" pero... |
|---|---|---|
| "ficheros que **no** usan X" | polaridad | `-v` (líneas sin X) en vez de `-L` (ficheros sin X) |
| "**cada** fichero de tests" | cuantificador / alcance | busca en todo el árbol, no solo en `tests/` |
| "**cuántas veces** aparece" | granularidad | `-c` cuenta líneas, no ocurrencias (`--count-matches`) |
| "la **palabra** id" | límite de palabra | `id` coincide dentro de `valid` |
| "llamadas a f, **no** su definición" | rol (agente/paciente) | `f` encuentra también `fn f(` |

Puede que no sirva: un modelo local decente quizá ya acierta estos casos, o el
beneficio puede venir solo de pedir salida estructurada, no del Meaning IR.

## Hipótesis H1

Sobre un conjunto **preregistrado** de N = 60 pedidos en lenguaje natural (12 por
cada fila de la tabla de arriba) contra `bench-corpus/corpus_1000` y `src/`, con
la respuesta correcta calculada por un oráculo:

> El pipeline **T** (IntentLang → Meaning IR → compilador determinista a un lote
> `--queries-file` → ZigGrep `--json=compact`) tiene una tasa de respuestas
> correctas **al menos 15 puntos** mayor que **B** (el mismo modelo local escribe
> el comando grep/rg directamente), sin gastar más de 1,2x los tokens de B.

`UNKNOWN` (abstención) se cuenta aparte y **nunca** como acierto.

## Brazos y controles

| brazo | qué es | para qué |
|---|---|---|
| **P** control positivo | consultas oro escritas a mano | valida el oráculo y el arnés: debe dar 100 %; si no, el experimento no vale |
| **N** control negativo | solo palabras de contenido → `zgrep -l palabra` | si N ≈ T, el IR no aporta nada |
| **B** línea base | el modelo escribe el comando directamente | la comparación de H1 |
| **S** ablación | el modelo escribe el lote JSON directamente, sin IntentLang | separa "salida estructurada" de "Meaning IR" |
| **T** tratamiento | IntentLang → IR → compilador → ZigGrep | la hipótesis |

Modelo de B y S: `qwen2.5-3b-instruct-q4_k_m.gguf` vía ISyInfer, temperatura 0,
prompts congelados y hasheados. Toda ejecución de modelo bajo `systemd-run
MemoryMax` y con `MemAvailable` comprobado antes (regla del host).

## Métricas

- Corrección: el conjunto respuesta (ficheros, líneas o recuentos según el
  pedido) es **exactamente** el del oráculo.
- Abstención: proporción de `UNKNOWN` / rechazos.
- Tokens reales (`../tokcount.py`) de la salida que lee el agente, llamadas y
  tiempo de pared.
- Error por estrato (polaridad, alcance, granularidad, palabra, rol).

## Criterios de refutación (fijados ANTES de ejecutar)

H1 queda **refutada** si se cumple cualquiera:

1. La diferencia T − B es menor que 15 puntos, o su IC 95 % bootstrap (10 000
   remuestreos, semilla fija) incluye valores por debajo de 15.
2. T se abstiene en más del 25 % de los pedidos (acierta por no responder).
3. T ≤ S: la ganancia viene de la salida estructurada, no de IntentLang.
4. T gasta más de 1,2x los tokens de B.
5. P no da 100 % (el arnés no es fiable: el resultado es nulo, no una confirmación).

Si se refuta, se archiva y **no se toca el CLI** de ZigGrep. Si sobrevive, el
contrato de máquina de M1–M5 (`zgrep/1`, `zgrep/1c`, lote, presupuesto,
procedencia) es la base sobre la que se compone.

## Lo que hay que construir para ejecutarlo (y dónde)

- El conjunto de 60 pedidos + respuestas oro: **antes** de construir T o
  escribir los prompts, y con su SHA-256 publicado aquí mismo.
- Un compilador Meaning IR → lote de consultas: código nuevo **en IntentLang**,
  no en ZigGrep.
- Un arnés que corra los 5 brazos y genere la tabla de claims desde el crudo
  (como `../task_bench/make_claims.py`).

## Paquete de evidencia

`intentlang/run_<fecha>/`: pedidos + hash, prompts + hash, salidas crudas de los
5 brazos, `SHA256SUMS.txt`, `claims.md` generado y una sección NOT_DEMONSTRATED
explícita. Una ejecución no reemplaza otra: carpeta nueva cada vez.

## NOT_DEMONSTRATED (hoy, todo)

Nada de esta composición existe ni se ha medido. Este documento solo fija cómo se
mediría y qué resultado la tumbaría.
