# GUIA.md — guía de uso de `zigrep` (antes `zgrep`)

Guía operativa para una persona o agente que usa `zigrep` a mano. El detalle técnico y
la evidencia están en `README.md` y `evidence/REPORT.md`.

---

## 1. Compilar

```sh
cd ~/Development/"ISyCo Git"/ZigGrep
zig build -Doptimize=ReleaseFast      # sale en zig-out/bin/zgrep (o zigrep)
zig build test --summary all          # debe decir 31/31 tests passed
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
# buscar en todo un árbol con el enjambre concurrente kamikaze
zigrep -k "const" workspace/assembly

# solo los nombres de los archivos que coinciden
zigrep -l "const" workspace/assembly

# contar coincidencias por archivo (una línea por archivo, incluidos los :0)
zigrep -c "const" workspace/assembly

# silencioso: solo el código de salida (0 = hubo coincidencia, 1 = no)
zigrep -q "const" workspace/assembly && echo "existe"

# modo Kamikaze con filtrado de extensiones (ej: solo código Zig)
zigrep -k --include-ext=zig "Searcher" .

# excluir extensiones ruidosas o pesadas
zigrep -k --exclude-ext=log,tmp,lock,min.js "token" .

# excluir carpetas personalizadas
zigrep -k --exclude-dir=build,dist,temp "patrón" /ruta/al/repo
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

`zgrep` solo acepta cadenas fijas (`-F`). No hay expresiones regulares, ni
`-i`, ni `-w`, ni `-z`. Un patrón con salto de línea se rechaza con
mensaje y salida 2.

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

* necesites salida **byte a byte idéntica a `grep -rInF`**, en el mismo
  orden (verificado en los controles de `evidence/`);
* el patrón sea corto (1–64 bytes) y el árbol grande: tras `5c89b40`,
  `zgrep` gana a `grep` por ~8× y a `rg` por ~1,4–1,7× en `-r`, `-l` y `-c`;
* no tengas `rg` instalado y quieras algo más rápido que `grep`.

**No lo uses cuando:**

* necesites expresiones regulares, `-i`, `-w` ni `-z`: no existen;
* el trabajo sea **salida muy voluminosa sobre árboles pequeños** (cientos de
  miles de líneas de salida en < 150 MB): ahí `rg` es 2,2× más rápido y
  `grep` 1,3× más rápido que `zgrep`;
* vayas a comparar `-c` con `rg`: las semánticas de archivos binarios
  difieren (sección 3);
* corras en Windows/macOS: solo se ha probado en Linux x86_64.

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
zig build test --summary all     # 24/24
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
