"""Carga y compilación de la librería nativa.

Dos modos, sin configuración:
  * si `libziggrep.so` está junto al paquete (instalado desde un wheel), se usa;
  * si no, se compila con `zig build-lib` en un caché de usuario la primera vez.

Comprobar la paridad con el puro Python es parte del contrato: cada función
nativa tiene su equivalente en `_py.py` y los tests las comparan.
"""
from __future__ import annotations

import ctypes
import hashlib
import os
import subprocess
import sys
import threading
from pathlib import Path

_HERE = Path(__file__).resolve().parent
_LOCK = threading.Lock()
_LIB: ctypes.CDLL | None = None

# Funciones exportadas por kernels.zig: nombre -> (argtypes, restype)
_SIGNATURES = {
    "zg_count": ([ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t,
                  ctypes.POINTER(ctypes.c_size_t), ctypes.POINTER(ctypes.c_size_t)],
                 ctypes.c_size_t),
    "zg_count_matches": ([ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_bool],
                          ctypes.c_size_t),
    "zg_count_icase": ([ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t],
                        ctypes.c_size_t),
    "zg_line_sum": ([ctypes.c_char_p, ctypes.c_size_t], ctypes.c_uint64),
    "zg_tiny": ([ctypes.c_char_p, ctypes.c_size_t], ctypes.c_uint64),
}


def _cache_dir() -> Path:
    base = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(base) / "ziggrep-python"


def _zig() -> str:
    zig = os.environ.get("ZIG", "zig")
    return zig


def _build_into(dest: Path) -> None:
    """Compila kernels.zig a `dest` con `zig build-lib`."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        _zig(), "build-lib", "-dynamic", "-OReleaseFast",
        f"-femit-bin={dest}", str(_HERE / "kernels.zig"),
    ]
    subprocess.run(cmd, check=True, capture_output=True, text=True)


def _build_library(force: bool = False) -> Path:
    """Compila (o reutiliza) el .so en el caché de usuario y devuelve su ruta."""
    global _LIB
    digest = hashlib.sha256((_HERE / "kernels.zig").read_bytes()).hexdigest()[:16]
    dest = _cache_dir() / f"libziggrep-{digest}.so"
    if force or not dest.exists():
        _build_into(dest)
        _LIB = None
    return dest


def _load() -> ctypes.CDLL:
    candidates = [_HERE / "libziggrep.so", _HERE.parent / "libziggrep.so"]
    for cand in candidates:
        if cand.exists():
            return _bind(cand)
    return _bind(_build_library())


def _bind(path: Path) -> ctypes.CDLL:
    lib = ctypes.CDLL(str(path))
    for name, (argtypes, restype) in _SIGNATURES.items():
        fn = getattr(lib, name)
        fn.argtypes = argtypes
        fn.restype = restype
    return lib


def library() -> ctypes.CDLL:
    global _LIB
    with _LOCK:
        if _LIB is None:
            _LIB = _load()
        return _LIB


def library_path() -> Path | None:
    for cand in (_HERE / "libziggrep.so", _HERE.parent / "libziggrep.so"):
        if cand.exists():
            return cand
    digest = hashlib.sha256((_HERE / "kernels.zig").read_bytes()).hexdigest()[:16]
    dest = _cache_dir() / f"libziggrep-{digest}.so"
    return dest if dest.exists() else None
