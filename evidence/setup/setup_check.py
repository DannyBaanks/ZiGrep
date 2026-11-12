#!/usr/bin/env python3
"""End-to-end check of `--setup` against a FAKE home directory.

Never touches the real HOME: every run gets HOME=<tmp>. Checks the plan,
the [s/N] prompt, idempotency, the backup, the exact undo, and the usage
errors.

    python3 setup_check.py [--zgrep BIN]
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BEGIN = "<!-- ziggrep:setup begin -->"
results = []


def check(name, ok, detail=""):
    results.append((name, ok))
    print(f"{'PASS' if ok else 'FAIL'} {name}" + (f"  ({detail})" if detail and not ok else ""))


def run(binary, home, *args, stdin=""):
    env = {"HOME": str(home), "PATH": os.environ.get("PATH", "")}
    return subprocess.run([str(binary), *args], input=stdin, capture_output=True, text=True, env=env, timeout=60)


def snapshot(home):
    out = {}
    for p in sorted(home.rglob("*")):
        if p.is_file():
            out[str(p.relative_to(home))] = p.read_bytes()
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zgrep", default=str(ROOT / "zig-out" / "bin" / "zigrep"))
    a = ap.parse_args()
    binary = Path(a.zgrep).resolve()
    home = Path(tempfile.mkdtemp(prefix="setup-home-"))
    try:
        # Claude and Codex installed (Codex with an RTK-style line), agy installed
        # without its file, opencode installed, OpenISy NOT installed.
        (home / ".claude").mkdir()
        (home / ".codex").mkdir()
        (home / ".codex" / "AGENTS.md").write_text("@/home/x/.codex/RTK.md\n")
        (home / ".gemini").mkdir()
        (home / ".config" / "opencode").mkdir(parents=True)
        original = snapshot(home)

        r = run(binary, home, "--setup", "--dry-run")
        check("dry-run: rc 0 and nothing written", r.returncode == 0 and snapshot(home) == original, r.stdout[-300:])
        check("dry-run: plan lists installed agents and skips OpenISy",
              all(s in r.stdout for s in ("Claude Code", "Codex", "agy / Gemini", "opencode")) and "no instalado" in r.stdout)

        r = run(binary, home, "--setup", stdin="n\n")
        check("answer 'n': rc 1 and nothing written", r.returncode == 1 and snapshot(home) == original)

        r = run(binary, home, "--setup", stdin="s\n")
        check("answer 's': rc 0", r.returncode == 0, r.stdout[-300:])
        codex = (home / ".codex" / "AGENTS.md").read_text()
        check("codex: RTK line kept, rule block added inline", codex.startswith("@/home/x/.codex/RTK.md\n") and BEGIN in codex and "Always pass a path" in codex)
        check("codex: backup is the original", (home / ".codex" / "AGENTS.md.bak-ziggrep").read_text() == "@/home/x/.codex/RTK.md\n")
        claude = (home / ".claude" / "CLAUDE.md").read_text()
        check("claude: imports the rule", "@~/.config/ziggrep/agents.md" in claude and "Always pass a path" not in claude)
        check("gemini and opencode: rule inline", "Always pass a path" in (home / ".gemini" / "GEMINI.md").read_text()
              and "Always pass a path" in (home / ".config" / "opencode" / "AGENTS.md").read_text())
        check("rule file written", (home / ".config" / "ziggrep" / "agents.md").is_file())
        check("OpenISy not installed: untouched", not (home / ".openisy").exists())
        after_setup = snapshot(home)

        r = run(binary, home, "--setup", "--force")
        check("second run: nothing to change, files identical", r.returncode == 0 and "Nada que cambiar" in r.stdout and snapshot(home) == after_setup)

        r = run(binary, home, "--setup", "--undo", "--force")
        check("undo: rc 0", r.returncode == 0, r.stdout[-300:])
        check("undo: codex restored byte for byte", (home / ".codex" / "AGENTS.md").read_text() == "@/home/x/.codex/RTK.md\n")
        check("undo: files that only held the rule are deleted",
              not (home / ".claude" / "CLAUDE.md").exists() and not (home / ".gemini" / "GEMINI.md").exists()
              and not (home / ".config" / "opencode" / "AGENTS.md").exists())

        r = run(binary, home, "--undo")
        check("--undo without --setup: usage error rc 2", r.returncode == 2)
        r = run(binary, home, "--setup", "--cache")
        check("--setup with --cache: usage error rc 2", r.returncode == 2)
    finally:
        shutil.rmtree(home, ignore_errors=True)
    fails = sum(not ok for _, ok in results)
    print(f"TOTAL {len(results) - fails} pass / {fails} fail")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
