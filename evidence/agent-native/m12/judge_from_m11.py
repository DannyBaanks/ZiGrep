#!/usr/bin/env python3
"""M11 benchmark, step 4: blinded judge (secondary to the mechanical score).

The judge sees the question, the reference answer and ONE reader answer. It
never sees the context or the condition; items are judged in a shuffled order
(fixed seed) under opaque ids. Backend: `claude -p --tools ""` from an empty
directory. Output: judge/<label>/<opaque>.json + mapping.json.

    python3 judge.py --contexts DIR --label NAME --workdir EMPTY_DIR [--model sonnet]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import random
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONDS = ["RG", "ZG"]  # M12; the rest of the file is M11's judge.py unchanged
SYSTEM = """You grade answers to questions about a code repository against a reference answer written by someone who read the code.

Grade:
  2 = correct: agrees with the reference on the point the question asks, no wrong claim.
  1 = partial: some key points right, but incomplete or hedged where the reference is definite.
  0 = wrong: a central claim contradicts the reference, or it answers a different question.
An answer that correctly says the information is not available is 2 if the reference says it is not answerable, otherwise at most 1.

List every claim in the answer that contradicts the reference (wrong_claims). Do not reward length or style.
Reply with ONLY a JSON object: {"grade": 0|1|2, "wrong_claims": ["..."], "reason": "<one sentence>"}"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--contexts", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--seed", type=int, default=20261111)
    ap.add_argument("--questions", default=str(HERE / "questions.json"), help="question corpus (round 2: questions_r2.json)")
    a = ap.parse_args()
    root = Path(a.contexts)
    qs = {q["id"]: q for q in json.loads(Path(a.questions).read_text())["questions"]}
    out = root / "judge" / a.label
    out.mkdir(parents=True, exist_ok=True)
    keys = [f"{q}__{c}" for q in qs for c in CONDS]
    rng = random.Random(a.seed)
    rng.shuffle(keys)
    mapping = {}
    for k in keys:
        opaque = hashlib.sha256(f"{a.seed}:{k}".encode()).hexdigest()[:10]
        mapping[opaque] = k
    (out / "mapping.json").write_text(json.dumps(mapping, indent=1) + "\n")
    for opaque, k in mapping.items():
        dest = out / f"{opaque}.json"
        if dest.exists():
            continue
        qid = k.split("__")[0]
        rec = json.loads((root / "answers" / a.label / f"{k}.json").read_text())
        q = qs[qid]
        user = f"QUESTION: {q['question']}\n\nREFERENCE ANSWER: {q['reference']}\n\nANSWER TO GRADE:\n<<<\n{rec.get('answer', '')}\n>>>"
        p = subprocess.run(["claude", "-p", "--tools", "", "--strict-mcp-config", "--no-session-persistence",
                            "--model", a.model, "--output-format", "json", "--system-prompt", SYSTEM, user],
                           cwd=a.workdir, capture_output=True, text=True, timeout=600)
        try:
            d = json.loads(p.stdout)
            txt = d.get("result") or ""
            m = re.search(r"\{.*\}", txt, re.S)
            g = json.loads(m.group(0)) if m else {"error": "no json", "raw": txt[:500]}
            g["cost_usd"] = d.get("total_cost_usd")
        except Exception as e:
            g = {"error": repr(e)[:300], "raw": p.stdout[:300]}
        dest.write_text(json.dumps(g, ensure_ascii=False, indent=1) + "\n")
        print(opaque, g.get("grade", "ERR"), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
