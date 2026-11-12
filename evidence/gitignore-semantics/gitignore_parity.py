#!/usr/bin/env python3
"""ZiGrep's .gitignore handling vs git itself.

usage: gitignore_parity.py [--zgrep PATH]

Builds a fixture repository (nested .gitignore files, negation, anchored and
middle-slash patterns, dir-only rules, **, escapes, .git/info/exclude) in a
temporary directory and compares, for several search roots, the files ZiGrep
searches with the files git does not ignore:

    git ls-files --cached --others --exclude-standard
    zgrep --no-default-ignore --exclude-dir=.git -l -e '' ROOT

(every fixture file has content, so -l -e '' lists every searched file).
A second case checks `.ignore` (read by rg/ag/fd, not by git) against rg.
Exit 0 only if every case is equal.
"""
import os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

FILES = {
    ".gitignore": "*.log\n!keep.log\n/build\nsub/gen/\ncache/\ndocs/**/*.tmp\n\\#hash.txt\n\\!bang.txt\nspace\\ \n*.bak  \n",
    "a.txt": "x", "a.log": "x", "keep.log": "x", "#hash.txt": "x", "!bang.txt": "x",
    "space ": "x", "space": "x", "x.bak": "x",
    "build/out.txt": "x", "src/build/kept.txt": "x",
    "sub/gen/g.txt": "x", "other/gen/kept.txt": "x",
    "deep/cache/c.txt": "x", "deep/cache.txt": "x",
    "docs/a/b/t.tmp": "x", "docs/t.tmp": "x", "docs/readme.md": "x",
    "pkg/.gitignore": "!debug.log\ntmp/*\n/local.txt\n",
    "pkg/debug.log": "x", "pkg/other.log": "x", "pkg/tmp/t.txt": "x",
    "pkg/local.txt": "x", "pkg/inner/local.txt": "x",
    "pkg/inner/.gitignore": "*\n!.gitignore\n!wanted.txt\n",
    "pkg/inner/wanted.txt": "x", "pkg/inner/unwanted.txt": "x",
    "excl/e.txt": "x", "excl/kept.txt": "x",
}
INFO_EXCLUDE = "excl/e.txt\n"

def build(root):
    for rel, body in FILES.items():
        p = os.path.join(root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(body + ("\n" if not body.endswith("\n") else ""))
    subprocess.run(["git", "init", "-q", root], check=True)
    with open(os.path.join(root, ".git", "info", "exclude"), "a") as f:
        f.write(INFO_EXCLUDE)

def git_view(repo, sub):
    out = subprocess.run(["git", "-C", repo, "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
                         capture_output=True, check=True).stdout.decode().split("\0")
    files = {f for f in out if f}
    if sub in ("", "."):
        return files
    pre = sub.rstrip("/") + "/"
    return {f[len(pre):] for f in files if f.startswith(pre)}

def zg_view(zg, cwd, root):
    p = subprocess.run([zg, "--no-default-ignore", "--exclude-dir=.git", "-l", "-e", "", root],
                       capture_output=True, cwd=cwd)
    out = set()
    for line in p.stdout.decode(errors="replace").splitlines():
        rel = os.path.relpath(line, root if os.path.isabs(root) else os.path.join(cwd, root)) \
            if os.path.isabs(line) else os.path.relpath(os.path.join(cwd, line), os.path.join(cwd, root))
        out.add(rel.replace(os.sep, "/"))
    return out

def main():
    zg = os.path.join(REPO, "zig-out", "bin", "zgrep")
    if "--zgrep" in sys.argv:
        zg = os.path.abspath(sys.argv[sys.argv.index("--zgrep") + 1])
    tmp = tempfile.mkdtemp(prefix="zg-gitignore-")
    passed = failed = 0
    try:
        repo = os.path.join(tmp, "repo")
        build(repo)
        # (label, cwd, root operand, subtree of the repo it covers)
        cases = [
            ("root .", repo, ".", ""),
            ("root pkg", repo, "pkg", "pkg"),
            ("root pkg/inner", repo, "pkg/inner", "pkg/inner"),
            ("root docs (absolute)", tmp, os.path.join(repo, "docs"), "docs"),
            ("cwd=pkg root .", os.path.join(repo, "pkg"), ".", "pkg"),
            ("root sub", repo, "sub", "sub"),
        ]
        for label, cwd, root, sub in cases:
            want = git_view(repo, sub)
            got = zg_view(zg, cwd, root)
            if want == got:
                passed += 1
                print(f"PASS {label} ({len(want)} files)")
            else:
                failed += 1
                print(f"FAIL {label}: extra={sorted(got - want)} missing={sorted(want - got)}")

        # .ignore: not a git file; rg/ag/fd read it. Compare with rg if present.
        if shutil.which("rg"):
            with open(os.path.join(repo, ".ignore"), "w") as f:
                f.write("!/build\nother/\n")
            rg = subprocess.run(["rg", "--hidden", "-g", "!.git/", "-l", "-e", "", "."],
                                capture_output=True, cwd=repo).stdout.decode().splitlines()
            want = {os.path.normpath(l).replace(os.sep, "/") for l in rg if l}
            got = zg_view(zg, repo, ".")
            if want == got:
                passed += 1
                print(f"PASS .ignore vs rg ({len(want)} files)")
            else:
                failed += 1
                print(f"FAIL .ignore vs rg: extra={sorted(got - want)} missing={sorted(want - got)}")
        else:
            print("SKIP .ignore vs rg (rg not installed)")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"TOTAL {passed} pass / {failed} fail")
    return 0 if failed == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
