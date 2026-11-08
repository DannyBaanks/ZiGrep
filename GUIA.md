# GUIA.md — guía de uso de `zgrep`

Guía operativa para una persona que usa `zgrep` a mano. El detalle técnico y
la evidencia están en `README.md` y `evidence/REPORT.md`.

---

## 1. Compilar

```sh
cd ~/Development/"ISyCo Git"/ZigGrep
zig build -Doptimize=ReleaseFast      # sale en zig-out/bin/zgrep
zig build test --summary all          # debe decir 24/24 tests passed
```

Requisitos: Zig 0.16.0. No necesita libc ni dependencias externas.

Para dejarlo en el PATH:

```sh
ln -sf "$PWD/zig-out/bin/zgrep" ~/.local/bin/zgrep
```

---

## 2. Uso básico

```sh
zgrep PATRÓN RUTA...          # siempre recursivo, siempre con número de línea
```

Ejemplos reales:

```sh
# buscar en todo un árbol
zgrep -F "const" workspace/assembly

# solo los nombres de los archivos que coinciden
zgrep -l -F "const" workspace/assembly

# contar coincidencias por archivo (una línea por archivo, incluidos los :0)
zgrep -c -F "const" workspace/assembly

# silencioso: solo el código de salida (0 = hubo coincidencia, 1 = no)
zgrep -q -F "const" workspace/assembly && echo "existe"
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
zgrep --algo=memchr -F "const" RUTA     # más rápido en la práctica
zgrep -j 4 -F "const" RUTA              # limitar hilos
zgrep --stats -F "const" RUTA           # informa por stderr: tiempo y MB/s
```

* `--algo=auto` (por defecto) usa `memchr` para patrones de ≤ 3 bytes y
  Boyer–Moore–Horspool para el resto.
* **Consejo práctico:** en el corpus de 655 MB medido, `--algo=memchr` fue
  2,1× más rápido que la configuración por defecto. Si te importa la
  velocidad, usa `--algo=memchr` explícitamente. La heurística `auto` es un
  defecto de rendimiento conocido (claim C8 del informe), no de corrección:
  los tres modos producen salida idéntica.
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
* el patrón sea raro o ausente en un árbol grande: ahí `zgrep` gana a
  `grep` por 6–8× y a `rg` por 1,2–1,5×;
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
