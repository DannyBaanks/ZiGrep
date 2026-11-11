# Corpus de superficie y decisions de paridad

Que tiene **GNU grep 3.11**, que tiene **ripgrep 14.1.0**, que tiene **zgrep**, y
que decision toma este proyecto para cada hueco.

## Como se regenera

```bash
# 1. capturas crudas (el inventario sale de aqui, no de memoria)
LC_ALL=C grep --help   > evidence/feature-corpus/raw/grep-help.txt
LC_ALL=C rg --help     > evidence/feature-corpus/raw/rg-help.txt
LC_ALL=C ziggrep --help > evidence/feature-corpus/raw/ziggrep-help.txt
{ echo "grep (GNU grep) 3.11"; echo "ripgrep 14.1.0"; echo "zgrep $(ziggrep --version)"; \
  echo "capturado: $(date -Is)"; echo "kernel: $(uname -srm)"; } \
  > evidence/feature-corpus/raw/versions.txt

# 2. matriz curada
python3 evidence/feature-corpus/build_corpus.py
```

El inventario (numero de tokens por herramienta) lo extrae `build_corpus.py` de
los `--help` capturados, asi que un ripgrep nuevo se nota solo. La columna de
estado y decision es curada a mano: "existe la bandera" no se puede deducir del
texto de ayuda.

## Correccion medida (2026-11-10): la numeracion por defecto

La fila `-n / --line-number` de la matriz decencia "zgrep imprime numero
siempre" apoyandose en que **rg numera por defecto**. Medido hoy, esa premisa
es falsa **cuando la salida es un pipe**, que es el caso de todo test
diferencial y de cualquier script:

```
$ rg 'cat' x.txt | cat        ->  cat          (sin numero)
$ rg -n 'cat' x.txt | cat     ->  1:cat
$ grep 'cat' x.txt            ->  cat          (sin numero)
$ zgrep 'cat' x.txt           ->  1:cat        (numero siempre)
```

rg solo numero en tty (como `--heading` y `--color`); de ahi que su propio
`--pretty` sea el alias `--color=always --heading --line-number`, que fuerza lo
que en pipe viene apagado. zgrep tiene ese mismo alias, asi que su `--pretty`
presupone numeracion apagada por defecto mientras el motor la tiene encendida:
incoherencia interna documentada, decision de diseno **pendiente de revision**
(no tocad en 0.3.2). `conformance.sh` lleva desde hoy la NOTA en su cabecera y
el caso `-x -F a.b (sin -n)` compara con `--no-line-number`, porque el fixture
recreado (nunca estuvieron en git) si tiene una linea exacta `a.b` y destapaba
la diferencia.

## Politica de colisiones de banderas cortas

Cuando grep y rg se contradicen, **manda GNU grep**; lo propio de rg entra solo
con nombre largo:

| Letra | grep | rg | zgrep |
|---|---|---|---|
| `-N` | (nada) | `--no-line-number` | navegacion Befunge (propio) |
| `-T` | `--initial-tab` | `--type-not` | libre (sin uso) |
| `-E` | `--extended-regexp` | `--encoding` | ERE (grep) |
| `-L` | `--files-without-match` | `--follow` | files-without-match (grep) |
| `-r` | `--recursive` | `--replace` | recursive no-op (grep) |
| `-s` | `--no-messages` | `--case-sensitive` | no-messages (grep) |
| `-z` | `--null-data` | `--search-zip` | libre |
| `-U` | `--binary` | `--multiline` | libre |
| `-h` | `--no-filename` | `--help` | no-filename (grep) |
| `-I` | `--binary-files=without-match` | `--no-filename` | binary skip no-op (grep) |

## `--json`: diferencial texto <-> JSON (M1, 45/45)

`json_conformance.py` corre cada caso dos veces —modo texto y con `--json`— y
comprueba tres cosas: que cada evento declare el schema `zgrep/1`, que los
eventos reproducen **en el mismo orden** las líneas de la salida de texto, y que
los `byte_start`/`byte_end` de cada evento con span sean los bytes reales del
fichero (rebanando el fichero, no confiando en el evento).

45 casos: básicos, contexto, modos de fichero/recuento, spans (`-o`, `--column`,
`--replace`, `--passthru`, `-U`, `--vimgrep`, `--crlf`, `-z`), corpus congelado
(offsets verificados contra ficheros de verdad) y stdin.

Tres bugs reales salieron de aquí, todos de la misma clase —decoración de texto
colándose en el stream JSON—:

1. el camino ordenado (`--sort`) tenía su propia construcción de `ScanConfig`,
   que no recibía `json`: `--sort --json` devolvía **texto en silencio**;
2. `--heading` emitía su línea de cabecera como texto pelado;
3. los separadores de grupo `--` (cinco sitios: `scan.zig` ×3, `uring` ×2,
   `kamikaze` ×2, `main.zig` ×2) rompían el JSONL con contexto multiví fichero.

Para un agente, un stream "JSON" con una línea `--` es peor que no tener JSON:
falla el parse en el momento peor. De ahí la regla de M1: en modo JSON no se
emite nada que no sea un evento.

## Lo entregado en esta ronda (0.3.0)

| Flag | Estado |
|---|---|
| `-A`, `-B`, `-C` (+ largos) | nuevo, verificado contra grep en 40 casos |
| `-x` / `--line-regexp` | nuevo (anclado en el AST) |
| `-f` / `--file` | nuevo (patrones desde fichero) |
| `--no-line-number` | nuevo (solo largo: `-N` es la navegacion) |
| `-Z`, `-0`, `--null` | nuevo |
| `-s` / `--no-messages` | **arreglado**: era un no-op que no suprimia nada |
| `--text` | alias nuevo de `-a` |

