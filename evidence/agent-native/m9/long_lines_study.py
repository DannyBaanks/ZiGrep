#!/usr/bin/env python3
"""M9: ¿cortar las líneas largas ahorra tokens de verdad? (regla RTK: >= 20 %)

Corpus REAL con líneas largas: el árbol de un proyecto JS con su node_modules
(código minificado y generado), que es donde un agente se las encuentra. Se
registran el commit del proyecto y el sha256 de su lockfile; el contenido no se
copia aquí (licencias de terceros).

Para cada búsqueda se toma la salida real `zgrep --json=compact` y se simula el
corte: el `text` de cada fila cuyo texto pasa de W bytes se reemplaza por una
ventana de W bytes alrededor del match, y la fila lleva además dónde empieza la
ventana y cuánto mide la línea completa (con eso, más byte_start de la línea,
la línea entera se recupera del fichero; con --provenance, verificable por hash).
El match no se corta nunca. Tokens reales (../tokcount.py).

REGLA (fijada antes de correr): se implementa si, para alguna W que deje el
match intacto en todas las filas, el ahorro TOTAL de tokens frente al compacto
actual es >= 20 %. Si no, no se implementa y se publica el negativo.

Uso: python3 evidence/agent-native/m9/long_lines_study.py --tree DIR [--seed 9] [--rows 3000]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import random
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "evidence" / "agent-native"))
import tokcount  # noqa: E402

Z = str(ROOT / "zig-out" / "bin" / "zgrep")
QUERIES = ["function", "export", r"require\(", "fetch", "Error"]
WINDOWS = [120, 200, 400]


def cut_row(row: list, w: int) -> tuple[list, bool]:
    """Fila compacta con span: [t, line, col, bs, len, text(, match)]."""
    if len(row) < 6:
        return row, False
    t, line, col, bs, n, text = row[:6]
    tb = text.encode()
    if len(tb) <= w:
        return row, False
    m0, m1 = col - 1, col - 1 + n
    if m1 - m0 >= w:                       # el match solo ya no cabe: se deja entero
        start, end = m0, m1
    else:
        pad = (w - (m1 - m0)) // 2
        start = max(0, m0 - pad)
        end = min(len(tb), start + w)
        start = max(0, end - w)
    win = tb[start:end].decode("utf-8", "ignore")
    # ["mw", line, col, bs, len, ventana, inicio_ventana, largo_linea]
    out = [t + "w", line, col, bs, n, win, start, len(tb)]
    if len(row) == 7:
        out.append(row[6])
    ok = tb[m0:m1] == win.encode()[m0 - start:m1 - start] if start <= m0 and end >= m1 else False
    return out, ok


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", required=True)
    ap.add_argument("--seed", type=int, default=9)
    ap.add_argument("--rows", type=int, default=3000)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    tree = Path(a.tree).resolve()
    commit = subprocess.run(["git", "-C", str(tree), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    locks = [tree / n for n in ("bun.lock", "package-lock.json", "pnpm-lock.yaml", "yarn.lock") if (tree / n).exists()]
    lock_desc = ", ".join(f"{l.name} sha256={hashlib.sha256(l.read_bytes()).hexdigest()}" for l in locks) or "sin lockfile"
    print(f"arbol: {tree.name} commit={commit[:12]} {lock_desc}")
    print(f"tokenizador: {tokcount.describe()['note']}; filas muestreadas por consulta={a.rows}, semilla {a.seed}")
    print(f"{'consulta':<11} {'W':>4} {'filas cortadas':>15} {'tokens actual':>14} {'tokens cortado':>15} {'ahorro':>7}  match intacto")
    tot = {w: [0, 0] for w in WINDOWS}
    all_intact = {w: True for w in WINDOWS}
    for q in QUERIES:
        out = subprocess.run([Z, "--json=compact", "--sort", "-E", q, "node_modules"], cwd=tree, capture_output=True).stdout
        lines = out.decode().split("\n")[:-1]
        rows = [(i, json.loads(l)) for i, l in enumerate(lines)]
        idx = [i for i, d in rows if isinstance(d, list) and d[0][0] in "moc" and len(d) >= 6]
        keep = set(rng.sample(idx, min(a.rows, len(idx))))
        # stream reducido: cabecera, y por cada fila muestreada su cabecera de fichero
        sample, cur_hdr, last = [lines[0]], None, None
        for i, d in rows[1:]:
            if isinstance(d, dict) and "path" in d:
                cur_hdr = lines[i]
            elif i in keep:
                if cur_hdr != last:
                    sample.append(cur_hdr)
                    last = cur_hdr
                sample.append(lines[i])
        base = ("\n".join(sample) + "\n").encode()
        tb = tokcount.count(base)
        for w in WINDOWS:
            cut, n_cut, intact = [], 0, True
            for l in sample:
                d = json.loads(l)
                if isinstance(d, list):
                    r, ok = cut_row(d, w)
                    if r is not d:
                        n_cut += 1
                        intact &= ok
                    cut.append(json.dumps(r, ensure_ascii=False, separators=(",", ":")))
                else:
                    cut.append(l)
            tc = tokcount.count(("\n".join(cut) + "\n").encode())
            tot[w][0] += tb
            tot[w][1] += tc
            all_intact[w] &= intact
            print(f"{q:<11} {w:>4} {n_cut:>15} {tb:>14} {tc:>15} {1 - tc / tb:>7.1%}  {'si' if intact else 'NO'}")
    print()
    best = None
    for w in WINDOWS:
        saving = 1 - tot[w][1] / tot[w][0]
        print(f"TOTAL W={w}: {tot[w][0]} -> {tot[w][1]} tokens, ahorro {saving:.1%}, match intacto en todas: {all_intact[w]}")
        if all_intact[w] and saving >= 0.20 and (best is None or w > best[0]):
            best = (w, saving)
    print(f"\nVEREDICTO (regla >= 20 % con match intacto): " +
          (f"IMPLEMENTAR; la W mas generosa que cumple es {best[0]} ({best[1]:.1%})" if best else "NO IMPLEMENTAR"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
