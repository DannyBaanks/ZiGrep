"""Tokens REALES (no bytes/4) con un tokenizador BPE de verdad.

Usa el subcomando `tokenize` de isyinfer-zig (el motor de inferencia de ISyCo) con
el GGUF de un modelo Qwen; el texto entra por argv, que admite como mucho 128 KiB
por argumento (MAX_ARG_STRLEN), así que se trocea en límites de línea por
debajo de ese tope. Cada llamada añade un BOS: se descuenta.

No es el tokenizador de Claude ni de ningún modelo en particular que vaya a leer
la salida: es UN BPE real, el mismo para todas las herramientas, que es lo que
hace justa la comparación. El evento resultado declara qué tokenizador se usó.

Configuración por entorno:
  ZGREP_TOKENIZER_BIN    (default: `isyinfer-zig` en el PATH)
  ZGREP_TOKENIZER_MODEL  (default: ~/models/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf)

La evidencia guarda solo el NOMBRE del binario y el sha256 del modelo, nunca
rutas locales (el repo es publico).
"""
from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
from pathlib import Path

HOME = Path.home()
BIN = os.environ.get("ZGREP_TOKENIZER_BIN") or shutil.which("isyinfer-zig") or "isyinfer-zig"
MODEL = os.environ.get("ZGREP_TOKENIZER_MODEL", str(HOME / "models/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf"))
CHUNK = 100_000  # < 131072 (MAX_ARG_STRLEN), con margen


def available() -> bool:
    return Path(BIN).is_file() and Path(MODEL).is_file()


_model_sha: str | None = None


def describe() -> dict:
    global _model_sha
    if _model_sha is None and Path(MODEL).is_file():
        h = hashlib.sha256()
        with open(MODEL, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 22), b""):
                h.update(chunk)
        _model_sha = h.hexdigest()
    return {"bin": Path(BIN).name, "model": Path(MODEL).name, "model_sha256": _model_sha,
            "model_bytes": Path(MODEL).stat().st_size if available() else None,
            "note": "BPE Qwen (vocab 151936) via isyinfer-zig tokenize; BOS descontado por trozo"}


def _chunks(text: str):
    start = 0
    while start < len(text):
        end = min(start + CHUNK, len(text))
        if end < len(text):
            nl = text.rfind("\n", start, end)
            if nl > start:
                end = nl + 1
        yield text[start:end]
        start = end


_cache: dict[str, int] = {}


def count(data: bytes) -> int:
    if not data:
        return 0
    key = hashlib.sha256(data).hexdigest()
    if key in _cache:
        return _cache[key]
    text = data.decode("utf-8", "replace").replace("\x00", "\\0")
    total = 0
    for piece in _chunks(text):
        # Tope de memoria: el binario carga el GGUF (regla del host: todo run de
        # modelo va acotado).
        p = subprocess.run(
            ["systemd-run", "--user", "--scope", "-q", "-p", "MemoryMax=6G",
             BIN, "tokenize", "--model", MODEL, "--prompt", piece],
            capture_output=True, text=True, timeout=120,
        )
        # isyinfer-zig imprime el "prompt" SIN escapar (comillas y saltos de
        # linea crudos), asi que su salida no es JSON valido cuando el texto
        # trae JSON o varias lineas: se leen solo status y n_tokens, que van
        # antes/despues del prompt y no dependen de el.
        out = p.stdout
        m = re.search(r'"n_tokens":(\d+)\}\s*$', out)
        if p.returncode != 0 or not out.startswith('{"status":"OK"') or not m:
            raise RuntimeError(f"tokenize fallo (rc {p.returncode}): {out[:200]!r} {p.stderr[:200]!r}")
        total += int(m.group(1)) - 1  # BOS
    _cache[key] = total
    return total
