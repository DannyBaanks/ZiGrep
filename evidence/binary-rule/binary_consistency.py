#!/usr/bin/env python3
"""ZiGrep's binary rule, checked against a model on every read path.

usage: binary_consistency.py [--zgrep PATH]

The rule (src/scan.zig, searchBytes), without -a / --null-data / UTF-16:
  - a binary signature at the start (PDF, ELF, PNG, zip, ...) or a NUL in the
    first 8192 bytes: the file is binary, nothing is reported;
  - a NUL further in: the file is text up to the start of the line holding
    the first NUL; nothing from that line on is printed or counted.

A generated tree mixes NUL positions (none, inside the window, after it,
before/after the matches) with file sizes that take each read path (scratch
buffer, mmap > 256 KiB, io_uring batches) and enough files to start the
swarm. For each mode and I/O engine the output must equal the model:
lines, -c, -l, -L, --count-matches, --json; and no output byte may be NUL.
Exit 0 only if every check passes.
"""
import json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
PROBE = 8192
PAT = b"needle"

def make_files():
    files = {}
    filler = b"filler text line\n"
    for size_name, pad in (("small", 200), ("mid", 12000), ("big", 300_000)):
        body = b"needle at the start\n" + filler * (pad // len(filler)) + b"needle in the middle\n"
        files[f"{size_name}_text.txt"] = body + b"needle at the end\n"
        files[f"{size_name}_nul_window.bin"] = b"\x00" + body
        files[f"{size_name}_nul_late.bin"] = body + b"bin\x00 needle after\nneedle tail\n"
        files[f"{size_name}_nul_late_only_after.bin"] = filler * (pad // len(filler) + PROBE // len(filler) + 2) + b"\x00needle\n"
        files[f"{size_name}_nul_mid_line.bin"] = body + b"text then needle\x00 rest\n"
    # A binary signature with no NUL at all (a PDF header is ASCII).
    files["doc_no_nul.pdf"] = b"%PDF-1.5\nneedle in a pdf\n" + filler * 20
    # Text that only mentions a format is still text.
    files["mentions_pdf.txt"] = b"PDF-1.5 needle\n"
    # Many small text files so the swarm and the io_uring batches engage.
    for i in range(80):
        files[f"bulk/f{i:03d}.txt"] = (b"needle bulk %d\n" % i) + filler * (i % 7)
    return files

MAGICS = (b"%PDF-", b"\x7fELF", b"\x89PNG\r\n\x1a\n", b"PK\x03\x04", b"\x1f\x8b")

def model(data):
    """Lines (as bytes) the rule allows to match, or None for 'binary'."""
    if data.startswith(MAGICS):
        return None
    nul = data.find(b"\x00")
    if 0 <= nul < PROBE:
        return None
    text = data if nul < 0 else data[: data.rfind(b"\n", 0, nul) + 1]
    return [l for l in text.split(b"\n") if PAT in l]

def run(zg, args, root):
    p = subprocess.run([zg, *args, root], capture_output=True)
    return p.returncode, p.stdout

def main():
    zg = os.path.join(REPO, "zig-out", "bin", "zgrep")
    if "--zgrep" in sys.argv:
        zg = os.path.abspath(sys.argv[sys.argv.index("--zgrep") + 1])
    tmp = tempfile.mkdtemp(prefix="zg-binary-")
    passed = failed = 0
    def check(name, ok, detail=""):
        nonlocal passed, failed
        if ok:
            passed += 1
        else:
            failed += 1
            print(f"FAIL {name} {detail}")
    try:
        root = os.path.join(tmp, "t")
        files = make_files()
        for rel, data in files.items():
            p = os.path.join(root, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "wb") as f:
                f.write(data)
        want = {}
        for rel, data in files.items():
            m = model(data)
            want[os.path.join(root, rel)] = [] if m is None else m

        for engine in ("--io-engine=sync", "--io-engine=uring", "--force-swarm", "-j1"):
            tag = engine
            # lines
            _, out = run(zg, [engine, "-H", "needle"], root)
            check(f"{tag} no NUL in output", b"\x00" not in out)
            got = {}
            for line in out.split(b"\n"):
                if not line:
                    continue
                path, _, text = line.partition(b":")
                got.setdefault(path.decode(), []).append(text)
            exp = {p: l for p, l in want.items() if l}
            check(f"{tag} lines", {p: sorted(v) for p, v in got.items()} == {p: sorted(v) for p, v in exp.items()},
                  f"diff={sorted(set(got) ^ set(exp))[:5]}")
            # -c
            _, out = run(zg, [engine, "-c", "needle"], root)
            counts = {l.rsplit(b":", 1)[0].decode(): int(l.rsplit(b":", 1)[1]) for l in out.split(b"\n") if l}
            check(f"{tag} -c", counts == {p: len(l) for p, l in want.items()},
                  f"diff={[(p, counts.get(p), len(want[p])) for p in want if counts.get(p) != len(want[p])][:4]}")
            # --count-matches (one needle per matching line in this tree)
            _, out = run(zg, [engine, "--count-matches", "needle"], root)
            cm = {l.rsplit(b":", 1)[0].decode(): int(l.rsplit(b":", 1)[1]) for l in out.split(b"\n") if l}
            check(f"{tag} --count-matches", cm == {p: sum(x.count(PAT) for x in l) for p, l in want.items()},
                  f"diff={[(p, cm.get(p)) for p in want if cm.get(p) != sum(x.count(PAT) for x in want[p])][:4]}")
            # -l / -L
            _, out = run(zg, [engine, "-l", "needle"], root)
            check(f"{tag} -l", set(out.decode().split()) == {p for p, l in want.items() if l})
            _, out = run(zg, [engine, "-L", "needle"], root)
            check(f"{tag} -L", set(out.decode().split()) == {p for p, l in want.items() if not l})
            # -l for a pattern that only occurs after the late NUL
            _, out = run(zg, [engine, "-l", "tail"], root)
            check(f"{tag} -l after NUL", out == b"", out[:200])
            # --json
            _, out = run(zg, [engine, "--json", "needle"], root)
            check(f"{tag} --json no NUL", b"\x00" not in out)
            jm = {}
            for line in out.split(b"\n"):
                if line:
                    ev = json.loads(line)
                    if ev.get("type") == "match":
                        jm[ev["path"]] = jm.get(ev["path"], 0) + 1
            check(f"{tag} --json", jm == {p: len(l) for p, l in want.items() if l})
        # --binary-files policies (never any binary content on stdout).
        binaries = {os.path.join(root, r): d for r, d in files.items() if model(d) is None}
        def fmt(d):
            return "pdf" if d.startswith(b"%PDF-") else "nul"
        def has_needle(d):
            return PAT in d
        p = subprocess.run([zg, "--binary-files=note", "needle", root], capture_output=True)
        notes = sorted(l for l in p.stderr.decode().splitlines() if "binary file skipped" in l)
        want_notes = sorted(f"zgrep: {b}: binary file skipped ({fmt(d)})" for b, d in binaries.items())
        check("note: one stderr line per binary, with its format", notes == want_notes, f"{notes[:3]} vs {want_notes[:3]}")
        check("note: stdout unchanged", p.stdout == run(zg, ["needle"], root)[1])
        p = subprocess.run([zg, "--binary-files=binary", "needle", root], capture_output=True)
        hits = sorted(l for l in p.stderr.decode().splitlines() if "binary file matches" in l)
        want_hits = sorted(f"zgrep: {b}: binary file matches ({fmt(d)})" for b, d in binaries.items() if has_needle(d))
        check("binary: stderr names exactly the matching binaries", hits == want_hits, f"{hits[:3]} vs {want_hits[:3]}")
        check("binary: no binary content on stdout", b"\x00" not in p.stdout and p.stdout == run(zg, ["needle"], root)[1])
        _, out = run(zg, ["--binary-files=binary", "-l", "needle"], root)
        check("binary: -l lists matching binaries too",
              set(out.decode().split()) == {p for p, l in want.items() if l} | {b for b, d in binaries.items() if has_needle(d)})
        _, out = run(zg, ["--binary-files=binary", "-c", "needle"], root)
        counts = {l.rsplit(b":", 1)[0].decode(): int(l.rsplit(b":", 1)[1]) for l in out.split(b"\n") if l}
        check("binary: -c counts the binary's lines",
              all(counts[b] == sum(1 for x in d.split(b"\n") if PAT in x) for b, d in binaries.items()))
        lone = os.path.join(root, "small_nul_window.bin")
        check("binary: rc 0 on a matching binary", run(zg, ["--binary-files=binary", "-q", "needle"], lone)[0] == 0)
        check("default: rc 1 on the same binary", run(zg, ["-q", "needle"], lone)[0] == 1)
        p = subprocess.run([zg, "--stats", "needle", root], capture_output=True)
        line = next((l for l in p.stderr.decode().splitlines() if l.startswith("binary:")), "")
        nfmt = {}
        for d in binaries.values():
            nfmt[fmt(d)] = nfmt.get(fmt(d), 0) + 1
        check("--stats counts binaries per format",
              f"binary_files={len(binaries)}" in line and all(f"{k}:{v}" in line for k, v in nfmt.items()), line)
        # -a: everything is text, so the late lines DO come back.
        _, out = run(zg, ["-a", "-c", "needle"], os.path.join(root, "small_nul_late.bin"))
        check("-a reads past the NUL", out.strip() == b"4", out)
        print(f"TOTAL {passed} pass / {failed} fail")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return 0 if failed == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
