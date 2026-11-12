#!/usr/bin/env python3
"""--include/--exclude glob parity with ripgrep's -g (globset).

Builds a deterministic tree (nested dirs, mixed extensions, a .gitignore'd
dir), then for each glob compares the set of (path, line) matches of

    rg --no-config --json --hidden --no-messages [-g GLOB ...] -- PAT
    zgrep --json --force-swarm [--include=G | --exclude=G ...] -e PAT .

A `!G` glob maps to --exclude=G. The zgrep side is the call an rg-compatible
adapter makes: --force-swarm (the zero-thread micro path does not read
.gitignore, a documented decision, and its 2 MB budget counts only the files
that pass the filter), --no-default-ignore (rg has no built-in *.log or
node_modules list) and --exclude-dir=.git (what rg's `-g '!**/.git/**'` says).
Nested braces (`{a,{b,c}}`) are left out: zgrep accepts them, rg's globset
rejects them.

    python3 glob_parity.py [--zgrep BIN] [--work DIR]
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

TREE = {
    "a.ts": "needle ts root\n", "a.tsx": "needle tsx root\n", "a.js": "needle js root\n",
    "lib.d.ts": "needle dts\n", "x.mjs": "needle mjs\n", "y.min.js": "needle min\n",
    "src/main.zig": "needle zig\n", "src/util.py": "needle py\n", "src/a.ts": "needle src ts\n",
    "src/gen/out.ts": "needle gen\n", "src/deep/er/x.ts": "needle deep\n",
    "packages/core/src/tool/grep.ts": "needle core grep\n", "packages/core/src/tool/read.ts": "needle core read\n",
    "packages/core/test/grep.test.ts": "needle core test\n", "packages/cli/src/grep.ts": "needle cli\n",
    "packages/cli/test/x.test.ts": "needle cli test\n",
    "weird/a[1].txt": "needle bracket\n", "weird/{x}.txt": "needle brace\n", "weird/file1.log": "needle log1\n",
    "ignored/a.ts": "needle ignored\n", ".gitignore": "ignored/\n",
}

GLOBS = [
    ["*.ts"], ["*.{ts,tsx}"], ["**/*.{ts,tsx}"], ["*.{d.ts,js,mjs}"], ["src/**"], ["/src/*.zig"],
    ["packages/core/**/*.ts"], ["packages/*/test/*.test.ts"], ["packages/core/src/tool/[gr]*.ts"],
    ["*.ts", "!**/test/**"], ["*.ts", "!*.test.ts"], ["!*.{js,mjs}"], ["**/gen/**"], ["!src/**"],
    ["file?.log"], ["src/*/er/*.ts"], ["[!a]*.ts"],
]


def run(cmd, cwd):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)


def rg_set(cwd, globs):
    a = ["rg", "--no-config", "--json", "--hidden", "--no-messages"] + [f"--glob={g}" for g in globs] + ["--glob=!**/.git/**", "--", "needle"]
    p = run(a, cwd)
    out = set()
    for l in p.stdout.splitlines():
        e = json.loads(l)
        if e["type"] == "match":
            out.add((os.path.normpath(e["data"]["path"]["text"]), e["data"]["line_number"]))
    return out


def zg_set(zgrep, cwd, globs):
    a = [zgrep, "--json", "--force-swarm", "--no-default-ignore", "--exclude-dir=.git"] + [f"--exclude={g[1:]}" if g.startswith("!") else f"--include={g}" for g in globs] + ["-e", "needle", "."]
    p = run(a, cwd)
    out = set()
    for l in p.stdout.splitlines():
        e = json.loads(l)
        if e.get("type") == "match":
            out.add((os.path.normpath(e["path"]), e["line"]))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zgrep", default=str(ROOT / "zig-out" / "bin" / "zgrep"))
    ap.add_argument("--work")
    a = ap.parse_args()
    # The searches run with cwd = the generated tree: a relative binary path
    # (CI passes zig-debug/bin/zgrep) must be resolved first.
    if os.sep in a.zgrep or "/" in a.zgrep:
        a.zgrep = str(Path(a.zgrep).resolve())
    work = Path(a.work) if a.work else Path(tempfile.mkdtemp(prefix="globparity-"))
    if work.exists():
        shutil.rmtree(work)
    for rel, text in TREE.items():
        (work / rel).parent.mkdir(parents=True, exist_ok=True)
        (work / rel).write_text(text)
    # rg only honours .gitignore inside a git repository.
    subprocess.run(["git", "init", "-q"], cwd=work, check=True)
    fails = 0
    for globs in GLOBS:
        r, z = rg_set(work, globs), zg_set(a.zgrep, work, globs)
        ok = r == z and len(r) > 0
        fails += not ok
        print(f"{'PASS' if ok else 'FAIL'} {' '.join(globs):42s} rg={len(r):2d} zgrep={len(z):2d}" + ("" if ok else f"  only_rg={sorted(r - z)} only_zgrep={sorted(z - r)}"))
    print(f"TOTAL {len(GLOBS) - fails} pass / {fails} fail")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
