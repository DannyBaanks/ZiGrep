# Native Windows ZiGrep port evidence

**Status:** local native Windows verification passed; the added GitHub Actions
Windows job has not yet run remotely.

This file is append-only for claims: each re-verification adds a new dated
section instead of rewriting an older one. The first re-verification below
(after upstream `492b506`) is kept as it was measured.

## Post-merge re-verification (2026-11-08, upstream `492b506` merged in)

The numbers captured below belong to the Windows port tree *before* the
upstream `492b506` work was merged in (the port was based on `30662a3`). After
resolving that merge the same checks were re-run on the merged tree, natively
on Windows 11 build 26200 with Zig 0.16.0:

| Check | Result |
|---|---|
| `zig build -Doptimize=ReleaseFast --summary all` | 7/7 steps succeeded |
| `zig build test --summary all` | 3/3 steps succeeded; 52/52 tests passed |
| `zig build -Doptimize=ReleaseFast oracle --summary all` | 10/10 steps succeeded; 24 PASSED, 0 FAILED (total 24) |
| `zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast` | 7/7 steps succeeded (cross-compile only) |

The oracle total is 24 on Windows instead of 25 because the `stdin pipeline
(pipe -> zigrep)` case is POSIX-only (it needs `sh -c` and `printf`); it is
skipped explicitly on Windows. The stdin feature itself was ported to the
native Zig I/O API and was checked manually on Windows:

```text
"alpha`nbeta`ngamma" | zigrep.exe -n beta   ->  2:beta
"alpha`nbeta`ngamma" | zigrep.exe -v beta   ->  1:alpha / 3:gamma
```

Linux *runtime* execution is **NOT_DEMONSTRATED** on this host: the Docker
daemon was not running, so only the Linux cross-compile was verified locally.
The GitHub Actions `linux-build` job remains the authority for the Linux run.

## Environment

- Captured: 2026-11-08 (local time, UTC-06:00)
- OS: Microsoft Windows 11 Home, build 26200
- CPU: Intel Xeon E5-2678 v3 @ 2.50 GHz; 24 logical processors
- Zig: 0.16.0
- GNU grep: 3.0 (Git for Windows)
- ripgrep: 15.0.0

## Verification

Commands were run from the ZiGrep repository root with native Windows
executables:

```powershell
zig build -Doptimize=ReleaseFast
zig build test --summary all
zig build oracle --summary all
```

Results: 43/43 unit tests passed and all 17 oracle cases passed against GNU
grep and ripgrep. A native smoke test searched a directory with spaces and
Unicode characters, returned the Unicode filename, and honored its
`.gitignore`. A separate generated 500-file corpus produced 24,405 matching
lines; `scripts/check.zig` reported sorted output identical for ZiGrep, grep,
and ripgrep. The Linux ReleaseFast target also cross-compiled successfully
from Windows; Linux runtime execution remains **NOT_DEMONSTRATED** on this
host.

Linux cross-compile command and result:

```powershell
$prefix = Join-Path $env:TEMP 'zigrep-linux-cross-check'
& $z build -Dtarget=x86_64-linux -Doptimize=ReleaseFast --prefix $prefix --summary all
```

```text
Build Summary: 7/7 steps succeeded
install success
```

The corpus was generated with seed `20261107`, 500 files, target 32,768 bytes
per file, 4 top-level directories, and 16 deep directories. The ground-truth
file reported 16,397,281 bytes, 317,351 lines, and 24,405 planted-token lines.

Generation command and captured output:

```powershell
$z = 'C:\Users\progr\AppData\Local\Temp\zig016-port\zig-x86_64-windows-0.16.0\zig.exe'
$out = Join-Path $env:TEMP 'zigrep windows benchmark corpus'
& $z run scripts\gen_corpus.zig -- "--out=$out" --files=500 --size=32768 --top=4 --deep=16 --seed=20261107
```

```text
gen_corpus: files=500 bytes=16397281 lines=317351 needle_lines=24405 rare_lines=3 in 1335 ms
gen_corpus: truth written to C:\Users\progr\AppData\Local\Temp\zigrep windows benchmark corpus.truth
```

