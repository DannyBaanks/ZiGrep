"""API pública del binding ZigGrep para Python.

Todas las funciones aceptan `bytes` y devuelven `int`; el coste medido del
cruce es ~0,5 us por llamada, así que este paquete se usa con buffers de
varios KB, no con llamadas diminutas.
"""
from __future__ import annotations

from . import _core

__version__ = "0.1.0"

__all__ = ["count", "count_matches", "count_icase", "line_sum", "library_path", "build"]


def _b(x):
    return x if isinstance(x, (bytes, bytearray)) else str(x).encode()


def count(data, needle: bytes, *, total: bool = False):
    """Líneas que contienen `needle` (como `zgrep -c`).

    Con `total=True` devuelve `(líneas_con_match, líneas_totales, bytes)`.
    """
    d, n = _b(data), _b(needle)
    if total:
        t = _core.ctypes.c_size_t(0)
        b = _core.ctypes.c_size_t(0)
        hits = _core.library().zg_count(d, len(d), n, len(n),
                                       _core.ctypes.byref(t), _core.ctypes.byref(b))
        return hits, t.value, b.value
    return _core.library().zg_count(d, len(d), n, len(n), None, None)


def count_matches(data, needle: bytes, *, overlapping: bool = False) -> int:
    """Ocurrencias totales de `needle` (como `zgrep --count-matches`).

    grep no cuenta las coincidencias que se solapan; con `overlapping=True`
    sí (por ejemplo 'aa' en 'aaaa' da 3 en vez de 2).
    """
    d, n = _b(data), _b(needle)
    return _core.library().zg_count_matches(d, len(d), n, len(n), overlapping)


def count_icase(data, needle: bytes) -> int:
    """Como `count`, pero sin distinguir mayúsculas (zgrep `-i`).

    Suele ir 10-20x más rápido que el equivalente puro de Python:
    `bytes.lower()` copia el buffer entero antes de buscar.
    """
    d, n = _b(data), _b(needle)
    return _core.library().zg_count_icase(d, len(d), n.lower(), len(n))


def line_sum(data) -> int:
    """Suma de los bytes de todas las líneas (para benchmarks)."""
    d = _b(data)
    return _core.library().zg_line_sum(d, len(d))


def library_path():
    """Ruta del .so en uso (o None si aún no se ha cargado)."""
    return _core.library_path()


def build(force: bool = False) -> str:
    """Fuerza la compilación de la librería y devuelve su ruta."""
    p = _core.library_path()
    if p is None or force:
        _core._build_library()
        _core._LIB = None
        return str(_core.library_path())
    return str(p)
