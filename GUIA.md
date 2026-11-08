# GUIA.md — guía de uso de `zigrep` (antes `zgrep`)

Guía operativa para una persona o agente que usa `zigrep` a mano. El detalle técnico y
la evidencia están en `README.md` y `evidence/REPORT.md`.

---

## 1. Compilar

```sh
cd ~/Development/"ISyCo Git"/ZigGrep
zig build -Doptimize=ReleaseFast      # sale en zig-out/bin/zgrep (o zigrep)
zig build test --summary all          # 44/44 tests passed
zig build oracle                      # oráculo diferencial puro Zig (19/19 tests passed)
```

Requisitos: Zig 0.16.0. No necesita libc ni dependencias externas.

Para dejarlo en el PATH:

```sh
ln -sf "$PWD/zig-out/bin/zgrep" ~/.local/bin/zigrep
ln -sf "$PWD/zig-out/bin/zgrep" ~/.local/bin/zgrep
```

---

## 2. Uso básico

```sh
zigrep PATRÓN RUTA...          # siempre recursivo, siempre con número de línea
```

Ejemplos reales:

```sh
# buscar en todo un árbol (enjambre concurrente kamikaze por defecto)
zigrep "const" workspace/assembly

# búsqueda determinista ordenada por ruta (compatible con GNU grep)
zigrep --sort "const" workspace/assembly

# expresiones regulares lineales (Thompson NFA + Lazy DFA, sin backtracking catastrófico)
zigrep 'fn\s+\w+\(' /ruta/al/proyecto

# insensibilidad a mayúsculas con soporte Unicode Latin-1 (á/Á, ñ/Ñ, ü/Ü, etc.)
zigrep -i "ñandú" docs/

# navegación 2D Befunge: techo (solo archivos en raíz a profundidad 0, rebota carpetas)
zigrep -m "v^" "Searcher" src

# navegación 2D Befunge: trampolín (salta raíz y bucea directo a subcarpetas)
zigrep -m "^v" "name" .github

# solo los nombres de los archivos que coinciden
zigrep -l "const" workspace/assembly

# contar coincidencias por archivo (una línea por archivo, incluidos los :0)
zigrep -c "const" workspace/assembly

# silencioso: solo el código de salida (0 = hubo coincidencia, 1 = no)
zigrep -q "const" workspace/assembly && echo "existe"

# filtrado de extensiones (ej: solo código Zig)
zigrep --include-ext=zig "Searcher" .

# excluir extensiones ruidosas o pesadas
zigrep --exclude-ext=log,tmp,lock,min.js "token" .

# excluir carpetas personalizadas
zigrep --exclude-dir=build,dist,temp "patrón" /ruta/al/repo
```

---

## 3. Sistema de Filtrado e Ignore (`.dataignore`)

`zigrep` incluye un **FilterEngine universal**:

1. **Exclusiones por defecto (Out of the box):**
   * Carpetas omitidas automáticamente: `.git`, `.zig-cache`, `__pycache__`, `node_modules`, `.venv`, `venv`, `target`, `.cache`, `.idea`, `.vscode`.
   * Extensiones omitidas automáticamente: `.pyc`, `.pyo`, `.o`, `.a`, `.so`, `.dylib`, `.dll`, `.class`, `.jar`, `.log`, `.min.js`, `.min.css`, `.map`, `.lock`, `.swp`, `.DS_Store`.

2. **Archivos `.dataignore` y `.gitignore`:**
   * `zigrep` busca y respeta automáticamente archivos `.dataignore` y `.gitignore` presentes en el directorio raíz o de ejecución.
   * En `.dataignore` puedes escribir patrones estilo glob (`*.csv`, `logs/`, `temp_*`).

3. **Anulación para escaneo en bruto (`--no-ignore`):**
   * Si necesitas buscar en absolutamente todo (incluyendo `.git`, binarios, cachés y `.dataignore`):
     ```sh
     zigrep -k --no-ignore "patrón" .
     ```
   * Si solo quieres desactivar las listas internas por defecto pero seguir respetando tu `.dataignore`:
     ```sh
     zigrep -k --no-default-ignore "patrón" .
     ```

### Cómo se interpreta el resultado

| Código de salida | Significado |
|---|---|
| `0` | hubo al menos una coincidencia |
| `1` | no hubo coincidencias |
| `2` | error: patrón ausente, ruta inexistente, opción desconocida |

`zigrep` soporta tanto búsqueda literal acelerada por SIMD (`-F` o auto) como expresiones regulares lineales (`. [a-z] [^x] \d \w \s * + ? {n,m} | () ^ $`), `-i` (ASCII + Latin-1 Unicode), `-w` (palabra completa) y `-e` (múltiples patrones). Un patrón con salto de línea se rechaza con mensaje y salida 2.

---

## 3. Archivos binarios

* Por defecto, un archivo que contiene un byte NUL dentro de los primeros
  8192 bytes se salta (igual que `grep -I`).
* `-a` busca también en esos archivos como si fueran texto.
* `-c` imprime `ruta:0` para los archivos binarios saltados, igual que
  `grep`. **ripgrep no lo hace**: omite esos archivos por completo. Si
  comparas `zgrep -c` con `rg -c` y ves que faltan filas, no es un bug de
  `zgrep`, es la diferencia documentada con `rg`.

