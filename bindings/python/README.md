# ziggrep — binding Python

Los mismos kernels que usa `zgrep` (contar líneas con una aguja y la variante
con plegado de mayúsculas), exportados como ABI de C y cargados con `ctypes`.

La idea no es “ejecutar Python con Zig” —eso no funciona, ya está medido— sino
**mover el bucle caliente**: Python manda, Zig obedece en el punto que cuesta.

## Uso

```python
import ziggrep

data = open("fichero.txt", "rb").read()

ziggrep.count(data, b"needle")          # líneas que contienen la aguja
ziggrep.count(data, b"needle", total=True)   # (matches, líneas, bytes)
ziggrep.count_matches(data, b"needle")  # ocurrencias totales
ziggrep.count_icase(data, b"needle")    # sin distinguir mayúsculas (-i)
```

## Instalación

```bash
cd bindings/python
pip install .        # o: PYTHONPATH=src python3 -c "import ziggrep"
```

El `.so` se compila solo la primera vez (con `zig build-lib`) y se cachea en
`$XDG_CACHE_HOME/ziggrep-python`, con un hash del fuente en el nombre: cambiar
los kernels invalida el anterior sin pasos manuales. Para desplegarlo sin zig
en la máquina destino, copia el `.so` junto al paquete y se usa tal cual.

## Qué gana y qué no (medido)

| buffer | Python puro | Zig (ctypes) | ganancia |
|---|---:|---:|---:|
| 100 KB | 2,42 ms | 0,77 ms | ×3,1 |
| 1 MB | 13,34 ms | 6,86 ms | ×1,9 |
| 10 MB | 133,70 ms | 32,59 ms | ×4,1 |

Y el plegado de mayúsculas, que es donde más duele: **×9,6 a 100 KB, ×19,8 a 1 MB**,
porque el `.lower()` de Python copia el buffer entero antes de buscar.

**El cruce cuesta ~1,2 µs por llamada** (mediana de 7 repeticiones de 200k
llamadas: 275 ms frente a 42 ms del `sum()` nativo de Python; la varianza
entre repeticiones es alta, 234-425 ms). Regla práctica: con buffers de
varios KB el cruce es despreciable; con millones de llamadas diminutas, no.

Datos completos y método: `ZigGrep/evidence/zig-python-bridge/RESULTS.md`.

## Desarrollo

```bash
cd bindings/python
PYTHONPATH=src python3 -m pytest tests -q   # paridad + rendimiento
```

`tests/test_parity.py` compara cada kernel contra su traducción literal en
Python (datos fijos y 300 fuzz aleatorios): si el wrapper diverge, el test lo
dice. `tests/test_perf.py` fija el orden de magnitud del cruce y de la
ganancia a 1 MB para que una regresión se note.