## Benchmark

The exact per-run samples and command arguments are in
[`benchmark.json`](benchmark.json). The measured commands were:

```powershell
Set-Location 'C:\Development\ISyCo Git\Zigrep'
$z = 'C:\Users\progr\AppData\Local\Temp\zig016-port\zig-x86_64-windows-0.16.0\zig.exe'
$out = Join-Path $env:TEMP 'zigrep windows benchmark corpus'
$json = Join-Path $env:TEMP 'zigrep windows benchmark.json'
& $z run scripts\bench.zig -- --runs=10 --warmup=3 --bytes=16397281 "--out=$json" --name=zigrep .\zig-out\bin\zigrep.exe -F -H ZGREP_PLANTED_TOKEN $out --name=grep grep.exe -r -n -I -F -H ZGREP_PLANTED_TOKEN $out --name=rg rg.exe -n -F -H --no-ignore --hidden ZGREP_PLANTED_TOKEN $out
```

The captured table output was:

```text
| label          |  median ms |     min ms |     max ms |    mean ms |   stddev ms |       MB/s |  exit |
|---|---:|---:|---:|---:|---:|---:|---:|
| zigrep         |     40.133 |     33.407 |     44.981 |     40.033 |       3.974 |      408.6 |     0 |
| grep           |    253.389 |    166.116 |    365.579 |    253.229 |      70.816 |       64.7 |     0 |
| rg             |     43.361 |     36.947 |     47.670 |     42.881 |       3.501 |      378.2 |     0 |
```

| Tool | Median | Min–max | Throughput |
|---|---:|---:|---:|
| ZiGrep | 40.133 ms | 33.407–44.981 ms | 408.6 MB/s |
| GNU grep | 253.389 ms | 166.116–365.579 ms | 64.7 MB/s |
| ripgrep | 43.361 ms | 36.947–47.670 ms | 378.2 MB/s |

On this single warm-cache synthetic workload, ZiGrep was 6.31x faster than
GNU grep and 1.08x faster than ripgrep by median. This is not a general
Windows performance claim; the benchmark table in the project README remains
Linux-only.

## Evidence hashes

- Benchmark samples JSON:
  `FEF6A4AAB1C95EEAAAC9F4D0A09F1169865181A47AB440EE152602015BF80900`
- Generated corpus truth file:
  `A0B673E50F2DDF821D4946BA47960B8A36D55603AED643556EF23EA35162B3B1`
- Generated corpus tree digest (500 sorted relative paths and per-file
  SHA-256 values):
  `0D13F93C66D1AE102F116F1688AAEDFC861EB8711F16D8226B3B93A27DC001A9`

---

## Re-verification after upstream `d85b0b7` + `c40eaea` merged (2026-11-08)

The port branch absorbed two more upstream commits after the first
re-verification: `d85b0b7` (native Linux `io_uring`, `ZIGREP_THREADS`, `-N`)
and `c40eaea` (the adversarial fuzzer). The merge was semantic, not textual:
`src/uring.zig` became a portable facade and the real engine moved to
`src/uring_linux.zig`, because `std.os.linux.IoUring` cannot be compiled for
non-Linux targets (its errno enum differs from `std.c`).

Re-run natively on Windows 11 build 26200 with Zig 0.16.0
(`C:\Users\progr\AppData\Local\opencode-tools\zig-0.16.0\zig-x86_64-windows-0.16.0\zig.exe`):

| Check | Result |
|---|---|
| `zig build -Doptimize=ReleaseFast --summary all` | 9/9 steps succeeded (the step count grew because the fuzzer is now part of the default build) |
| `zig build test --summary all` | 3/3 steps succeeded; **54/54** tests passed (52 before + 2 new thread-count regression tests) |
| `zig build -Doptimize=ReleaseFast oracle --summary all` | 12/12 steps succeeded; **25 PASSED, 0 FAILED (total 25)** |
| `zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast` | **9/9** steps succeeded (cross-compile only; also proves `src/uring_linux.zig` still builds for Linux) |

