# GUIA.md — guía de uso de `zigrep` (antes `zgrep`)

Guía operativa para una persona o agente que usa `zigrep` a mano. El detalle técnico y
la evidencia están en `README.md` y `evidence/REPORT.md`.

## El comando de Windows

**Instalar (una sola vez, sin permisos de administrador):**

```powershell
irm https://raw.githubusercontent.com/DannyBaanks/ZiGrep/v0.2.2/install.ps1 | iex
```

> La URL con `main` (`.../main/install.ps1`) empieza a funcionar cuando el
> PR #1 se mergee. Hasta entonces usa la del **tag**, que es la verificada
> (esta guia se escribio ejecutando exactamente esa linea).

**Regla de oro:** no ejecutes `irm ... | iex` sobre un texto que no hayas
leído antes. El instalador verifica el SHA-256 del `.zip` descargado contra el
`SHA256SUMS.txt` publicado en la release y **aborta sin instalar nada** si no
coincide. Si prefieres revisarlo antes, descárgalo y léelo:

```powershell
irm https://raw.githubusercontent.com/DannyBaanks/ZiGrep/v0.2.2/install.ps1 -OutFile install.ps1
Get-Content install.ps1
.\install.ps1
```

**Usarlo (después de reiniciar la terminal):**

```powershell
zigrep -l -F Searcher src
```

Salida real:

```text
src\kamikaze.zig
src\main.zig
src\scan.zig
src\search.zig
```

`-l` lista los archivos con coincidencias; quítalo para mostrar las líneas.

### Salida real del instalador publicado (v0.2.2)

Ejecutado de verdad contra la release publicada (no un simulacro), desde cero:

```text
=== 0. estado inicial ===
  install dir existe : False
  ya esta en el PATH  : False
=== 1. descargar el instalador (irm) ===
  descargado: 11536 caracteres
  primera linea: <#
=== 2. ejecutar el instalador real (irm | iex) ===

  ZiGrep - native Windows installer
  (Windows-native build; no WSL, no C runtime needed)

==> Architecture: x86_64
==> Install directory: C:\Users\progr\AppData\Local\Programs\ZiGrep
==> Downloading zigrep-windows-x86_64.zip
==> Verifying SHA-256
OK  checksum matches (c6d07401109d4a47ceb31170543e691a3d131b9c84a1d1f19dcd667871a84543)
==> Extracting
OK  installed 2 executable(s) into C:\Users\progr\AppData\Local\Programs\ZiGrep
OK  added C:\Users\progr\AppData\Local\Programs\ZiGrep to the user PATH

  Restart your terminal (or open a new one) so the PATH change applies.

  Version check:
    zgrep 0.2.2

  Try it:
    zigrep --help
    zigrep -n TODO src

  ZiGrep is ready.
  exit=0
=== 3. verificacion ===
  zigrep.exe instalado : True
  zgrep.exe  instalado : True
  install.ps1 copiado  : True
  version reportada    : zgrep 0.2.2
  install dir en PATH   : True
=== 4. uso real del binario instalado ===
  busqueda: 2:needle
=== 5. hash publicado vs asset real ===
  SHA256SUMS.txt publicado:
    f9a6198b023a7cf44454bd23b5216c7106d8d892b16810eafa5a9c120a6d3174  zigrep-linux-x86_64.tar.gz
    40bf3ce12bf44e9134763ba9a7381c47de63d0e081dfdaf946d6635f3ed5737f  zigrep-linux-aarch64.tar.gz
    c6d07401109d4a47ceb31170543e691a3d131b9c84a1d1f19dcd667871a84543  zigrep-windows-x86_64.zip
=== 5b. el binario responde por stdout (no stderr) ===
  stdout : 'zgrep 0.2.2'
  stderr : ''
  exit   : 0
=== 6. PATH de usuario restaurado ===
  install dir sigue en el PATH: False
=== fin ===
```

Lo que se ve en `busqueda: 2:needle` es el binario **instalado** buscando
`needle` en un fichero de prueba: la linea 2 es la que contenia la palabra.

### Qué hace el instalador (y cómo leer su salida)

