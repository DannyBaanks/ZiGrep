#!/usr/bin/env python3
"""Brute-force the Adversary 2 argument space to find hanging invocations.

scripts/fuzz.zig runs its CLI permutations as child processes, but it only
checks the EXIT CODE: a child that never returns is invisible to it (there
is no timeout on the subprocess). This script replays the same argument
space with a hard timeout so a hang becomes an observable event.

Usage: py scripts/hunt_hang.py [binary]
"""
import itertools
import os
import subprocess
import sys
from pathlib import Path

BIN = sys.argv[1] if len(sys.argv) > 1 else str(
    Path(__file__).resolve().parent.parent / ("zig-out/bin/zigrep.exe" if os.name == "nt" else "zig-out/bin/zigrep")
)

TIMEOUT = 3.0

CORPUS_WORDS = [
    "searcher", "filter", "kamikaze", "io_uring", "walk", "scan", "buffer",
    "result", "allocator", "pattern", "literal", "vector", "stream", "corrupt",
    "alpha", "omega", "zenith", "nadir", "über", "añejo", "const", "pub", "fn",
]

SHORT_FLAGS = ["-F", "-E", "-i", "-v", "-w", "-c", "-l", "-L", "-q", "-H", "-h", "-a", "-k", "-r", "-n"]
LONG_FLAGS = [
    "--fixed-strings", "--extended-regexp", "--ignore-case",
    "--invert-match", "--word-regexp", "--count",
    "--files-with-matches", "--files-without-match", "--quiet",
    "--kamikaze", "--sort", "--uring",
    "--stats", "--no-ignore", "--no-default-ignore", "--no-hidden",
]
NUM_VALUES = ["0", "1", "2", "4", "12", "16", "64", "999999", "18446744073709551615", "-1", "auto", "max"]
BEFUNGE_VALUES = ["v^", "^v", "><", "ud", "du", "rl", "v^><udrl", "vvvvvv", "^^^^^^", "invalid_op_!"]
PATHS = ["src", "nul", "nonexistent_dir_or_file_xyz", "build.zig"]


def try_run(args):
    """Return (status, elapsed) where status is 'ok', 'hang' or 'err'."""
    import time
    t0 = time.time()
    try:
        r = subprocess.run([BIN] + args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           stdin=subprocess.DEVNULL, timeout=TIMEOUT)
        return ("ok", time.time() - t0, r.returncode)
    except subprocess.TimeoutExpired:
        return ("hang", time.time() - t0, None)
    except Exception as e:
        return ("err", time.time() - t0, str(e))


def main():
    print(f"binary: {BIN}")
    print(f"timeout: {TIMEOUT}s")
    hangs = []

    # Phase 1: one flag at a time, with every value class.
    singles = []
    for f in SHORT_FLAGS + LONG_FLAGS:
        singles.append([f])
    for f in ["-j", "-m"]:
        for v in NUM_VALUES:
            singles.append([f, v])
    for v in BEFUNGE_VALUES:
        singles.append(["-N", v])
        singles.append([f"--nav={v}"])
    for v in ["bmh", "memchr", "auto", "bogus"]:
        singles.append(["--algo", v])

    for flags in singles:
        for pat in CORPUS_WORDS[:4]:
            for path in PATHS[:2]:
                args = flags + [pat, path]
                status, dt, code = try_run(args)
                if status == "hang":
                    hangs.append(args)
                    print(f"  [HANG] {' '.join(args)}  ({dt:.1f}s)")
    print(f"phase 1 done: {len(hangs)} hangs")

    # Phase 2: the pairs the fuzzer really produces (a numeric flag + a value,
    # possibly clustered), over every pattern and path.
    for numflag in ["-j", "-m"]:
        for v in NUM_VALUES:
            for extra in [[], ["-k"], ["-i"], ["-v"], ["-c"], ["-n"], ["-w"], ["-l"], ["-L"], ["-q"]]:
                for pat in CORPUS_WORDS:
                    for path in PATHS:
                        args = extra + [numflag, v, pat, path]
                        status, dt, code = try_run(args)
                        if status == "hang":
                            hangs.append(args)
                            print(f"  [HANG] {' '.join(args)}  ({dt:.1f}s)")
    print(f"phase 2 done: {len(hangs)} hangs")

    # Phase 3: two numeric flags together (-j and -m), the nastiest combo.
    for jv in NUM_VALUES:
        for mv in NUM_VALUES:
            for extra in [[], ["-k"], ["-v"], ["-c"]]:
                args = extra + ["-j", jv, "-m", mv, "needle", "src"]
                status, dt, code = try_run(args)
                if status == "hang":
                    hangs.append(args)
                    print(f"  [HANG] {' '.join(args)}  ({dt:.1f}s)")
    print(f"phase 3 done: {len(hangs)} hangs")

    print("=" * 70)
    if hangs:
        print(f"  HANGING COMBINATIONS: {len(hangs)}")
        for h in hangs[:40]:
            print("   ", " ".join(h))
        return 1
    print("  No hanging combination found in this sweep.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