The oracle total went from 24 to 25 because upstream added the `io_uring`
case. On Windows the `--uring` flag falls back to the synchronous workers and
the differential result is identical; the POSIX-only piped-stdin case is still
skipped there (25 checks on Windows, 26 on Linux).

## Adversarial fuzzing on native Windows (2026-11-08)

The upstream fuzzer was ported to Windows in this branch: `scripts/fuzz.zig`
now uses the portable `std.Io` API instead of raw Linux syscalls
(`std.os.linux` -> `builtin`, `linux.nanosleep` -> `std.Io.sleep`, the
executable path and the null device are chosen per platform), and
`scripts/tri_fuzz.py` derives the repository root from `__file__` instead of a
hardcoded Linux home path.

| Campaign | Command | Result |
|---|---|---|
| Swarm, all adversaries, entropy knob 3 | `fuzz.exe 3000 --seed=12345 --threads=8` | 3001 ops, **0 anomalies**, 0 crashes, 0 invalid exit codes, 0 invariant violations, ~2967 ops/s |
| Tri-way, knob 3 (grammar) | `py scripts/tri_fuzz.py 40 3` | 0 crashes, 0 timeouts, 0 anomalous discrepancies |
| Tri-way, knob 4 (ReDoS bait) | `py scripts/tri_fuzz.py 200 4` | 0 crashes, 0 timeouts, 0 anomalous discrepancies |
| Tri-way, knob 5 (chaos) | `py scripts/tri_fuzz.py 250 5` | 0 crashes, 0 timeouts, 0 anomalous discrepancies |
| Hang sweep, timeout-bounded | `py scripts/hunt_hang.py <binary>` | see below |

Scope note: the tri-way fuzzer compares **exit codes, crashes and timeouts**,
not output content. Content parity is what the differential oracle verifies.
The swarm's fourth adversary does check mathematical invariants
(`matches(P) + matches(-v P) == total_lines`, quiet-mode exit equivalence,
line-count invariants, BMH vs memchr equivalence).

### Bug found by the Windows fuzzing: unbounded worker pool

The fuzzer's CLI adversary and the timeout-bounded sweep (`scripts/hunt_hang.py`,
which puts a hard 3-second limit on every invocation -- the original fuzzer
had no timeout, so a hanging child was invisible to it) found a real defect:
an absurd thread count (`-j 18446744073709551615`, `--threads=...`, or the
`ZIGREP_THREADS` environment variable) reached the thread-spawn loop and turned
it into an endless create-and-exit cycle. The machine was pinned at 100% CPU
and the process did not respond to `taskkill /F` promptly (observed: 2321
seconds of accumulated CPU on a single thread, 0 handles).

The sweep against the **pre-fix** binary quantified it:

```text
phase 2 done: 452 hangs
phase 3 done: 452 hangs
==============================================================
  HANGING COMBINATIONS: 452
    -j 999999 filter build.zig
    -k -j 999999 searcher build.zig
```

Every hanging combination had the shape `-j <very large number>`. The trigger
is a **single file** (`build.zig`): with a directory operand the
single-directory fast path resolves before the swarm is reached.

The **same sweep** against the fixed binary found nothing:

```text
binary: ...\zigrep-e2e\build\bin\zigrep.exe
timeout: 3.0s
phase 1 done: 0 hangs
phase 2 done: 0 hangs
phase 3 done: 0 hangs
======================================================================
  No hanging combination found in this sweep.
```

That is the before/after pair for this defect: **452 hanging combinations
before the fix, 0 after**, over the same argument space.

Fix (this branch):

* The CLI rejects any count above **1024** with exit code 2 and the message
  `thread count out of range (max 1024)` (four call sites: `-j`,
  `--threads=`, `--threads`, and the `ZIGREP_THREADS` / `ZGREP_THREADS` /
  `THREADS` environment variables).
* `src/kamikaze.zig` clamps the pool to `max_threads = 1024` as a second line
  of defence for every other caller.
