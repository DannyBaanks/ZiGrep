#!/usr/bin/env python3
"""Experimento decisivo para el mockup de Argon: ¿gana io_uring en frío?

Mide el mismo árbol (workspace/assembly, 634 MB, 5338 ficheros) en caliente y
en frío, con los dos motores, en la MISMA condición de caché para los dos.
El frío se provoca expulsando cada fichero con posix_fadvise(DONTNEED), que
no necesita root. La alternativa (echo 3 > /proc/sys/vm/drop_caches) sí lo
necesitaría y midiría también el cache de otros procesos.
"""
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

TREE = "/home/danny/Development/ISyCo/workspace/assembly"
ZIGREP = "/home/danny/Development/ISyCo Git/ZigGrep/zig-out/bin/zigrep"
PATTERN = "const"
COLD = 4  # POSIX_FADV_DONTNEED


def _files():
    root = Path(TREE)
    return [str(p) for p in root.rglob("*") if p.is_file() and not p.is_symlink()]


FILES = _files()


def evict() -> None:
    for path in FILES:
        try:
            fd = os.open(path, os.O_RDONLY)
        except OSError:
            continue
        try:
            os.posix_fadvise(fd, 0, 0, COLD)
        except OSError:
            pass
        finally:
            os.close(fd)


def run(extra):
    cmd = [ZIGREP] + extra + ["-c", "-e", PATTERN, TREE]
    t = time.perf_counter()
    p = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ms = (time.perf_counter() - t) * 1000
    if p.returncode not in (0, 1):
        raise SystemExit(f"{cmd} salió con código {p.returncode}")
    return ms


def series(label, extra, warm, n=5):
    samples = []
    for _ in range(n):
        if not warm:
            evict()
        samples.append(run(extra))
    print(
        f"  {label:<28} mediana={statistics.median(samples):8.2f} ms  "
        f"min={min(samples):8.2f}  máx={max(samples):8.2f}  "
        f"todas={[round(s, 1) for s in samples]}",
        flush=True,
    )
    return statistics.median(samples)


def loadavg():
    with open("/proc/loadavg") as f:
        return f.read().split()[0]


print(f"árbol      : {TREE} ({len(FILES)} ficheros)")
print(f"carga host : {loadavg()}   núcleos: {os.cpu_count()}")
print(f"memoria    : ", end="")
subprocess.run(["free", "-g"], stdout=sys.stdout, check=False)
print("\n=== 1. CALIENTE (el cache se llena en la primera pasada) ===")
series("kamikaze (default)", [], warm=True, n=3)  # calienta el cache
hot_kam = series("kamikaze (default)", [], warm=True, n=5)
hot_ur = series("--uring", ["--uring"], warm=True, n=5)
print(f"  => en caliente el enjambre síncrono gana por {hot_ur - hot_kam:.1f} ms "
      f"({hot_ur / hot_kam:.2f}x)\n")

print("=== 2. FRÍO (se expulsa cada fichero antes de cada corrida) ===")
cold_kam = series("kamikaze (default)", [], warm=False, n=5)
cold_ur = series("--uring", ["--uring"], warm=False, n=5)
print(f"\n  => en frío uring gana por {cold_kam - cold_ur:.1f} ms "
      f"({cold_kam / cold_ur:.2f}x)" if cold_ur < cold_kam else
      f"\n  => en frío uring NO gana: {cold_kam - cold_ur:.1f} ms de diferencia")

print("\n=== 3. Resumen ===")
print(f"  kamikaze  caliente {hot_kam:7.2f} ms   frío {cold_kam:7.2f} ms   "
      f"penalización por frío: {cold_kam / hot_kam:.2f}x")
print(f"  --uring   caliente {hot_ur:7.2f} ms   frío {cold_ur:7.2f} ms   "
      f"penalización por frío: {cold_ur / hot_ur:.2f}x")
gap_hot = hot_ur - hot_kam
gap_cold = cold_kam - cold_ur
print(f"\n  lo que está en juego: en caliente uring PIERDE {gap_hot:.1f} ms; "
      f"en frío GANA {gap_cold:.1f} ms")
print(f"  un despachador híbrido capturaría {min(abs(gap_hot), abs(gap_cold)):.1f} ms "
      "en el mejor de los dos casos")
