"""Rendimiento: cuánto cuesta el cruce y cuándo merece la pena.

Estos tests no compitan por microsegundos: fijan el ORDEN de magnitud para
que una regresión de 10x se note. Se saltan si zig no está disponible.
"""
from __future__ import annotations

import time

import pytest

import ziggrep

BIG = b"\n".join(b"linea %d valor=%d nota=ok" % (i, i % 97) for i in range(36000)) + b"\n" + b"needle aqui\n" * 5


def med(fn, runs=5):
    ts = []
    for _ in range(runs):
        t0 = time.perf_counter()
        fn()
        ts.append((time.perf_counter() - t0) * 1000)
    ts.sort()
    return ts[len(ts) // 2]


def test_crossing_is_microseconds():
    """El cruce debe ser submilisegundo: si se pasa de 1 ms, algo fue mal."""
    tiny = b"abcdefghijklmnop"
    t = med(lambda: [ziggrep.line_sum(tiny) for _ in range(20000)])
    # Medido: ~0,5-1,3 us por llamada => 20k en 10-26 ms. Un 10x serían
    # ~250 ms, así que umbral en 60 ms detecta regresiones de orden grande.
    assert t < 60.0, f"20000 llamadas x 16 B tardaron {t:.2f} ms (> 60 ms)"


def test_beats_python_at_scale():
    """A 1 MB el kernel debe ganarle al puro Python: si no, el cruce no paga."""
    def py():
        n = 0
        for line in BIG.split(b"\n"):
            if b"needle" in line:
                n += 1
        return n
    assert ziggrep.count(BIG, b"needle") == py()
    tp = med(py)
    tz = med(lambda: ziggrep.count(BIG, b"needle"))
    assert tz < tp, f"zig {tz:.2f} ms no batió a python {tp:.2f} ms"


def test_icase_beats_lower_copy():
    """El plegado gana en Python por el `.lower()` que copia el buffer."""
    def py():
        low = BIG.lower()
        return sum(1 for line in low.split(b"\n") if b"needle" in line)
    assert ziggrep.count_icase(BIG, b"needle") == py()
    tp = med(py)
    tz = med(lambda: ziggrep.count_icase(BIG, b"needle"))
    assert tz < tp, f"zig {tz:.2f} ms no batió a python {tp:.2f} ms"
