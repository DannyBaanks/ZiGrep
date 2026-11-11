#!/usr/bin/env python3
"""M9 (confirmación): el ahorro medido con la IMPLEMENTACIÓN, en el árbol real.

`long_lines_study.py` simuló el recorte en Python antes de escribirlo. Este
script mide el recorte REAL (`--max-columns N`) sobre el mismo árbol con
node_modules, con tokens de verdad (tokcount, BPE Qwen).

Las dos salidas llevan las MISMAS filas: `--max-results` corta por número de
eventos y el recorte no cambia ni el orden ni cuántos eventos hay, así que la
comparación es de uno a uno. Lo que se imprime:

  * tokens de la salida completa (sin recorte) y de la recortada, por consulta;
  * el ahorro total y si el match quedó intacto en todas las filas recortadas
    (verificado rebanando la línea REAL del fichero en disco: la ventana es
    file[line_start+win_start .. +len], line_start = byte_start-(col-1)).

REGLA (fijada antes de correr, heredada del estudio): implementar si el ahorro
total con el match intacto es >= 20 %.

Uso: python3 evidence/agent-native/m9/real_tree_tokens.py --tree DIR [--rows 2000]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "evidence" / "agent-native"))
import tokcount  # noqa: E402

Z = str(ROOT / "zig-out" / "bin" / "zgrep")
QUERIES = ["function", "export", r"require\(", "fetch", "Error"]
WINDOWS = [200, 400]


def run(argv: list[str], cwd: Path) -> bytes:
    return subprocess.run(argv, cwd=str(cwd), capture_output=True).stdout


def rows_of(out: bytes) -> list[list]:
    return [json.loads(l) for l in out.decode().split("\n")[:-1]]


def files_of(tree: Path) -> dict[str, bytes]:
    """Los ficheros que aparecen en la salida, leídos una sola vez."""
    return {}


def check_intact(rows: list[list], tree: Path, w: int) -> tuple[int, bool]:
    """Filas recortadas y si el match quedó intacto en todas (contra el disco)."""
    cache: dict[str, bytes] = {}
    cut = 0
    intact = True
    path = None
    for d in rows:
        if isinstance(d, dict):
            if "path" in d:
                path = d["path"]
            continue
        if not isinstance(d, list) or len(d) < 6 or not isinstance(d[0], str):
            continue
        tag, line, col, bs, n, text = d[0], d[1], d[2], d[3], d[4], d[5]
        if not tag.endswith("w"):
            continue
        cut += 1
        full = (tree / path).read_bytes() if path not in cache else cache[path]
        cache.setdefault(path, full)
        line_start = bs - (col - 1)
        whole = full.split(b"\n")[line - 1]
        win = text.encode()
        ok = (whole[col - 1:col - 1 + n] == full[bs:bs + n]
              and len(whole) == d[7]
              and whole[d[6]:d[6] + len(win)] == win
              and 0 <= col - 1 - d[6] and win[col - 1 - d[6]:col - 1 - d[6] + n] == full[bs:bs + n])
        intact &= ok
    return cut, intact


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", required=True)
    ap.add_argument("--rows", type=int, default=2000)
    a = ap.parse_args()
    tree = Path(a.tree).resolve()
    commit = subprocess.run(["git", "-C", str(tree), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    locks = [tree / n for n in ("bun.lock", "package-lock.json", "pnpm-lock.yaml", "yarn.lock") if (tree / n).exists()]
    lock_desc = ", ".join(f"{l.name} sha256={hashlib.sha256(l.read_bytes()).hexdigest()}" for l in locks) or "sin lockfile"
    print(f"arbol: {tree.name} commit={commit[:12]} {lock_desc}")
    print(f"tokenizador: {tokcount.describe()['note']}")
    print(f"filas por consulta: las primeras {a.rows} (--max-results, mismas filas en ambas salidas)")
    print(f"{'consulta':<11} {'W':>4} {'recortadas':>10} {'tokens sin recorte':>19} {'tokens recortado':>18} {'ahorro':>7}  match intacto")
    tot = {w: [0, 0] for w in WINDOWS}
    all_intact = {w: True for w in WINDOWS}
    for q in QUERIES:
        base = [Z, "--json=compact", "--sort", "-E", q, "node_modules", "--max-results", str(a.rows)]
        plain = run(base, tree)
        tb = tokcount.count(plain)
        for w in WINDOWS:
            cut_out = run([*base, "--max-columns", str(w)], tree)
            rows = rows_of(cut_out)
            n_cut, intact = check_intact(rows, tree, w)
            tc = tokcount.count(cut_out)
            tot[w][0] += tb
            tot[w][1] += tc
            all_intact[w] &= intact
            print(f"{q:<11} {w:>4} {n_cut:>10} {tb:>19} {tc:>18} {1 - tc / tb:>7.1%}  {'si' if intact else 'NO'}")
    print()
    for w in WINDOWS:
        saving = 1 - tot[w][1] / tot[w][0]
        print(f"TOTAL W={w}: {tot[w][0]} -> {tot[w][1]} tokens, ahorro {saving:.1%}, match intacto en todas: {all_intact[w]}")
    ok = [w for w in WINDOWS if all_intact[w] and 1 - tot[w][1] / tot[w][0] >= 0.20]
    print(f"\nVEREDICTO (regla >= 20 % con match intacto, implementacion real): "
          + (f"CONFIRMADO para W={', '.join(map(str, ok))}" if ok else "NO CONFIRMADO"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
