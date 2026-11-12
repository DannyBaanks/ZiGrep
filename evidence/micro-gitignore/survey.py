#!/usr/bin/env python3
"""Does the zero-thread micro path return the same files as the swarm?

usage: survey.py OLD_BIN NEW_BIN REPOS_DIR [--out results.json]

For every immediate subdirectory of REPOS_DIR that NEW_BIN scans on the micro
path (--stats prints micro_path=yes), list the files that contain any line
(-l -e '') three ways: OLD_BIN default, NEW_BIN default, NEW_BIN --force-swarm.
Only aggregate counts and the top-level component of each extra path are
written: repo names and full paths stay local (this repo is public).
"""
import collections, json, os, subprocess, sys

def files(cmd, root):
    p = subprocess.run(cmd + ["-l", "-e", "", root], capture_output=True, text=True,
                       errors="replace", timeout=60)
    return {os.path.relpath(l, root) for l in p.stdout.splitlines() if l}, p.stderr

GENERIC = {".pytest_cache", ".ruff_cache", ".mypy_cache", "build", "dist", "src",
           "tests", "results", "evidence", "out", "obj", "data", "web", "node_modules"}

def bucket(rel):
    """Top-level component, but only generic names: project names stay local."""
    parts = rel.split(os.sep)
    if len(parts) == 1:
        return "(top-level file)"
    top = parts[0]
    if top.endswith(".egg-info"):
        return "*.egg-info/"
    if any(p == "obj" for p in parts[:-1]):
        return "**/obj/"
    return top + "/" if top in GENERIC else "(other dir)"

def main():
    old, new, base = (os.path.abspath(a) for a in sys.argv[1:4])
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else None
    repos = sorted(d for d in os.listdir(base) if os.path.isdir(os.path.join(base, d)))
    micro = old_eq = new_eq = 0
    extra_total = 0
    kinds = collections.Counter()
    for d in repos:
        root = os.path.join(base, d)
        _, err = files([new, "--stats"], root)
        if "micro_path=yes" not in err:
            continue
        micro += 1
        swarm, _ = files([new, "--force-swarm"], root)
        o, _ = files([old], root)
        n, _ = files([new], root)
        old_eq += o == swarm
        new_eq += n == swarm
        extra = o - swarm
        extra_total += len(extra)
        for e in extra:
            kinds[bucket(e)] += 1
    res = {"repos_scanned": len(repos), "micro_path_repos": micro,
           "old_micro_equals_swarm": old_eq, "new_micro_equals_swarm": new_eq,
           "old_micro_extra_files": extra_total,
           "extra_files_by_top_component": dict(kinds.most_common(15))}
    print(json.dumps(res, indent=2))
    if out:
        with open(out, "w") as f:
            json.dump(res, f, indent=2)
            f.write("\n")
    return 0 if new_eq == micro else 1

if __name__ == "__main__":
    sys.exit(main())
