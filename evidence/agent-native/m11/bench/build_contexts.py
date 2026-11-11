#!/usr/bin/env python3
"""M11 benchmark, step 1: build the context every condition delivers.

For each question x condition, runs the command an agent would run, caps the
output at the same delivery budget for every condition, and writes
contexts/<qid>__<cond>.txt plus manifest.json (command, bytes, sha256,
truncated). Nothing here calls a model.

Conditions (fixed before any model run):
  A   zgrep -n -w -F SYMBOL SCOPE            matches only (one grep)
  B   zgrep -n -w -F -C 8 SYMBOL SCOPE       matches with 8 lines of context
  P1  zgrep_pack --sections blocks           whole enclosing blocks, no relations
  P2  zgrep_pack --sections tests            definitions, references, tests, uncertainty
  P3  zgrep_pack --sections all              + structure, history, docs

    python3 build_contexts.py --zgrep BIN --out DIR [--budget 28000]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
PACK = HERE.parent / "prototype" / "zgrep_pack.py"
CONDS = ["A", "B", "P1", "P2", "P3"]


def cap(text: str, budget: int) -> tuple[str, bool]:
    b = text.encode()
    if len(b) <= budget:
        return text, False
    marker = f"\n[output truncated by the harness at {budget} bytes; the rest was not delivered]\n"
    cut = b[: budget - len(marker.encode())].decode("utf-8", errors="ignore")
    cut = cut[: cut.rfind("\n") + 1] if "\n" in cut else cut
    return cut + marker, True


def command(cond: str, zgrep: str, sym: str, scope: list[str], spill: Path, budget: int) -> list[str]:
    if cond == "A":
        return [zgrep, "-n", "-w", "-F", "--sort", "-e", sym, "--", *scope]
    if cond == "B":
        return [zgrep, "-n", "-w", "-F", "--sort", "-C", "8", "-e", sym, "--", *scope]
    sect = {"P1": "blocks", "P2": "tests", "P3": "all"}[cond]
    return [sys.executable, str(PACK), sym, *scope, "--repo", str(ROOT), "--zgrep", zgrep,
            "--sections", sect, "--budget-bytes", str(budget), "--spill-dir", str(spill)]


def display(cmd: list[str]) -> str:
    """The command as the reader sees it: no local absolute paths."""
    out = []
    for i, c in enumerate(cmd):
        if i == 0 or c.endswith(("/zgrep", "/zigrep")):
            c = Path(c).name
        c = c.replace(str(ROOT) + "/", "").replace(str(ROOT), ".")
        out.append(c)
    return " ".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zgrep", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--budget", type=int, default=28000)
    a = ap.parse_args()
    qs = json.loads((HERE / "questions.json").read_text())
    out = Path(a.out)
    (out / "contexts").mkdir(parents=True, exist_ok=True)
    spill = Path(os.path.relpath(out.resolve() / "spill", ROOT))
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    dirty = subprocess.run(["git", "status", "--porcelain", "--", "src"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    manifest = {"revision": head, "src_dirty": bool(dirty), "budget": a.budget, "scope": qs["scope"], "items": []}
    for q in qs["questions"]:
        for cond in CONDS:
            cmd = command(cond, a.zgrep, q["symbol"], qs["scope"], spill, a.budget)
            p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
            if p.returncode not in (0, 1):
                raise SystemExit(f"{q['id']} {cond}: rc={p.returncode} {p.stderr[:300]}")
            raw = p.stdout
            text, truncated = cap(raw, a.budget)
            pack_trunc = "truncated: true" in raw if cond.startswith("P") else None
            path = out / "contexts" / f"{q['id']}__{cond}.txt"
            path.write_text(text)
            manifest["items"].append({
                "qid": q["id"], "cond": cond,
                "command": display(cmd),
                "raw_bytes": len(raw.encode()), "delivered_bytes": len(text.encode()),
                "harness_truncated": truncated, "pack_truncated": pack_trunc,
                "sha256": hashlib.sha256(text.encode()).hexdigest(),
            })
            print(f"{q['id']:3s} {cond:3s} raw={len(raw.encode()):6d} delivered={len(text.encode()):6d} cut={truncated} pack_trunc={pack_trunc}")
    (out / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
