#!/usr/bin/env python3
"""Tokens por sha256 según su codificación SIN PÉRDIDA (M5): por qué zgrep/1c
usa base64url. Mismos 32 bytes, distinto texto; tokens reales (tokcount.py),
descontando el envoltorio JSON igual en todos los casos.
Uso: python3 evidence/agent-native/m5/hash_encoding.py [--n 500] [--seed 20261111]"""
import argparse
import base64
import hashlib
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tokcount  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--n", type=int, default=500)
ap.add_argument("--seed", type=int, default=20261111)
a = ap.parse_args()
rng = random.Random(a.seed)
hs = [hashlib.sha256(rng.randbytes(64)).digest() for _ in range(a.n)]
ENC = {
    "hex (zgrep/1, sha256sum)": lambda h: h.hex(),
    "base64url sin relleno (zgrep/1c)": lambda h: base64.urlsafe_b64encode(h).decode().rstrip("="),
    "base64": lambda h: base64.b64encode(h).decode(),
    "base85": lambda h: base64.b85encode(h).decode(),
}
base = tokcount.count("\n".join('{"sha256":""}' for _ in hs).encode())
print(f"tokenizador: {tokcount.describe()['note']}; n={a.n} hashes, semilla {a.seed}")
for name, f in ENC.items():
    txt = "\n".join('{"sha256":"%s"}' % f(h) for h in hs).encode()
    t = tokcount.count(txt) - base
    print(f"{name:<34} chars={len(f(hs[0])):>3}  tokens/hash={t / a.n:6.2f}")
