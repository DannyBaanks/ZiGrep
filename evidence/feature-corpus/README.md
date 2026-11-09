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

Eso desbloqueó `-o`, `--column`, `--color`, `-r/--replace` y `--count-matches`.

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
