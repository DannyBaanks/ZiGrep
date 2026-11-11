#!/usr/bin/env python3
"""M10 (estudio, sin implementar): techo de ahorro de un hook PreToolUse que
reescribe los grep/rg de los agentes a ziggrep.

Lee, en solo lectura, las sesiones locales de dos harness y SOLO imprime
agregados (ninguna ruta, comando ni salida de sesion sale de aqui):

  --claude-dir DIR   directorio con transcripts *.jsonl de Claude Code
                     (p. ej. ~/.claude/projects); se recorre */*.jsonl
  --opencode-db F    base SQLite de opencode (p. ej. ~/.local/share/opencode/opencode.db)

Que se mide:
  * cuantas llamadas Bash tienen un segmento que EMPIEZA por grep/rg/egrep
    (lo unico que un hook sobre Bash puede reescribir; un `| grep` filtra la
    salida de otro comando y no cambia lo que llega al agente);
  * cuantos bytes de salida producen esas llamadas, frente a toda la salida;
  * cuantos de esos bytes caen MAS ALLA DE LA COLUMNA W (por defecto 400):
    es el techo de lo que --max-columns W (M9) podria quitar. Techo en bytes,
    no tokens, y optimista: M9 centra la ventana en el match, asi que no
    siempre quita exactamente lo que pasa de W.
El otro mecanismo del hook seria el formato: task_bench/claims.md ya midio
que zgrep/1c gasta 1.03x los tokens del mejor control de texto (no ahorra).
"""
import argparse, glob, json, os, re, sqlite3, sys

SEG = re.compile(r"\|\||&&|;|\n|\$\(")


def grep_segment(cmd):
    for s in SEG.split(cmd):
        w = s.strip().split()
        if w and w[0] in ("grep", "rg", "egrep"):
            return True
    return False


def beyond(out, w):
    return sum(max(0, len(l) - w) for l in out.split("\n"))


def claude(d, w):
    uses, res = {}, {}
    for f in glob.glob(os.path.join(d, "*", "*.jsonl")):
        with open(f, errors="ignore") as fh:
            for line in fh:
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                cont = (ev.get("message") or {}).get("content")
                if not isinstance(cont, list):
                    continue
                for b in cont:
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "tool_use" and b.get("name") == "Bash":
                        uses[b["id"]] = (b.get("input") or {}).get("command", "")
                    elif b.get("type") == "tool_result":
                        c = b.get("content")
                        if isinstance(c, list):
                            c = "".join(x.get("text", "") for x in c if isinstance(x, dict))
                        res[b.get("tool_use_id")] = c or ""
    r = {"bash_calls": 0, "bash_bytes": 0, "grep_calls": 0, "grep_bytes": 0, "grep_beyond": 0}
    for k, cmd in uses.items():
        out = res.get(k)
        if out is None:
            continue
        r["bash_calls"] += 1
        r["bash_bytes"] += len(out)
        if grep_segment(cmd):
            r["grep_calls"] += 1
            r["grep_bytes"] += len(out)
            r["grep_beyond"] += beyond(out, w)
    return r


def opencode(db, w):
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    r = {"bash_calls": 0, "bash_bytes": 0, "grep_calls": 0, "grep_bytes": 0, "grep_beyond": 0,
         "all_tool_bytes": 0, "grep_tool_calls": 0, "grep_tool_bytes": 0, "grep_tool_beyond": 0}
    for (data,) in con.execute("select data from part where data like '%\"type\":\"tool\"%'"):
        try:
            d = json.loads(data)
        except ValueError:
            continue
        st = d.get("state") or {}
        out = st.get("output") or ""
        if not isinstance(out, str):
            out = json.dumps(out)
        r["all_tool_bytes"] += len(out)
        t = d.get("tool")
        if t == "bash":
            r["bash_calls"] += 1
            r["bash_bytes"] += len(out)
            if grep_segment((st.get("input") or {}).get("command", "")):
                r["grep_calls"] += 1
                r["grep_bytes"] += len(out)
                r["grep_beyond"] += beyond(out, w)
        elif t == "grep":  # herramienta propia de opencode: un hook de Bash NO la ve
            r["grep_tool_calls"] += 1
            r["grep_tool_bytes"] += len(out)
            r["grep_tool_beyond"] += beyond(out, w)
    return r


def pct(a, b):
    return f"{100 * a / b:.1f} %" if b else "n/a"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--claude-dir")
    ap.add_argument("--opencode-db")
    ap.add_argument("--width", type=int, default=400)
    a = ap.parse_args()
    w = a.width
    print(f"W = {w} (techo de --max-columns W, en bytes)")
    if a.claude_dir:
        r = claude(a.claude_dir, w)
        print("\n[Claude Code] (sin herramienta Grep en este harness: se busca por Bash)")
        print(f"  llamadas Bash                       {r['bash_calls']}")
        print(f"  con un segmento grep/rg             {r['grep_calls']}  ({pct(r['grep_calls'], r['bash_calls'])})")
        print(f"  bytes de salida de esas llamadas    {r['grep_bytes']}  ({pct(r['grep_bytes'], r['bash_bytes'])} de toda la salida Bash)")
        print(f"  bytes mas alla de la col {w}        {r['grep_beyond']}  ({pct(r['grep_beyond'], r['grep_bytes'])} de su salida; {pct(r['grep_beyond'], r['bash_bytes'])} de toda la salida Bash)")
    if a.opencode_db:
        r = opencode(a.opencode_db, w)
        print("\n[opencode]")
        print(f"  llamadas bash                       {r['bash_calls']}")
        print(f"  con un segmento grep/rg             {r['grep_calls']}  ({pct(r['grep_calls'], r['bash_calls'])})")
        print(f"  bytes de salida de esas llamadas    {r['grep_bytes']}")
        print(f"  bytes mas alla de la col {w}        {r['grep_beyond']}  ({pct(r['grep_beyond'], r['grep_bytes'])} de su salida; {pct(r['grep_beyond'], r['all_tool_bytes'])} de toda la salida de herramientas)")
        print(f"  herramienta grep propia (fuera del alcance de un hook de Bash): {r['grep_tool_calls']} llamadas, {r['grep_tool_bytes']} bytes, {r['grep_tool_beyond']} mas alla de la col {w} ({pct(r['grep_tool_beyond'], r['all_tool_bytes'])} de toda la salida de herramientas)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
