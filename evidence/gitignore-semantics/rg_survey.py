#!/usr/bin/env python3
"""Which files ZiGrep and rg search in real repositories (ignore rules only).

usage: rg_survey.py ZGREP REPOS_DIR [--subdirs]

For each git repository directly under REPOS_DIR (or, with --subdirs, for up
to three top-level subdirectories of each, as a relative and as an absolute
root) compare
    rg --hidden -g '!.git/' -l -e '' ROOT
    zgrep --force-swarm --no-default-ignore --exclude-dir=.git -l -e '' ROOT
Prints aggregates only (repo names and paths stay local; this repo is public).
For each difference it says whether `zgrep --no-ignore` would also skip the
file: then the cause is binary detection, not ignore rules.
"""
import os, subprocess, sys

def ls(cmd, cwd):
    p = subprocess.run(cmd, capture_output=True, text=True, errors="replace", cwd=cwd, timeout=300)
    return {os.path.normpath(l) for l in p.stdout.splitlines() if l}

def main():
    zg, base = os.path.abspath(sys.argv[1]), sys.argv[2]
    subdirs = "--subdirs" in sys.argv
    total = equal = 0
    only_binary = 0
    other = 0
    for d in sorted(os.listdir(base)):
        repo = os.path.join(base, d)
        if not os.path.isdir(os.path.join(repo, ".git")):
            continue
        roots = ["."]
        if subdirs:
            subs = [s for s in sorted(os.listdir(repo)) if s != ".git" and os.path.isdir(os.path.join(repo, s))][:3]
            roots = [r for s in subs for r in (s, os.path.join(repo, s))]
        for root in roots:
            total += 1
            a = ls(["rg", "--hidden", "-g", "!.git/", "-l", "-e", "", root], repo)
            b = ls([zg, "--force-swarm", "--no-default-ignore", "--exclude-dir=.git", "-l", "-e", "", root], repo)
            if a == b:
                equal += 1
                continue
            raw = ls([zg, "--no-ignore", "-l", "-e", "", root], repo)
            # rg-only files that zgrep skips even with --no-ignore, and
            # zgrep-only files rg reports as binary: binary detection.
            diff = (a - b) | (b - a)
            if all((f in a and f not in raw) for f in a - b) and not (b - a - binary_in_rg(b - a, repo)):
                only_binary += 1
            else:
                other += 1
                # Names go to stderr only, for local debugging.
                print(f"differs: {d} root={root} zg_only={sorted(b - a)[:3]} rg_only={sorted(a - b)[:3]}", file=sys.stderr)
    print(f"roots {total}  equal {equal}  differ_only_by_binary_detection {only_binary}  differ_otherwise {other}")

def binary_in_rg(files, repo):
    """Files rg skips as binary (rg --debug says 'found binary data')."""
    # Ask about the directory, not the file: rg searches a binary file that
    # is named explicitly instead of skipping it.
    out = set()
    for f in files:
        d = os.path.dirname(f) or "."
        p = subprocess.run(["rg", "--debug", "--no-ignore", "--hidden", "--max-depth", "1", "-l", "-e", "", d],
                           capture_output=True, text=True, errors="replace", cwd=repo, timeout=60)
        name = os.path.basename(f)
        if any("binary data" in l and name in l for l in p.stderr.splitlines()):
            out.add(f)
    return out

if __name__ == "__main__":
    sys.exit(main())
