# GUIA.md — guía de uso de `zigrep` (antes `zgrep`)

Guía operativa para una persona o agente que usa `zigrep` a mano. El detalle técnico y
la evidencia están en `README.md` y `evidence/REPORT.md`.

## Release 0.3.2 (Linux verificado; Windows hereda la 0.3.1)

La 0.3.2 es la **0.3.1 + `--cache`**: mergea la re-auditoría de Windows
(ocho bugs corregidos, §4h/§4i) y añade el limpiador de caches de Zig (§4j).
El binario de Windows no cambia: nada de lo que toca la 0.3.2 es específico
de Windows (`clean.zig` está guardado por `builtin.os.tag`, y el cross-build
`x86_64-windows` compila).

Evidencia de esta release, ejecutada en Linux sobre el commit tageado:

| qué | resultado |
|---|---|
| `zig build test` | 99 pass / 1 skip |
| oráculo diferencial (grep + rg) | 30/30 |
| conformance grep (40 casos) | 40/40 |
| paridad rg (25 casos) | 25/25 |
| BRE (15) · `\b` (12) | 15/15 · 12/12 |
| fuzzer entrópico | 100.001 permutaciones, 0 anomalías |
| cell-fuzz | 1.000 coordenadas, 0 anomalías |
| cross-build Windows | compila (`x86_64-windows`, ReleaseFast) |

## El comando de Windows

**Instalar (una sola vez, sin permisos de administrador):**

```powershell
irm https://raw.githubusercontent.com/DannyBaanks/ZiGrep/v0.3.2/install.ps1 | iex
```

> La URL con `main` (`.../main/install.ps1`) empieza a funcionar cuando el
> PR #1 se mergee. Hasta entonces usa la del **tag**, que es la verificada
> (esta guia se escribio ejecutando exactamente esa linea).

**Regla de oro:** no ejecutes `irm ... | iex` sobre un texto que no hayas
leído antes. El instalador verifica el SHA-256 del `.zip` descargado contra el
`SHA256SUMS.txt` publicado en la release y **aborta sin instalar nada** si no
coincide. Si prefieres revisarlo antes, descárgalo y léelo:

```powershell
irm https://raw.githubusercontent.com/DannyBaanks/ZiGrep/v0.3.2/install.ps1 -OutFile install.ps1
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

### Salida real del instalador publicado (v0.2.2, histórica)

Ejecutado de verdad contra la release publicada (no un simulacro), desde cero.
La transcripción de la **v0.3.1** está más abajo, con los hashes de sus
assets; el instalador no cambió en la 0.3.2, así que sigue siendo la
verificación vigente.

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

### Salida real del instalador publicado (v0.3.1)

Ejecutado de verdad contra la release publicada (no un simulacro), desde cero,
con la one-liner tal cual la escribe el usuario:

```text
=== 0. estado inicial ===
  install dir existe : False
  ya esta en el PATH  : False
  install dir existe ahora : False
=== 1. descargar el instalador (irm) ===
  descargado: 12753 caracteres
  primera linea: <#
=== 2. ejecutar el instalador real (irm | iex) ===
  ZiGrep - native Windows installer
  (Windows-native build; no WSL, no C runtime needed)
==> Architecture: x86_64
==> Install directory: C:\Users\progr\AppData\Local\Programs\ZiGrep
==> Downloading zigrep-windows-x86_64.zip
==> Verifying SHA-256
OK  checksum matches (0dae279f63db4bfe7984acbf0ad4dc01afe0dcdf963f3efd486d9daf29a4e58a)
==> Extracting
OK  installed 2 executable(s) into C:\Users\progr\AppData\Local\Programs\ZiGrep
OK  added C:\Users\progr\AppData\Local\Programs\ZiGrep to the user PATH
  Restart your terminal (or open a new one) so the PATH change applies.
  Version check:
    zgrep 0.3.1
  Try it:
    zigrep --help
    zigrep -n TODO src
  ZiGrep is ready.
  exit=0
  errores en la consola: 0
=== 3. verificacion ===
  zigrep.exe instalado : True
  zgrep.exe  instalado : True
  install.ps1 copiado  : True
  version reportada    : zgrep 0.3.1
  install dir en PATH   : True
=== 4. uso real del binario instalado ===
  busqueda: 2:needle
=== 5. hash publicado vs asset real ===
  SHA256SUMS.txt publicado:
    708c6379136be5ccc1586398b9b65343c3100e5afd6cc06f4693217d818a9ba3  zigrep-linux-x86_64.tar.gz
    bae614ed33e7c943cf86f7435b9da6a29ac180616a009abb0947413cad076174  zigrep-linux-aarch64.tar.gz
    0dae279f63db4bfe7984acbf0ad4dc01afe0dcdf963f3efd486d9daf29a4e58a  zigrep-windows-x86_64.zip
=== 5b. el binario responde por stdout (no stderr) ===
  stdout : 'zgrep 0.3.1'
  stderr : ''
  exit   : 0
=== 6. el escenario que abortaba en la 0.3.0 ===
  ZiGrep - native Windows installer
  (Windows-native build; no WSL, no C runtime needed)
==> Architecture: x86_64
==> Install directory: C:\Users\progr\AppData\Local\Programs\ZiGrep
==> Downloading zigrep-windows-x86_64.zip
==> Verifying SHA-256
OK  checksum matches (0dae279f63db4bfe7984acbf0ad4dc01afe0dcdf963f3efd486d9daf29a4e58a)
==> Extracting
OK  installed 2 executable(s) into C:\Users\progr\AppData\Local\Programs\ZiGrep
OK  added C:\Users\progr\AppData\Local\Programs\ZiGrep to the user PATH
  Restart your terminal (or open a new one) so the PATH change applies.
  Version check:
    zgrep 0.3.1
  Try it:
    zigrep --help
    zigrep -n TODO src
  ZiGrep is ready.
  errores en la consola: 0
  instalado : True
  version   : zgrep 0.3.1
  el $InstallDir del usuario sigue siendo: 'C:\predefinido'
=== 7. estado de la maquina restaurado ===
  install dir sigue en el PATH: False
  install dir existe          : False
