# Contrato de máquina de zgrep — medido, no recordado (M0 del plan agent-native)

Este documento congela el contrato **actual** de `zgrep` antes de que el plan lo
cambie. Cada número salió de `baseline/exit_codes.txt` (crudo pegado tal cual) y
del baseline `baseline/task_bench.json`. Nada aquí es memoria: si un dato no está
en un fichero de `baseline/`, no está en este documento.

Commit de referencia del baseline: `d965084c07afe418c000a343950407ffc56d13e6`
("--cache: los acentos que faltaban y el falso positivo de ACTIVA"), binario
ReleaseFast, corpus congelado `bench-corpus/corpus_1000` (1.000 ficheros,
32.795.967 bytes, semilla 20261108).

## 1. Códigos de salida

Matriz medida sobre el mismo caso para `zgrep`, `grep` (GNU grep 3.11) y `rg`
(14.1.0). `zgrep` **coincide con `grep` en el contrato 0/1/2** salvo una fila:

| caso | zgrep | grep | rg |
|---|---|---|---|
| match | 0 | 0 | 0 |
| sin match | 1 | 1 | 1 |
| fichero inexistente | 2 | 2 | 2 |
| inexistente con `-s` | 2 (stderr vacío) | 2 (stderr vacío) | 2 (**stderr con texto**) |
| flag inválido | 2 + usage en stderr | 2 + usage | 2 |
| `-f` con patrón vacío | 1 | 1 | 1 |
| stdin con match | 0 | 0 | 0 |
| stdin sin match | 1 | 1 | 1 |
| **directorio sin `-r`** | **0 (lo recorre)** | **2 ("Es un directorio")** | **0 (lo recorre)** |

La única divergencia de contrato es el directorio sin `-r`: `zgrep` hereda la
semántica "recursivo siempre" (como `rg`), no el error de `grep`. Para un agente
eso ahorra un viaje de ida y vuelta, pero **debe saberse**: está aquí.

Clases de stderr observadas: error de fichero (`path: FileNotFound`), error de
uso (`unrecognized option: '...'` + `try 'zgrep --help' for usage`), y nada más
en el contrato de búsqueda. `-s` silencia la clase de error de fichero (igual
que `grep`), pero `rg` no la silencia.

## 2. Comportamiento en pipe (la decisión pendiente de M2)

Medido, una línea por herramienta sobre el mismo fichero:

```
$ grep beta f.txt | cat   ->  beta
$ rg   beta f.txt | cat   ->  beta
$ zgrep beta f.txt | cat  ->  2:beta      <- numero SIEMPRE
```

`zgrep` imprime el número de línea por defecto; ni `grep` ni `rg` lo hacen cuando
la salida es un pipe (`rg` solo numera en tty). El coste queda medido en el
baseline: en la tarea `word_boundary_occurrences`, `zgrep` emite 10.447.305 bytes
frente a 9.885.342 con `--no-line-number` (**+5,7 % de salida**, proxy de tokens).
La premisa del corpus ("rg numera por defecto") está falsada desde el 2026-11-10
(`evidence/feature-corpus/README.md`); la decisión de M2 la cierra.

## 3. Operaciones interactivas sin tty (EOF en stdin)

Ninguna se cuelga — verificado una por una:

| operación | con EOF en stdin | rc |
|---|---|---|
| `--cache` (interactivo) | `cancelado: no se borró nada` | 1 |
| `--cache --dry-run` | muestra la tabla y sale | 0 |
| `--cache --force` | ejecuta sin preguntar (por diseño) | 0 |

