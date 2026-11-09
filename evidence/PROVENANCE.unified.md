# Provenance del manifiesto unificado de evidencia

**Fecha:** 2026-11-09 · **Árbol:** commit `1af9572` (main, tras el merge
`4439ed4` del port nativo de Windows `feature/zigrep-windows-port`) ·
**Binario de verificación:** `zgrep 0.2.2`, Zig 0.16.0, `-Doptimize=ReleaseFast`

Este documento **no sustituye** a ningún manifiesto anterior: los conserva
todos, byte a byte, y explica por qué existe un manifiesto nuevo. La regla que
gobierna esta carpeta es la que ya declaró el agente del port de Windows en
`evidence/windows-port/README.md`: *reportar la obsolescencia, no reescribir el
registro histórico*.

---

## 1. Cadena de manifiestos (todos siguen en disco, ninguno se borró)

| Manifiesto | SHA-256 | Estado | Por qué se conserva |
|---|---|---|---|
| `evidence/SHA256SUMS.txt` | `a12d8fc3e22f44dca4b4c382354e6ad2e81a1e36a7814664e94c7de17c597d99` | histórico, **obsoleto en 33 entradas** | Es el índice raíz acumulado por campañas sucesivas: 163 entradas con **duplicados** (`evidence/REPORT.md` aparece 5 veces, `src/main.zig` 4 veces) y rutas de ficheros que han cambiado desde entonces. Es el registro de cómo se construía la evidencia; no una foto del árbol actual. |
| `evidence/SHA256SUMS_source.txt` | `ce0c321c871b683f0428ee4d9dc035afbfd9e54c5fb8433c07bb6231dded5195` | histórico | Índice del conjunto original de capturas, anterior a las campañas del port. |
| `evidence/windows-port/SHA256SUMS.txt` | `4f985fe406187c60e19238f5f90df35401dc5beadb44f91cec1fabc9c1a89862` | histórico, **1 entrada obsoleta** (`GUIA.md`) | Pertenece al port de Windows y fija el hash de `GUIA.md` **de su rama**; el merge cambió ese fichero, así que la entrada dejó de cuadrar. Sus dos entradas de evidencia (`benchmark.json`, `README.md`) siguen cuadrando. |
| `evidence/pruning-windows/SHA256SUMS.txt` | `948dcdcd567848182d57c501cc034c571bb26938fb356e23347c199b39f5c150` | histórico, **verificable con adaptación** | Generado en Windows: usa **separadores backslash** (`raw\file.txt`), que `sha256sum -c` no resuelve en Linux. Sus 46 entradas cuadran tras convertir `\` → `/`. |
| **`evidence/SHA256SUMS.unified.txt`** | `f0d1fb0ada5a1bc0534282917f51cafe4540a52734f243cec880b00e70d82429` | **vigente** | Índice único, sin duplicados, con rutas POSIX, del árbol unificado. 243 entradas, **243/243 verifican**. |

Los cuatro manifiestos antiguos se conservan **sin modificar un byte**: sus
hashes son los de la tabla y así quedan fixing la procedencia. Para verificar
los que usan backslash en Linux:

```sh
sed 's|\\|/|g' evidence/pruning-windows/SHA256SUMS.txt > /tmp/sums-linux.txt
(cd evidence/pruning-windows && sha256sum -c /tmp/sums-linux.txt)
```

## 2. Qué cubre el manifiesto vigente

- `evidence/**` — las 212 piezas de evidencia, incluidas las capturas crudas
  del port de Windows (`windows-port/`, `pruning-windows/raw/`), los informes
  de bench, fuzz, REA y los JSON de 10 runs.
- `src/**` (13) y `scripts/**` (12) — el código exacto con el que se produjo
  esa evidencia.
- `build.zig`, `build.zig.zon`, `README.md`, `GUIA.md`, `PRUEBAS.md` y
  `.github/workflows/ci.yml` — la configuración y la documentación que
  describen esa misma foto.

Reglas (aplicadas por `evidence/regen_manifest.sh`, determinista):

1. Rutas relativas a la raíz del repo, separadores POSIX, orden `LC_ALL=C`.
2. Sin duplicados.
3. **No** cubre el propio manifiesto ni este documento: eso rompe la
   circularidad y permite anclar el hash del manifiesto aquí.
4. Es una **foto de un commit**, no un invariante: cuando cambie el árbol, se
   regenera y se anota el commit en la cabecera.

```sh
bash evidence/regen_manifest.sh
sha256sum -c evidence/SHA256SUMS.unified.txt
```

## 3. Procedencia del port de Windows que este manifiesto absorbe

El PR `feature/zigrep-windows-port` (tip `56ec40d`, 19 commits) llega con su
propio paquete de evidencia, íntegro dentro de `evidence/`:

- `evidence/windows-port/` — informe del port, `benchmark.json` y el manifiesto
  de tres entradas cuyo hash se conserva arriba.
- `evidence/pruning-windows/` — 46 capturas crudas (`raw/`) del podado de
  árboles sobre `CoEvoLang` con `rg` y con `zigrep`, y `RESULTS.md`.

Nada de ese material se editó ni se normalizó al unificar: el manifiesto
vigente lo cubre tal cual, de modo que la cadena "captura cruda → hash →
manifiesto" sigue siendo auditable.

## 4. Verificación re-ejecutada sobre el árbol unificado (2026-11-09)

Recompilación **desde cero** de ambos lados (cachés nuevas, Zig 0.16.0,
`-Doptimize=ReleaseFast`):

| Comprobación | Baseline `aa81c9b` | Unificado `1af9572` |
|---|---|---|
| Binario | `02d8b676…` (4.918.264 B) | `dbd6e4c5…` (4.975.208 B) |
| `zig build test` | 52/52 | **56/56** |
| `zig build oracle` (GNU grep + ripgrep) | 26/26 | **26/26** |
| Fuzz entrópico, 100.002 ops | 0 anomalías, 0 crashes | **0 anomalías, 0 crashes** |
| Cell fuzzer, 200.000 celdas | 0 anomalías | **idénticas byte a byte** (`00bc39ca…`) |
| Cell fuzzer, 373.248 celdas (`--all`) | 0 anomalías | **idénticas byte a byte** (`8af748e6…`) |
| Matriz diferencial, 540 casos, `--force-swarm` | — | **540/540 idéntico al baseline** |
| Matriz diferencial, 540 casos, path por defecto | — | 520/540; las 20 diferencias están **todas** en el árbol `ignored`, por la semántica deliberada del micro path (ignora `.gitignore`) |

### 4.1 Hallazgo sobre el propio fuzzer (no sobre la herramienta)

`common.readFile` leía **solo los primeros 128 bytes** del fichero de
haystack. Como los 128 primeros bytes de `src/main.zig`, `src/kamikaze.zig`,
`src/search.zig` y `build.zig` son idénticos entre el baseline y el árbol
unificado, el digest por celda daba el mismo SHA-256 con cualquier corpus: la
igualdad observada **no dependía del contenido real** del haystack.

Para que la campaña midiera algo, se recompilaron **dos veces** los harnesses
—copias externas al repo, el árbol queda intacto— con `readFile` leyendo el
fichero completo:

- Con los 128 B: 74.151 match / 105.015 nomatch.
- Con el fichero completo: 80.782 match / 98.384 nomatch (200.000 celdas).

El digest pasa a ser `00bc39ca…` (200.000 celdas) y `8af748e6…` (373.248
celdas), idénticos en ambos binarios con el haystack real. Es decir: **con el
payload completo, la igualdad sigue siendo exacta**.

### 4.2 Semántica confirmada

El micro path **ignora** `.gitignore`/`.dataignore` (el usuario lo confirma
explícitamente el 2026-11-09). `--force-swarm` reproduce el comportamiento
anterior byte a byte. El job nativo de Windows del CI cubre **las dos**
variantes.

---

## 5. Ampliación 2026-11-09 (posterior al texto de arriba)

La campaña de paridad con GNU grep añadió `evidence/feature-corpus/`
(corpus de superficie + matriz de decisiones + conformance contra
`grep 3.11`) y regeneró `SHA256SUMS.unified.txt`. La cabecera de este
documento sigue describiendo el estado del commit con el que nació; lo que
cuenta es el manifiesto vigente y lo que verifique en disco.

| Componente | Resultado |
|---|---|
| `zig build test` | 82 pass / 1 skip |
| Oráculo diferencial (`zig build oracle`) | 26/26 contra `grep` y `rg` |
| Conformance nuevo (`conformance.sh`) | 40/40 contra `grep 3.11` |
| Fuzzer (100.001 permutaciones) | 0 anomalías |
| Cell fuzzer (1.000 celdas) | 0 anomalías |
| A/B sin contexto, 171 MB | 0.2.2 y 0.3.0 idénticos (mediana 0,01 s) |
| Binario de las mediciones | `zgrep 0.3.0`, Zig 0.16.0, ReleaseFast |