=== fin ===
```

Lo importante de esa transcripción:

* `errores en la consola: 0` — **ni un `RemoteException`**, que era el
  requisito: el instalador no aborta.
* `exit=0` y `ZiGrep is ready.`.
* El `checksum matches` es el hash **publicado** de la release (0dae279f…),
  no uno inventado.
* El bloque 6 es el escenario que **abortaba** en la 0.3.0 (§4i): ahora
  instala sin errores y **no toca** el `$InstallDir` del usuario.
* Al final la máquina queda como estaba (sin el directorio de ZiGrep y sin su
  entrada en el `PATH`): la prueba no deja rastro.

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
zig build test --summary all          # 97/98 tests passed, 1 skip (Linux-only io_uring)
zig build oracle                      # oráculo diferencial puro Zig (29/29 native Windows)
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

# insensibilidad a mayúsculas; un patrón LITERAL pliega también Latin-1 (á/Á, ñ/Ñ, ü/Ü);
# una regex (con metacaracteres) solo pliega ASCII: -i 'ñand.' no encuentra ÑANDÚ
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
   * Lo que pides explícitamente **sigue aplicándose** con `--no-ignore`:
     `--no-hidden`, `--exclude-dir`, `--exclude`, `--exclude-ext`, `--include`
     e `--include-ext` (igual que ripgrep, que con `--no-ignore` conserva sus
     `-g`). Hasta 2026-11-11 un `return false` temprano en `src/filter.zig`
     los anulaba todos; lo encontró la evaluación de M11 y lo fija el test
     "--no-ignore keeps the explicit filters…".

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

`zigrep` soporta tanto búsqueda literal acelerada por SIMD (`-F` o auto) como expresiones regulares lineales (`. [a-z] [^x] \d \w \s * + ? {n,m} | () ^ $`), `-i` (ASCII; Latin-1 solo en patrones literales, la regex pliega ASCII), `-w` (palabra completa) y `-e` (múltiples patrones). Un patrón con salto de línea se rechaza con mensaje y salida 2.

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

## 4f. Lo que quedaba pendiente: `-G`, `-z`, `--crlf`, `--heading`

```sh
zgrep -G 'cat\|dog' fichero.txt     # BRE real: \| ES alternacion aqui
zgrep -G 'a\{2\}' fichero.txt      # y \{ \} el intervalo
zgrep -G 'a(b)c' fichero.txt         # parentesis LITERALES en BRE
zgrep -z 'patron' fichero.bin        # NUL separa registros (grep -z)
zgrep --crlf 'x$' fichero.txt        # CRLF es el terminador
zgrep --heading -e pat a.txt b.txt   # ruta como cabecera, no como prefijo
zgrep -p pat fichero.txt             # alias de --color=always --heading -n
zgrep --vimgrep pat fichero.txt      # una linea por match, con columna
```

El que mas importa de los cuatro es **`-G`**: antes se aceptaba la bandera y
el patron se leia como ERE, o sea que **significaba otra cosa** — peor que no
soportarla. Ahora se traduce BRE a ERE (`src/bre.zig`): los escapes invertidos
(`\(`, `\)`, `\{`, `\}`, `\|`, `\+`, `\?`) y los caracteres que en ERE son
operadores y en BRE literales (`( ) { } | + ?`). Verificado contra `grep -G`
en 15 casos.

`-z` hizo falta tocar **tres** sitios a la vez: el separador de registro, la
sonda de binario (un NUL ya no puede significar "binario" si es el separador)
y el DFA (un registro puede contener `\n`, asi que `.` y las clases dejan de
excluirlo). El camino rapido queda desactivado con `-z` porque divide por `\n`
internamente.

---

## 4g. Las cinco que el corpus tenía por "no vale" y ya no lo son

```sh
zgrep -U 'alpha[\s\S]*gamma' *.txt   # multilínea (un match puede cruzar \n)
zgrep -U --multiline-dotall 'a.*b' .   # y además '.' cruza el \n
zgrep --pre 'cat {}' .                 # busca la salida del comando, no el fichero
zgrep --encoding utf-16 fichero.txt     # o none, para ver los bytes crudos
zgrep '\bcat\b' fichero.txt            # frontera de palabra (\b y \B)
zgrep --heading -e pat a.txt b.txt     # ruta como cabecera
zgrep --stop-on-nonmatch pat sorted.txt
```

**`` era la razón principal de echar de menos PCRE2**, y se resolvió en el
motor propio: es una aserción de ancho cero como `^` y `$`, resuelta en el cierre
del NFA con el contexto del byte anterior y del siguiente. Verificado contra
`grep -E` en 12 casos (línea y `-o`). Ojo con un detalle que solo se ve midiendo:
la frontera debe resolverse **antes** de consumir el byte que viene; hacerlo
después alargaba el match una posición y `-o` devolvía `cat ` en vez de `cat`.

**`-U` necesitó tres cambios coordinados** (como `-z`): el fichero deja de
partirse en líneas, el DFA resuelve `^`/`$` por línea dentro del registro, y la
impresora emite cada línea que el match **abarca** — que es lo que hace rg, no
el registro entero.

**`--pre`** reutiliza la maquinaria de procesos de `--exec`, pero capturando la
salida en vez de heredarla. Verificado contra rg, incluido `--pre-glob`.

**`--encoding`** tal cual lo define rg: `auto` (solo BOM), `none` (bytes crudos)
y los utf-16 que ya sabíamos decodificar.

**`--heading`** fuerza el camino ordenado: en streaming los grupos de ficheros
se entremezclarían y una cabecera apuntaría al clúster equivocado.

---

## 4j. `--cache`: analizar y limpiar las caches de Zig

Un problema de espacio resuelto por la herramienta. El motor analiza el disco,
clasifica lo que ve y **pregunta antes de borrar**; la última palabra es del
usuario, pero con el análisis ya hecho.

```sh
ziggrep --cache                  # analiza, muestra, pregunta, borra
ziggrep --cache --dry-run        # solo el análisis
ziggrep --cache --force --cache-root /ruta   # sin preguntar, sobre una ruta
```

La tabla clasifica cada cache en cuatro estados:

| estado | qué significa |
|---|---|
| `segura` | una `.zig-cache`: se regenera al compilar |
| `peligrosa` | un `zig-out`: puede contener un binario **instalado** (por eso no entra salvo `--cache-include-out`) |
| `ACTIVA` | hay una compilación en marcha: **no se toca** |
| `PROTEGIDA` | algo apunta a ella: un symlink en un directorio de binarios la usa |

Sobre la detección de build activo, medido: Zig **no** deja ficheros de bloqueo
(verificado con el build en marcha), así que la señal fiable es el proceso: en
Linux se lee `/proc` y se marca ACTIVA si algún `zig` tiene su `cwd` en el repo
que contiene la cache, o —para la cache global `~/.cache/zig`, que es
compartida— si hay cualquier compilador vivo.

La selección es explícita: `1,3-5`, `all` (todo, incluidas activas y
protegidas), `safe` (solo las seguras) o `nada`. Después se pide confirmación
S/N con la lista exacta y el total.

Verificado en tres fixtures: cache segura borrada, build en marcha omitido, y
`zig-out` apuntado desde `~/bin` marcado PROTEGIDA.

## 4k. `--json`: salida estructurada para agentes (nuevo en 0.4.0-dev)

Una línea JSON por registro de salida. Para un agente es la diferencia entre
parsear texto con regexes y leer campos:

```sh
zigrep --json -n HIT a.txt
```

```json
{"schema":"zgrep/1","type":"match","path":"a.txt","line":3,"column":1,"byte_start":8,"byte_end":11,"match":"HIT","text":"HIT","inverted":false}
```

| tipo | cuándo | qué trae |
|---|---|---|
| `match` | línea coincidente (o no, con `-v`: entonces `inverted:true`) | span del primer match, o `null` |
| `context` | línea de `-A`/`-B`/`-C` | sin span |
| `passthru` | línea NO coincidente que imprime `--passthru` | sin span, `inverted:false` |
| `occurrence` | `-o`, `--vimgrep` | uno por ocurrencia, con span |
| `file` | `-l` / `-L` | `mode`: with-match / without-match |
| `count` | `-c` / `--count-matches` | `lines` o `matches` |

Reglas del schema, deliberadas:

* **`schema: "zgrep/1"` en cada evento** y solo se añaden campos: un campo nuevo
  es un release, quitarlo es un release mayor;
* `byte_start`/`byte_end` son **absolutos en el fichero** y están verificados
  contra el fichero real por el diferencial (`json_conformance.py`, 45/45);
* los campos que no aplican salen `null`, nunca inventados;
* `--color`, `--heading`, `--column` y los separadores `--` son decoración de
  texto: en JSON no existen (la información va en los campos). Si un modo
  decorativo se cuela en el stream, es bug —ya pasó tres veces y hay test.

El modo estructura es aditivo y apagado por defecto: la salida de texto no cambia
ni un byte (hay test que lo fija).

## 4l. 0.4.0-dev: los números de línea arrancan APAGADOS

Cambio de comportamiento con migración explícita. Medido: ni `grep` ni `rg`
numeran por defecto cuando la salida es un pipe —que es el caso de todo script y
de todo agente—; `rg` solo numera en una terminal. El default viejo de `zgrep`
("siempre número") costaba **+5,7 % de bytes de salida** en la tarea `word_boundary_occurrences`
(`-o`) del benchmark task-level, y contaminaba cada pipe.

```sh
zgrep HIT a.txt        # HIT            (antes: 3:HIT)
zgrep -n HIT a.txt     # 3:HIT
zgrep --pretty HIT a.txt   # número + color + heading, como rg
```

`--no-line-number` sigue aceptada: con el default apagado solo importa contra
`--column`, que implica número de línea como en `rg` (`2:6:texto`); con
`--no-line-number` en cualquier posición queda solo la columna. `--pretty`, que
ya era el alias `--color=always --heading --line-number`, por fin significa lo
que dice.

Si te molestó el cambio en un script, es una línea: añade `-n`. Y si querés el
comportamiento viejo por defecto en tu entorno, `--line-number` en un alias.

## 4m. Arreglos de la auditoría e2e de M2 (0.4.0-dev)

Cuatro bugs que pasaban todas las baterías y salieron comparando a mano contra
GNU grep 3.11 y rg 14.1.0. Cada uno tiene ya su test o su caso de oráculo:

| # | Bug | Antes | Ahora |
|---|---|---|---|
| 1 | `--column` sin `-n` | `6:beta HIT` (¿línea o columna?) | `2:6:beta HIT`, como `rg` |
| 2 | `--json --passthru` | líneas no coincidentes con `type:"match"` | `type:"passthru"`; `inverted` sale de `-v` |
| 3 | varios ficheros sueltos | `zgrep p a b c` imprimía c, b, a | orden de los argumentos, como `grep` |
| 4 | `--json --exec` | texto libre del hijo en el stream JSONL | error de uso, rc 2, stdout vacío |

El bug 1 lo tapaba el propio oráculo: el caso `--column` le pasaba `-n` a zgrep
para igualar a `rg`. Ahora el caso va sin `-n`, a propósito.

Sigue igual, y queda documentado en `evidence/agent-native/contract.md`: con
**directorios** el orden es el de terminación del enjambre (como `rg`); para un
orden fijo, `--sort`. `-N` es la navegación Befunge, no el `--no-line-number`
de `rg`.

## 4n. Lote y presupuesto: `--queries-file`, `--max-results`, `--max-output-tokens` (0.4.0-dev, M3)

Para un agente, N preguntas sobre el mismo árbol eran N procesos y N salidas que
juntar a mano. Ahora es **una llamada**: un fichero JSONL con una consulta por
línea (o `-` para leerlo de stdin).

```sh
cat q.jsonl
```

```json
{"id":"hit","pattern":"HIT"}
{"id":"beta","pattern":"beta","paths":["b.txt"]}
{"id":"nada","pattern":"ZZZ"}
```

```sh
zgrep --queries-file q.jsonl a.txt b.txt     # las rutas de la línea son el default
```

```json
{"schema":"zgrep/1","query_id":"hit","type":"match","path":"a.txt","line":3,"column":1,"byte_start":8,"byte_end":11,"match":"HIT","text":"HIT","inverted":false}
{"schema":"zgrep/1","query_id":"hit","type":"match","path":"b.txt","line":2,"column":1,"byte_start":10,"byte_end":13,"match":"HIT","text":"HIT here","inverted":false}
{"schema":"zgrep/1","query_id":"hit","type":"query_end","rc":0,"returned":2,"omitted":0,"truncated":false,"dropped_non_event":0,"error":null}
{"schema":"zgrep/1","query_id":"beta","type":"match","path":"b.txt","line":1,"column":1,"byte_start":0,"byte_end":4,"match":"beta","text":"beta line","inverted":false}
{"schema":"zgrep/1","query_id":"beta","type":"query_end","rc":0,"returned":1,"omitted":0,"truncated":false,"dropped_non_event":0,"error":null}
{"schema":"zgrep/1","query_id":"nada","type":"query_end","rc":1,"returned":0,"omitted":0,"truncated":false,"dropped_non_event":0,"error":null}
{"schema":"zgrep/1","type":"summary","queries":3,"returned":3,"omitted":0,"truncated":false,"reason":null,"output_bytes":496,"max_results":null,"max_output_tokens":null,"token_estimate":"bytes/4","dropped_non_event":0}
```

* Cada consulta corre como `zgrep --json --sort <flags globales> <"flags"> -e
  <"pattern"> -- <"paths" o las rutas de la línea>`. Las banderas globales
  (`-i`, `-w`, `-C2`...) valen para todas; `"flags"` añade por consulta.
* Cada evento lleva `query_id`; cada consulta cierra con `query_end` (`rc`,
  `returned`, `omitted`, `truncated`, `error`); el stream cierra con `summary`.
* Orden determinista (`--sort`): el lote es byte a byte lo mismo que N procesos
  separados con `--json --sort` (`evidence/agent-native/batch_conformance.py`).
* Una consulta inválida falla **sola** (`query_end` con `rc` 2 y el motivo); un
  fichero de consultas inválido (JSON roto, `id` repetido, campo desconocido)
  falla **entero** antes de ejecutar nada. Un lote nunca lee stdin como ruta.
* rc del lote: 2 si alguna consulta falló, si no 0 si alguna encontró algo, si no 1.

### Presupuesto con truncado que se hace saber

```sh
zgrep --queries-file q.jsonl --max-results 1 a.txt b.txt
```

```json
{"schema":"zgrep/1","query_id":"hit","type":"match","path":"a.txt","line":3,"column":1,"byte_start":8,"byte_end":11,"match":"HIT","text":"HIT","inverted":false}
{"schema":"zgrep/1","query_id":"hit","type":"query_end","rc":0,"returned":1,"omitted":1,"truncated":true,"dropped_non_event":0,"error":null}
{"schema":"zgrep/1","query_id":"beta","type":"query_end","rc":0,"returned":0,"omitted":1,"truncated":true,"dropped_non_event":0,"error":null}
{"schema":"zgrep/1","query_id":"nada","type":"query_end","rc":1,"returned":0,"omitted":0,"truncated":false,"dropped_non_event":0,"error":null}
{"schema":"zgrep/1","type":"summary","queries":3,"returned":1,"omitted":2,"truncated":true,"reason":"max-results","output_bytes":161,"max_results":1,"max_output_tokens":null,"token_estimate":"bytes/4","dropped_non_event":0}
```

* `--max-results N`: cuenta resultados (`match`, `occurrence`, `file`, `count`;
  el `context` y el `passthru` acompañan y no cuentan) en **toda** la llamada.
* `--max-output-tokens N`: tamaño de la salida en tokens **estimados por clases
  de caracteres** (`token_estimate: "zgrep-classes-v1"`, desde M7), calibrado
  contra un BPE real para no subestimar; el `summary` informa
  `output_tokens_est`. Nunca se corta un evento por la mitad: el stream sigue
  siendo JSONL válido. *(Hasta M7 era bytes/4, que subestimaba: ver §4q.)*
* Truncar **no** detiene el escaneo: `omitted` es el número exacto de
  resultados que no se emitieron. Evidencia incompleta, pero sabida incompleta.
* Lo emitido es siempre un **prefijo** de lo que saldría sin presupuesto.
* Sin lote también vale: `zgrep --json --max-results 5 pat dir`. Sin `--json`
  es error de uso: el marcador de truncado es un evento y el texto no tiene
  sitio honesto para él.

### Lo que el lote NO hace (medido, `evidence/agent-native/m3/`)

* No lee los ficheros una sola vez para todas las consultas: cada consulta
  recorre el árbol. Es más rápido que N procesos con la misma salida, pero más
  lento que N procesos de texto en streaming.
* No ahorra bytes frente al texto: el JSON con `query_id` pesa más. Lo que ahorra
  es procesos y el trabajo de juntar y atribuir resultados.

## 4o. Procedencia por fichero: `--provenance` (0.4.0-dev, M4)

Un agente que afirma "esto está en `a.txt:3`" puede ahora atarlo al contenido
exacto que se buscó. Con `--json --provenance`, antes de los eventos de cada
fichero con salida va un evento `provenance`:

```sh
zgrep --json --provenance HIT a.txt b.txt
```

```json
{"schema":"zgrep/1","type":"provenance","path":"a.txt","sha256":"89f3e85d8bd8b4156bafcd5dbef16db596a610cd9707d2097cfaab9e1aebb07b","size":26,"mtime_ns":1794350072429715620,"source":"file"}
{"schema":"zgrep/1","type":"match","path":"a.txt","line":3,"column":1,"byte_start":8,"byte_end":11,"match":"HIT","text":"HIT","inverted":false}
{"schema":"zgrep/1","type":"provenance","path":"b.txt","sha256":"9e011eb2d04d64c73b63643ac869ebf9c786846c11852a94ec831293db2bdce4","size":25,"mtime_ns":1794350072429715620,"source":"file"}
{"schema":"zgrep/1","type":"match","path":"b.txt","line":2,"column":1,"byte_start":10,"byte_end":13,"match":"HIT","text":"HIT here","inverted":false}
```

Y se comprueba con las herramientas de siempre:

```text
89f3e85d8bd8b4156bafcd5dbef16db596a610cd9707d2097cfaab9e1aebb07b  a.txt
9e011eb2d04d64c73b63643ac869ebf9c786846c11852a94ec831293db2bdce4  b.txt
a.txt size=26 mtime=1794350072,429715620
b.txt size=25 mtime=1794350072,429715620
```

* `sha256` y `size` son de **los bytes que zgrep leyó y buscó**, no de una
  relectura: no hay carrera entre buscar y hashear.
* `mtime_ns` sale de `statx` sobre el descriptor que se leyó.
* `source`: `file`, `file-utf16` (hash del fichero crudo; los offsets son del
  texto decodificado), `pre` (hash de la salida de `--pre`) o `stdin` (hash de
  lo recibido, `mtime_ns` null).
* Un evento por fichero y **solo** si ese fichero produjo algún evento: los
  ficheros sin coincidencias no se hashean. `-c` emite un recuento por fichero,
  así que con `-c` todos llevan procedencia.
* Aditivo: quitando los eventos `provenance`, el stream es byte a byte el de
  siempre. Sin `--json` es error de uso.
* En lote vale como bandera global o por consulta; el evento lleva `query_id` y
  no cuenta como resultado para `--max-results` (sí pesa en
  `--max-output-tokens`).

Coste medido (`evidence/agent-native/m4/`): sin la bandera, nada (A/B intercalado
contra el binario anterior, IQR solapados en texto y JSON). Con la bandera, lo
que cuesta hashear los ficheros con salida: casi nada si son pocos, y del orden
de un 17 % de pared cuando coinciden los 1000 ficheros del corpus (SHA-256 por
hardware en esta máquina).

Arreglo de paso: stdin con `--json -c` imprimía el recuento en texto y con
`--count-matches` no imprimía nada; ahora usa el mismo emisor que los ficheros.

## 4p. `--json=compact`: la misma información en menos tokens (0.4.0-dev, M5)

M5 midió con un tokenizador BPE real que `--json` cuesta ~2,8x los tokens del
texto de grep. `--json=compact` (schema `zgrep/1c`) lleva **exactamente la misma
información** que `--json` —offsets, columnas, tipo, procedencia— y en el arnés
cuesta prácticamente lo mismo que el texto de grep, que sí pierde los offsets
(cifras en `evidence/agent-native/task_bench/claims.md`, generado desde el crudo).

```sh
zgrep --json=compact -C1 HIT a.txt b.txt
```

```json
{"schema":"zgrep/1c"}
{"path":"a.txt"}
["c",2,"two"]
["m",3,1,8,3,"HIT"]
["c",4,"four"]
{"path":"b.txt"}
["c",1,"beta line"]
["m",2,1,10,3,"HIT here"]
["c",3,"gamma"]
```

Cómo se lee (la leyenda no viaja en la salida, para no pagarla en cada llamada):

| línea | significado |
|---|---|
| `{"schema":"zgrep/1c"}` | cabecera, una vez, antes de la primera línea (búsqueda vacía = stdout vacío) |
| `{"path":P}` | las filas que siguen son del fichero `P` |
| `[t, line, col, byte_start, len, text]` | fila con span; `t` = `m` match, `o` ocurrencia (`-o`) |
| `[t, line, text]` | fila sin span; `t` = `c` contexto, `p` passthru, `mv` línea de `-v` |
| `[..., text, match]` | 7º elemento solo si el match NO es `text[col-1 .. col-1+len]` (con `--replace`) |
| `["l",P]` / `["L",P]` | `-l` / `-L` |
| `["#",P,n]` / `["#m",P,n]` | `-c` / `--count-matches` |

`col` y `byte_start` cuentan bytes; `byte_start + len` = `byte_end` de zgrep/1.

```sh
zgrep --json=compact -c HIT a.txt x.txt
```

```json
{"schema":"zgrep/1c"}
["#","a.txt",1]
["#","x.txt",0]
```

Con `--provenance`, la cabecera de fichero lleva la procedencia, y el hash va en
**base64url sin relleno** (`sha256_b64u`): el mismo sha256, ~44 % menos tokens
que en hex (medido). `zgrep/1` sigue en hex, como `sha256sum`.

```sh
zgrep --json=compact --provenance HIT a.txt
```

```json
{"schema":"zgrep/1c"}
{"path":"a.txt","sha256_b64u":"ifPoXYvYtBVrr81dvvFttZamEM2XB9IJfPqrnhrrsHs","size":26,"mtime_ns":1794350072429715620,"source":"file"}
["m",3,1,8,3,"HIT"]
```

En lote, cada consulta abre con `{"query_id":ID}` y sus filas son de esa
consulta hasta el `query_end`; `query_end` y `summary` son los de zgrep/1. El
dialecto es de la llamada: una consulta no puede cambiarlo en `"flags"`.

Verificado sin pérdida (`compact_conformance.py`, en CI): cada caso decodifica a
exactamente los registros de `--json`, en todos los modos y caminos de lectura,
con procedencia, stdin y lote.

## 4q. `--max-output-tokens` ya cuenta tokens de verdad (0.4.0-dev, M7)

Hasta M7, el presupuesto estimaba tokens como bytes/4 (igual que RTK). Medido
contra un BPE real sobre salida de zgrep en los tres dialectos: bytes/4
**subestimaba en todos los bloques**, hasta 2,3x, así que `--max-output-tokens
1000` podía dejar pasar más de 2000 tokens reales.

Ahora el estimador cuenta bytes, dígitos, puntuación, tramos de espacio y bytes
no-ASCII (un BPE parte mucho más los números y lo no-ASCII que las palabras), con
pesos ajustados contra el tokenizador real y un margen declarado. Se eligió por
una regla escrita antes de la corrida confirmatoria (datos nuevos): no
subestimar en ningún bloque de validación. Cifras y crudo:
`evidence/agent-native/m7/`.

Lo que significa para quien lo usa: con `--max-output-tokens T`, lo emitido
queda por debajo de T tokens reales (verificado en lote y en búsqueda suelta, en
los dos dialectos), y cuando corta aprovecha la mayor parte del presupuesto.
El `summary` dice cuánto estimó (`output_tokens_est`).

Límite honesto: está calibrado con UN tokenizador (BPE de Qwen). Otro modelo
tokeniza distinto; el margen cubre la diferencia que se midió, no cualquiera.

## 4r. `--spill`: recuperar lo que el presupuesto cortó, sin re-ejecutar (0.4.0-dev, M8)

La idea es de RTK (cuando recorta, dice dónde está la salida completa), con una
diferencia: aquí lo recuperado es **verificable**. Con un presupuesto y
`--spill`, lo que no cabe se escribe —exactamente como habría salido— en un
fichero JSONL 0600, y el `summary` dice dónde está y su sha256:

```sh
zgrep --json=compact --max-results 1 --spill HIT a.txt b.txt
```

```json
{"schema":"zgrep/1c"}
{"path":"a.txt"}
["m",3,1,8,3,"HIT"]
{"schema":"zgrep/1","type":"summary","queries":null,"returned":1,"omitted":1,"truncated":true,"reason":"max-results","output_bytes":37,"max_results":1,"max_output_tokens":null,"spill":{"path":"/home/tu/.cache/zgrep/spill/spill-1794380243796547359-924241.jsonl","sha256":"9e75e6c469b5e798b0253abd43ab5312abcf1efbc79d2626d311b9d6440faec0","bytes":65,"events":1},"output_tokens_est":18,"token_estimate":"zgrep-classes-v1","dropped_non_event":0}
```

*(Ejecutado con `--spill=<dir temporal>`; en el ejemplo se muestra la ruta del directorio por defecto en lugar de la temporal. Hash, bytes y contenido son los reales.)*

El fichero es un stream válido del mismo dialecto (en compacto, con su cabecera):

```json
{"schema":"zgrep/1c"}
{"path":"b.txt"}
["m",2,1,10,3,"HIT here"]
```

* Lo emitido + el spill = la salida sin presupuesto (verificado en CI con
  `spill_conformance.py`, en lote y en búsqueda suelta, en los dos dialectos).
* Directorio: `--spill=DIR`, o `$XDG_CACHE_HOME/zgrep/spill` (si no,
  `~/.cache/zgrep/spill`). Nombre único por llamada, creado exclusivo.
* Perezoso: si no hay truncado no se crea nada (`"spill":null`).
* Nunca silencioso: si no se puede escribir, `"spill":{"error":...}` y la búsqueda
  sigue igual; truncado sin `--spill` da `"spill":null` (hay que re-ejecutar).
* `--spill` sin presupuesto es error de uso; en lote es de la llamada.

**No va por defecto, por los datos** (`evidence/agent-native/m8/`): sin truncado
no cuesta nada, pero con un truncado fuerte escribe todo lo omitido (megabytes)
y encarece la llamada en proporción. **zgrep no borra los spills**: quien los
pide los limpia, p. ej. `find ~/.cache/zgrep/spill -mtime +1 -delete`.

## 4s. `--max-columns`: la línea larga, recortada sin perder nada (0.4.0-dev, M9)

Un `node_modules` con código minificado tiene líneas de miles de bytes y un
match de tres. Eso es lo que un agente se encuentra cuando busca, y es donde un
resultado se come el contexto. El estudio (`evidence/agent-native/m9/`, árbol
real, tokens de verdad con un BPE) midió que recortar el `text` a una ventana
alrededor del match ahorra el **58-59 %** de los tokens reales dejando el match
intacto en todas las filas; la regla fijada antes de correr (>= 20 % con el
match intacto) decía IMPLEMENTAR, y la confirmación con la implementación real
reproduce la cifra.

```sh
zgrep --json=compact --sort --max-columns 40 HIT evidence/agent-native/m9/fix/multi.txt
```

```json
{"schema":"zgrep/1c"}
{"path":"evidence/agent-native/m9/fix/multi.txt"}
["mw",2,121,196,3,"ppppppppppppppppppHITqqqqqqqqqqqqqqqqqqq",102,243]
["mw",4,301,697,3,"rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrHIT",263,303]
["m",5,1,701,3,"HIT"]
["mw",6,701,1405,3,"ttttttttttttttttttttttttttttHITttttttttt",672,712]
```

*(Salida real del fixture versionado: `evidence/agent-native/m9/fix`, W=40. Las
tres líneas largas se recortan; la que cabe (`["m",5,...]`) sale entera.)*

Fila recortada en `zgrep/1c`: el tag lleva el sufijo `w` y dos elementos más.

| línea | significado |
|---|---|
| `[t+"w", line, col, byte_start, len, ventana, win_start, line_len]` | el `text` es una ventana: a lo sumo N bytes alrededor del match |
| `[..., match]` | 9º elemento, solo si el match no es derivable dentro de la ventana (con el recorte no ocurre: la ventana siempre lo contiene) |

En `zgrep/1` el mismo recorte añade dos campos junto a `text`:

```json
{"schema":"zgrep/1","type":"match","path":"evidence/agent-native/m9/fix/long.txt","line":1,"column":201,"byte_start":200,"byte_end":203,"match":"HIT","text":"xxxxxxxxxxxxxxxxxxHITyyyyyyyyyyyyyyyyyyy","win_start":182,"line_len":403,"inverted":false}
```

`win_start` y `line_len` viajan **solo** en la fila recortada: su presencia es la
señal, y una fila que cabe es byte a byte la de siempre. Los dos campos son
aditivos (el schema no cambia), y se leen así: `col` y `byte_start` siguen
contando la línea ENTERA, así que la línea entera se recupera leyendo el
fichero —`line_start = byte_start - (col - 1)`, la línea es
`fichero[line_start .. line_start + line_len]` y la ventana empieza en
`line_start + win_start`—; con `--provenance`, verificable por sha256.

Lo que **nunca** hace (contrato verificado en CI con `m9_conformance.py`, 446
comprobaciones contra el fichero en disco):

* cortar una fila **sin match** (contexto, `-v`, passthru): no hay centro, sale
  entera;
* cortar el **match**: la ventana siempre lo contiene, y si el match solo ya no
  cabe en N, la ventana ES el match;
* **partir un carácter** UTF-8: la ventana se alinea a límites de código;
* recortar con `--replace`: la fila lleva la línea sustituida, donde el match ya
  no marca una posición, así que sale entera;
* recortar líneas que caben en N.

El límite honesto, medido también: en una línea que **apenas** pasa de N el
recorte puede costar un par de bytes más de lo que ahorra (las dos cifras
extra), y el ahorro real depende de cuántas líneas largas tenga el árbol. Con
`--max-columns` enorme (o sin la bandera) la salida es la de siempre, byte a
byte. Es de la llamada también en lote: una consulta no puede pedirla en
`"flags"`.

## 4h. Los siete bugs que salieron al re-auditar la 0.3.0 en Windows

Ninguno se veía leyendo el diff: todos aparecieron **comparando contra `rg` y
`grep`** en esta máquina, y todos tienen ya su test o su caso de oráculo.

| # | Bug | Síntoma medido | Arreglo |
|---|---|---|---|
| 1 | `--count-matches` | imprimía **`0`** siempre | el contador se incrementaba en una rama que el informe no leía |
| 2 | `-z` / `--null-data` | `1\0texto` en vez de `1:texto` | el NUL es separador de **registro**, no de campo |
| 3 | `--crlf` | numeraba **1, 3, 5…** y borraba el CR | cada CRLF contaba como dos terminadores |
| 4 | `--exclude-from` | **ignorado** en la ruta streaming | solo se aplicaba en el camino ordenado |
| 5 | `--heading` | **sin cabecera** al pasar un directorio | la regla era `len(operandos) > 1`, no "¿se imprime la ruta?" |
| 6 | `--replace` | se comía **el resto de la línea** | sustituía el match y descartaba la cola |
| 7 | `--help` | decía que `\b` **no** está soportado (y mostraba `\\d`, `\\b`) | el texto estaba viejo y los backslashes iban dobles |

Comprobar que siguen arreglados (salidas reales, `rg` 15.0.0 en el `PATH`):

```powershell
$z = ".\zig-out\bin\zigrep.exe"

