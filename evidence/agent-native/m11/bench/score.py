#!/usr/bin/env python3
"""M11 benchmark, step 3: mechanical scoring (rules fixed in questions.json).

Per answer:
  fact_score   matched required facts / total (case-insensitive regex)
  forbidden    regexes of known wrong conclusions that matched (candidate induced errors)
  cites        number of file:line citations
  abstains     says the context is insufficient
Per context (independent of any model):
  available    required facts whose evidence regex matches the CONTEXT itself

    python3 score.py --contexts DIR --label NAME [--out FILE]
"""
from __future__ import annotations

import argparse
import itertools
import json
import math
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONDS = ["A", "B", "P1", "P2", "P3"]
CITE = re.compile(r"[\w./-]+\.(zig|py|md|sh|yml|txt)[:#~ ]{1,2}~?\d+")
ABSTAIN = re.compile(r"(?i)(not (enough|sufficient|available|in the context|provided|shown|included|present)|insufficient|cannot (determine|answer|tell|be determined)|does(n't| not) (contain|include|provide|say|show|mention)|no (information|data|measurement|evidence))")


def fact_hits(text: str, facts: list[list[str]]) -> list[bool]:
    return [any(re.search(alt, text, re.I | re.S) for alt in alts) for alts in facts]


def sign_test(wins: int, losses: int) -> float:
    n = wins + losses
    if n == 0:
        return 1.0
    k = min(wins, losses)
    p = sum(math.comb(n, i) for i in range(0, k + 1)) / 2 ** n
    return min(1.0, 2 * p)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--contexts", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--out")
    a = ap.parse_args()
    root = Path(a.contexts)
    qs = json.loads((HERE / "questions.json").read_text())["questions"]
    rows = []
    for q in qs:
        for c in CONDS:
            ctx = (root / "contexts" / f"{q['id']}__{c}.txt").read_text()
            af = root / "answers" / a.label / f"{q['id']}__{c}.json"
            rec = json.loads(af.read_text()) if af.exists() else {"error": "missing"}
            ans = rec.get("answer", "")
            fh = fact_hits(ans, q["required"])
            av = fact_hits(ctx, q["required"])
            fb = [f for f in q["forbidden"] if re.search(f, ans, re.I | re.S)]
            rows.append({"qid": q["id"], "set": q["set"], "cond": c, "error": rec.get("error"),
                         "fact_score": round(sum(fh) / len(fh), 3), "facts": fh,
                         "available": round(sum(av) / len(av), 3), "forbidden": fb,
                         "cites": len(CITE.findall(ans)), "abstains": bool(ABSTAIN.search(ans)),
                         "seconds": rec.get("seconds"), "answer_chars": len(ans)})
    lines = [f"M11 mechanical scores, reader={a.label}", ""]
    lines.append("question  " + "  ".join(f"{c:>12s}" for c in CONDS) + "    (fact score of the ANSWER / facts AVAILABLE in the context)")
    for q in qs:
        cells = []
        for c in CONDS:
            r = next(x for x in rows if x["qid"] == q["id"] and x["cond"] == c)
            mark = "!" if r["forbidden"] else ("E" if r["error"] else " ")
            cells.append(f"{r['fact_score']:.2f}/{r['available']:.2f}{mark}".rjust(12))
        lines.append(f"{q['id']:3s} {q['set']:7s}" + "  ".join(cells))
    lines.append("")
    lines.append("'!' = a forbidden (known-wrong) pattern matched;  'E' = reader error or missing answer")
    lines.append("")
    for subset in ("dev", "heldout", "all"):
        sel = [r for r in rows if subset == "all" or r["set"] == subset]
        lines.append(f"[{subset}]  mean fact score / mean availability / forbidden hits / mean cites / abstentions")
        for c in CONDS:
            rs = [r for r in sel if r["cond"] == c]
            lines.append(f"  {c:3s} {sum(r['fact_score'] for r in rs) / len(rs):.3f} / {sum(r['available'] for r in rs) / len(rs):.3f} / "
                         f"{sum(len(r['forbidden']) for r in rs)} / {sum(r['cites'] for r in rs) / len(rs):.1f} / {sum(r['abstains'] for r in rs)}")
    lines.append("")
    lines.append("paired by question (fact score), all questions: wins/ties/losses, two-sided sign test p")
    for x, y in itertools.product(["P1", "P2", "P3"], ["A", "B"]):
        w = t = l = 0
        for q in qs:
            sx = next(r for r in rows if r["qid"] == q["id"] and r["cond"] == x)["fact_score"]
            sy = next(r for r in rows if r["qid"] == q["id"] and r["cond"] == y)["fact_score"]
            w, t, l = w + (sx > sy), t + (sx == sy), l + (sx < sy)
        lines.append(f"  {x} vs {y}: {w}/{t}/{l}  p={sign_test(w, l):.3f}")
    text = "\n".join(lines) + "\n"
    sys.stdout.write(text)
    if a.out:
        Path(a.out).write_text(json.dumps(rows, indent=1) + "\n")
        Path(a.out).with_suffix(".txt").write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