* Two regression tests in `src/main.zig` cover the boundary (1024 is still
  valid).

Measured behaviour after the fix:

```text
zgrep: thread count out of range (max 1024): '18446744073709551615'
try 'zgrep --help' for usage
exit=2 elapsed_ms=163
```

### Windows-specific adversarial probe

`scripts/adversarial_windows.py` builds a hostile tree (Unicode and spaces in
directory and file names, 12-level nesting, paths longer than 260 characters,
CRLF files, UTF-16 BOM files, NUL-containing binaries, `.gitignore`, symlinks,
empty directories, directories containing only subdirectories) and compares
ZiGrep against GNU grep case by case across the `ScanConfig` surface (`-v`,
`-m`, `-L`, `-c`, `-q`) and the Windows path surfaces.

## Windows installer end-to-end verification (2026-11-08)

`install.ps1` was verified by running it against a local HTTP server that
served exactly the release layout (`zigrep-windows-x86_64.zip` +
`SHA256SUMS.txt`), which is the same layout `.github/workflows/release.yml`
produces.

Happy path (real output):

```text
  ==> Architecture: x86_64
  ==> Downloading zigrep-windows-x86_64.zip
  ==> Verifying SHA-256
  OK  checksum matches (9a0142b678f33cd5fb76e4ff430f20db0502a4b52a5b338a16a46891c7f05c75)
  ==> Extracting
  OK  installed 2 executable(s) into <install dir>
  OK  added <install dir> to the user PATH
    Version check:
  zgrep 0.2.0
    ZiGrep is ready.
exit=0
```

Tampered-checksum path (real output):

```text
  ==> Verifying SHA-256
  ERR Checksum mismatch!
    expected: 0000000000000000000000000000000000000000000000000000000000000000
    actual  : 9a0142b678f33cd5fb76e4ff430f20db0502a4b52a5b338a16a46891c7f05c75
exit=1
NO debe haber instalado nada: False
```

The installer refuses to install anything when the checksum does not match,
and it needs no administrator rights (it appends to the **user** `PATH`).

## NOT_DEMONSTRATED

* **Linux runtime execution on this host**: the Docker daemon is not running,
  so only the Linux cross-compile was verified locally. The GitHub Actions
  `linux-build` job remains the authority for the Linux run.
* **Remote `windows-native` CI job**: configured, but it had not executed for
  this branch at the time of writing.
* **The swarm fuzzer under a cold filesystem cache**: every campaign above ran
  against the same warm working tree. A cold-cache run was not measured.

The exhaustive 373,248-cell sweep of the N-dimensional fuzzer is **not** in
this list: it was executed on native Windows (10.84 s, 0 anomalies).

---

## Correction: stale checksum entries (recorded 2026-11-08)

Two checksum findings were produced while re-verifying this evidence package.
They are recorded here instead of being silently repaired elsewhere.

### 1. `evidence/windows-port/SHA256SUMS.txt` had a stale `GUIA.md` entry

The manifest committed in `18bc3b4` contained this content (kept verbatim here
as the raw record):

```text
FEF6A4AAB1C95EEAAAC9F4D0A09F1169865181A47AB440EE152602015BF80900  evidence\windows-port\benchmark.json
710197F76A3E25A7951657DAF25EF4F1BFE37A4718CE278838FC6F3330ACA693  evidence\windows-port\README.md
E88E9403E075CC75F1DDCDFB4C77D243539694D841289A64409788FC545088F4  GUIA.md
```

`benchmark.json` and `README.md` still matched their committed blobs, but the
`GUIA.md` entry did **not**: the upstream merge `e38aed8` brought a new
`GUIA.md` section and the manifest was not updated with it. The manifest is
regenerated in this commit with the hashes of the content as git stores it
(LF, independent of `core.autocrlf`), and the three entries were re-verified
against the committed blobs after committing.

The hashes are computed over the **LF-canonical** bytes (what git stores), not
over the raw working-tree bytes: on this Windows host `core.autocrlf=true`
rewrites line endings on checkout, so a working-tree hash would not match a
blob hash and would not be reproducible on Linux.

