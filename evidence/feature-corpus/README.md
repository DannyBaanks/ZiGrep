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