| Salida | Significado | Qué hacer |
|---|---|---|
| `OK  checksum matches (<sha256>)` | El `.zip` coincide con el `SHA256SUMS.txt` de la release | Nada: la instalación es segura |
| `ERR Checksum mismatch!` + `expected/actual` | El fichero descargado **no** coincide con el hash publicado | **No instalar.** Puede ser un proxy que reescribe el archivo o un release corrupto. Descarga el `.zip` a mano desde la página de la release y compara los hashes |
| `OK  installed 2 executable(s) into <dir>` | `zigrep.exe` y `zgrep.exe` copiados | Ninguno |
| `OK  added <dir> to the user PATH` | El directorio se añadió al `PATH` **de usuario** (sin admin) | Reinicia la terminal: el `PATH` ya está actualizado, pero las shells abiertas conservan el valor antiguo |
| `OK  <dir> is already in the user PATH` | Ya estaba instalado | Ninguno |
| `WARN  No published checksum for ...; continuing without verification` | La release no tiene `SHA256SUMS.txt` (o no se pudo descargar) | Instala, pero **no confíes en la integridad**: descarga el `.zip` y verifícalo a mano |
| `ERR  Could not download the prebuilt binary: ...` | No hay red o no existe el asset para tu arquitectura | Si tienes Zig 0.16+, el instalador compila desde fuente; si no, descarga el `.zip` a mano desde https://github.com/DannyBaanks/ZiGrep/releases |
| `ERR  Unsupported architecture: ...` | Ni `AMD64` ni `ARM64` (p. ej. Windows en ARM emulado o x86 de 32 bits) | Compila desde fuente: `zig build -Doptimize=ReleaseFast` |

Ficheros de la release (todos los assets, con sus hashes en `SHA256SUMS.txt`):

| Asset | Plataforma |
|---|---|
| `zigrep-linux-x86_64.tar.gz` | Linux x86_64 (estático, stripped) |
| `zigrep-linux-aarch64.tar.gz` | Linux ARM64 (estático, stripped) |
| `zigrep-windows-x86_64.zip` | Windows x86_64 (`.exe` nativo) |
| `SHA256SUMS.txt` | Hashes de los tres archivos |

### Trampas del instalador

* **`irm | iex` no pide confirmación**: se ejecuta al instante. Revisa el
  fichero antes si no te fías de la fuente.
* **El `PATH` solo cambia para las terminales nuevas**: la sesión actual sí
  queda actualizada (el instalador la modifica en memoria), pero cualquier
  terminal ya abierta necesita un reinicio.
* **`zgrep --version` y `zgrep --help` escriben en `stdout`** (como `grep` y
  `ripgrep`). En las versiones anteriores (hasta la 0.2.1) escribían en
  `stderr`, y en PowerShell eso aparecía como un `RemoteException` rojo
  aunque todo hubiera ido bien. Además el instalador abortaba en el "Version
  check" por eso. Corregido en la **0.2.2**.
* **No hay versión ARM64 de Windows todavía**: el instalador detecta `ARM64` y
  pide `zigrep-windows-aarch64.zip`, que todavía no se publica. En ese caso
  compila desde fuente.

---

## 1. Compilar