# 1. count-matches: 35 lineas, 35 matches; rg dice lo mismo
& $z --count-matches Searcher src\search.zig   # 35
rg --count-matches -F Searcher src/search.zig  # 35

# 3. crlf: numeros consecutivos, y el CR sigue ahi
#    (fichero con "needle one\r\nneedle two\r\nplain\r\n")
& $z --crlf needle f.txt
# 1:needle one
# 2:needle two
# bytes reales: b'1:needle one\r\n2:needle two\r\n'  (el CR NO se pierde)

# 4. exclude-from: src\search.zig ya no aparece; 28 lineas, las mismas que rg
& $z --exclude-from=scripts/fixtures/exclude.txt -F Searcher src
rg -n -F --ignore-file=scripts/fixtures/exclude.txt Searcher src

# 5. heading: la ruta va en su propia linea, y solo cuando toca
& $z --heading -F "pub const Searcher" src\search.zig src\scan.zig
# src\search.zig
# 114:pub const Searcher = struct {
& $z --heading -F "pub const Searcher" src\search.zig   # un solo fichero: sin cabecera

# 7. help: los backslashes salen simples y \b ya no se declara ausente
& $z --help | Select-String "word boundaries"
# word boundaries \b and \B are supported (zero-width assertions).
```

**Trampa que costó 20 minutos:** el test de `--crlf` pasaba por la ruta del
**prefiltro**, que entrega a `firstMatchingLine` un `to` = índice del `\n`. Con
la guarda `i + 1 < to` el par CRLF justo en el borde no se veía nunca, así que
el bug solo aparecía con patrones que activan el prefiltro. Ahora la guarda es
`i + 1 < data.len`.

**Segundo bug, este en el binding de Python y no en `zigrep`:** 8 tests de
paridad morían con `ValueError: the environment variable is longer than 32767
characters`. pytest deriva el id del test del propio parámetro, y los parámetros
son buffers de 200 KB; `PYTEST_CURRENT_TEST` choca con el límite de
`SetEnvironmentVariable`. El test era correcto: el **id** no era portable.
Con `ids=IDS` explícitos: **42/42 en Windows**.

---

## 4i. El instalador y el ámbito de PowerShell (corregido en 0.3.1)

Este bug salió al **verificar la release de verdad**, no leyendo el código:
el `irm ... | iex` de la 0.3.0 abortaba **sin instalar nada** en una sesión que
ya tuviera una variable `$InstallDir` (o `$Version`, ...) en un ámbito
superior:

```text
iex : No puede sobrescribirse la variable InstallDir porque se optimiza. ...
    FullyQualifiedErrorId : VariableNotWritableRare,Microsoft.PowerShell.Commands.InvokeExpressionCommand