### 2. The root `evidence/SHA256SUMS.txt` is stale and was left intact

The root manifest has 163 entries; **131 match** their committed blobs and
**32 do not**. Every stale entry points at a file that upstream or this branch
has since changed (`src/main.zig`, `src/scan.zig`, `src/search.zig`,
`src/kamikaze.zig`, `src/filter.zig`, `src/regex.zig`, `src/root.zig`,
`src/walk.zig`, `build.zig`, `README.md`, `GUIA.md`, `evidence/REPORT.md`,
`scripts/matcher_sweep.zig` and three `evidence/bench/*.json` files), and
several of them appear twice in the manifest.

That manifest was inherited from upstream and is deliberately **not**
regenerated here: rewriting it would destroy the historical record and mix
this branch's claims with upstream's. Its stale state is reported instead.
The only checksum index this branch owns is
`evidence/windows-port/SHA256SUMS.txt`, and that one is verified.

---

## Bug found by the Windows fuzzing (second one): the swarm could deadlock on
## `std.process.run`'s truncated reads

The first fuzzing campaign on Windows did not finish. The swarm completed all
200,001 operations and then **never returned**: a child process stayed alive
with 1 thread and 0% CPU while the parent waited for it. It was an
intermittent deadlock, reproduced in **4 of 12** campaigns.

### Diagnosis

The CLI adversary (adversary 2) runs real `zigrep` invocations through
`std.process.run` with `stdout_limit` / `stderr_limit` set to 4096 bytes.
`std.process.run` **stops reading** a stream once it exceeds the limit, but
the child keeps writing. On Windows a pipe holds 8 KB, so the child blocks
forever writing into a full pipe while the parent waits for it to exit.

Two controlled experiments (Python, same command line):

```text
=== A: el padre drena a EOF ===
  A leer-a-EOF: TERMINO exit=0 en 0.04s
      stdout=11130 stderr=0
=== B: el padre nunca lee ===
  B no-leer: COLGADO (>12s)
=== C: emula std.process.run (limite 4096) ===
  C limite-4096 (como run): TERMINO exit=0 en 1.01s
      leidos stdout=8192 stderr=0
```

The offending command line was captured with the `--trace-cli` diagnostic
added in this branch (paired `START`/`END` markers, one per spawned child):

```text
spawns=31 terminados=30 sin_terminar=1
  #14 SIN TERMINAR: zig-out/bin/zigrep.exe --no-hidden -e scan src
```

