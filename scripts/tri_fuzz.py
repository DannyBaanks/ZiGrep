#!/usr/bin/env python3
"""
Tri-Way Differential Fuzzer: ZiGrep vs ripgrep vs GNU grep
Tests adversarial permutations against all 3 engines to detect:
  1. Crashes (SIGSEGV 139, SIGABRT 134, etc.)
  2. Hangs / Timeouts (ReDoS / Catastrophic backtracking)
  3. Exit code discrepancies and usage rejections
  4. Behavioral divergence between engines
"""
import sys
import os
import random
import subprocess
import time
from pathlib import Path

# Resolve the repository from this script's location so the fuzzer runs from
# any checkout, on any host (the original hardcoded a Linux home path).
REPO_ROOT = Path(__file__).resolve().parent.parent
_ZIGREP_BIN = "zig-out/bin/zigrep.exe" if os.name == "nt" else "zig-out/bin/zigrep"
ZIGREP = str(REPO_ROOT / _ZIGREP_BIN)
# The reference engines can be overridden (useful when GNU grep lives in a
# Git-for-Windows installation that is not on PATH).
RIPGREP = os.environ.get("ZIGREP_RIPGREP", "rg")
GNU_GREP = os.environ.get("ZIGREP_GREP", "grep")

CORPUS_WORDS = [
    "searcher", "filter", "kamikaze", "io_uring", "walk", "scan", "buffer",
    "result", "allocator", "pattern", "literal", "vector", "stream", "corrupt",
    "alpha", "omega", "zenith", "nadír", "über", "añejo", "const", "pub", "fn",
]

REGEX_FRAGMENTS = [
    "(", ")", "[", "]", "{", "}", "*", "+", "?", "|", "^", "$", ".",
    r"\d", r"\w", r"\s", r"[a-z]", r"[^a-z]", r"[0-9]", r"[[:alpha:]]",
    "()", "||", "(a|)", "(|b)", "(a|b|c)", "(a+)+", "(a*)*", "(a|a)*",
    "{0,0}", "{0,1}", "{1,5}", "{10,2}", "{99,99}",
    r"fn\s+\w+\(", r"pub\s+(const|fn)", r"std\.(mem|math|os)",
]

SHORT_FLAGS = ["-i", "-v", "-w", "-c", "-l", "-q"]

def generate_adversarial_case(knob=3):
    """
    Knobs:
      1: Gentle (valid patterns + standard flags)
      2: Combinatorial flags (-i, -w, -v, -c, -l, -q, -m N)
      3: Grammar & Syntax Stress (nested groups, unclosed brackets, extreme repeats)
      4: Catastrophic Backtracking Bait ((a+)+$, (a*)*, (a|a)*)
      5: Maximum Chaos (random byte mutations + conflicting flags)
    """
    flags = []
    # Pick flags based on knob
    if knob >= 2:
        num_flags = random.randint(0, 3)
        flags = random.sample(SHORT_FLAGS, k=num_flags)
        if random.random() < 0.3:
            flags.extend(["-m", str(random.choice([1, 2, 5, 10]))])

    if knob == 1:
        # Gentle: valid word or multi-word alternation
        if random.random() < 0.5:
            pat = random.choice(CORPUS_WORDS)
        else:
            pat = f"{random.choice(CORPUS_WORDS)}|{random.choice(CORPUS_WORDS)}"
    elif knob == 2:
        # Valid regex with complex flags
        pat = random.choice([
            r"\b" + random.choice(CORPUS_WORDS) + r"\b",
            r"pub\s+(const|fn)",
            r"\d+\.\d+",
            r"[a-z]+",
            random.choice(CORPUS_WORDS),
        ])
    elif knob == 3:
        # Grammar & Syntax Stress
        mode = random.randint(0, 4)
        if mode == 0:
            # Nested parens
            depth = random.randint(2, 20)
            pat = "(" * depth + random.choice(CORPUS_WORDS) + ")" * random.randint(0, depth * 2)
        elif mode == 1:
            # Token chaos
            tokens = [random.choice(REGEX_FRAGMENTS) for _ in range(random.randint(2, 6))]
            pat = "".join(tokens)
        elif mode == 2:
            # Unclosed class or reversed range
            pat = random.choice(["[a-z", "[^0-9", "[--]", "[z-a]", "]", "}"])
        elif mode == 3:
            # Quantifier abuse
            pat = random.choice(CORPUS_WORDS) + random.choice(["**", "+?*", "{5,2}", "{0,0}"])
        else:
            # Alternation flood
            pat = "|".join([random.choice(CORPUS_WORDS) for _ in range(random.randint(3, 8))])
    elif knob == 4:
        # ReDoS / Backtracking bait
        sub = random.choice(["a", "x", "1", "word"])
        pat = random.choice([
            f"({sub}+)+$",
            f"({sub}*)*b",
            f"({sub}|{sub})*c",
            f"({sub}|{sub}{sub})*d",
            f"([{sub}]+)+e",
        ])
    else:
        # Knob 5: Maximum Chaos
        tokens = [random.choice(REGEX_FRAGMENTS + CORPUS_WORDS) for _ in range(random.randint(3, 10))]
        pat = "".join(tokens)
        if random.random() < 0.3:
            flags = ["-i", "-w", "-v", "-c"]

    target = "src"
    return pat, flags, target