```

**Por qué.** `irm ... | iex` evalúa el script en el ámbito de **quien llama**.
Al ejecutar un script con bloque `param()` así, PowerShell crea las variables
de los parámetros en ese ámbito **como constantes**. El instalador luego
asignaba a `$InstallDir` (para calcular la ruta por defecto) y esa asignación
sobre una constante está prohibida: de ahí el "because it is optimized".

**El arreglo (0.3.1).** Los parámetros ya no se asignan nunca (todo el trabajo
happens sobre `$targetDir`, `$versionToUse`, `$baseUrlToUse`,
`$skipPathUpdate`), y las variables de los parámetros llevan prefijo
(`$RequestedVersion`, `$RequestedInstallDir`, ...) con alias para conservar la
API pública: `-Version`, `-InstallDir`, `-BaseUrlOverride` y `-NoPathUpdate`
siguen funcionando igual. Efecto secundario que también se arregla: el
instalador ya **no pisa** las variables `$Version` / `$InstallDir` de tu
sesión.

Comprobarlo (Windows PowerShell 5.1):

```powershell
# Escenario que fallaba: variable con el mismo nombre en un ámbito padre
$InstallDir = "C:\predefinido"
& {
    irm https://raw.githubusercontent.com/DannyBaanks/ZiGrep/v0.3.2/install.ps1 | iex
}
# 0.3.0: "No puede sobrescribirse la variable InstallDir porque se optimiza"
# 0.3.1: instala, y tu $InstallDir sigue siendo "C:\predefinido"
```

**Trampa:** si ves ese error, no es tu máquina: es una versión del
instalador anterior a la 0.3.1. Reinstala con la línea de arriba.

---

## 4t. `--setup`: que tus agentes de IA busquen con ziggrep (0.4.0-dev, M12)

```bash
ziggrep --setup
```

Busca los agentes de programación instalados en esta máquina (Claude Code,
Codex, agy/Gemini, OpenISy y opencode), enseña qué cambiaría en el archivo de
instrucciones global de cada uno, pregunta `[s/N]` y, solo si respondes `s`,
escribe la regla que les dice que busquen con `ziggrep`. Salida real de
`--dry-run` en un HOME de prueba con Claude Code y Codex instalados:

```text
Configurar ZiGrep en los agentes de IA de esta máquina (comando: zigrep)

  Claude Code    ~/.claude/CLAUDE.md             se crea
  Codex          ~/.codex/AGENTS.md              se añade la regla (respaldo .bak-ziggrep)
  agy / Gemini   ~/.gemini/GEMINI.md             no instalado
  OpenISy        ~/.openisy/config/AGENTS.md     no instalado
  opencode       ~/.config/opencode/AGENTS.md    no instalado
  regla          ~/.config/ziggrep/agents.md     se crea

