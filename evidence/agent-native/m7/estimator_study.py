#!/usr/bin/env python3
"""M7: ¿qué estimador de tokens acierta? (corrige el bytes/4 de M3)

Dataset: líneas REALES de salida de zgrep en todos los dialectos y modos
(texto -n/-l/-c/-o/-C, zgrep/1, zgrep/1c, con --provenance), sobre el corpus
sintético, el código de src/ y la GUIA (español, unicode). Se agrupan en bloques
de líneas del mismo origen; cada bloque se tokeniza con el BPE real
(../tokcount.py). Los estimadores son lineales en rasgos que se cuentan en una
pasada por byte (lo que se puede implementar en Zig sin coste apreciable), así
que la suma de rasgos de un bloque predice sus tokens.

Protocolo (fijado antes de mirar los resultados):
  * bloques barajados con semilla fija; mitad AJUSTE, mitad VALIDACIÓN;
  * cada estimador se ajusta (mínimos cuadrados no negativos sobre los rasgos)
    en AJUSTE y luego se escala por el cuantil máximo de real/estimado en
    AJUSTE, para que no subestime ahí;
  * se informa, en VALIDACIÓN: peor subestimación (real/estimado máximo),
    sesgo medio (estimado/real) y error absoluto medio relativo;
  * criterio de elección: el que NO subestime en ningún bloque de validación
    (real/estimado <= 1) con el menor sesgo medio. Si ninguno lo cumple, el de
    menor peor-subestimación, y se declara el margen.

CORRECCION (2026-11-11, tras la primera corrida, seed 7): el "bytes/4 (M3,
actual)" se evaluaba ESCALADO, asi que no era bytes/4. Ahora el actual se mide
tal cual (escala 1). Esa corrida (estimator_study_output_seed7.txt) se conserva.

CONFIRMATORIA (regla escrita ANTES de correrla, seed 11, bloques de 30, datos
nuevos): el estimador por clases, con los pesos y la escala ajustados en SU
mitad de ajuste y un margen declarado de +1 %, se adopta solo si no subestima
NINGUN bloque de validacion. Si subestima alguno, se adopta bytes/k ajustado.

Uso: python3 evidence/agent-native/m7/estimator_study.py [--seed 7] [--block 40]
"""
from __future__ import annotations

import argparse
import json
import random
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "evidence" / "agent-native"))
import tokcount  # noqa: E402

Z = str(ROOT / "zig-out" / "bin" / "zgrep")
C = "bench-corpus/corpus_1000"
SOURCES = {
    # nombre: argv (sin el binario). Cubre los tres dialectos y los modos.
    "texto -n": ["-n", "-e", "ZGREP_RARE_TOKEN", "-e", "socket path", C],
    "texto -l": ["-l", "ZGREP_PLANTED_TOKEN", C],
    "texto -c": ["-c", "ZGREP_PLANTED_TOKEN", C],
    "texto -o": ["-o", "-E", r"\bZGREP_PLANTED_TOKEN\b", C],
    "texto src": ["-n", "-w", "-e", "Searcher", "-e", "const", "src"],
    "texto GUIA": ["-n", "-e", "ñ", "-e", "é", "-e", "→", "GUIA.md"],
    "json -n": ["--json", "-e", "ZGREP_RARE_TOKEN", "-e", "socket path", C],
    "json -l": ["--json", "-l", "ZGREP_PLANTED_TOKEN", C],
    "json -o": ["--json", "-o", "-E", r"\bZGREP_PLANTED_TOKEN\b", C],
    "json src": ["--json", "-w", "-e", "Searcher", "-e", "const", "src"],
    "json GUIA": ["--json", "-e", "ñ", "-e", "é", "-e", "→", "GUIA.md"],
    "json prov": ["--json", "--provenance", "-c", "ZGREP_PLANTED_TOKEN", C],
    "compact -n": ["--json=compact", "-e", "ZGREP_RARE_TOKEN", "-e", "socket path", C],
    "compact -l": ["--json=compact", "-l", "ZGREP_PLANTED_TOKEN", C],
    "compact -o": ["--json=compact", "-o", "-E", r"\bZGREP_PLANTED_TOKEN\b", C],
    "compact src": ["--json=compact", "-w", "-e", "Searcher", "-e", "const", "src"],
    "compact GUIA": ["--json=compact", "-e", "ñ", "-e", "é", "-e", "→", "GUIA.md"],
    "compact prov": ["--json=compact", "--provenance", "-c", "ZGREP_PLANTED_TOKEN", C],
}
MAX_LINES_PER_SOURCE = 1200


def features(b: bytes) -> list[float]:
    """Rasgos contables en una pasada por byte:
    [bytes, tramos de letras ASCII, digitos, puntuacion ASCII, tramos de
     espacio, bytes no-ASCII, transiciones letra<->digito]"""
    n_alpha_runs = n_digit = n_punct = n_space_runs = n_nonascii = n_ld = 0
    prev = None  # 'a' letra, 'd' digito, 's' espacio, 'p' punct, 'n' no-ascii
    for c in b:
        if c >= 0x80:
            k = "n"
            n_nonascii += 1
        elif (65 <= c <= 90) or (97 <= c <= 122) or c == 95:
            k = "a"
            if prev != "a":
                n_alpha_runs += 1
        elif 48 <= c <= 57:
            k = "d"
            n_digit += 1
        elif c in (32, 9, 10, 13):
            k = "s"
            if prev != "s":
                n_space_runs += 1
        else:
            k = "p"
            n_punct += 1
        if (prev, k) in (("a", "d"), ("d", "a")):
            n_ld += 1
        prev = k
    return [len(b), n_alpha_runs, n_digit, n_punct, n_space_runs, n_nonascii, n_ld]