```sh
cd ~/Development/"ISyCo Git"/ZigGrep
zig build -Doptimize=ReleaseFast      # sale en zig-out/bin/zgrep (o zigrep)
zig build test --summary all          # 56/56 tests passed (Linux y native Windows)
zig build oracle                      # oráculo diferencial puro Zig (26/26 Linux, 25/25 native Windows)
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
   * **Micro-árboles (< 2 MB): el walk ascendente se omite.** Por defecto, un
     árbol cuyos archivos regulares sumen menos de 2 MB se escanea en el
     hilo llamante, con 0 hilos y **sin** inspeccionar `.dataignore` /
     `.gitignore` hacia arriba: en un árbol tan pequeño el mantenimiento de
     ignorados es ruido. Si necesitas ese comportamiento *sí* (o el
     rendimiento del enjambre), pídelo explícitamente:

     ```sh
     zigrep --force-swarm "patrón" .
     ```

     `--force-swarm` restaura el comportamiento anterior completo: 12 hilos
     Kamikaze y walk ascendente de `.dataignore` / `.gitignore`.

3. **Anulación para escaneo en bruto (`--no-ignore`):**
   * Si necesitas buscar en absolutamente todo (incluyendo `.git`, binarios, cachés y `.dataignore`):
     ```sh
     zigrep -k --no-ignore "patrón" .
     ```
   * Si solo quieres desactivar las listas internas por defecto pero seguir respetando tu `.dataignore`:
     ```sh
     zigrep -k --no-default-ignore "patrón" .
     ```

   * `--no-ignore` desactiva también las exclusiones por defecto (`.git`,
     `node_modules`, `*.log`, …): es un escaneo en bruto.

### Cómo saber qué ruta se usó

`--stats` imprime `micro_path=yes|no` por stderr:

```sh
zigrep --stats -F "const" . 2>&1 >/dev/null | grep micro_path
# kamikaze: dirs=… files=… micro_path=yes elapsed_s=… throughput_MBps=…
```

`micro_path=yes` ⇒ 0 hilos, sin walk de ignorados. `micro_path=no` ⇒ el
enjambre (árbol ≥ 2 MB, varias rutas, `--sort`, `--force-swarm`, …).

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
zgrep --force-swarm -F "const" RUTA     # siempre enjambre (nunca micro path)
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

## 4b. Paridad con GNU grep (nuevo en 0.3.0, 2026-11-09)

Bandera por bandera, con la semántica de GNU grep y verificado contra
`grep 3.11` en 40 casos (`evidence/feature-corpus/conformance-results.txt`):

```sh
zgrep -A2 -B1 -n "patron" RUTA       # contexto: 2 después, 1 antes
zgrep -C3 "patron" RUTA              # contexto simétrico
zgrep -x "linea exacta" RUTA         # solo líneas completas (-x / --line-regexp)
zgrep -f patrones.txt RUTA           # patrones desde fichero, uno por línea
zgrep --no-line-number "patron" RUTA # sin número de línea
zgrep -Z -l "patron" RUTA            # nombres separados por NUL (para xargs -0)
zgrep -s "patron" /ruta/ilegible     # sin mensajes de error
zgrep --text "patron" RUTA           # alias largo de -a
```

* El contexto usa un bucle ordenado por línea; el salto directo al siguiente
  match se conserva cuando **no** hay contexto ni `-v`, así que el caso normal
  no pierde rendimiento (medido: igual que 0.2.2 en 171 MB).
* `-m N` con contexto: deja de contar matches pero **vací­a** el contexto
  posterior del último, igual que `grep`.
* Los grupos disjuntos se separan con `--`, y también entre ficheros.
* `--no-line-number` solo tiene forma larga: `-N` es la navegación Befunge.
* `-f` con un fichero vacío selecciona nada (como `grep`); `-f -` no existe.
* `-s` antes se aceptaba y **no suprimía nada**: era un no-op. Ahora suprime
  los mensajes de fichero ilegible.

Lo que **no** está y por qué, en `evidence/feature-corpus/CORPUS.md`
(PCRE2/-P, multilínea, `-o`, `--color`, `--replace`, `--json`…).

## 4c. Los spans: -o, --column, --color, --replace, --count-matches

El motor dejó de responder "¿coincide?" y responde "¿dónde?" (leftmost-longest,
la semántica POSIX que usa `grep`). Verificado contra `grep -E -o`: **1419/1419
casos idénticos**.

```sh
zgrep -o '\d+\.\d+' fichero.txt          # solo la parte que coincide
zgrep -o -n 'cat' a.txt b.txt               # con numero de linea
zgrep --column 'cat' fichero.txt            # columna (1-based) del primer match
zgrep --color=always 'cat' fichero.txt      # resalta SOLO los spans
zgrep --count-matches -c 'a' fichero.txt    # cuenta matches, no lineas
zgrep --replace NUEVO -o 'a' fichero.txt    # reemplaza cada match (literal)
zgrep --passthru --replace NUEVO 'a' f.txt # e imprime tambien las que no coinciden
```

Notas honestas:

* `--replace` (solo largo: `-r` es `--recursive`) es **reemplazo literal**: `$1` no existe porque el motor no
  guarda capturas.
* El formato de bytes de `--color` es el nuestro (línea en verde, match en
  `01;31`), no el de `grep` (que además rellena con `\e[K`); la paridad se
  compara quitando el ANSI.
* Ojo con el dialecto: es ERE (el de `rg`), no el BRE de `grep` (ver 4b).

## 4d. `--exec`: de "encontré" a "actúo" (nuevo en 0.3.0)

```sh
zgrep -e MARCADOR --exec 'python3 main.py {}' .
zgrep -e MARCADOR -X 'sh -c "echo ruta=\$1" {}' .
zgrep -e MARCADOR --exec 'wc -l' .        # sin {} la ruta se añade al final
```

Por cada fichero que coincide, ejecuta el comando con la ruta; las corrientes
del hijo se heredan, así que se ve exactamente lo que escribirías a mano.
`{}` se sustituye en cualquier parte del argumento (no solo como palabra
completa, que es lo que exige `find`).

Medido cara a cara (`evidence/feature-corpus/README.md`):

| Escenario | Resultado |
|---|---|
| Un fichero, mismo trabajo que Python | +5,7 ms (1,03×) → **no acelera Python, no lo frena** |
| 40 ficheros, 6 marcados | **6,4×** más rápido que el shell loop; 11 % mejor que `grep -rl | xargs` |

La ganancia no está en ejecutar Python más rápido (para eso haría falta un
intérprete de Python), sino en **no ejecutarlo donde no hace falta**: el filtro
ocurre antes de lanzar el proceso. Detalles de implementación: secuencial a
propósito (procesos arbitrarios en paralelo dan salida entrelazada) y usa el
camino ordenado, que es el que sabe qué ficheros coincidieron.

---

## 4e. Paridad con rg: tipos, `--max-depth`, `--max-filesize`, `-b`, `-S`

```sh
zgrep -t py -l 'patron' RUTA          # solo ficheros Python
zgrep -tpy -l 'patron' RUTA           # junto, como rg
zgrep -t zig --type-not txt -l .      # combinar include y exclude
zgrep --type-list                     # los 48 tipos del registro
zgrep --max-depth 1 -l 'patron' .     # solo la raiz (equivale a nav v^)
zgrep --max-filesize 2M -l 'patron' . # salta los ficheros grandes
zgrep --exclude-from=globs.txt .      # globs desde fichero
zgrep -bn 'patron' fichero.txt        # offset en bytes: linea:offset:text
zgrep -bo 'patron' fichero.txt        # offset del MATCH (como grep -bo)
zgrep -S 'patron' RUTA                # insensible salvo que haya mayuscula
zgrep --binary-files=text -l 'p' bin.dat
```

Verificado contra `rg` y `grep` en 25 casos (`evidence/feature-corpus/`):

* `-t` es libre (grep no lo tiene); `-T` **no** se asigno a `--type-not`
  porque en grep es `--initial-tab`. Manda la politica de colisiones.
* `--binary-files=binary` se **rechaza** con un mensaje claro: zgrep nunca
  imprime contenido binario, asi que aceptarlo seria mentir.
* `--max-depth 1` es exactamente `--nav=v^` (mismo caso en la conformance).

---

## 5. Cuándo usarlo — y cuándo no

**Úsalo cuando:**

* necesites rendimiento extremo en escaneo de archivos con enjambre de hilos Kamikaze o salida determinista (`--sort`);
* el patrón sea corto o largo: `zigrep` bate a `grep` por hasta 165× y a `rg` por hasta 2,6×;
* quieras evitar el overhead de dependencias de libc o runtimes pesados;
* busques patrones con regex lineal con garantía de $O(N)$ sin backtracking catastrófico.

**No lo uses cuando:**

* necesites backreferences o lookaround en regex (no soportados por diseño para garantizar $O(N)$);
* el trabajo sea **salida muy voluminosa sobre árboles pequeños** (cientos de
  miles de líneas de salida en < 150 MB): ahí `rg` es 2,2× más rápido y
  `grep` 1,3× más rápido que `zgrep`;
* vayas a comparar `-c` con `rg`: las semánticas de archivos binarios
  difieren (sección 3);
* corras en macOS: sigue sin probarse en ese sistema.

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
zig build test --summary all     # 56/56 tests passed (Linux y native Windows)
zig build oracle                 # 26/26 differential oracle tests passed (Linux), 25/25 (native Windows)
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

## Operaciones Estándar Grupo 1 (-v, -L, stdin, -m NUM / --max-count) (2026-11-08)

1. `-v, --invert-match`: Muestra o cuenta las líneas que **no** coinciden con el patrón.
2. `-L, --files-without-match`: Lista únicamente los archivos que **no** contienen coincidencias.
3. `stdin`: Lectura por tubería o descriptor estándar cuando no se especifican rutas o cuando la ruta es `"-"` (`cat log.txt | zigrep error` o `zigrep error -`). Funciona igual en Windows nativo.
4. `-m NUM, --max-count=NUM`: Detiene la búsqueda tras `NUM` coincidencias por archivo. Se desambigua automáticamente con la navegación 2D Befunge: si el valor es numérico (`-m 5`), actúa como `--max-count`; si contiene vectores Befunge (`-m v^`), navega por el espacio vectorial 2D. También se puede usar explícitamente `--max-count=NUM` y `--nav=SPEC`.

## 8. Windows nativo (probado 2026-11-08)

El Linux conserva la ruta de syscalls; Windows usa I/O nativo de Zig. No
requiere WSL. Verificado con Zig 0.16.0 en Windows 11 build 26200.

```powershell
# Zig 0.16.0 (la versión que fija el CI). Si ya está en el PATH:
$z = (Get-Command zig).Source
# Si no, descomprime el tarball oficial en una carpeta fija y apunta ahí:
# $z = "$env:LOCALAPPDATA\zig\zig-x86_64-windows-0.16.0\zig.exe"

& $z build -Doptimize=ReleaseFast --summary all
```

Salida:

```text
Build Summary: 7/7 steps succeeded
```

```powershell
& $z build test --summary all
```

Salida:

```text
Build Summary: 3/3 steps succeeded; 54/54 tests passed
test success
```

> Ese 54/54 es la medición de la rama del port (2026-11-08), antes de
> unificarla con el micro-tree fast path. En el árbol unificado la suite son
> **56/56 también en Windows**, medido por el job nativo del CI
> (run `42609558486`); el oráculo sigue siendo 25/25 en Windows porque el caso
> de stdin POSIX se omite allí.

```powershell
# Requiere GNU grep y ripgrep en el PATH (en Windows: Git for Windows + ripgrep)
& $z build -Doptimize=ReleaseFast oracle --summary all
```

Salida:

```text
Results: 25 PASSED, 0 FAILED (total 25)
Build Summary: 10/10 steps succeeded
oracle success
```

El caso `stdin pipeline (pipe -> zigrep)` del oráculo se salta en Windows: usa
`sh -c` y `printf`, que no están garantizados en el PATH nativo; en Linux son
26 checks. La lectura por stdin sí funciona en Windows (ver abajo).

El smoke test usó un directorio con espacios y Unicode y un `.gitignore` que
excluía `skip.txt`:

```powershell
$root = Join-Path $env:TEMP 'zigrep windows 高速'
New-Item -ItemType Directory -Force -Path $root | Out-Null
[IO.File]::WriteAllText((Join-Path $root '.gitignore'), "skip.txt`n", [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $root 'keep 你好.txt'), "needle`n", [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $root 'skip.txt'), "needle`n", [Text.UTF8Encoding]::new($false))
$result = & .\zig-out\bin\zigrep.exe -H -F needle $root
$result
```

Salida:

```text
C:\Users\progr\AppData\Local\Temp\zigrep windows 高速\keep 你好.txt:1:needle
```

Stdin en Windows (mismo resultado que GNU grep):

```powershell
"alpha`nbeta`ngamma" | & .\zig-out\bin\zigrep.exe -n beta
```

Salida:

```text
2:beta
```

Sobre el Xeon E5-2678 v3 (24 procesadores lógicos), Windows 11 build 26200,
un corpus sintético caliente de 500 archivos / 16,397,281 bytes dio medianas
de 40.133 ms (ZiGrep), 253.389 ms (GNU grep 3.0) y 43.361 ms (ripgrep
15.0.0). Son las corridas capturadas en `evidence/windows-port/`, tomadas sobre
el árbol del port Windows antes de fusionar el trabajo de upstream; no son una
afirmación general de rendimiento en Windows. El job `windows-native` está
configurado en GitHub Actions; su primera ejecución remota queda
NOT_DEMONSTRATED hasta que el CI publique el resultado.

Trampas: `--sort` hace determinista el orden; la CLI muestra separadores
nativos (`\`) pero el oráculo normaliza separadores y CRLF al comparar.

---

## 9. Release 0.2.2, fuzzer en Windows y el bug del enjambre de hilos

### Qué trae la 0.2.2

| | |
|---|---|
| Versión | `0.2.2` (`zgrep --version` → `zgrep 0.2.2`) |
| Port Windows | Nativo, sin WSL ni runtime de C. `src/uring.zig` es ahora una fachada portable y el motor `io_uring` real vive en `src/uring_linux.zig` (Linux-only) |
| Installer Windows | `install.ps1`, instalable con `irm ... | iex`, verifica SHA-256 y actualiza el `PATH` de usuario |
| Release | `zigrep-linux-x86_64.tar.gz`, `zigrep-linux-aarch64.tar.gz`, `zigrep-windows-x86_64.zip` y `SHA256SUMS.txt` |

### Fuzzer en Windows (portado en esta rama)

El fuzzer de upstream (`scripts/fuzz.zig`) usaba syscalls de Linux. En esta
rama está portado a la API de E/S de Zig, que es portable. En Windows:

```powershell
.\zig-out\bin\fuzz.exe 3000 --seed=12345 --threads=8
```

Salida real (recorte):

```text
  Total Executions Completed : 3001 ops
  Wall Clock Elapsed Time    : 1.01 seconds
  Average Swarm Throughput   : 2967 ops/sec
  - Total Anomalies Detected       : 0
  - Process Crashes (SIGSEGV/ABRT) : 0
  - Invalid Exit Codes (> 2)       : 0
```

El fuzzer tri-way (ZiGrep vs ripgrep vs GNU grep, `scripts/tri_fuzz.py`) también
está portado: las rutas absolutas de Linux se sustituyeron por
`Path(__file__).resolve().parent.parent` y el nombre del ejecutable se elige
según `os.name`.

```powershell
py scripts/tri_fuzz.py 250 5
```

Salida real (recorte):

```text
  Total Permutations Tested : 250
  ZiGrep Crashes (SIGSEGV)   : 0
  ZiGrep Timeouts (>1.5s)    : 0
  Anomalous Discrepancies    : 0
```

Ojo: el tri-way compara **códigos de salida, crashes y timeouts**, no el
contenido de la salida. El contenido lo compara el oráculo diferencial.

### El bug que encontró el fuzzer (y que el barrido cuantificó)

Un número absurdo de hilos (`-j 18446744073709551615`, `--threads=...` o la
variable de entorno `ZIGREP_THREADS`) llegaba al bucle de creación de hilos y
lo convertía en un ciclo infinito de crear-y-terminar: el equipo se quedaba
al 100% de CPU y el proceso no respondía ni a `taskkill /F`.

El barrido con timeout (`scripts/hunt_hang.py`, que sí pone un límite de 3 s
a cada invocación, cosa que el fuzzer original no hacía) cuantificó el problema
sobre el binario **anterior al fix**:

```text
phase 2 done: 452 hangs
phase 3 done: 452 hangs
==============================================================
  HANGING COMBINATIONS: 452
    -j 999999 filter build.zig
    -k -j 999999 searcher build.zig
    ...
```

Todas las combinaciones colgantes eran de la forma `-j <número enorme>`. El
 detonante es **un único fichero** (`build.zig`): con un directorio, el camino
rápido de un solo directorio resuelve antes de llegar al enjambre.

Arreglo aplicado en esta rama:

* La CLI rechaza cualquier cuenta por encima de **1024** con código de salida 2
  y un mensaje explícito.
* `kamikaze.zig` recorta el tamaño del enjambre a 1024 como segunda línea de
  defensa, para cualquier otro llamador.
* Dos tests de regresión cubren el límite (el valor 1024 sigue siendo válido).

Comprobación del fix (mismo binario, mismo argumento):

```powershell
.\zig-out\bin\zigrep.exe -j 18446744073709551615 needle src
```

Salida real:

```text
zgrep: thread count out of range (max 1024): '18446744073709551615'
try 'zgrep --help' for usage
```

Código de salida: **2** (antes: cuelgue indefinido).

Trampas: el mensaje va a `stderr`; en PowerShell sale en rojo como
`RemoteException` aunque el comportamiento sea el correcto. Usa
`$LASTEXITCODE` para comprobarlo.

---

## 10. El fuzzer de celdas en Windows y el segundo bug (deadlock del enjambre)

### El fuzzer N-dimensional ya corre en Windows

El fuzzer de celdas (`scripts/cell_fuzz.zig`, 373.248 celdas) llegó desde
upstream **después** de este port y no compilaba: estaba escrito contra la
API antigua de `scripts/common.zig`, pero el port de Windows la movió a la API
*io-first* de Zig 0.16, donde cada helper necesita un handle `std.Io`
explícito. Está portado en esta rama.

```powershell
.\zig-out\bin\cell_fuzz.exe --cell=48291     # una celda concreta
.\zig-out\bin\cell_fuzz.exe --all             # las 373.248 celdas
```

Salida real del barrido exhaustivo (Windows 11 build 26200, Zig 0.16.0):

```text
  Cells Executed             : 373248 / 373248
  Elapsed Wall Clock Time    : 10.840 seconds
  Execution Throughput       : 34433 cells/sec

  Fuzzing Invariants & Safety:
    - Total Anomalies Found  : 0
    - Invariant Violations   : 0
    - Crashes / Panics       : 0
  Verdict: 🟢 ZERO ANOMALIES — All 373248 cell coordinates executed with mathematical precision!
```

### El segundo bug: el enjambre se colgaba (4 de 12 campañas)

El enjambre capturaba la salida del hijo con un límite de 4 KB, pero
`std.process.run` **deja de leer** cuando se supera el límite mientras el
hijo sigue escribiendo. En Windows el pipe aguanta 8 KB, así que el hijo se
queda bloqueado escribiendo y el enjambre nunca vuelve: deadlock.

Aislado con un probe mínimo de Zig:

```text
calling std.process.run with limits 4096...
run returned error: StreamTooLong
EXIT=-1 t=294.2s
```

El mismo probe sin límites:

```text
calling std.process.run WITHOUT limits...
run returned OK: stdout=11130 bytes stderr=0 bytes after 57 ms
```

Arreglo: el enjambre **drena la salida del hijo hasta EOF** (nunca trunca) y
mantiene un watchdog (`--cli-timeout-ms=N`, 10000 ms por defecto) por si el
hijo deja de producir y nunca termina.

Comprobación (mismo utillaje, misma semilla, 90 s de límite por campaña):

| Estado | Campañas | Cuelgues |
|---|---|---|
| Antes del arreglo | 12 | **4** |
| Después del arreglo | 18 | **0** |

### Diagnóstico: `--trace-cli`

Para que este tipo de fallo se pueda diagnosticar en vez de adivinar:

```powershell
.\zig-out\bin\fuzz.exe 200000 --seed=987654321 --knob=5 --threads=16 --trace-cli
```

Cada invocación sale con marcadores emparejados `START` / `END`; el que se
queda sin `END` es el culpable:

```text
spawns=31 terminados=30 sin_terminar=1
  #14 SIN TERMINAR: zig-out/bin/zigrep.exe --no-hidden -e scan src
```

El timeout de un hijo cuenta como anomalía, escribe un reproductor en
`evidence/reproducers/` y el enjambre sigue adelante.

Trampa: **`zig build` mientras corre una campaña rompe la campaña.** El
build reemplaza `zig-out\bin\*.exe`, y los hijos que el enjambre tiene
abiertos dejan de existir a mitad: los cuelgues que se veían antes del fix
eran, en parte, esto. Compila antes de lanzar el fuzzer, no durante.

---

## 11. Las releases 0.2.1 y 0.2.2: el binario que no arrancaba (AVX-512)

### Qué pasó

La release **0.2.0** se publicó con un `.exe` que **no arrancaba** en este
equipo. No era un fallo de `zigrep`: era el workflow de release.

El job de Windows compilaba sin `-Dtarget`, y eso significa `native`, es
decir **"la CPU que tenga este runner"**. El runner `windows-latest` de GitHub
tiene AVX-512, así que el binario publicado lleva instrucciones AVX-512 y
muere al cargarse en cualquier x86_64 que no las tenga (Haswell, Broadwell,
Zen 1...):

```text
zigrep.exe --version
exit=-1073741795   (0xC000001D = STATUS_ILLEGAL_INSTRUCTION)
```

Cómo se aisló (comparando los prefijos de instrucción del `.text`):

```text
release (CI):        EVEX(0x62)=3499   VEX(0xC4/0xC5)=11671
build local (este PC): EVEX(0x62)= 144   VEX(0xC4/0xC5)=12486
```

Prueba cruzada, compilando el mismo código con distintos targets:

| Build | Arranca en esta CPU |
|---|---|
| `-Dtarget=x86_64-windows` (baseline SSE2) | **sí** |
| `-Dtarget=x86_64-windows -Dcpu=skylake_avx512` | **no** (mismo crash) |
| `native` en esta CPU (AVX2) | sí |
| release 0.2.0 (`native` en el runner con AVX-512) | **no** |

### El arreglo

El workflow compila ahora para el target **explícito** `x86_64-windows`
(baseline x86_64, SSE2), y además comprueba que el binario arranca antes de
empaquetarlo:

```yaml
run: zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast

- name: Verify the binary runs
  shell: pwsh
  run: |
    & .\zig-out\bin\zigrep.exe --version
    if ($LASTEXITCODE -ne 0) { throw "zigrep.exe --version failed with $LASTEXITCODE" }
```

Coste medido en este host (Xeon E5-2678 v3, 2.639 ficheros / 522 MB, 10
corridas cronometradas, 3 de calentamiento):

| Build | Media | Mediana | Min | Max |
|---|---|---|---|---|
| baseline (SSE2) | 143,4 ms | 139,6 ms | 122,9 ms | 164,1 ms |
| native (AVX2) | 141,2 ms | 139,7 ms | 123,7 ms | 172,0 ms |

**1,6% de diferencia**, dentro del ruido: el trabajo está limitado por el
disco, no por el SIMD.

### Qué release usar

* **`v0.2.2`**: la actual. Binario baseline, instalador que no aborta y
  `--version` en `stdout`. Es la que instala el `irm ... | iex` por defecto
  (usa `releases/latest`).
* **`v0.2.1`**: publicada y **supersedida** por la 0.2.2. Su `.exe` ya es
  baseline y arranca en todas partes, pero su `install.ps1` (el que va dentro
  del `.zip`) abortaba en el "Version check".
* **`v0.2.0`**: publicada y **supersedida**. Su `.exe` no arranca en CPUs
  sin AVX-512. No la borres del historial: está ahí como registro.

Si tienes una versión anterior instalada y el binario te da error al
arrancar, reinstala:

```powershell
irm https://raw.githubusercontent.com/DannyBaanks/ZiGrep/v0.2.2/install.ps1 | iex
```

### Segundo arreglo del instalador: el fallback compilaba la versión equivocada

Si la descarga del `.zip` falla, el instalador compila desde fuente. Antes
clonaba la rama por defecto (`main`), que **no tenía el port de Windows**: el
fallback construía un binario que ni siquiera compilaba en Windows. Ahora
clona **el tag de la release**:

```powershell
$cloneRef = $null
if ($Version -eq "latest") {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" ...
    $cloneRef = $rel.tag_name
} else {
    $cloneRef = $Version
    if (-not $cloneRef.StartsWith("v")) { $cloneRef = "v$cloneRef" }
}
git clone --depth 1 --branch $cloneRef "https://github.com/$Repo.git" $repoDir
```

---

## 12. El quinto bug: el instalador abortaba en una instalación correcta

### Qué pasó

La instalación de la 0.2.1 se completaba (checksum verificado, ficheros
copiados, `PATH` actualizado) y a continuación el instalador **murió**:

```text
  Version check:
powershell : zigrep.exe : zgrep 0.2.1
    + CategoryInfo          : NativeCommandError
En línea 69 Carácter: 5
+     & (Join-Path $InstallDir "zigrep.exe") --version
    + CategoryInfo          : NativeCommandError
```

El mensaje rojo es la trampa: en Windows PowerShell, una aplicación nativa
que escribe en `stderr` produce un `NativeCommandError`, y como el instalador
usa `$ErrorActionPreference = "Stop"` (para negarse a instalar cuando el
checksum no cuadra), ese error se vuelve **terminante**. El instalador
abortaba en el último paso, sin llegar a imprimir "ZiGrep is ready.".

La causa de fondo: `zigrep --version` escribía en `stderr` (con
`std.debug.print`), cuando la versión es una **respuesta**, no un diagnóstico.

### Los dos arreglos

**1. El CLI responde en `stdout`.** `--version` y `--help` ahora se escriben
en `stdout`, como `grep` y `ripgrep`. `parseArgs` ya no escribe en ningún
stream: deja un flag (`print_version` / `print_help`) y quien lo llama decide
el stream, lo que además hace el parser testeable.

```zig
    if (opts.print_help or opts.print_version) {
        if (opts.print_version) {
            _ = platform.writeStdout(init.io, std.fmt.comptimePrint("zgrep {s}\n", .{version}));
        } else {
            _ = platform.writeStdout(init.io, usage);
        }
        std.process.exit(0);
    }
```

**2. El instalador no puede morir por el stderr de un hijo.** Todos los
comandos nativos pasan por un ayudante que captura la salida y devuelve el
código de salida:

```powershell
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$Capture
    )
    # Function scope: the caller's preference is not modified.
    $ErrorActionPreference = "Continue"
    if ($Capture) {
        $raw = & $FilePath @Arguments 2>&1
        $code = $LASTEXITCODE
        $parts = foreach ($item in $raw) {
            if ($item -is [System.Management.Automation.ErrorRecord]) { $item.ToString() }
            else { [string]$item }
        }
        return [pscustomobject]@{ Output = (($parts -join "`n")).Trim(); ExitCode = $code }
    }
    & $FilePath @Arguments
    return [pscustomobject]@{ Output = ""; ExitCode = $LASTEXITCODE }
}
```

Esto también cubre el `git clone` y el `zig build` del fallback, que también
escriben en `stderr`.

### Comprobación

```text
=== 2. ejecutar el instalador real (irm | iex) ===

  ZiGrep - native Windows installer
  (Windows-native build; no WSL, no C runtime needed)

==> Architecture: x86_64
==> Install directory: C:\Users\progr\AppData\Local\Programs\ZiGrep
==> Downloading zigrep-windows-x86_64.zip
==> Verifying SHA-256
OK  checksum matches (905845afe15370a5031dfda67d7539be98bc8762fb674ad200818cf63c75688f)
==> Extracting
OK  installed 2 executable(s) into C:\Users\progr\AppData\Local\Programs\ZiGrep
OK  added C:\Users\progr\AppData\Local\Programs\ZiGrep to the user PATH

  Version check:
    zgrep 0.2.1

  Try it:
    zigrep --help
    zigrep -n TODO src

  ZiGrep is ready.
  exit=0
```

Y el binario responde en stdout, con stderr vacío:

```text
stdout: 'zgrep 0.2.1'
stderr: ''
exit=0
```

Trampa: **`$ErrorActionPreference = "Stop"` convierte el stderr de cualquier
aplicación nativa en un error terminante.** Si tu script llama a un `.exe` y
no quieres que un mensaje por stderr lo tumbe, envuélvelo en
`Invoke-Native` (o baja la preferencia solo alrededor de esa llamada).