--dry-run: no se cambió nada.
rc=0
```

| Opción | Qué hace |
|---|---|
| `--setup --dry-run` | solo enseña, no toca nada |
| `--setup --force` | aplica sin preguntar (scripts, o un modelo que lo ejecuta) |
| `--setup --undo` | quita exactamente lo que puso |

Cómo lo hace:
- **La regla** se guarda una vez en `~/.config/ziggrep/agents.md`. Su texto va
  dentro del binario, así que funciona en cualquier máquina.
- **En cada agente** escribe un bloque entre `<!-- ziggrep:setup begin -->` y
  `<!-- ziggrep:setup end -->`. Claude Code recibe una importación de la regla;
  Codex, agy, OpenISy y opencode, el texto completo, porque **Codex no
  resuelve importaciones `@ruta`** (medido el 2026-11-11).
- **Solo toca** los agentes cuya carpeta existe. Correrlo dos veces no cambia
  nada.
- **Respaldo.** Antes de cambiar por primera vez un archivo que ya existía,
  guarda una copia `<archivo>.bak-ziggrep`, y nunca la sobrescribe. `--undo`
  quita el bloque y borra un archivo solo si el bloque era todo su contenido.
- **El nombre del comando** que escribe la regla es el que usaste para
  invocarlo. Si lo invocas como `zgrep` (nombre que en Linux usa gzip), elige
  `ziggrep` o `zigrep` si alguno está en el PATH.

`--dry-run` y `--force` siguen significando `--cache` cuando van solos: con
`--setup` son de `--setup`. `--setup --cache` es error de uso.

Verificado por `evidence/setup/setup_check.py`, siempre con un HOME falso: el
plan, la pregunta, la idempotencia, el respaldo, el `--undo` exacto y los
errores de uso.

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
zig build test --summary all     # 97/98 tests passed, 1 skip (Linux-only io_uring)
zig build oracle                 # 29/29 differential oracle tests passed (native Windows)
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
Build Summary: 11/11 steps succeeded
```

