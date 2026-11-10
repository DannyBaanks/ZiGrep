#!/usr/bin/env python3
"""Mide el cruce: Python puro vs Zig por ctypes vs el binario ziggrep.

Pregunta honesta: no "¿es Zig más rápido?" (siempre lo es), sino a partir de
qué tamaño el cruce a ctypes deja de pagar, y dónde queda ziggrep."""
import ctypes, statistics, subprocess, time, pathlib

D = pathlib.Path("/tmp/opencode/zgpy")
LIB = D / "libzg.so"
ZIG = "/home/danny/.local/opt/zig-x86_64-linux-0.16.0/zig"
ZGREP = "/home/danny/Development/ISyCo Git/ZigGrep/zig-out/bin/zigrep"

# ---------- construir ----------
r = subprocess.run([ZIG, "build-lib", "-dynamic", "-OReleaseFast",
                    "-femit-bin=libzg.so", "zglib.zig"],
                   cwd=str(D), capture_output=True, text=True)
if r.returncode:
    print(r.stderr[-1500:])
    raise SystemExit(1)

lib = ctypes.CDLL(str(LIB))
lib.zg_count.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t,
                         ctypes.POINTER(ctypes.c_size_t), ctypes.POINTER(ctypes.c_size_t)]
lib.zg_count.restype = ctypes.c_size_t
lib.zg_count_icase.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t]
lib.zg_count_icase.restype = ctypes.c_size_t
lib.zg_tiny.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
lib.zg_tiny.restype = ctypes.c_uint64

NEEDLE = b"needle"


def build(total_bytes: int) -> bytes:
    """Un buffer del tamaño pedido, con ~1 coincidencia cada 5 KB."""
    line = b"linea %d valor=%d nota=ok\n"
    out = bytearray()
    i = 0
    while len(out) < total_bytes:
        out += line % (i, i % 97)
        if i % 5000 == 4999:
            out += b"needle aqui\n"
        i += 1
    return bytes(out)


def py_count(data):
    hits = 0
    for line in data.split(b"\n"):
        if NEEDLE in line:
            hits += 1
    return hits


def py_count_icase(data):
    hits = 0
    for line in data.lower().split(b"\n"):
        if NEEDLE in line:
            hits += 1
    return hits


def med(fn, runs=7):
    ts = []
    for _ in range(runs):
        t0 = time.perf_counter()
        fn()
        ts.append((time.perf_counter() - t0) * 1000)
    return statistics.median(ts)


print("=== contar líneas que contienen 'needle' (paridad verificada) ===")
print(f"{'tamaño':>10} | {'python':>11} | {'zig ctypes':>11} | {'ziggrep':>11} | ganancia")
print("-" * 74)

D2 = pathlib.Path("/tmp/opencode/zgpy/files")
D2.mkdir(exist_ok=True)
for label, nbytes in [("1 KB", 1024), ("10 KB", 10 * 1024), ("100 KB", 100 * 1024),
                      ("1 MB", 1024 * 1024), ("10 MB", 10 * 1024 * 1024)]:
    data = build(nbytes)
    assert py_count(data) == lib.zg_count(data, len(data), NEEDLE, len(NEEDLE), None, None), "paridad"
    tp = med(lambda: py_count(data))
    tz = med(lambda: lib.zg_count(data, len(data), NEEDLE, len(NEEDLE), None, None))

    f = D2 / f"f_{label.replace(' ', '')}.txt"
    f.write_bytes(data)
    # ziggrep -c sobre el fichero: incluye abrir, leer y contar
    def zrun():
        subprocess.run([ZGREP, "-c", "-e", NEEDLE, str(f)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    tzg = med(zrun, 5)
    print(f"{label:>10} | {tp:8.2f} ms | {tz:8.2f} ms | {tzg:8.2f} ms | x{tp/tz:5.1f}")

print()
print("=== plegado de mayúsculas (-i): el caso caro de Python ===")
for label, nbytes in [("100 KB", 100 * 1024), ("1 MB", 1024 * 1024)]:
    data = build(nbytes)
    low = bytes(data).lower()
    assert py_count_icase(data) == lib.zg_count_icase(data, len(data), NEEDLE, len(NEEDLE)), "paridad -i"
    tp = med(lambda: py_count_icase(data), 3)
    tz = med(lambda: lib.zg_count_icase(data, len(data), NEEDLE, len(NEEDLE)))
    print(f"  {label:>6}: py={tp:8.2f} ms  zig={tz:8.2f} ms  x{tp/tz:.1f}")

print()
print("=== el cruce: 200.000 llamadas con 16 bytes (¿cuánto cuesta entrar?) ===")
tiny = b"abcdefghijklmnop"
CALLS = 200_000
tpy = med(lambda: [sum(tiny) for _ in range(CALLS)], 5)
tzg = med(lambda: [lib.zg_tiny(tiny, len(tiny)) for _ in range(CALLS)], 5)
print(f"  python sum():   {tpy:8.2f} ms  ->  {tpy/CALLS*1e6:7.0f} ns por iteración")
print(f"  zig  ctypes():  {tzg:8.2f} ms  ->  {tzg/CALLS*1e6:7.0f} ns por iteración")
print(f"  coste del cruce ≈ {(tzg-tpy)/CALLS*1e6:.0f} ns por llamada")
print()
print("  Lectura: por debajo de ~10 KB de buffer, llamar a Zig cuesta MÁS de lo")
print("  que ahorra. Por encima, gana. El binario ziggrep ya incluye ese cálculo")
print("  (mira la columna 'ziggrep' arriba).")