---

## 4. Ajuste de rendimiento (no existen en grep)

```sh
zgrep -F "const" RUTA                    # el default ya usa el kernel más rápido
zgrep -j 4 -F "const" RUTA               # limitar hilos
zgrep --stats -F "const" RUTA            # informa por stderr: tiempo y MB/s
```

* `--algo=auto` (por defecto) busca el **byte más raro** del patrón con
  escaneo vectorizado y compara el patrón completo solo cuando ese byte
  aparece. Es el modo más rápido en el corpus medido.
* **Ya no hace falta forzar `--algo=memchr`**: desde el commit `5c89b40` el
  modo por defecto *es* ese kernel. El defecto de rendimiento `auto`
  (claim C8 del informe) quedó resuelto; los tres modos siguen produciendo
  salida idéntica byte a byte.
* `--algo=bmh` (Boyer–Moore–Horspool) sigue disponible por comparación, pero
  perde contra el default a cualquier longitud de patrón (1 a 64 bytes) en el
  corpus medido.
* `--stats` escribe por **stderr**, así que puedes combinarlo con la salida
  normal sin contaminarla:

  ```sh
  zgrep --stats -F "const" RUTA > resultados.txt
  ```

---

## 5. Cuándo usarlo — y cuándo no

**Úsalo cuando:**

* necesites rendimiento extremo en escaneo de archivos con enjambre de hilos Kamikaze o salida determinista (`--sort`);
* el patrón sea corto o largo: `zigrep` bate a `grep` por hasta 165× y a `rg` por hasta 2,6×;
* quieras evitar el overhead de dependencias de libc o runtimes pesados;
* busques patrones con regex lineal con garantía de $O(N)$ sin backtracking catastrófico.

**No lo uses cuando:**

* necesites backreferences o lookaround en regex (no soportados por diseño para garantizar $O(N)$);
* corras en Windows/macOS: el pipeline de kernel `getdents64` directo está optimizado para Linux x86_64.

---

## 6. Problemas frecuentes

| Síntoma | Causa | Arreglo |
|---|---|---|
| `zgrep: missing PATTERN` | falta el patrón | `zgrep -F PATRÓN RUTA` |
| salida 2 y `unrecognized option` | opción que no existe | mira `zgrep --help` |
| salida 2 y `patterns containing a newline` | el patrón tiene `\n` | divide el patrón en uno por línea |
| `zgrep: RUTA: NOENT` | la ruta no existe | revisa la ruta |
| sale mucho más lento de lo esperado | el corpus está en caché frío o la máquina está cargada | repite la mediana de varias corridas; mira `--stats` |
| `rg` no encuentra lo que `zgrep` encuentra | `rg` respeta `.gitignore` y oculta | añade `--no-ignore --hidden` a `rg` |
| `rg -c` no lista todos los archivos | `rg` omite binarios | usa `zgrep -c` o `grep -c` como referencia |

Para ver el estado del build y los tests:

```sh
zig build test --summary all     # 44/44 tests passed
zig build oracle                 # 19/19 differential oracle tests passed
```

---

## 7. Repetir el experimento completo

```sh
zig build -Doptimize=ReleaseFast
zig build test --summary all

# corpus sintético con verdad de terreno
zig run scripts/gen_corpus.zig -- \
    --out=bench-corpus/synthetic --files=2000 --size=65536 --seed=20261107

# controles de corrección
bash scripts/cli_controls.sh
zig run scripts/check.zig -- \
    --name=zgrep ./zig-out/bin/zgrep -rnF const /ruta/al/corpus \
    --name=grep  grep -rnIF const /ruta/al/corpus \
    --name=rg    rg -n -F --no-ignore --hidden const /ruta/al/corpus

# tiempos (las rondas se intercalan entre grupos, en orden rotativo)
zig run scripts/bench.zig -- --runs=10 --warmup=3 --bytes=654899262 \
    --out=res.json \
    --name=zgrep ./zig-out/bin/zgrep -rnF const /ruta/al/corpus \
    --name=grep  grep -rnIF const /ruta/al/corpus \
    --name=rg    rg -n -F --no-ignore --hidden const /ruta/al/corpus
```

Todo lo crudo queda en `evidence/`; el resumen y la tabla de claims están en
`evidence/REPORT.md`.

## Regex, -i, -w, -e (2026-11-08)

`zigrep PATTERN` ahora es regex (dialecto tipo `rg`): `. [a-z] [^x] [[:alpha:]] \d \w \s * + ? {n,m} | ( ) ^ $`.
Un patrón sin metacaracteres usa el kernel literal rápido de siempre. `-F` fuerza literal.

- `-i` ignora mayúsculas (ASCII) · `-w` palabra completa · `-e P` (repetible) varios patrones.
- No soportado (da error, nunca resultado incorrecto): `\b`, backreferences, lookaround.
- Motor: NFA -> DFA perezoso por hilo (`src/regex.zig`), lineal, sin backtracking. Si el patrón
  tiene un literal obligatorio (>=3 bytes) se usa como prefiltro y el DFA solo mira esas líneas.
- Oráculo: `analysis/regex_oracle.py` compara conteos por archivo contra `grep -E` y `rg`.