```powershell
& $z build test --summary all
```

Salida:

```text
Build Summary: 3/3 steps succeeded; 97/98 tests passed (1 skipped)
test success
+- run test 97 pass, 1 skip (98 total) 478ms MaxRSS:18M
```

> El único skip es el test de `io_uring`, que es Linux-only: en Windows el
> motor `--uring` se acepta y cae a los workers síncronos. Los **mismos 97**
> pasan también compilando para el target baseline `x86_64-windows`, que es el
> que va en la release, y en Linux (CI, run `42908701408`):
>
> ```powershell
> & $z build test -Dtarget=x86_64-windows --summary all
> # Build Summary: 3/3 steps succeeded; 97/98 tests passed (1 skipped)
> ```

```powershell
# Requiere GNU grep y ripgrep en el PATH (en Windows: Git for Windows + ripgrep)
& $z build -Doptimize=ReleaseFast oracle --summary all
```

Salida:

```text
Results: 29 PASSED, 0 FAILED (total 29)
Build Summary: 14/14 steps succeeded
oracle success
```

El caso `stdin pipeline (pipe -> zigrep)` del oráculo se salta en Windows: usa
`sh -c` y `printf`, que no están garantizados en el PATH nativo; en Linux son
30 checks (medido en el CI, run `42908701408`: `Results: 30 PASSED, 0 FAILED`
en `ubuntu-latest` y `Results: 29 PASSED, 0 FAILED` en Windows). La lectura
por stdin sí funciona en Windows (ver abajo).

