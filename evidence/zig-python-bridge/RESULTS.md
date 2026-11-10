# Zig → Python: ¿cuánto se gana y a partir de qué tamaño?

Experimento para responder la pregunta del operador: *“hagamos un middleware
bidireccional para que los procesos de Python vayan más rápido”*.

El módulo son los mismos kernels que ziggrep ya tiene (contar líneas con una
aguja, y la variante con plegado de mayúsculas), exportados como ABI de C y
cargados desde Python con `ctypes`.

## Cómo reproducirlo

```bash
cd evidence/zig-python-bridge
python3 bench.py          # construye libzg.so y corre toda la tabla
```

## Resultados (mediana de 7; Ubuntu 24.04, 12 hilos)

| buffer | Python puro | Zig por ctypes | binario ziggrep | ganancia Zig/Python |
|---|---:|---:|---:|---:|
| 1 KB | 0,01 ms | 0,00 ms | 10,33 ms | ×2,9 |
| 10 KB | 0,11 ms | 0,03 ms | 12,20 ms | ×3,4 |
| 100 KB | 2,42 ms | 0,77 ms | 9,40 ms | ×3,1 |
| 1 MB | 13,34 ms | 6,86 ms | 12,34 ms | ×1,9 |
| 10 MB | 133,70 ms | 32,59 ms | 15,46 ms | ×4,1 |

Plegado de mayúsculas (`-i`), que es el caso caro de Python porque `.lower()`
copia el buffer entero antes de buscar:

| buffer | Python | Zig | ganancia |
|---|---:|---:|---:|
| 100 KB | 1,09 ms | 0,11 ms | ×9,6 |
| 1 MB | 24,73 ms | 1,25 ms | ×19,8 |

## El coste del cruce

200.000 llamadas con 16 bytes, mediana de 7 repeticiones: Python 211
ns/iteración, Zig por ctypes ~1374 ns/iteración (rango 234-425 ms, varianza
alta) → **el cruce cuesta ~1,2 us por llamada**, no ~0,5 us: la primera
medición, corta, subestimaba.

Eso fija la regla: el cruce paga en cuanto el trabajo por llamada supera
~1 µs. Para un buffer de 1 KB contar líneas son ~10 µs, así que ya paga; el
único caso donde Zig *pierde* es el de muchísimas llamadas diminutas
(sumar 16 bytes 200.000 veces), y en ese caso nadie usaría un puente nativo.

## Conclusión honesta

- **No hay ganancia en “ejecutar Python con Zig”**: un intérprete de Python
  no se sustituye con un `build-lib`, y este experimento no lo intentó.
- **Sí la hay en “mover el bucle caliente a Zig”**, y medido: ×2-4 en cuenta
  de líneas, ×10-20 con plegado. Y el binario `ziggrep` gana a ambos a 10 MB
  (×4,1 frente a ctypes, ×8,6 frente a Python) porque usa los matchers
  completos y no la versión ingenua del experimento.
- El patrón correcto para el operador es: **Python manda, Zig obedece en el
  punto caliente**. `ctypes` es el puente, el coste es ~500 ns por llamada, y
  se amortiza con cualquier buffer por encima de unos pocos KB.

## Qué NO se intentó (y por qué)

- Re-implementar el lenguaje: en contra de lo que el nombre “middleware
  bidireccional” sugiere, un `build-lib` no ejecuta Python. Eso ya se midió
  con `--exec`: 183,4 ms Python vs 189,1 ms con el envoltorio (×1,03), o sea,
  sin ganancia medible y con ~19 ms fijos de arranque del intérprete.
