#!/usr/bin/env python3
"""¿Cuánto del sobrecoste del JSON es necesario? Estudio de formatos (M5).

M3 midió que `zgrep/1` pesa ~2-3x el texto de grep. Este estudio NO cambia la
herramienta: toma la salida real de `zgrep --json` en tareas del arnés y la
reescribe en formatos candidatos SIN PERDER INFORMACIÓN (cada candidato se
decodifica de vuelta y debe dar exactamente los mismos registros canónicos que
zgrep/1; si no, queda descalificado). Mide bytes y tokens reales (tokcount.py).

Candidatos:
  A  zgrep/1 tal cual (control)
  B  texto `grep -n` (cota inferior; PIERDE offsets: no es candidato, es la vara)
  C  A sin "schema" por evento (una cabecera) y sin campos nulos/por defecto
  D  C sin campos derivables: byte_end = byte_start + len(match); "match"
     omitido cuando es la línea entera
  E  agrupado por fichero: un objeto por fichero con el path una vez y los
     eventos como arrays posicionales [tipo, line, column, byte_start, len, texto]

Uso: python3 evidence/agent-native/m5/format_study.py [--zgrep RUTA]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "evidence" / "agent-native"))
import tokcount  # noqa: E402

C1000 = "bench-corpus/corpus_1000"
TASKS = {
    "rare_call_sites (-n)": ["ZGREP_RARE_TOKEN", C1000],
    "context_audit (-C2)": ["-A2", "-B2", "ZGREP_RARE_TOKEN", C1000],
    "files_with_needle (-l)": ["-l", "ZGREP_PLANTED_TOKEN", C1000],
    "count (-c)": ["-c", "ZGREP_PLANTED_TOKEN", C1000],
    "src_audit (-w, codigo real)": ["--sort", "-w", "Searcher", "src"],
    "occurrences (-o, 1er MB)": ["-o", "-E", r"\bZGREP_PLANTED_TOKEN\b", C1000],
}
GREP_EQUIV = {
    "rare_call_sites (-n)": ["-rn", "ZGREP_RARE_TOKEN", C1000],
    "context_audit (-C2)": ["-rn", "-A2", "-B2", "ZGREP_RARE_TOKEN", C1000],
    "files_with_needle (-l)": ["-rl", "ZGREP_PLANTED_TOKEN", C1000],
    "count (-c)": ["-rc", "ZGREP_PLANTED_TOKEN", C1000],
    "src_audit (-w, codigo real)": ["-rnw", "Searcher", "src"],
    "occurrences (-o, 1er MB)": ["-rnoE", r"\bZGREP_PLANTED_TOKEN\b", C1000],
}
LIMIT = 1 << 20  # las tareas enormes se estudian sobre su primer MiB de eventos enteros

FIELDS = ("type", "path", "line", "column", "byte_start", "byte_end", "match", "text", "inverted",
          "lines", "matches", "mode")


def canon(e: dict) -> tuple:
    return tuple(e.get(k) for k in FIELDS)


# --- C -----------------------------------------------------------------------
DEFAULTS = {"inverted": False}


def enc_c(evs: list[dict]) -> str:
    out = ['{"schema":"zgrep/1c"}']
    for e in evs:
        d = {k: v for k, v in e.items() if k != "schema" and v is not None and DEFAULTS.get(k, object()) != v}
        out.append(json.dumps(d, separators=(",", ":"), ensure_ascii=False))
    return "\n".join(out) + "\n"


def dec_c(s: str) -> list[dict]:
    res = []
    for l in s.split("\n")[:-1][1:]:
        d = json.loads(l)
        e = {k: None for k in FIELDS}
        e.update({"inverted": False} if d["type"] in ("match", "context", "passthru", "occurrence") else {})
        e.update(d)
        res.append(e)
    return res


# --- D -----------------------------------------------------------------------
def enc_d(evs: list[dict]) -> str:
    out = ['{"schema":"zgrep/1d"}']
    for e in evs:
        d = {k: v for k, v in e.items() if k != "schema" and v is not None and DEFAULTS.get(k, object()) != v}
        if "byte_end" in d and "match" in d:
            del d["byte_end"]
            if d["match"] == d.get("text"):
                del d["match"]
                d["whole"] = 1
        out.append(json.dumps(d, separators=(",", ":"), ensure_ascii=False))
    return "\n".join(out) + "\n"


def dec_d(s: str) -> list[dict]:
    res = []
    for l in s.split("\n")[:-1][1:]:
        d = json.loads(l)
        if d.pop("whole", None):
            d["match"] = d["text"]
        if "match" in d and "byte_start" in d:
            d["byte_end"] = d["byte_start"] + len(d["match"].encode())
        e = {k: None for k in FIELDS}
        e.update({"inverted": False} if d["type"] in ("match", "context", "passthru", "occurrence") else {})
        e.update(d)
        res.append(e)
    return res


# --- E -----------------------------------------------------------------------
T = {"match": "m", "context": "c", "occurrence": "o", "passthru": "p"}
RT = {v: k for k, v in T.items()}


def enc_e(evs: list[dict]) -> str:
    out = ['{"schema":"zgrep/1e","row":["t","line","col","byte_start","len","text","match?"]}']
    cur, rows = None, []

    def flush():
        if cur is not None and rows:
            out.append(json.dumps({"path": cur, "rows": rows}, separators=(",", ":"), ensure_ascii=False))

    for e in evs:
        t = e["type"]
        if t in ("file", "count"):
            flush()
            cur, rows = None, []
            d = {k: v for k, v in e.items() if k != "schema" and v is not None}
            out.append(json.dumps(d, separators=(",", ":"), ensure_ascii=False))
            continue
        if e["path"] != cur:
            flush()
            cur, rows = e["path"], []
        tag = T[t] + ("v" if e.get("inverted") else "")
        if e["byte_start"] is None:
            rows.append([tag, e["line"], e["text"]])
            continue
        n = e["byte_end"] - e["byte_start"]
        row = [tag, e["line"], e["column"], e["byte_start"], n, e["text"]]
        tb = e["text"].encode()
        if tb[e["column"] - 1:e["column"] - 1 + n].decode(errors="replace") != e["match"]:
            row.append(e["match"])  # solo si no se deriva del texto
        rows.append(row)
    flush()
    return "\n".join(out) + "\n"


def dec_e(s: str) -> list[dict]:
    res = []
    for l in s.split("\n")[:-1][1:]:
        d = json.loads(l)
        if "rows" not in d:
            e = {k: None for k in FIELDS}
            e.update(d)
            res.append(e)
            continue
        for r in d["rows"]:
            e = {k: None for k in FIELDS}
            e.update({"type": RT[r[0][0]], "path": d["path"], "line": r[1], "inverted": r[0].endswith("v")})
            if len(r) == 3:
                e["text"] = r[2]
            else:
                col, bs, n, text = r[2], r[3], r[4], r[5]
                e.update({"column": col, "byte_start": bs, "byte_end": bs + n, "text": text})
                e["match"] = r[6] if len(r) == 7 else text.encode()[col - 1:col - 1 + n].decode(errors="replace")
            res.append(e)
    return res


# --- F: E en streaming (lo implementable sin bufferizar un fichero entero) ---
# Cabecera {"path":...} cuando cambia el fichero; una fila JSON (array) por
# linea. -l/-L/-c tambien como arrays, con el path dentro (no tienen filas).
# etiquetas: m c o p (+v invertida) para lineas; l/L ficheros; #/#m recuentos


def enc_f(evs: list[dict]) -> str:
    out = ['{"schema":"zgrep/1c","row":["t","line","col","byte_start","len","text","match?"]}']
    cur = None
    for e in evs:
        t = e["type"]
        if t == "file":
            out.append(json.dumps(["l" if e["mode"] == "with-match" else "L", e["path"]], ensure_ascii=False, separators=(",", ":")))
            cur = None
            continue
        if t == "count":
            out.append(json.dumps(["#", e["path"], e["lines"]] if e["lines"] is not None else ["#m", e["path"], e["matches"]],
                                  ensure_ascii=False, separators=(",", ":")))
            cur = None
            continue
        if e["path"] != cur:
            out.append(json.dumps({"path": e["path"]}, ensure_ascii=False, separators=(",", ":")))
            cur = e["path"]
        tag = T[t] + ("v" if e.get("inverted") else "")
        if e["byte_start"] is None:
            row = [tag, e["line"], e["text"]]
        else:
            n = e["byte_end"] - e["byte_start"]
            row = [tag, e["line"], e["column"], e["byte_start"], n, e["text"]]
            if e["text"].encode()[e["column"] - 1:e["column"] - 1 + n].decode(errors="replace") != e["match"]:
                row.append(e["match"])
        out.append(json.dumps(row, ensure_ascii=False, separators=(",", ":")))
    return "\n".join(out) + "\n"


def dec_f(s: str) -> list[dict]:
    res, cur = [], None
    for l in s.split("\n")[:-1][1:]:
        d = json.loads(l)
        e = {k: None for k in FIELDS}
        if isinstance(d, dict):
            cur = d["path"]
            continue
        tag = d[0]
        if tag in ("l", "L"):
            e.update({"type": "file", "path": d[1], "mode": "with-match" if tag == "l" else "without-match"})
        elif tag in ("#", "#m"):
            e.update({"type": "count", "path": d[1], ("lines" if tag == "#" else "matches"): d[2]})
        else:
            e.update({"type": RT[tag[0]], "path": cur, "line": d[1], "inverted": tag.endswith("v")})
            if len(d) == 3:
                e["text"] = d[2]
            else:
                col, bs, n, text = d[2], d[3], d[4], d[5]
                e.update({"column": col, "byte_start": bs, "byte_end": bs + n, "text": text})
                e["match"] = d[6] if len(d) == 7 else text.encode()[col - 1:col - 1 + n].decode(errors="replace")
        res.append(e)
    return res


CANDS = {"C": (enc_c, dec_c), "D": (enc_d, dec_d), "E": (enc_e, dec_e), "F": (enc_f, dec_f)}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zgrep", default=str(ROOT / "zig-out" / "bin" / "zgrep"))
    z = ap.parse_args().zgrep
    print(f"tokenizador: {tokcount.describe()['note']}")
    print(f"{'tarea':<30} {'formato':<8} {'bytes':>9} {'tokens':>8} {'tok/A':>6}  sin perdida")
    totals: dict[str, int] = {}
    for name, args in TASKS.items():
        raw = subprocess.run([z, "--json", *args], cwd=ROOT, capture_output=True).stdout
        if len(raw) > LIMIT:
            raw = raw[: raw.rfind(b"\n", 0, LIMIT) + 1]
        evs = [json.loads(l) for l in raw.decode().split("\n")[:-1]]
        want = [canon(e) for e in evs]
        paths = {e["path"] for e in evs}
        grep_out = subprocess.run(["/usr/bin/grep", *GREP_EQUIV[name]], cwd=ROOT, capture_output=True).stdout
        # el texto de grep sobre los MISMOS ficheros que cubre el recorte
        grep_out = b"".join(l + b"\n" for l in grep_out.splitlines()
                            if l.split(b":", 1)[0].split(b"-", 1)[0].decode(errors="replace") in paths
                            or any(l.startswith(p.encode()) for p in paths))
        rows = {"A": raw, "B (texto)": grep_out}
        for k, (enc, dec) in CANDS.items():
            s = enc(evs)
            ok = [canon(e) for e in dec(s)] == want
            rows[k] = s.encode() if ok else None
            if not ok:
                print(f"{name:<30} {k:<8} DESCALIFICADO: no reconstruye zgrep/1")
        ta = tokcount.count(raw)
        for k, data in rows.items():
            if data is None:
                continue
            t = tokcount.count(data)
            totals[k] = totals.get(k, 0) + t
            lossless = "-" if k.startswith("B") else ("si" if k != "A" else "control")
            print(f"{name:<30} {k:<8} {len(data):>9} {t:>8} {t / ta if ta else 0:>6.2f}  {lossless}")
    print("\nTOTAL tokens:", ", ".join(f"{k}={v}" for k, v in totals.items()))
    a = totals["A"]
    print("relativo a A:", ", ".join(f"{k}={v / a:.2f}" for k, v in totals.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