A minimal Zig probe isolated it from the fuzzer completely
(`std.process.run` with the fuzzer's exact options):

```text
calling std.process.run with limits 4096...
run returned error: StreamTooLong
EXIT=-1 t=294.2s
```

The same probe with the limits removed:

```text
calling std.process.run WITHOUT limits...
run returned OK: stdout=11130 bytes stderr=0 bytes after 57 ms
```

So the limit was the cause: 294 s versus 57 ms for the identical call.

The `run` timeout is not a substitute for draining the pipes. It works when
the child is direct (measured: `error Timeout after 3760 ms` for a silent
`ping.exe` child), but it does not help in the truncation case, because the
parent is not waiting for data, it is waiting for the child to exit.

### Fix

`scripts/fuzz.zig` now captures the child's streams with
`.stdout_limit = .unlimited` and `.stderr_limit = .unlimited`: the parent
always drains to EOF, so the child can never block on a full pipe. The
captured volume is bounded by the fuzzer's own corpus (the repository tree).

The `--cli-timeout-ms=N` watchdog (default 10000) was kept as a second line
of defence: a child that stops producing output and never exits is reported
as an anomaly, a reproducer is written to `evidence/reproducers/`, and the
swarm keeps going instead of hanging forever.

### Verification

Same harness, same seed, hard 90-second timeout on every campaign, before and
after the fix:

| State | Campaigns | Hangs | Result |
|---|---|---|---|
| Before the fix | 12 | **4** | swarm never returned |
| After the fix | 18 | **0** | every campaign finished |

Per-knob results after the fix (200,001 operations each):

| Knob | Campaigns | Wall clock | Anomalies | Crashes | Invalid exit codes | Invariant violations |
|---|---|---|---|---|---|---|
| 3 (grammar) | 10 | 2.2 - 2.6 s | 0 | 0 | 0 | 0 |
| 4 (ReDoS bait) | 4 | 5.3 - 5.6 s | 0 | 0 | 0 | 0 |
| 5 (chaos) | 4 | 3.4 - 3.6 s | 0 | 0 | 0 | 0 |

Throughput after the fix: 37,493 - 96,483 ops/second depending on the knob.

### Diagnostics added to the fuzzer

Two permanent flags were added so this class of failure can be diagnosed
instead of guessed at:

* `--trace-cli` prints every spawned CLI argv to stderr with a paired
  `START` / `END` marker, so a child that never finishes is identifiable.
* `--cli-timeout-ms=N` sets the hard limit for a CLI child (default 10000).
  On timeout the swarm counts an anomaly, writes a reproducer and continues.

## N-dimensional cell space fuzzer on native Windows

Upstream's `scripts/cell_fuzz.zig` (373,248 cells) was written against the
pre-port `scripts/common.zig` API and did not compile in this branch
(`scripts/cell_fuzz.zig:470:19: error: expected 3 argument(s), found 2`): the
Windows port moved `common.zig` to the io-first API, where every helper takes
an explicit `std.Io` handle. The cell fuzzer was ported accordingly
(`std.os.linux` -> `builtin`, `common.makePath/writeFile/readFile/nowNs/
printOut` now take the io handle, and the reproducer script points at the
platform's executable name).

After the port the whole build is **11/11 steps** (the new `cell_fuzz`
executable included) and the fuzzer runs natively on Windows 11 build 26200
with Zig 0.16.0.

### Measured results on native Windows

Single-cell diagnostic (`--cell=48291`):

```text
  Coordinates : [Mode:1, Mod:2, Engine:5, Pattern:16, Haystack:3]
  Output Mode : count (max_count=null)
  Modifiers   : fixed=no, icase=no, word=YES, invert=no
  Engine      : -j 12 (12 threads)
  Pattern     : '((((((searcher))))))' (deep nested parens, is_syntax_error=no)
  Haystack    : build.zig
  Verdict: 🟢 CELL #48291 PASSED ALL INVARIANTS CLEANLY!
```

Partial sweep (20,000 cells, Weyl dispersion):

```text
  Cells Executed             : 20000 / 20000
  Elapsed Wall Clock Time    : 0.639 seconds
  Execution Throughput       : 31297 cells/sec
    - Total Anomalies Found  : 0
    - Invariant Violations   : 0
    - Crashes / Panics       : 0
```

**Exhaustive sweep (all 373,248 cells)** — the run upstream measured on Linux:

```text
  Discrete Manifold Size: 373248 total unique cells (9 × 16 × 9 × 24 × 12)
  Test Range            : Cells 0 .. 373247 (373248 cells scheduled)
  Traversal Mode        : Entropic Coprime Weyl Dispersion (100% bijective)
  Parallel Workers      : 24 threads
  Cells Executed             : 373248 / 373248
  Elapsed Wall Clock Time    : 10.840 seconds
  Execution Throughput       : 34433 cells/sec

  State Space Breakdown:
    - Syntax Errors Rejected : 38880 (100% clean exit 2)
    - Matches Detected       : 138384
    - Zero Matches           : 195984

  Fuzzing Invariants & Safety:
    - Total Anomalies Found  : 0
    - Invariant Violations   : 0
    - Crashes / Panics       : 0
  Verdict: 🟢 ZERO ANOMALIES — All 373248 cell coordinates executed with mathematical precision!
```

The exhaustive 373,248-cell sweep is therefore **DEMONSTRATED on native
Windows**, not NOT_DEMONSTRATED: full coverage, 0 anomalies, 0 invariant
violations, 0 crashes, in 10.84 seconds (34,433 cells/second) on 24 workers.

