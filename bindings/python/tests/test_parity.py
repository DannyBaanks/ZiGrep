"""Paridad contra el equivalente puro de Python.

Si el nativo diverge de aqui, el wrapper miente: cada kernel tiene su
traduccion literal y se comparan con datos fijos y aleatorios."""
from __future__ import annotations

import random

import pytest

import ziggrep


def py_lines(data: bytes):
    """Semántica de línea de grep: el vacío final tras un '\n' no es línea."""
    parts = data.split(b"\n")
    if parts and parts[-1] == b"":
        parts.pop()
    return parts


def py_count(data: bytes, needle: bytes) -> int:
    return sum(1 for line in py_lines(data) if needle in line)


def py_count_matches(data: bytes, needle: bytes, *, overlapping: bool = False) -> int:
    if not needle:
        return 0
    n, i, step = 0, 0, 1 if overlapping else len(needle)
    while i + len(needle) <= len(data):
        j = data.find(needle, i)
        if j < 0:
            break
        n += 1
        i = j + step
    return n


def py_count_icase(data: bytes, needle: bytes) -> int:
    low = data.lower()
    return sum(1 for line in low.split(b"\n") if needle in low.split(b"\n")[:0]) if False else \
        sum(1 for line in low.split(b"\n") if needle in line)


def py_line_sum(data: bytes) -> int:
    return sum(sum(line) for line in py_lines(data))


DATA = [
    b"",
    b"needle",
    b"needle\n",
    b"a needle b\n",
    b"\n\n\n",
    b"Needle\nNEEDLE\nneedle\n",
    b"aa aa aa\n",
    b"linea 1 valor=42\nlinea 2\nneedle\n\n",
    b"x" * 100000 + b"needle" + b"y" * 100000,
]


@pytest.mark.parametrize("data", DATA)
def test_count(data):
    assert ziggrep.count(data, b"needle") == py_count(data, b"needle")


@pytest.mark.parametrize("data", DATA)
def test_count_matches(data):
    assert ziggrep.count_matches(data, b"needle") == py_count_matches(data, b"needle")
    assert ziggrep.count_matches(data, b"needle", overlapping=True) == \
        py_count_matches(data, b"needle", overlapping=True)


@pytest.mark.parametrize("data", DATA)
def test_count_icase(data):
    assert ziggrep.count_icase(data, b"needle") == py_count_icase(data, b"needle")


@pytest.mark.parametrize("data", DATA)
def test_line_sum(data):
    assert ziggrep.line_sum(data) == py_line_sum(data)


def test_count_total():
    hits, total, nbytes = ziggrep.count(b"a\nneedle\nb\n", b"needle", total=True)
    assert hits == 1 and total == 3 and nbytes == 11


def test_random_fuzz():
    rng = random.Random(0x5eed)
    for _ in range(300):
        buf = bytearray()
        for _ in range(rng.randrange(0, 40)):
            buf += bytes(rng.randrange(32, 127) for _ in range(rng.randrange(0, 40)))
            buf += b"\n"
        data = bytes(buf)
        for needle in (b"a", b"aa", b"needle", b"41"):
            assert ziggrep.count(data, needle) == py_count(data, needle), (data, needle)
            assert ziggrep.count_matches(data, needle) == py_count_matches(data, needle), (data, needle)
            assert ziggrep.count_icase(data, needle) == py_count_icase(data, needle), (data, needle)
            assert ziggrep.line_sum(data) == py_line_sum(data), data


def test_empty_needle_matches_every_line():
    # Aguja vacía: coincide en cada línea (semántica de grep).
    assert ziggrep.count(b"a\nb\nc\n", b"") == 3
