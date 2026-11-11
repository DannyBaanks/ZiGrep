#!/usr/bin/env python3
"""Aceptación de M7: con `--max-output-tokens T`, los tokens REALES (BPE,
../tokcount.py) de los eventos de búsqueda emitidos no pasan de T.

Se mide en los dos dialectos (--json, --json=compact), en lote y en búsqueda
suelta, para varios T. Además del veredicto se informa el APROVECHAMIENTO
(tokens reales / T): un estimador demasiado conservador cumple la cota pero
desperdicia presupuesto. Los eventos de control (cabecera de stream, marcador de
consulta, query_end, summary) no están en el presupuesto (contract.md §10).

Con --zgrep apuntando al binario anterior a M7 sirve de control negativo: su
bytes/4 debería pasarse de T.
Uso: python3 evidence/agent-native/m7/budget_real_tokens.py [--zgrep RUTA]
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "evidence" / "agent-native"))
import tokcount  # noqa: E402

C = "bench-corpus/corpus_1000"
QF = "evidence/agent-native/queries/phrase_survey.jsonl"
BUDGETS = [50, 200, 1000, 5000, 20000]
MODES = {
    "suelta -n needle": ["-e", "ZGREP_PLANTED_TOKEN", C],
    "suelta -C2 rare": ["-C", "2", "-e", "ZGREP_RARE_TOKEN", C],
    "lote phrase_survey": ["--queries-file", QF, C],
}


def search_lines(out: bytes) -> bytes:
    keep = []
    for l in out.decode().split("\n")[:-1]:
        d = json.loads(l)
        if isinstance(d, dict):
            if d.get("type") in ("query_end", "summary") or d == {"schema": "zgrep/1c"} or list(d) == ["query_id"]:
                continue
        keep.append(l + "\n")
    return "".join(keep).encode()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zgrep", default=str(ROOT / "zig-out" / "bin" / "zgrep"))
    z = ap.parse_args().zgrep
    ver = subprocess.run([z, "--version"], capture_output=True, text=True).stdout.strip()
    print(f"zgrep: {ver} ({z})\ntokenizador: {tokcount.describe()['note']}")
    print(f"{'modo':<20} {'dialecto':<9} {'T':>6} {'reales':>7} {'real/T':>7}  cota")
    over = 0
    total = 0
    for name, args in MODES.items():
        for dialect in ("--json", "--json=compact"):
            for T in BUDGETS:
                out = subprocess.run([z, dialect, "--max-output-tokens", str(T), *args], cwd=ROOT,
                                     capture_output=True).stdout
                real = tokcount.count(search_lines(out))
                ok = real <= T
                over += not ok
                total += 1
                print(f"{name:<20} {dialect[7:] or 'full':<9} {T:>6} {real:>7} {real / T:>7.2f}  {'OK' if ok else 'SE PASA'}")
    print(f"TOTAL {total - over} dentro de la cota / {over} se pasan")
    return 0 if over == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
