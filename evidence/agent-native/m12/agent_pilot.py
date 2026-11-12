#!/usr/bin/env python3
"""M12 pilot: the same OpenISy agent with ripgrep vs ZiGrep behind its grep tool.

For each question and engine, runs (no --auto, stdin closed, in a throwaway
clone of this repository):

    [OPENISY_GREP_ENGINE=ziggrep OPENISY_ZIGGREP_BIN=<logging wrapper>]
    openisy run --standalone --format json -m MODEL "<question>"

and records the answer, every tool call, and (ziggrep engine) every ziggrep
invocation from the wrapper's log, which proves which engine served the
grep tool. Grading reuses M11's blinded judge prompt (judge.py) via a
questions file and answers in the M11 layout.

    python3 agent_pilot.py --openisy BIN --clone DIR --out DIR --model M --qids R02,R03,...
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
Q = HERE / "questions_r2_from_m11.json"  # copy of m11-context-pack:evidence/agent-native/m11/bench/questions_r2.json
PREFIX = "Answer this question about the repository in the current directory. Use your tools to look at the code. Cite file:line for every claim. Keep the answer under 150 words.\n\nQUESTION: "


def run_one(openisy, clone, model, question, engine, log):
    env = dict(os.environ)
    env.pop("OPENISY_GREP_ENGINE", None)
    if engine == "ziggrep":
        env["OPENISY_GREP_ENGINE"] = "ziggrep"
        env["OPENISY_ZIGGREP_BIN"] = str(log.with_suffix(".sh"))
    t0 = time.time()
    p = subprocess.run([openisy, "run", "--standalone", "--format", "json", "-m", model, PREFIX + question],
                       cwd=clone, env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=900)
    secs = time.time() - t0
    tools, texts = [], []
    for line in p.stdout.splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        part = e.get("part", {})
        if part.get("type") == "tool":
            st = part.get("state", {})
            out = str(st.get("output", ""))
            tools.append({"tool": part.get("tool"), "status": st.get("status"), "input": st.get("input", {}),
                          "output_head": out[:200], "no_matches": out.startswith("No matches found")})
        elif part.get("type") == "text":
            texts.append(part.get("text", ""))
    return {"rc": p.returncode, "seconds": round(secs, 1), "answer": texts[-1] if texts else "", "tools": tools,
            "stderr_tail": p.stderr[-400:]}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--openisy", required=True)
    ap.add_argument("--clone", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--qids", required=True)
    ap.add_argument("--ziggrep", default="ziggrep")
    ap.add_argument("--questions", default=str(Q))
    a = ap.parse_args()
    qs = {q["id"]: q for q in json.loads(Path(a.questions).read_text())["questions"]}
    # Absolute: the grep tool spawns the wrapper with cwd = the searched
    # directory, so a relative wrapper path is not found there (first run:
    # every ZG grep call failed and no ziggrep call was logged; those records
    # are kept in <out>/invalid_relative_wrapper/).
    out = Path(a.out).resolve()
    (out / "answers" / "agent").mkdir(parents=True, exist_ok=True)
    (out / "zlog").mkdir(exist_ok=True)
    sel = [qs[i] for i in a.qids.split(",")]
    (out / "questions.json").write_text(json.dumps({"questions": sel}, ensure_ascii=False, indent=1) + "\n")
    items = []
    for q in sel:
        for engine, cond in (("ripgrep", "RG"), ("ziggrep", "ZG")):
            key = f"{q['id']}__{cond}"
            dest = out / "answers" / "agent" / f"{key}.json"
            if dest.exists():
                items.append({"qid": q["id"], "cond": cond})
                continue
            log = out / "zlog" / f"{key}.log"
            wrapper = log.with_suffix(".sh")
            wrapper.write_text(f"#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> '{log}'\nexec '{a.ziggrep}' \"$@\"\n")
            wrapper.chmod(0o755)
            rec = run_one(a.openisy, a.clone, a.model, q["question"], engine, log)
            calls = log.read_text().splitlines() if log.exists() else []
            rec.update({"qid": q["id"], "cond": cond, "engine": engine, "model": a.model, "ziggrep_calls": len(calls)})
            dest.write_text(json.dumps(rec, ensure_ascii=False, indent=1) + "\n")
            items.append({"qid": q["id"], "cond": cond})
            g = [t for t in rec["tools"] if t["tool"] == "grep"]
            print(f"{key:9s} rc={rec['rc']} {rec['seconds']:6.1f}s tools={len(rec['tools']):2d} grep={len(g)} empty={sum(t['no_matches'] for t in g)} ziggrep_calls={rec['ziggrep_calls']}", flush=True)
    (out / "manifest.json").write_text(json.dumps({"items": items}, indent=1) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
