#!/usr/bin/env python3
"""Run scripts/diff_fuzz.zig at scale and judge what it finds.

usage: diff_fuzz_run.py CASES [--procs=N] [--seed=S] [--knob=auto|1..5]
                        [--out=DIR] [--zgrep=PATH] [--fuzzer=PATH]

Why processes and not threads: every case compiles a new pattern, and the
engine's per-thread DFA is mapped with page_allocator (mmap/munmap). Inside
one process the threads then queue on the kernel's mmap lock: 12 threads gave
~9 000 cases/s, 12 single-thread processes ~57 000 (measured 2026-11-12). In
normal zgrep runs the pattern is fixed, so this only matters here.

Each divergence the fuzzer reports (already shrunk) is replayed with the CLI,
zgrep vs `LC_ALL=C grep -E/-F` (byte semantics, like zgrep):
  zgrep_bug    zgrep differs from grep  -> a real bug (or a documented
               divergence, to be checked by hand)
  oracle_bug   zgrep agrees with grep   -> the fuzzer's reference is wrong
Exit 0 only if there were no divergences at all.
"""
import json, os, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

def arg(name, default):
    for a in sys.argv[1:]:
        if a.startswith(f"--{name}="):
            return a.split("=", 1)[1]
    return default

def grep_args(rec, extra):
    # -a on both sides: the fuzzer tests the matcher, not the binary rule
    # (a NUL in the haystack would make the CLI skip or flag the file).
    a = ["-a", "-F" if rec["fixed"] else "-E"]
    for k, f in (("icase", "-i"), ("word", "-w"), ("line", "-x"), ("invert", "-v")):
        if rec[k]:
            a.append(f)
    a += extra
    for p in rec["patterns"]:
        a += ["-e", p.encode("latin-1")]
    return a

def replay(tool, rec, path, extra):
    env = dict(os.environ, LC_ALL="C")
    p = subprocess.run([*tool, *grep_args(rec, extra), path], capture_output=True, env=env, timeout=30)
    return p.stdout

def judge(recs, zg):
    verdicts = {"zgrep_bug": [], "oracle_bug": []}
    with tempfile.TemporaryDirectory(prefix="zg-dfz-") as tmp:
        for r in recs:
            path = os.path.join(tmp, "hay")
            with open(path, "wb") as f:
                f.write(r["haystack"].encode("latin-1"))
            same = True
            for extra in (["-n"], ["-c"], ["-ob"] if not (r["word"] or r["line"] or r["invert"]) else None):
                if extra is None:
                    continue
                if replay([zg], r, path, extra) != replay(["/usr/bin/grep"], r, path, extra):
                    same = False
            # The line-by-line path (forced by --json) must give grep's count too.
            jc = [json.loads(l) for l in replay([zg], r, path, ["--json", "-c"]).splitlines() if l]
            want_c = int(replay(["/usr/bin/grep"], r, path, ["-c"]) or b"0")
            if sum(e.get("lines") or 0 for e in jc if e.get("type") == "count") != want_c:
                same = False
            verdicts["oracle_bug" if same else "zgrep_bug"].append(r)
    return verdicts

def main():
    zg = os.path.abspath(arg("zgrep", os.path.join(REPO, "zig-out", "bin", "zgrep")))
    only = arg("triage-only", None)
    if only:
        recs = [json.loads(l) for l in open(only)]
        v = judge(recs, zg)
        print(f"triage-only {only}: records={len(recs)} zgrep_bug={len(v['zgrep_bug'])} oracle_bug={len(v['oracle_bug'])}")
        for r in v["zgrep_bug"][:8]:
            print("  ZGREP:", r["what"], r["patterns"], {k: r[k] for k in ("fixed", "icase", "word", "line", "invert")}, repr(r["haystack"]))
        return 0
    cases = int(next(a for a in sys.argv[1:] if not a.startswith("--")))
    procs = int(arg("procs", os.cpu_count() or 4))
    seed = int(arg("seed", int(time.time())))
    knob = arg("knob", "auto")
    out = os.path.abspath(arg("out", "fuzz-out"))
    fz = os.path.abspath(arg("fuzzer", os.path.join(REPO, "zig-out", "bin", "diff_fuzz")))
    os.makedirs(out, exist_ok=True)

    per = cases // procs
    t0 = time.time()
    running = []
    for i in range(procs):
        n = per + (1 if i < cases % procs else 0)
        d = os.path.join(out, f"p{i:02d}")
        os.makedirs(d, exist_ok=True)
        log = open(os.path.join(d, "log.txt"), "w")
        running.append((subprocess.Popen([fz, str(n), "--threads=1", f"--seed={seed + i}", f"--knob={knob}", f"--out={d}"],
                                         stdout=log, stderr=log), d, log))
    total = div = rej = 0
    recs = {}
    for p, d, log in running:
        p.wait()
        log.close()
        text = open(os.path.join(d, "log.txt")).read()
        # Only the summary lines: the per-knob lines repeat "cases=".
        head = " ".join(l for l in text.splitlines() if not l.strip().startswith("knob "))
        for tok in head.split():
            if tok.startswith("cases="):
                total += int(tok.split("=")[1])
            elif tok.startswith("divergences="):
                div += int(tok.split("=")[1])
            elif tok.startswith("rejected_patterns="):
                rej += int(tok.split("=")[1])
        for line in open(os.path.join(d, "divergences.jsonl")):
            r = json.loads(line)
            key = (r["what"], tuple(r["patterns"]), r["fixed"], r["icase"], r["word"], r["line"], r["invert"])
            recs.setdefault(key, r)
    secs = time.time() - t0

    verdicts = judge(list(recs.values()), zg)

    with open(os.path.join(out, "triage.json"), "w") as f:
        json.dump({"cases": total, "seed": seed, "procs": procs, "knob": knob, "elapsed_s": round(secs, 1),
                   "divergences": div, "unique": len(recs), "rejected_patterns": rej,
                   "zgrep_bug": verdicts["zgrep_bug"], "oracle_bug": verdicts["oracle_bug"]}, f, indent=1)
    print(f"cases={total} procs={procs} seed={seed} knob={knob} elapsed_s={secs:.1f} cases_per_s={total / secs:.0f}")
    print(f"divergences={div} unique={len(recs)} zgrep_bug={len(verdicts['zgrep_bug'])} "
          f"oracle_bug={len(verdicts['oracle_bug'])} rejected_patterns={rej}")
    for r in verdicts["zgrep_bug"][:10]:
        print("  ZGREP:", r["what"], r["patterns"], {k: r[k] for k in ("fixed", "icase", "word", "line", "invert")}, repr(r["haystack"]))
    for r in verdicts["oracle_bug"][:5]:
        print("  ORACLE:", r["what"], r["patterns"], repr(r["haystack"]))
    print(f"report: {os.path.join(out, 'triage.json')}")
    return 0 if div == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
