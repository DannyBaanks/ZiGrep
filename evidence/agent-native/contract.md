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