Tres de los 29 casos nuevos no se pueden comparar contra GNU grep 3.0 porque
grep no tiene esas opciones (`--count-matches`, `--replace`, `--column`): se
comparan contra ripgrep y el campo `grep_args` queda en `null` de forma
explícita, en vez de saltarse el caso en silencio.

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

* **`v0.3.1`**: la actual. Corrige el instalador: `irm ... | iex` ya no
  aborta (ni pisa tus variables) cuando la sesión ya tiene un `$InstallDir` o
  un `$Version` (ver §4i). Los binarios son los de la 0.3.0 más el número de
  versión.
* **`v0.3.0`**: publicada y **supersedida** por la 0.3.1. Trae las flags
  nuevas (`--count-matches`, `--exclude-from`, `--replace`, `--column`,
  `--heading`) y los siete bugs corregidos, pero su `install.ps1` abortaba en
  el escenario descrito arriba. Si ya la tienes instalada, **reinstala** con la
  0.3.1.
* **`v0.2.2`**: publicada y **supersedida** por la 0.3.0. Sigue siendo válida
  para lo que hacía; no tiene las flags nuevas.
* **`v0.2.1`**: publicada y **supersedida** por la 0.2.2. Su `.exe` ya es
  baseline y arranca en todas partes, pero su `install.ps1` (el que va dentro
  del `.zip`) abortaba en el "Version check".
* **`v0.2.0`**: publicada y **supersedida**. Su `.exe` no arranca en CPUs
  sin AVX-512. No la borres del historial: está ahí como registro.

Si tienes una versión anterior instalada y el binario te da error al
arrancar, reinstala:

```powershell
irm https://raw.githubusercontent.com/DannyBaanks/ZiGrep/v0.3.2/install.ps1 | iex
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