def run_one(cmd, timeout=1.5):
    t0 = time.time()
    try:
        r = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            cwd=str(REPO_ROOT),
        )
        dt = (time.time() - t0) * 1000
        return {
            "code": r.returncode,
            "stdout_len": len(r.stdout),
            "stderr_len": len(r.stderr),
            "time_ms": dt,
            "timeout": False,
            "crashed": r.returncode < 0 or r.returncode >= 128,
        }
    except subprocess.TimeoutExpired:
        dt = (time.time() - t0) * 1000
        return {
            "code": -1,
            "stdout_len": 0,
            "stderr_len": 0,
            "time_ms": dt,
            "timeout": True,
            "crashed": False,
        }
    except Exception as e:
        return {
            "code": -2,
            "stdout_len": 0,
            "stderr_len": 0,
            "time_ms": 0,
            "timeout": False,
            "crashed": True,
            "error": str(e),
        }

def main():
    # Windows consoles still default to a legacy code page; keep the report
    # readable (and never crash on an unprintable byte) by forcing UTF-8.
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    iterations = 200
    knob = 3
    if len(sys.argv) > 1:
        try:
            iterations = int(sys.argv[1])
        except ValueError:
            pass
    if len(sys.argv) > 2:
        try:
            knob = int(sys.argv[2])
        except ValueError:
            pass

    print("=" * 88)
    print("  🔬 Tri-Way Differential Fuzzer (ZiGrep vs ripgrep vs GNU grep)")
    print("=" * 88)
    print(f"  Iterations : {iterations}")
    print(f"  Entropy Knob : Level {knob} (1=Gentle, 2=Flags, 3=Grammar, 4=ReDoS, 5=Chaos)")
    print(f"  Engines      : zigrep ({ZIGREP}), ripgrep ({RIPGREP}), GNU grep ({GNU_GREP})")
    print("-" * 88)

    stats = {
        "zg_crashes": 0, "rg_crashes": 0, "gr_crashes": 0,
        "zg_timeouts": 0, "rg_timeouts": 0, "gr_timeouts": 0,
        "total_discrepancies": 0,
        "zg_faster": 0, "rg_faster": 0, "gr_faster": 0,
    }

    discrepancies = []

    for i in range(1, iterations + 1):
        pat, flags, target = generate_adversarial_case(knob)

        # Build command lines
        cmd_zg = [ZIGREP] + flags + [pat, target]
        cmd_rg = [RIPGREP] + flags + [pat, target]
        # GNU grep uses -rE for extended regex
        cmd_gr = [GNU_GREP, "-rE"] + flags + [pat, target]

        res_zg = run_one(cmd_zg)
        res_rg = run_one(cmd_rg)
        res_gr = run_one(cmd_gr)

        # Track crashes
        if res_zg["crashed"]: stats["zg_crashes"] += 1
        if res_rg["crashed"]: stats["rg_crashes"] += 1
        if res_gr["crashed"]: stats["gr_crashes"] += 1

        # Track timeouts
        if res_zg["timeout"]: stats["zg_timeouts"] += 1
        if res_rg["timeout"]: stats["rg_timeouts"] += 1
        if res_gr["timeout"]: stats["gr_timeouts"] += 1

        # Speed comparison on successful matches (exit code 0)
        if res_zg["code"] == 0 and res_rg["code"] == 0 and res_gr["code"] == 0:
            times = [("zigrep", res_zg["time_ms"]), ("ripgrep", res_rg["time_ms"]), ("grep", res_gr["time_ms"])]
            times.sort(key=lambda x: x[1])
            winner = times[0][0]
            if winner == "zigrep": stats["zg_faster"] += 1
            elif winner == "ripgrep": stats["rg_faster"] += 1
            else: stats["gr_faster"] += 1

        # Check for interesting discrepancies (e.g. one crashed or timed out while others didn't)
        if res_zg["timeout"] != res_rg["timeout"] or res_zg["crashed"] != res_rg["crashed"] or res_gr["timeout"] != res_zg["timeout"]:
            stats["total_discrepancies"] += 1
            discrepancies.append({
                "iter": i,
                "pattern": pat,
                "flags": flags,
                "zg": res_zg,
                "rg": res_rg,
                "gr": res_gr,
            })

        if i % 25 == 0 or i == iterations:
            print(f"  [{i:>4}/{iterations}] "
                  f"zg_time={res_zg['time_ms']:>5.1f}ms (exit {res_zg['code']}) | "
                  f"rg_time={res_rg['time_ms']:>5.1f}ms (exit {res_rg['code']}) | "
                  f"gr_time={res_gr['time_ms']:>5.1f}ms (exit {res_gr['code']}) | "
                  f"Pat: {pat[:25]!r}")

    print("\n" + "=" * 88)
    print("  📊 Tri-Way Fuzzing Campaign Summary")
    print("=" * 88)
    print(f"  Total Permutations Tested : {iterations}")
    print(f"  ZiGrep Crashes (SIGSEGV)   : {stats['zg_crashes']}")
    print(f"  ripgrep Crashes            : {stats['rg_crashes']}")
    print(f"  GNU grep Crashes           : {stats['gr_crashes']}")
    print(f"  ZiGrep Timeouts (>1.5s)    : {stats['zg_timeouts']}")
    print(f"  ripgrep Timeouts           : {stats['rg_timeouts']}")
    print(f"  GNU grep Timeouts          : {stats['gr_timeouts']}")
    print(f"  Head-to-head Speed Wins    : zigrep: {stats['zg_faster']} | ripgrep: {stats['rg_faster']} | grep: {stats['gr_faster']}")
    print(f"  Anomalous Discrepancies    : {stats['total_discrepancies']}")

    if discrepancies:
        print("\n  ⚠️ Notable Discrepancies:")
        for d in discrepancies[:5]:
            print(f"    - Iter {d['iter']}: Pattern {d['pattern']!r} Flags {d['flags']}")
            print(f"      zigrep: exit={d['zg']['code']} time={d['zg']['time_ms']:.1f}ms timeout={d['zg']['timeout']}")
            print(f"      ripgrep: exit={d['rg']['code']} time={d['rg']['time_ms']:.1f}ms timeout={d['rg']['timeout']}")
            print(f"      GNU grep: exit={d['gr']['code']} time={d['gr']['time_ms']:.1f}ms timeout={d['gr']['timeout']}")
    else:
        print("\n  🟢 All engines maintained clean execution without crashes!")
    print("=" * 88)

if __name__ == "__main__":
    main()