Ver `conformance.sh` + `conformance-results.txt` para la comparacion caso por
caso contra GNU grep 3.11 (micro path, swarm, uring y stdin incluidos).

## Trampa de dialecto que encontro esta campaña

zgrep habla **ERE** (el dialecto de `rg`), no el BRE de `grep` sin `-E`. Un
patrón con paréntesis literales copiado de un `grep -x 'f(a, b)'` **no
coincide**: en ERE los paréntesis son grupos. Con `\(` y `\)` coinciden
`zgrep`, `rg` y `grep -E` (verificado en `.opencode/role_doctor/doctor.py:552`).
No es un defecto de `-x`: es la frontera BRE/ERE, anotada en la fila `-G` del
corpus y como trampa 10 de la guía del monorepo.

## La inversión del motor y su veredicto medido

El motor (`regex.zig`) pasó de responder *"¿coincide esta línea?"* a responder
***"¿dónde coincide?"***: el match ya no colapsa el estado, se conserva dentro
del conjunto de estados del NFA, y el runner de spans usa una tabla de
transición **sin inyección de `start`** para saber dónde empieza el match.
Verificado con el oráculo perfecto para esto, `grep -E -o`:
**1419/1419 casos idénticos** (patrones × líneas), cero desajustes.

Eso desbloqueó `-o`, `--column`, `--color`, `--replace` y `--count-matches`.

### ¿Y ejecutar Python desde zgrep? Medido, no opinado

`--exec` ejecuta un comando por cada fichero que coincide. La pregunta de si
Zig puede *ejecutar Python más rápido* se responde con dos números:

| Escenario | python3 directo | zgrep --execute | Lectura |
|---|---:|---:|---|
| Un fichero, 1,2 M líneas, mismo trabajo | 183,4 ms | 189,1 ms | **+5,7 ms (1,03×)**: no lo acelera (haría falta un intérprete) pero tampoco lo frena |
| 40 ficheros, solo 6 marcan | 776,8 ms (shell loop) | 121,1 ms | **6,4×**, y un 11 % mejor que `grep -rl 'marca' | xargs` |

El coste fijo de Python (~19 ms por arranque) no se quita desde fuera. Lo que
sí se quita es **ejecutarlo donde no hace falta**: filtrar antes de lanzar el
proceso. `--exec` es ese filtro, sin tubería intermedia.

## Rebanada de paridad (0.3.0): las 7 que faltaban

`-S` · `-t` / `--type-not` / `--type-list` (48 tipos) · `--max-depth` ·
`--max-filesize` · `--exclude-from` · `--binary-files` · `-b`.

Verificado contra GNU grep y ripgrep en 25 casos (`parity.sh`), y todo lo
anterior sigue verde (87 tests, oraculo 26/26, 1419/1419 spans, 40/40 y 5/5
de conformance, fuzzers a cero).

### El hallazgo: hay TRES walkers, no dos

Al medir `--max-filesize` salio que por debajo de 2 MB (micro path) **no se
filtraba nada**: el micro-tree fast path tiene su propia recoleccion de
ficheros, distinta del explorador concurrente y del camino ordenado. Un
filtro nuevo que se anada solo a dos de los tres produce la peor
discontinuidad posible: **el mismo comando devuelve listas distintas** segun
el tamano del arbol. Corregido en los tres; `micro == swarm` es ahora un caso
de la conformance.

## Ultima rebANADA: -G, -z, --crlf, --heading

- **`-G`**: era una mentira. La bandera se aceptaba y el patron se leia como
  ERE, asi que significaba otra cosa. `src/bre.zig` traduce BRE->ERE; 15/15
  casos contra `grep -G`.
- **`-z` / `--null-data`**: semantica de grep (en rg `-z` es `--search-zip`).
  Tres cambios coordinados + el camino rapido desactivado. Verificado contra
  `grep -z`.
- **`--crlf`**: `$` acepta antes del `\r`; medido contra `rg --crlf`.
- **`--heading` / `--pretty` / `--vimgrep`**: `--vimgrep` sale byte a byte
  igual que rg; `--heading` fuerza el camino ordenado porque en streaming los
  grupos de ficheros se entremezclan.

Verificacion completa: 90 tests, oraculo 26/26, 1419/1419 spans, 40/40 + 25/25
+ 15/15 + 5/5 de conformance, fuzzers a cero.

## Las cinco que dejaron de ser "no vale"

Revisadas una a una con lo que ya teníamos (procesos, spans, registros NUL):

- **`` / `\B`**: la razón principal de querer PCRE2, resuelta en el motor.
  12/12 contra `grep -E` (línea y `-o`).
- **`-U` / `--multiline`**: el match puede cruzar `
`; `^`/`$` siguen siendo por
  línea (rg) y se imprimen las líneas que el match abarca.
- **`--pre` / `--pre-glob`**: busca la salida de un comando. Verificado contra rg.
- **`--encoding`**: auto/none/utf-16*/latin1, contra rg.
- **`--heading` / `--pretty` / `--vimgrep`** + `--stop-on-nonmatch`.

Dos defectos reales salieron de aquí:

1. **`` en `-o` devolvía un byte de más**: la frontera se resolvía al consumir
   el byte siguiente. La regla correcta es resolverla antes, y eso vale para los
   tres runners (línea, spans y multilínea).
2. **El cell-fuzz se puso rojo**: su tabla de expectativas tenía `pub` como
   "error de sintaxis conocido". Ya no lo es, así que la tabla se actualizó
   (junto con `\Bscan\B`) y el RADIX subió de 24 a 25 patrones.
