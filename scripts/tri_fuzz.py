#!/usr/bin/env python3
"""
Tri-Way Differential Fuzzer: ZiGrep vs ripgrep vs GNU grep (parallel, seeded).

Usage: tri_fuzz.py ITERATIONS KNOB [--seed=N] [--workers=N] [--out=FILE.json]

Knobs: 1 gentle | 2 flags | 3 grammar | 4 ReDoS | 5 chaos | 6 apocalypse
No console spam: only a summary is printed; samples go to the JSON file.

Verdict per case (exit-code class + set of "path:line" keys in line mode):
  agree_all        all three agree
  zg_with_rg       zigrep == ripgrep != grep   (GNU grep quirk, not a zigrep bug)
  zg_with_grep     zigrep == grep   != ripgrep
  zg_alone         zigrep differs from BOTH, which agree with each other  -> SUSPECT
  all_differ       three different answers
  zg_crash/zg_hang zigrep died by signal / timed out while others did not
"""
import json, os, random, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ZIGREP = str(REPO / "zig-out/bin/zigrep")
TIMEOUT = 3.0

WORDS = ["searcher", "filter", "kamikaze", "io_uring", "walk", "scan", "buffer", "result",
         "allocator", "pattern", "literal", "vector", "stream", "corrupt", "alpha", "omega",
         "const", "pub", "fn", "std", "usize", "test", "return", "error", "nadír", "über"]
FRAGS = ["(", ")", "[", "]", "{", "}", "*", "+", "?", "|", "^", "$", ".", r"\d", r"\w", r"\s",
         "[a-z]", "[^a-z]", "[0-9]", "[[:alpha:]]", "()", "||", "(a|)", "(|b)", "(a|b|c)",
         "(a+)+", "(a*)*", "(a|a)*", "{0,0}", "{0,1}", "{1,5}", "{10,2}", "{2,}",
         r"fn\s+\w+\(", r"pub\s+(const|fn)", r"std\.(mem|math)", r"\.", r"\\", "a{3}"]
FLAGS = ["-i", "-v", "-w", "-c", "-l", "-L", "-q", "-F", "-a"]


def gen(rnd, knob):
    flags = []
    if knob >= 2:
        flags = rnd.sample(FLAGS, k=rnd.randint(0, 3))
        if rnd.random() < 0.3:
            flags += ["-m", str(rnd.choice([1, 2, 5, 10]))]
    if knob == 1:
        pat = rnd.choice(WORDS) if rnd.random() < .5 else "|".join(rnd.sample(WORDS, 2))
    elif knob == 2:
        pat = rnd.choice([r"[a-z]+_" + rnd.choice(WORDS), "^" + rnd.choice(WORDS),
                          rnd.choice(WORDS) + "$", r"\d+", rnd.choice(WORDS)])
    elif knob == 3:
        m = rnd.randint(0, 4)
        if m == 0:
            d = rnd.randint(2, 30)
            pat = "(" * d + rnd.choice(WORDS) + ")" * rnd.randint(max(0, d - 2), d + 2)
        elif m == 1:
            pat = "".join(rnd.choice(FRAGS) for _ in range(rnd.randint(2, 6)))
        elif m == 2:
            pat = rnd.choice(["[a-z", "[^0-9", "[--]", "[z-a]", "]", "}", "a{", "a{1", "a{1,"])
        elif m == 3:
            pat = rnd.choice(WORDS) + rnd.choice(["**", "+?*", "{5,2}", "{0,0}", "?+", "{1000,2000}"])
        else:
            pat = "|".join(rnd.choice(WORDS) for _ in range(rnd.randint(3, 10)))
    elif knob == 4:
        s = rnd.choice(["a", "x", "e", "word", "st"])
        pat = rnd.choice([f"({s}+)+$", f"({s}*)*b", f"({s}|{s})*c", f"({s}|{s}{s})*d",
                          f"([{s}]+)+e", f"(({s}+)+)+$", f"({s}?){{20}}{s}{{20}}"])
    elif knob == 5:
        pat = "".join(rnd.choice(FRAGS + WORDS) for _ in range(rnd.randint(3, 10)))
        if rnd.random() < .3:
            flags = ["-i", "-w", "-v", "-c"]
    else:  # 6: apocalypse - raw bytes, huge patterns, flag storms
        k = rnd.randint(0, 3)
        if k == 0:
            pat = bytes(rnd.choice([b for b in range(1, 256) if b != 10])
                        for _ in range(rnd.randint(1, 64))).decode("latin-1")
        elif k == 1:
            pat = "".join(rnd.choice(FRAGS + WORDS) for _ in range(rnd.randint(20, 80)))
        elif k == 2:
            pat = "(" * rnd.randint(150, 260) + "a" + ")" * rnd.randint(150, 260)
        else:
            pat = "|".join(rnd.choice(WORDS) for _ in range(rnd.randint(30, 120)))
        flags = rnd.sample(FLAGS, k=rnd.randint(1, 5))
        if rnd.random() < .5:
            flags += ["-m", rnd.choice(["0", "1", "3"])]
    return pat, flags


