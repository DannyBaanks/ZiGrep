#!/usr/bin/env python3
"""Fixture determinista de M9: líneas largas de verdad.

El estudio (long_lines_study.py) usó un árbol real con node_modules, cuyo
contenido no se copia aquí (licencias de terceros). Este fixture fija las
formas que importan para el contrato de `--max-columns`, reproducibles byte a
byte sin depender de nadie:

  * línea mucho más larga que cualquier W de prueba, con el match al principio,
    en el medio y al final;
  * padding multibyte (UTF-8) alrededor del match: ahí un corte naïve parte un
    carácter;
  * líneas que CABEN (no deben recortarse nunca);
  * una línea larga SIN match (fila de contexto / passthru / -v);
  * un match que SOLO ya no cabe en N (la ventana es el match).

Uso: python3 evidence/agent-native/m9/make_fixture.py
Escribe fix/*.txt + fix/SHA256SUMS.txt (determinista: mismo contenido, mismo hash).
"""
from __future__ import annotations

import hashlib
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIX = HERE / "fix"

# El carácter de relleno y el patrón son fijos a propósito: un off-by-one en la
# ventana tiene que ser visible en la aserción de cadena, no escondido en datos.
PAT = "HIT"


def line(head: str, pat: str | None, tail: str) -> str:
    return head + (pat or "") + tail


def main() -> int:
    FIX.mkdir(parents=True, exist_ok=True)
    files: dict[str, str] = {
        # 403 / 608 / 509 / 403 / 13 / 800 bytes: tres ventanas de prueba
        # (40, 200, 400) cortan unas y dejan otras enteras.
        "long.txt": "\n".join(
            [
                "x" * 200 + PAT + "y" * 200,  # match en el medio
                "a" * 5 + PAT + "b" * 600,  # match casi al principio
                "c" * 500 + " ENDLINE",  # match al final, con espacio antes
                "ñ" * 100 + PAT + "é" * 100,  # padding multibyte a los dos lados
                "short " + PAT + " line",  # cabe: jamás se recorta
                "z" * 800,  # línea larga SIN match (contexto / passthru / -v)
                "m" * 500,  # match que solo ya no cabe en 40/200
                "M" * 3,  # línea corta al final, para el orden
            ]
        )
        + "\n",
        # Todas las líneas caben en 40 bytes: con W=40 nada debe recortarse.
        "short.txt": "\n".join(["one " + PAT, "two", "three " + PAT + " here"]).replace("\n\n", "\n") + "\n",
        # Varias líneas largas seguidas, para el lote y el contexto.
        "multi.txt": "\n".join(
            [
                "first no match " + "f" * 60,
                "p" * 120 + PAT + "q" * 120,
                "second no match " + "s" * 60,
                "r" * 300 + PAT,
                PAT,
                "t" * 700 + PAT + "t" * 9,
            ]
        )
        + "\n",
    }
    for name, text in files.items():
        (FIX / name).write_bytes(text.encode())

    sums = []
    for p in sorted(FIX.glob("*")):
        if p.is_file():
            sums.append(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}")
    (FIX / "SHA256SUMS.txt").write_text("\n".join(sums) + "\n")
    print("\n".join(sums))
    return 0


if __name__ == "__main__":
    sys.exit(main())
