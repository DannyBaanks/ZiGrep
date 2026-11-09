#!/usr/bin/env python3
"""Adversarial probe for the Windows port of ZiGrep.

The generic fuzzers (scripts/fuzz.zig, scripts/tri_fuzz.py) mutate patterns
and CLI flags. They do NOT exercise the Windows-specific surfaces of the
port: native path separators, the ScanConfig (invert / max_count) plumbing
that the merge had to re-thread, UTF-16 BOM files, CRLF files, long paths,
deep trees, or symlink handling.

This probe builds a hostile tree and compares zigrep against GNU grep
case by case. Contents never contain backslashes or colons, so normalising
separators and CRLF is unambiguous.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ZIGREP = str(Path(__file__).resolve().parent.parent / ("zig-out/bin/zigrep.exe" if os.name == "nt" else "zig-out/bin/zigrep"))
GREP = os.environ.get("ZIGREP_GREP", "grep")
TIMEOUT = 20

failures = []
checked = 0


def norm(text: str) -> str:
    # Native separators -> POSIX, strip trailing CR, normalise the drive letter.
    text = text.replace("\\", "/")
    text = re.sub(r"^[A-Za-z]:/", "", text)
    return "\n".join(line.rstrip("\r") for line in text.split("\n"))


def run(cmd, cwd):
    try:
        r = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=TIMEOUT)
        return {"code": r.returncode, "out": norm(r.stdout.decode("utf-8", "replace")),
                "err": r.stderr.decode("utf-8", "replace")}
    except subprocess.TimeoutExpired:
        return {"code": -1, "out": "", "err": "TIMEOUT"}
    except Exception as e:  # pragma: no cover
        return {"code": -2, "out": "", "err": str(e)}


def check(label, zargs, gargs, cwd, sort=False):
    """Run zigrep and GNU grep and compare exit code + normalised output."""
    global checked
    checked += 1
    zcmd = [ZIGREP] + zargs
    gcmd = [GREP, "-rIE"] + gargs
    z = run(zcmd, cwd)
    g = run(gcmd, cwd)
    if sort:
        z_out = "\n".join(sorted(z["out"].split("\n")))
        g_out = "\n".join(sorted(g["out"].split("\n")))
    else:
        z_out, g_out = z["out"], g["out"]
    if z["code"] != g["code"] or z_out != g_out:
        failures.append({
            "label": label, "zargs": zargs, "gargs": gargs,
            "zcode": z["code"], "gcode": g["code"],
            "zout": z_out, "gout": g_out, "zerr": z["err"], "gerr": g["err"],
        })
        print(f"  [FAIL] {label}")
    else:
        print(f"  [ok]   {label} (exit {z['code']})")


def build_tree(root: Path):
    """Build the hostile tree. Contents avoid backslashes and colons."""
    def w(rel, text, encoding="utf-8", newline="\n"):
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(text.encode(encoding, "replace").replace("\n", newline).encode("utf-8", "replace"))

    (root / "plain").mkdir(parents=True, exist_ok=True)
    (root / "plain" / "a.txt").write_text("alpha beta\ngamma delta\nneedle here\n", encoding="utf-8")
    (root / "plain" / "b.txt").write_text("needle one\nneedle two\nneedle three\n", encoding="utf-8")
    (root / "plain" / "c.txt").write_text("nothing relevant\n", encoding="utf-8")

    # Unicode + spaces
    d = root / "unicode dir 高速"
    d.mkdir(parents=True, exist_ok=True)
    (d / "你好 world.txt").write_text("needle unicode\nplain line\n", encoding="utf-8")
    (d / "café.txt").write_text("plain line\nneedle accent\n", encoding="utf-8")

    # CRLF file
    (root / "crlf").mkdir(parents=True, exist_ok=True)
    (root / "crlf" / "win.txt").write_bytes(b"needle crlf\r\nsecond line\r\n")

    # UTF-16 LE BOM file
    (root / "bom").mkdir(parents=True, exist_ok=True)
    (root / "bom" / "u16.txt").write_bytes("﻿needle bom\nsecond\n".encode("utf-16-le"))

    # Binary file with NUL
    (root / "bin").mkdir(parents=True, exist_ok=True)
    (root / "bin" / "data.bin").write_bytes(b"needle\x00binary\n")

    # Deep tree
    deep = root / "deep"
    for i in range(12):
        deep = deep / f"level{i}"
    deep.mkdir(parents=True, exist_ok=True)
    (deep / "bottom.txt").write_text("needle deep\n", encoding="utf-8")

    # Long path (> 260 chars is the classic Windows limit without long-path support)
    long_dir = root / ("L" * 60)
    for _ in range(4):
        long_dir = long_dir / ("D" * 60)
    long_dir.mkdir(parents=True, exist_ok=True)
    (long_dir / "long.txt").write_text("needle long\n", encoding="utf-8")

    # Empty directory
    (root / "empty").mkdir(parents=True, exist_ok=True)

    # Only subdirectories
    (root / "onlydirs" / "sub").mkdir(parents=True, exist_ok=True)
    (root / "onlydirs" / "sub" / "x.txt").write_text("needle sub\n", encoding="utf-8")

    # .gitignore
    (root / "ignored").mkdir(parents=True, exist_ok=True)
    (root / "ignored" / ".gitignore").write_text("skip.txt\n", encoding="utf-8")
    (root / "ignored" / "skip.txt").write_text("needle skipped\n", encoding="utf-8")
    (root / "ignored" / "keep.txt").write_text("needle kept\n", encoding="utf-8")

    # Symlink (Windows needs privileges; skipped when it cannot be created)
    try:
        os.symlink(root / "plain" / "a.txt", root / "plain" / "link.txt")
        (root / "symlink_note").write_text("symlink created\n", encoding="utf-8")
    except Exception:
        pass

    # Name with shell-ish and space characters
    (root / "plain" / "weird name (1).txt").write_text("needle weird\n", encoding="utf-8")


def main():
    if not Path(ZIGREP).exists():
        print(f"ERROR: zigrep binary not found at {ZIGREP}")
        return 2

    tmp = Path(tempfile.mkdtemp(prefix="zigrep-adv-"))
    try:
        build_tree(tmp)

        print("== ScanConfig plumbing (the merge had to re-thread it) ==")
        check("invert -v", ["-v", "needle", "plain"], ["-v", "needle", "plain"], tmp, sort=True)
        check("invert -v whole tree", ["-v", "needle", "."], ["-v", "needle", "."], tmp, sort=True)
        check("max-count -m 1", ["-m", "1", "needle", "plain"], ["-m", "1", "needle", "plain"], tmp, sort=True)
        check("max-count -m 2", ["-m", "2", "needle", "plain"], ["-m", "2", "needle", "plain"], tmp, sort=True)
        check("invert + max-count", ["-v", "-m", "1", "needle", "plain"], ["-v", "-m", "1", "needle", "plain"], tmp, sort=True)
        check("files-without-match -L", ["-L", "needle", "plain"], ["-L", "needle", "plain"], tmp, sort=True)
        check("count -c", ["-c", "needle", "plain"], ["-c", "needle", "plain"], tmp, sort=True)
        check("quiet -q present", ["-q", "needle", "plain"], ["-q", "needle", "plain"], tmp)
        check("quiet -q absent", ["-q", "zzzznotfound", "plain"], ["-q", "zzzznotfound", "plain"], tmp)

        print("== Windows path surfaces ==")
        check("unicode + spaces dir", ["needle", "unicode dir 高速"], ["needle", "unicode dir 高速"], tmp, sort=True)
        check("weird filename", ["needle", "plain/weird name (1).txt"], ["needle", "plain/weird name (1).txt"], tmp)
        check("deep tree", ["needle", "deep"], ["needle", "deep"], tmp, sort=True)
        check("empty dir", ["needle", "empty"], ["needle", "empty"], tmp)
        check("only subdirs", ["needle", "onlydirs"], ["needle", "onlydirs"], tmp, sort=True)
        check("long path", ["needle", str(Path("L" * 60))], ["needle", str(Path("L" * 60))], tmp, sort=True)

        print("== Content encodings ==")
        check("crlf file", ["needle", "crlf"], ["needle", "crlf"], tmp, sort=True)
        check("utf16 bom file", ["needle", "bom"], ["needle", "bom"], tmp, sort=True)
        check("binary file", ["needle", "bin"], ["needle", "bin"], tmp, sort=True)

        print("== Ignore handling ==")
        check("gitignore respected", ["needle", "ignored"], ["needle", "ignored"], tmp, sort=True)

        print("== Single file vs directory ==")
        check("single file", ["needle", "plain/a.txt"], ["needle", "plain/a.txt"], tmp)
        check("single file invert", ["-v", "needle", "plain/a.txt"], ["-v", "needle", "plain/a.txt"], tmp)

        print("== CLI surface ==")
        check("kamikaze -k", ["-k", "needle", "plain"], ["needle", "plain"], tmp, sort=True)
        check("sort mode", ["--sort", "needle", "plain"], ["needle", "plain"], tmp, sort=True)
        check("uring fallback", ["--uring", "needle", "plain"], ["needle", "plain"], tmp, sort=True)

        print()
        print("=" * 80)
        print(f"  Casos comprobados : {checked}")
        print(f"  Divergencias      : {len(failures)}")
        print("=" * 80)
        if failures:
            print("\n  Detalle de divergencias:")
            for f in failures:
                print(f"\n  --- {f['label']}")
                print(f"      zigrep args : {f['zargs']}")
                print(f"      grep args   : {f['gargs']}")
                print(f"      exit        : zigrep={f['zcode']} grep={f['gcode']}")
                print(f"      zigrep out  : {f['zout']!r}")
                print(f"      grep out    : {f['gout']!r}")
                if f["zerr"]:
                    print(f"      zigrep err  : {f['zerr'][:300]!r}")
            return 1
        print("\n  VEREDICTO: sin divergencias contra GNU grep en Windows.")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