def run(cmd):
    try:
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=TIMEOUT, cwd=str(REPO))
        return r.returncode, r.stdout, False
    except subprocess.TimeoutExpired:
        return -999, b"", True
    except Exception:
        return -998, b"", False


def keys(out, flags):
    if any(f in flags for f in ("-c", "-l", "-L", "-q")):
        return tuple(sorted(out.decode("latin-1").split("\n")))
    ks = set()
    for ln in out.decode("latin-1").split("\n"):
        p = ln.split(":", 2)
        if len(p) >= 2:
            ks.add(p[0] + ":" + p[1])
    return tuple(sorted(ks))


def cls(rc):
    return rc if rc in (0, 1, 2) else ("sig" if rc < 0 else rc)


def one(args):
    seed, knob, i = args
    rnd = random.Random(seed * 1_000_003 + i)
    pat, flags = gen(rnd, knob)
    fx = [f for f in flags if f != "-F"]
    # -e guards patterns that start with '-'
    zg = [ZIGREP] + flags + ["-e", pat, "src"]
    rg = ["rg", "-n", "-H", "--no-heading"] + flags + ["-e", pat, "src"]
    gr = ["grep", "-rnI" + ("F" if "-F" in flags else "E")] + fx + ["-e", pat, "src"]
    # grep has no -a-equivalent semantics problem; keep as is
    (zc, zo, zt), (rc, ro, rt), (gc, go, gt) = run(zg), run(rg), run(gr)
    rec = {"i": i, "pat": pat, "flags": flags, "zg": zc, "rg": rc, "gr": gc}
    if zt and not (rt or gt):
        rec["v"] = "zg_hang"; return rec
    if zc is not None and zc < 0 and zc != -999 and zc != -998:
        rec["v"] = "zg_crash"; return rec
    if zc >= 128:
        rec["v"] = "zg_crash"; return rec
    if zc == 126 or zc == 127:
        rec["v"] = "zg_crash"; return rec
    if zc not in (0, 1, 2) and zc != -999:
        rec["v"] = "zg_badexit"; return rec
    z = (cls(zc), keys(zo, flags) if zc == 0 else ())
    r = (cls(rc), keys(ro, flags) if rc == 0 else ())
    g = (cls(gc), keys(go, flags) if gc == 0 else ())
    if z == r == g: rec["v"] = "agree_all"
    elif z == r: rec["v"] = "zg_with_rg"
    elif z == g: rec["v"] = "zg_with_grep"
    elif r == g: rec["v"] = "zg_alone"
    else: rec["v"] = "all_differ"
    return rec


def main():
    a = [x for x in sys.argv[1:] if not x.startswith("--")]
    opt = dict(x[2:].split("=", 1) for x in sys.argv[1:] if x.startswith("--") and "=" in x)
    iters = int(a[0]) if a else 20000
    knob = int(a[1]) if len(a) > 1 else 3
    seed = int(opt.get("seed", int(time.time())))
    workers = int(opt.get("workers", 4))
    out = opt.get("out")
    t0 = time.time()
    counts, samples = {}, {}
    with ThreadPoolExecutor(max_workers=workers) as ex:
        for rec in ex.map(one, ((seed, knob, i) for i in range(iters)), chunksize=64):
            v = rec["v"]
            counts[v] = counts.get(v, 0) + 1
            if v not in ("agree_all", "zg_with_rg", "zg_with_grep") and len(samples.setdefault(v, [])) < 25:
                samples[v].append(rec)
    dt = time.time() - t0
    summary = {"iters": iters, "knob": knob, "seed": seed, "workers": workers,
               "secs": round(dt, 1), "counts": counts, "samples": samples}
    if out:
        Path(out).parent.mkdir(parents=True, exist_ok=True)
        Path(out).write_text(json.dumps(summary, indent=1, ensure_ascii=False))
    line = " ".join(f"{k}={v}" for k, v in sorted(counts.items()))
    print(f"knob={knob} seed={seed} iters={iters} {dt:.0f}s | {line}")


if __name__ == "__main__":
    main()
