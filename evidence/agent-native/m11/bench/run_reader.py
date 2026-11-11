#!/usr/bin/env python3
"""M11 benchmark, step 2: ask a tool-less reader each question with each context.

Backends:
  openai   any OpenAI-compatible /v1/chat/completions endpoint (ISyInfer `serve`)
  claude   `claude -p --tools ""` from an empty directory (no tools, no repo)

Writes answers/<label>/<qid>__<cond>.json with the answer, timing and usage.
Skips items whose answer file already exists (resumable). Temperature 0.

    python3 run_reader.py --contexts DIR --label NAME --backend openai --url URL [--model M]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent


def ask_openai(url, model, system, user, max_tokens, timeout):
    body = json.dumps({"model": model, "temperature": 0, "max_tokens": max_tokens,
                       "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = json.loads(r.read())
        hdr = dict(r.headers)
    return data["choices"][0]["message"].get("content") or "", data.get("usage"), time.time() - t0, {k: v for k, v in hdr.items() if k.lower().startswith("x-isyinfer")}


def ask_claude(model, system, user, workdir, timeout):
    t0 = time.time()
    p = subprocess.run(["claude", "-p", "--tools", "", "--strict-mcp-config", "--no-session-persistence",
                        "--model", model, "--output-format", "json", "--system-prompt", system, user],
                       cwd=workdir, capture_output=True, text=True, timeout=timeout)
    d = json.loads(p.stdout)
    return d.get("result") or "", {"cost_usd": d.get("total_cost_usd"), "turns": d.get("num_turns"), "models": list((d.get("modelUsage") or {}).keys())}, time.time() - t0, {}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--contexts", required=True, help="directory with manifest.json and contexts/")
    ap.add_argument("--label", required=True)
    ap.add_argument("--backend", choices=["openai", "claude"], required=True)
    ap.add_argument("--url")
    ap.add_argument("--model", default="local")
    ap.add_argument("--max-tokens", type=int, default=600)
    ap.add_argument("--timeout", type=int, default=3600)
    ap.add_argument("--workdir", help="empty directory for the claude backend")
    ap.add_argument("--only", help="comma-separated qid__cond keys")
    ap.add_argument("--questions", default=str(HERE / "questions.json"), help="question corpus (round 2: questions_r2.json)")
    a = ap.parse_args()
    root = Path(a.contexts)
    man = json.loads((root / "manifest.json").read_text())
    qs = {q["id"]: q for q in json.loads(Path(a.questions).read_text())["questions"]}
    system = (HERE / "reader_prompt.txt").read_text()
    out = root / "answers" / a.label
    out.mkdir(parents=True, exist_ok=True)
    only = set(a.only.split(",")) if a.only else None
    for it in man["items"]:
        key = f"{it['qid']}__{it['cond']}"
        if only and key not in only:
            continue
        dest = out / f"{key}.json"
        if dest.exists():
            continue
        ctx = (root / "contexts" / f"{key}.txt").read_text()
        cmd = it["command"]
        user = f"QUESTION: {qs[it['qid']]['question']}\n\nCONTEXT (output of `{cmd}`):\n<<<\n{ctx}\n>>>"
        try:
            if a.backend == "openai":
                ans, usage, secs, hdr = ask_openai(a.url, a.model, system, user, a.max_tokens, a.timeout)
            else:
                ans, usage, secs, hdr = ask_claude(a.model, system, user, a.workdir, a.timeout)
            rec = {"qid": it["qid"], "cond": it["cond"], "label": a.label, "backend": a.backend, "model": a.model,
                   "context_sha256": it["sha256"], "answer": ans, "usage": usage, "seconds": round(secs, 2), "headers": hdr}
        except Exception as e:  # recorded, not hidden
            rec = {"qid": it["qid"], "cond": it["cond"], "label": a.label, "error": repr(e)[:500]}
        dest.write_text(json.dumps(rec, ensure_ascii=False, indent=1) + "\n")
        print(f"{key:10s} {rec.get('seconds', 'ERR')}s {len(rec.get('answer', ''))} chars {rec.get('error', '')[:80]}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