FEATS = ["bytes", "alpha_runs", "digits", "punct", "space_runs", "nonascii", "letter_digit"]


def nnls(X: list[list[float]], y: list[float], iters: int = 20000, lr: float = 1e-3) -> list[float]:
    """Minimos cuadrados no negativos por descenso proyectado (sin numpy)."""
    m = len(X[0])
    scale = [max(1.0, max(r[j] for r in X)) for j in range(m)]
    Xs = [[r[j] / scale[j] for j in range(m)] for r in X]
    ys = max(y)
    yn = [v / ys for v in y]
    w = [0.1] * m
    n = len(Xs)
    for _ in range(iters):
        g = [0.0] * m
        for r, t in zip(Xs, yn):
            e = sum(a * b for a, b in zip(r, w)) - t
            for j in range(m):
                g[j] += 2 * e * r[j] / n
        w = [max(0.0, wj - lr * 50 * gj) for wj, gj in zip(w, g)]
    return [wj * ys / scale[j] for j, wj in enumerate(w)]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--block", type=int, default=40)
    a = ap.parse_args()
    rng = random.Random(a.seed)

    blocks = []  # (source, bytes)
    for name, args in SOURCES.items():
        out = subprocess.run([Z, *args], cwd=ROOT, capture_output=True).stdout
        lines = out.splitlines(keepends=True)
        if len(lines) > MAX_LINES_PER_SOURCE:
            lines = rng.sample(lines, MAX_LINES_PER_SOURCE)
        for i in range(0, len(lines) - a.block + 1, a.block):
            blocks.append((name, b"".join(lines[i:i + a.block])))
    rng.shuffle(blocks)
    print(f"tokenizador: {tokcount.describe()['note']}; bloques={len(blocks)} de {a.block} lineas; semilla {a.seed}")
    data = [(src, b, features(b), tokcount.count(b)) for src, b in blocks]
    half = len(data) // 2
    fit, val = data[:half], data[half:]

    def evaluate(name: str, est, scaled: bool = True, margin: float = 1.0):
        # escala conservadora en AJUSTE: que real/estimado <= 1 en todo AJUSTE
        # (el estimador ACTUAL se mide tal cual: scaled=False)
        k = (max(t / est(f) for _, _, f, t in fit if est(f) > 0) if scaled else 1.0) * margin
        rows = [(src, t, k * est(f)) for src, _, f, t in val]
        worst = max(t / e for _, t, e in rows)
        bias = sum(e / t for _, t, e in rows) / len(rows)
        mae = sum(abs(e - t) / t for _, t, e in rows) / len(rows)
        under = sum(1 for _, t, e in rows if t > e)
        by_src: dict[str, float] = {}
        for src, t, e in rows:
            by_src[src] = max(by_src.get(src, 0), t / e)
        return {"name": name, "scale": k, "worst_real_over_est": worst, "mean_est_over_real": bias,
                "mae_rel": mae, "underestimated_blocks": under, "val_blocks": len(rows), "worst_by_source": by_src}

    res = []
    res.append(evaluate("bytes/4 (M3, actual, tal cual)", lambda f: f[0] / 4, scaled=False))
    # bytes/k ajustado: misma forma, solo cambia la escala
    res.append(evaluate("bytes/k ajustado", lambda f: f[0]))
    Xf = [f for _, _, f, _ in fit]
    yf = [t for _, _, _, t in fit]
    w = nnls(Xf, yf)
    res.append(evaluate("clases de caracteres (lineal)", lambda f, w=w: sum(a * b for a, b in zip(w, f))))
    res.append(evaluate("clases + margen 1 % (candidato)", lambda f, w=w: sum(a * b for a, b in zip(w, f)), margin=1.01))
    print("pesos del estimador por clases:", ", ".join(f"{n}={v:.4f}" for n, v in zip(FEATS, w)))
    print(f"\n{'estimador':<32} {'escala':>7} {'peor real/est':>14} {'sesgo est/real':>15} {'MAE rel':>8} {'subestima':>10}")
    for r in res:
        print(f"{r['name']:<32} {r['scale']:7.3f} {r['worst_real_over_est']:14.3f} {r['mean_est_over_real']:15.3f} "
              f"{r['mae_rel']:8.3f} {r['underestimated_blocks']:>4}/{r['val_blocks']}")
    # el actual no es candidato a ganar: es el control
    cands = [r for r in res if not r["name"].startswith("bytes/4")]
    ok = [r for r in cands if r["worst_real_over_est"] <= 1.0]
    choice = min(ok, key=lambda r: r["mean_est_over_real"]) if ok else min(cands, key=lambda r: r["worst_real_over_est"])
    print(f"\nELEGIDO: {choice['name']} (no subestima en validacion: {choice['worst_real_over_est'] <= 1.0})")
    print("peor real/est por origen (elegido):")
    for src, v in sorted(choice["worst_by_source"].items()):
        print(f"  {src:<14} {v:.3f}")
    out = {"seed": a.seed, "block": a.block, "features": FEATS, "weights": w, "results": res, "choice": choice["name"],
           "tokenizer": tokcount.describe()}
    (Path(__file__).resolve().parent / f"estimator_study_seed{a.seed}.json").write_text(json.dumps(out, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