Esto corrige una suposición de la sesión ("un agente que olvide `--force` se
cuelga para siempre"): medido, `--cache` falla cerrado.

## 4. Baseline task-level (control)

Arnés: `evidence/agent-native/task_bench.py`, 8 tareas de agente sobre el corpus
congelado, 4 configuraciones (`zgrep`, el mismo con `--no-line-number`, `grep`,
`rg`), mediana de 3 pasadas. Correctitud 32/32 contra el `.truth` o contra `grep`
como referencia. Crudo: `baseline/task_bench.json`.

Resumen (muro en segundos, bytes de salida totales de 3 pasadas):

| tarea | zgrep | zgrep ‑‑nn | grep | rg |
|---|---|---|---|---|
| files_with_needle | 0,012 | 0,010 | 0,031 | 0,016 |
| count_matching_lines | 0,014 | 0,015 | 0,051 | 0,030 |
| rare_files | 0,010 | 0,010 | 0,048 | 0,011 |
| rare_call_sites | 0,011 | 0,012 | 0,065 | 0,012 |
| absent_token | 0,009 | 0,007 | 0,047 | 0,010 |
| context_audit | 0,017 | 0,019 | 0,065 | 0,013 |
| two_patterns | 0,009 | 0,008 | 0,032 | 0,014 |
| word_boundary_occurrences | 0,188 | 0,178 | 0,193 | 0,041 |

Lecturas honestas del control:

- `zgrep` es **3–6× más rápido que `grep`** en 8/8 tareas.
- Pierde contra `rg` en dos: `context_audit` (0,017 vs 0,013) y
  `word_boundary_occurrences` (0,188 vs 0,041, **4,6×**). Son datos, no
  excusas: el `-o` con `\b` es el punto débil medido.
- En bytes de salida es idéntico a todos salvo el impuesto de la numeración
  (§2).
- **Lo que el control NO muestra** es la razón de ser del plan: las 8 tareas son
  de 1 llamada cada una. La hipótesis "menos llamadas y menos tokens" se mide en
  M3 (lote) y M5 (repetir este arnés contra el estado final). Este documento
  existe justamente para que esa comparación tenga un control honesto.

## 5. Alcance de este baseline

- Una máquina (Xeon E5-2678 v3, AVX2), Linux, árbol en page cache, 3 repeticiones.
- Corpus sintético: sin ficheros binarios, sin ignore-files, sin Unicode.
- Las tareas son de una llamada: no miden todavía el ahorro de llamadas.
- `zgrep` medido en modo texto (aún no existe `--json`; eso es M1).

## 6. DECISION (M2): la numeración arranca apagada

Medido por tercera vez, y esta es la que cerró el asunto:

```
$ grep 'beta' f.txt | cat   ->  beta
$ rg   'beta' f.txt | cat   ->  beta
$ zgrep 'beta' f.txt | cat  ->  beta      <- desde M2
$ zgrep -n 'beta' f.txt     ->  2:beta
```

La premisa del corpus ("rg numera por defecto") era falsa **en el caso que
importa**: rg solo numera en tty. Un agente siempre es pipe. Decisión: default
apagado, `-n`/`--line-number` enciende, `--no-line-number` queda aceptada por
compatibilidad (no-op), y `--pretty` —que ya era el alias
`--color=always --heading --line-number`— por fin tiene sentido.

Coste medido del default viejo, en la tarea `word_boundary_occurrences` del
baseline: **10.447.305 bytes con número vs 9.885.342 sin él (+5,7 % de salida,
proxy de tokens)**. Con el flip, las cuatro configuraciones del benchmark emiten
**exactamente los mismos bytes en las 8 tareas** (verificado abajo).

## 7. Re-ejecución del baseline con el default nuevo (ReleaseFast, caché caliente)

| tarea | zgrep | grep | rg | bytes (las 4 configs) |
|---|---|---|---|---|
| files_with_needle | 0,011 | 0,031 | 0,014 | 142.125 |
| count_matching_lines | 0,013 | 0,048 | 0,015 | 151.125 |
| rare_files | 0,010 | 0,048 | 0,011 | 441 |
| rare_call_sites | 0,011 | 0,065 | 0,012 | 963 |
| absent_token | 0,007 | 0,047 | 0,010 | 0 |
| context_audit | 0,017 | 0,065 | 0,013 | 2.724 |
| two_patterns | 0,006 | 0,012 | 0,009 | 142.125 |
| word_boundary_occurrences | 0,073 | 0,067 | 0,017 | 9.885.342 |

*(Los muros de esta tabla son de una ejecución con el árbol caliente; los del §4
son el control original. Lo que no depende de la carga son los bytes: idénticos
en las cuatro configuraciones.)*

Zgzrep sigue 2–6× por debajo de `grep` en 8/8 tareas y pierde contra `rg` en las
dos de siempre (`context_audit` y `word_boundary_occurrences`, esta última 4×).
Null el flip cambia el número de línea por defecto, no el motor.

## 8. Contrato de salida: lo que un agente puede dar por sentado

| situación | stdout | stderr | rc |
|---|---|---|---|
| match | registros | vacío | 0 |
| sin match | vacío | vacío | 1 |
| fichero ilegible | lo demás | `zgrep: PATH: FileNotFound` | 2 |
| uso inválido | vacío | `unrecognized option: '...'` + `try 'zgrep --help'` | 2 |
| `--json` en cualquier caso | **solo eventos JSONL**, nunca otra cosa | igual | igual |

La última fila es la regla de M1/M2: en modo JSON no se emite nada que no sea un
evento. Verificado por el diferencial texto↔json (45/45) que ademas comprueba
los `byte_start`/`byte_end` contra el fichero real.

## 9. Correcciones de la auditoría e2e de M2 (2026-11-10, claude_code)

Las secciones 1–8 no se reescriben: estas filas las corrigen o completan.
Medido con GNU grep 3.11 (`/usr/bin/grep`: en un shell interactivo `grep`
puede ser una función o un alias, verifícalo con `type grep`) y rg 14.1.0.

**Afirmaciones que no se sostenían:**

- §4 y §7: "zgrep 3–6× / 2–6× más rápido que grep en **8/8**". En
  `word_boundary_occurrences` empata o pierde (§4: 0,188 vs 0,193; §7: 0,073 vs
  0,067). Son **7/8**.
- §6 y §7: las cifras de bytes (142.125, 9.885.342, 10.447.305...) son la
  **suma de 3 repeticiones**, no la salida de una llamada (el §4 sí lo decía).
  Una ejecución de `word_boundary_occurrences` son 3.295.114 bytes. El +5,7 % es
  un cociente y no cambia. `task_bench.py` publica ahora `out_bytes_per_rep` e
  imprime esa columna; `out_bytes_total` se conserva por compatibilidad.
- §1, fila `-s`: en rg, `-s` es `--case-sensitive`, no "silenciar errores". Su
  equivalente es `--no-messages`: rc 2 con stderr vacío, igual que zgrep y grep.
- §3: "ninguna se cuelga" vale para las operaciones interactivas. Una búsqueda
  **sin ruta** lee stdin, y si stdin es un pipe que nadie cierra espera para
  siempre, igual que grep y rg (`sleep 4 | timeout 2 zgrep X` → 124 en los
  tres). Un agente debe pasar siempre una ruta o `</dev/null`.

**Bugs encontrados y corregidos** (tests y oráculo en el mismo commit):

| caso | antes | ahora | referencia |
|---|---|---|---|
| `--column` sin `-n` | `6:beta HIT` | `2:6:beta HIT` | rg: `--column` implica `-n`; `--no-line-number` en cualquier orden lo apaga |
| `-q pat presente inexistente` | rc 2 | rc 0 | grep y rg: con `-q`, un match gana al error |
| `zgrep pat a b c` (ficheros) | c, b, a | a, b, c | grep: orden de los argumentos |
| `--json --passthru` | línea no coincidente = `type:"match"`, `inverted:true` | `type:"passthru"`, `inverted:false` | schema zgrep/1 (§4k de la GUIA) |
| `--json --exec` | texto del hijo mezclado en el stream | error de uso, rc 2, stdout vacío | regla del §8 |

El caso `--column` del oráculo le pasaba `-n` a zgrep para igualar a rg, y eso
escondía el bug 1. Ahora va sin `-n`, a propósito.

**Filas que se añaden al contrato:**

| situación | comportamiento |
|---|---|
| `-q`, match + operando ilegible | rc 0 (stderr con el error, salvo `-s`) |
| varios **ficheros** explícitos | salida en el orden de los argumentos |
| algún **directorio** entre los operandos | orden de terminación del enjambre, como rg; `--sort` lo fija |
| `--json` con `--exec` | rc 2, stdout vacío |
| `--json` con `--version` / `--type-list` | texto: son acciones informativas, no búsquedas, y no emiten eventos |
| `-N` | navegación Befunge (no es el `--no-line-number` de rg) |

Versión: este cambio de comportamiento sale como **0.4.0-dev**; el binario
desplegado decía `zgrep 0.3.2`, y el plan exige 0.4.0 para cualquier cambio de
comportamiento.

## 10. M3: lote y presupuesto (2026-11-10, claude_code)

Interfaces nuevas (GUIA §4n, `zgrep --help`): `--queries-file FILE|-`,
`--max-results N`, `--max-output-tokens N`. Eventos nuevos del schema `zgrep/1`
(solo se añaden campos y tipos): `query_id` en cada evento del lote, `query_end`
por consulta y `summary` al final.

**Contrato de salida que se añade:**

| situación | stdout | rc |
|---|---|---|
| lote correcto | eventos con `query_id`, un `query_end` por consulta, `summary` último | 2 si alguna consulta dio 2; si no, 0 si alguna encontró algo; si no, 1 |
| una consulta inválida (p. ej. `--exec` en `"flags"`) | su `query_end` con `rc` 2 y `error`; las demás corren | 2 |
| fichero de consultas inválido (JSON roto, `id` repetido, campo desconocido) | vacío: no se ejecuta nada | 2 |
| `-e`/`-f` global junto con `--queries-file` | vacío | 2 |
| `--max-results`/`--max-output-tokens` sin `--json` ni lote | vacío | 2 |
| presupuesto agotado | prefijo de lo que saldría sin presupuesto + `summary` con `truncated:true`, `reason`, `returned`, `omitted` exacto | el de la búsqueda (truncar no es error) |

El presupuesto cubre los eventos de búsqueda; `query_end` y `summary` se emiten
siempre. Tokens = bytes/4 (declarado en `summary.token_estimate`).

**Claims (aceptación del plan, M3)**

Evidencia en `evidence/agent-native/m3/` (crudos y `SHA256SUMS.txt`). Las cifras
son de esta ejecución (Xeon E5-2678 v3, árbol en page cache), no constantes.

| claim | estado | evidencia |
|---|---|---|
| N consultas en **1** proceso dan la **misma evidencia** que N procesos | DEMOSTRADO | `batch_conformance_output.txt`: cada consulta byte a byte igual a su proceso separado (`--json --sort`), 16 consultas con todos los modos de salida; `task_bench_output.txt`, `phrase_survey`: 16 llamadas → 1, respuesta igual a GNU grep |
| el truncado nunca es silencioso | DEMOSTRADO | `batch_conformance_output.txt`: con cada `--max-results` y `--max-output-tokens` probado, lo emitido es prefijo, `returned + omitted` = total, `truncated`/`reason` correctos, nunca un evento partido; tests de `src/batch.zig` |
| los errores fallan cerrado | DEMOSTRADO | `batch_conformance_output.txt`, sección "cerrado" |
| el lote es más rápido que N procesos con **la misma salida** | DEMOSTRADO, margen pequeño | `fair_compare_output.txt`: 1 × lote frente a 16 × `--json --sort` |
| el lote es más rápido que N procesos de **texto** | **FALSO** en esta medida | `fair_compare_output.txt` y `task_bench_output.txt`: 16 × texto en streaming es más rápido. Cada consulta recorre el árbol entero, con `--sort` y emisión JSON |
| el lote ahorra tokens | **FALSO** frente a texto | mismos ficheros: el JSON con `query_id` pesa ~3× el texto. Lo que ahorra es procesos y el trabajo de juntar y atribuir resultados |

**NOT_DEMONSTRATED / fuera de alcance:**

- Una sola pasada por los ficheros para todas las consultas (sería lo que
  convierte el lote en más rápido que el texto): toca el motor, que el plan deja
  fuera ("no reescritura del motor"). Decisión pendiente de Danny.
- Una salida JSON compacta (menos bytes por evento): es un cambio de schema, no
  de este milestone.
- Lotes grandes (cientos de consultas, árboles de GB): no medidos. Cada consulta
  usa su propio arena, liberado al terminarla.
- El caso "40 → 1" que cita el plan era ilustrativo: la tarea medida tiene 16
  consultas.
