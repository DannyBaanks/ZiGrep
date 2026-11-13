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

### 1b. The same manifest, regenerated for the 0.3.1 round (2026-11-10)

The `GUIA.md` entry changes on every documentation round, so the manifest is
regenerated the same way (LF-canonical bytes taken from the git index, i.e.
exactly what the commit stores) and re-verified against the committed blobs.
The `GUIA.md` entry after the 0.3.1 round:

```text
F4031A8B1BB2803EDC7B5302A03661F11FD2C370F1FEDF00E7ACBA31592DA7AC  GUIA.md
```

The entry for this `README.md` cannot be quoted here: any edit to this file
changes its own hash, so the manifest is the only place where it is written.
Re-verify the whole manifest with `sha256sum -c evidence/windows-port/SHA256SUMS.txt`
(after checking out with LF endings).

Note that the manifest lists the paths with `/` separators: the older entry
used `\`, which is not what `sha256sum -c` expects on a POSIX host.

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

---

## Release verification (2026-11-09) and the third bug: a release binary that
## could not start

The Windows installer was verified end to end against the **published**
GitHub release (not a local mock): `irm` the installer from the `v0.2.0` tag,
execute it, and check what it installed.

### What the published release did

```text
  ==> Architecture: x86_64
  ==> Install directory: C:\Users\progr\AppData\Local\Programs\ZiGrep
  ==> Downloading zigrep-windows-x86_64.zip
  ==> Verifying SHA-256
  OK  checksum matches (2dd2fe1261b179a48369adcde9beca653be65989c05a039ff9690d9d0a1e3fdd)
  ==> Extracting
  OK  installed 2 executable(s) into C:\Users\progr\AppData\Local\Programs\ZiGrep
  OK  added C:\Users\progr\AppData\Local\Programs\ZiGrep to the user PATH
    ZiGrep is ready.
  exit=-1073741795
```

The install worked, the checksum matched, the files were copied and the user
`PATH` was updated. **The installed binary then died immediately**:

```text
version reportada    : (empty)
busqueda:            : (empty)
exit=-1073741795
```

`-1073741795` is `0xC000001D` = `STATUS_ILLEGAL_INSTRUCTION`: the process was
killed by the CPU before `main()` ran.

### Root cause

The release workflow built the Windows binary **without an explicit target**:

```yaml
- name: Build ReleaseFast (native Windows)
  run: zig build -Doptimize=ReleaseFast
```

Without `-Dtarget`, Zig builds for `native`, which means "whatever CPU this
runner happens to have". The `windows-latest` runner reports AVX-512, so the
published binary contained AVX-512 instructions and could not start on any
x86_64 CPU without them (Haswell, Broadwell, Zen 1, ...).

### Evidence

Instruction-prefix census over the `.text` section (EVEX `0x62` is the
AVX-512 prefix, VEX `0xC4`/`0xC5` is AVX/AVX2):

```text
release (CI):         EVEX(0x62)=3499   VEX(0xC4/0xC5)=11671
local build (this host): EVEX(0x62)= 144   VEX(0xC4/0xC5)=12486
```

Cross-check by compiling the same source for different targets and running
each one on this host (Xeon E5-2678 v3, **no AVX-512**):

| Build | Starts on this CPU |
|---|---|
| `-Dtarget=x86_64-windows` (baseline SSE2) | **yes** |
| `-Dtarget=x86_64-windows -Dcpu=skylake_avx512` | **no** (same crash) |
| `native` on this host (AVX2) | yes |
| published `v0.2.0` (`native` on the AVX-512 runner) | **no** |

### Fix and cost

The workflow now builds for the explicit baseline target and verifies that
the binary starts before packaging it:

```yaml
run: zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast

- name: Verify the binary runs
  shell: pwsh
  run: |
    & .\zig-out\bin\zigrep.exe --version
    if ($LASTEXITCODE -ne 0) { throw "zigrep.exe --version failed with $LASTEXITCODE" }
```

Performance cost, measured on this host (2,639 files / 522,454,982 bytes,
`-F "pub fn"`, 3 warm-up rounds then 10 timed runs):

| Build | Mean | Median | Min | Max |
|---|---|---|---|---|
| baseline `x86_64-windows` (SSE2) | 143.4 ms | 139.6 ms | 122.9 ms | 164.1 ms |
| `native` on this host (AVX2) | 141.2 ms | 139.7 ms | 123.7 ms | 172.0 ms |

**1.6% difference**, inside the run-to-run noise: the workload is I/O bound.

### A fourth bug in the installer: the source-build fallback cloned the wrong
### ref

When the download failed, the installer fell back to building from source and
cloned the **default branch** (`main`), which does not carry the Windows port.
The fallback therefore built code that does not even compile on Windows. It
now clones the release tag, and for `latest` it resolves the real tag through
the GitHub API:

```powershell
$cloneRef = $null
if ($Version -eq "latest") {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" ...
    $cloneRef = $rel.tag_name
} else {
    $cloneRef = $Version
    if (-not $cloneRef.StartsWith("v")) { $cloneRef = "v$cloneRef" }
}
git clone --depth 1 --branch $cloneRef "https://github.com/$Repo.git" $repoDir
```

### Release outcome

* **`v0.2.0`** was published and then found to ship an unusable Windows
  binary. It is **superseded** and is left in place as a record (releases are
  not rewritten).
* **`v0.2.1`** is the first release with the baseline binary, the installer
  fix and the corrected fallback.

### A network note (not a defect in the release)

The first attempt to download the freshly published assets returned
`HTTP 504 Gateway Time-out` from this host, while the same assets downloaded
normally a few minutes later and the published `SHA256SUMS.txt` downloaded
immediately. All three assets of `v0.2.0` were verified byte for byte
against the published checksums once the CDN had propagated:

```text
OK   zigrep-linux-x86_64.tar.gz   0e66d6d2f44309f3e9b325fb63d6ab7e68e1e7887b5604c545f2255f21c4bfd7
OK   zigrep-linux-aarch64.tar.gz  14eac390f29ab651d43260eea3e34348d765e00027202318c320c3e7a9c3ce3f
OK   zigrep-windows-x86_64.zip    2dd2fe1261b179a48369adcde9beca653be65989c05a039ff9690d9d0a1e3fdd
```

---

## Release v0.2.1 verification and the fifth bug: the installer aborted on a
## successful install

### v0.2.1 was published and its binary works

The workflow run `42570222825` completed all four jobs successfully, including
the new step:

```text
JOB: Build native Windows binary  ->  success
    success  Build ReleaseFast (native Windows)
    success  Verify the binary runs
    success  Package the Windows executables
    success  Upload asset
JOB: Build Linux binaries (aarch64-linux, ...)  ->  success
JOB: Build Linux binaries (x86_64-linux, ...)   ->  success
JOB: Publish GitHub Release  ->  success
```

The published assets were verified byte for byte against the published
`SHA256SUMS.txt` (3/3 OK):

```text
published SHA256SUMS.txt (v0.2.1): 3 entries
  bdce7e875998f2b642c4bcb25fccc6e619ebd476e67c93477a92cfbdd1e6f97e  zigrep-linux-x86_64.tar.gz
  505925d9c17b7c416ab4fcd1654fa3ff8f28a642dfd85d8ed04231600534e7ca  zigrep-linux-aarch64.tar.gz
  905845afe15370a5031dfda67d7539be98bc8762fb674ad200818cf63c75688f  zigrep-windows-x86_64.zip

OK    zigrep-linux-x86_64.tar.gz   bdce7e87...   (285080 bytes)
OK    zigrep-linux-aarch64.tar.gz  505925d9...   (1305401 bytes)
OK    zigrep-windows-x86_64.zip    905845af...   (682517 bytes)

=== 3/3 assets verificados contra el SHA256SUMS.txt publicado ===
```

The published Windows binary now starts on this host (no AVX-512):

```text
=== contenido del zip publicado ===
    install.ps1   9571
    zgrep.exe   988160
    zigrep.exe  988160

=== census EVEX ===
zigrep.exe: EVEX(0x62)=149  VEX(0xC4/0xC5)=1780     (v0.2.0: 3499 EVEX)

=== ARRANCA? ===
zgrep 0.2.1
exit=0
```

149 EVEX prefixes instead of 3,499: the baseline target did what it was
supposed to do.

### The installer aborted on a successful install

Running the **published** installer end to end (`irm` the installer from the
tag, execute it) installed everything correctly and then died:

```text
==> Downloading zigrep-windows-x86_64.zip
==> Verifying SHA-256
OK  checksum matches (905845afe15370a5031dfda67d7539be98bc8762fb674ad200818cf63c75688f)
==> Extracting
OK  installed 2 executable(s) into C:\Users\progr\AppData\Local\Programs\ZiGrep
OK  added C:\Users\progr\AppData\Local\Programs\ZiGrep to the user PATH

  Version check:
powershell : zigrep.exe : zgrep 0.2.1
En línea 69 Carácter: 5
+     & (Join-Path $InstallDir "zigrep.exe") --version
    + CategoryInfo          : NativeCommandError
```

The install was healthy; the installer still died, before printing
"ZiGrep is ready.".

### Root cause

Two facts combined:

1. `zigrep --version` printed on **stderr** (upstream used `std.debug.print`
   for it). The version is an answer, not a diagnostic.
2. In Windows PowerShell, a native command writing to stderr produces a
   `NativeCommandError`, and the installer sets `$ErrorActionPreference =
   "Stop"` (it needs that to refuse to install when the checksum does not
   match). Under `Stop`, that error is **terminating**.

So the last line of a successful installation killed the installer. The same
trap applied to `git clone` ("Cloning into ...") and `zig build` in the
source-build fallback.

### Fix

**The CLI answers on stdout.** `--version` and `--help` are printed with
`platform.writeStdout`, and `parseArgs` no longer writes to any stream: it
sets `opts.print_version` / `opts.print_help` and lets the caller choose the
stream. That also matches `parseArgs`' own documented contract ("`parseArgs`
itself never writes to a stream, which keeps it testable") and the behaviour
of `grep` and `ripgrep`.

```zig
    if (opts.print_help or opts.print_version) {
        if (opts.print_version) {
            _ = platform.writeStdout(init.io, std.fmt.comptimePrint("zgrep {s}\n", .{version}));
        } else {
            _ = platform.writeStdout(init.io, usage);
        }
        std.process.exit(0);
    }
```

**The installer cannot be killed by a child's stderr.** Every native command
goes through `Invoke-Native`, which runs with the error preference relaxed
inside the function's own scope, captures the output and returns the exit
code:

```powershell
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$Capture
    )
    $ErrorActionPreference = "Continue"
    if ($Capture) {
        $raw = & $FilePath @Arguments 2>&1
        $code = $LASTEXITCODE
        $parts = foreach ($item in $raw) {
            if ($item -is [System.Management.Automation.ErrorRecord]) { $item.ToString() }
            else { [string]$item }
        }
        return [pscustomobject]@{ Output = (($parts -join "`n")).Trim(); ExitCode = $code }
    }
    & $FilePath @Arguments
    return [pscustomobject]@{ Output = ""; ExitCode = $LASTEXITCODE }
}
```

### Verification

The installer now completes and the binary answers on stdout:

```text
  Version check:
    zgrep 0.2.1

  Try it:
    zigrep --help
    zigrep -n TODO src

  ZiGrep is ready.
  exit=0
```

```text
stdout: 'zgrep 0.2.1'
stderr: ''
exit=0
```

A regression test covers the new parser contract:

```zig
test "parseArgs: --version and -V ask for the version instead of searching" {
```

The suite is now **55/55 tests passed** (native and baseline
`x86_64-windows`), and the differential oracle still reports **25 PASSED,
0 FAILED**.

### Release outcome after this fix

* **`v0.2.0`**: superseded (the binary could not start without AVX-512).
* **`v0.2.1`**: superseded (the binary is fine, but the installer inside it
  aborted on the version check).
* **`v0.2.2`**: the current release. Baseline binary, installer that
  completes, `--version` on stdout.

---

## Release v0.2.2: the release that installs cleanly (final verification)

### The workflow

The release run `42574402048` completed all four jobs successfully:

```text
JOB: Build native Windows binary  ->  success
JOB: Build Linux binaries (aarch64-linux, ...)  ->  success
JOB: Build Linux binaries (x86_64-linux, ...)   ->  success
JOB: Publish GitHub Release  ->  success
```

### The published assets

All three archives were downloaded and verified byte for byte against the
published `SHA256SUMS.txt`:

```text
published SHA256SUMS.txt (v0.2.2): 3 entries
  f9a6198b023a7cf44454bd23b5216c7106d8d892b16810eafa5a9c120a6d3174  zigrep-linux-x86_64.tar.gz
  40bf3ce12bf44e9134763ba9a7381c47de63d0e081dfdaf946d6635f3ed5737f  zigrep-linux-aarch64.tar.gz
  c6d07401109d4a47ceb31170543e691a3d131b9c84a1d1f19dcd667871a84543  zigrep-windows-x86_64.zip

OK    zigrep-linux-x86_64.tar.gz   f9a6198b...   (285031 bytes, 1 intento(s))
OK    zigrep-linux-aarch64.tar.gz  40bf3ce1...   (1305803 bytes, 1 intento(s))
OK    zigrep-windows-x86_64.zip    c6d07401...   (682740 bytes, 1 intento(s))

=== 3/3 assets verificados contra el SHA256SUMS.txt publicado ===
```

### The one-line installer, executed against the published release

The installer was fetched with `irm` from the public tag URL and executed
with `iex`, from a clean state (no install directory, not in the user
`PATH`):

```text
=== 0. estado inicial ===
  install dir existe : False
  ya esta en el PATH  : False
=== 1. descargar el instalador (irm) ===
  descargado: 11536 caracteres
  primera linea: <#
=== 2. ejecutar el instalador real (irm | iex) ===

  ZiGrep - native Windows installer
  (Windows-native build; no WSL, no C runtime needed)

==> Architecture: x86_64
==> Install directory: C:\Users\progr\AppData\Local\Programs\ZiGrep
==> Downloading zigrep-windows-x86_64.zip
==> Verifying SHA-256
OK  checksum matches (c6d07401109d4a47ceb31170543e691a3d131b9c84a1d1f19dcd667871a84543)
==> Extracting
OK  installed 2 executable(s) into C:\Users\progr\AppData\Local\Programs\ZiGrep
OK  added C:\Users\progr\AppData\Local\Programs\ZiGrep to the user PATH

  Restart your terminal (or open a new one) so the PATH change applies.

  Version check:
    zgrep 0.2.2

  Try it:
    zigrep --help
    zigrep -n TODO src

  ZiGrep is ready.
  exit=0
=== 3. verificacion ===
  zigrep.exe instalado : True
  zgrep.exe  instalado : True
  install.ps1 copiado  : True
  version reportada    : zgrep 0.2.2
  install dir en PATH   : True
=== 4. uso real del binario instalado ===
  busqueda: 2:needle
=== 5b. el binario responde por stdout (no stderr) ===
  stdout : 'zgrep 0.2.2'
  stderr : ''
  exit   : 0
=== 6. PATH de usuario restaurado ===
  install dir sigue en el PATH: False
=== fin ===
```

Everything the installer claims is true: the checksum matched, three files
were installed, the user `PATH` was updated, the version check answered
**cleanly** (no `NativeCommandError` any more), the installer reached
"ZiGrep is ready." with exit code 0, and the installed binary actually
searched (`2:needle` is line 2 of the probe file, which is where `needle`
was written).

The harness restored the user `PATH` to its original state afterwards, so the
machine was left as it was found.

### Final state of the release line

| Release | State |
|---|---|
| `v0.2.0` | Published, superseded: the Windows binary was built for `native` on an AVX-512 runner and cannot start without AVX-512. |
| `v0.2.1` | Published, superseded: the binary is baseline, but the installer inside it aborted on its own successful install. |
| `v0.2.2` | **Current.** Baseline binary, installer that completes, `--version` on stdout, verified end to end against the published release. |

### Gates measured for the shipped commit (`701361e`)

| Gate | Result |
|---|---|
| `zig build -Doptimize=ReleaseFast` | 11/11 steps succeeded |
| `zig build test` | 55/55 tests passed |
| `zig build test -Dtarget=x86_64-windows` | 55/55 tests passed |
| `zig build oracle` | 25 PASSED, 0 FAILED |
| `zig build oracle -Dtarget=x86_64-windows` | 25 PASSED, 0 FAILED |
| `zig build -Dtarget=x86_64-linux` | 11/11 steps succeeded |
| fuzz swarm (12 campaigns x 200,001 ops) | 0 anomalies, 0 crashes, 0 invalid exit codes, 0 invariant violations, 0 hangs |
| cell fuzzer (exhaustive 373,248 cells) | 10.28 s, 36,300 cells/sec, 0 anomalies, 0 invariant violations, 0 crashes |

## Re-audit of the 66 new upstream commits on native Windows (2026-11-12)

`v0.3.2` was published upstream with the 66 new commits already in it. This
campaign re-audited that new code **on Windows**, by running it, not by
reading the diff. Five bugs were found, fixed and pinned by tests; the
release that carries the fixes is `v0.3.3` (tagged commit `05f126b`).

### Environment

| | |
|---|---|
| Host | Windows 11 build 26200, x86_64, **Xeon E5-2678 v3 (no AVX-512)** |
| Toolchain | Zig 0.16.0 (`zig-x86_64-windows-0.16.0`) |
| Target | `x86_64-windows` (baseline, SSE2), `ReleaseFast` |
| References | GNU grep 3.0 (Git for Windows), ripgrep 15.0.0 |

### Bug 1 — `--cache` / `--spill` read `HOME` with no `USERPROFILE` fallback

`src/main.zig` resolved the home with `init.environ_map.get("HOME") orelse "."`.
PowerShell and cmd do **not** define `HOME` (only Git Bash and MSYS do), so
on a plain Windows session:

* `--cache` listed `<cwd>/.cache/zig` as if it were the global Zig cache, and
  offered to **delete** it;
* `--spill` wrote its spill file into the current directory.

Measured before the fix (HOME removed from the environment):

```
   #  tamano  estado      ruta
   1   4.1K  segura     .\.cache\zig
```

After the fix (one resolver: `HOME` wins, `USERPROFILE` is the fallback):

```
   1     0B  segura     C:\Users\progr\AppData\Local\Temp\...\profile\.cache\zig
```

and `--spill` writes under `USERPROFILE`, with 0 files left in the cwd.
Fix: `pickHome()` / `homeDir()` + the unit test
`pickHome: HOME wins, USERPROFILE is the Windows fallback`.

### Bug 2 — `--pre` was dead code on every platform

`preApplies()` received an empty glob when `--pre-glob` was absent, and
`globMatch(text, "")` is `false` (an empty pattern only matches an empty
text). Every file was therefore excluded from the pre-processing and zgrep
searched the **file** instead of the command's output, with no error and no
warning.

Proof with a marker that can only come from the command's stdout:

```
$ zgrep --pre "cmd /c echo needle DESDE-PRE" needle pre.txt
PRE needle here          <-- before: the file's own lines
needle two

$ zgrep --pre "cmd /c echo needle DESDE-PRE" needle pre.txt
needle DESDE-PRE pre.txt <-- after: the command's output
```

Fix: an absent or empty `--pre-glob` means "every file" + the unit test
`preApplies: without --pre-glob every file goes through --pre`.

### Bug 3 — `-q` did not always win

zgrep kept the **last** mode, so the answer depended on the order of the
flags. GNU grep and ripgrep print nothing with `-q -c` / `-q -l` whatever the
order.

```
$ zgrep -q -c needle a.txt     ->  1        (before)      -> (nothing) (after)
$ zgrep -c -q needle a.txt     ->  (nothing) (before)     -> (nothing) (after)
$ zgrep -q -l needle a.txt     ->  a.txt    (before)      -> (nothing) (after)
```

Fix: `-q` is a sticky flag that wins over every mode that prints + the unit
test `parseArgs: -q wins over -c / -l / -L in any order`.

### Bugs 4 and 5 — the differential fuzzer's verdict was meaningless

Both in `scripts/tri_fuzz.py`:

* the report was written without `encoding="utf-8"`, so the raw-byte
  patterns of knob 6 raised `UnicodeEncodeError` and **the whole run was
  lost**;
* zgrep was run **without** `-n` while ripgrep and GNU grep were run **with**
  `-n`. `keys()` extracts `path:line`, so zgrep's key was
  `path:<first fragment of the text>` and the references' key was
  `path:<line number>`: two key spaces that never intersect.

Measured on Windows, the **same** 250 knob-1 cases:

```
before:  all_differ=239  agree_all=11
after:   agree_all=250
```

The path separator is now normalized too (`\` -> `/`), because on Windows
zgrep and ripgrep print `src\file.zig` while Git-for-Windows' grep prints
`src/file.zig`.

### The divergences that remain are not zgrep bugs

With the comparator fixed, knobs 2-6 still differ from the references. Every
divergence over 1,250 cases was classified:

| Cause | Cases |
|---|---|
| zgrep agrees with ripgrep, GNU grep differs | 230 |
| all three different (regex dialect) | 87 |
| zgrep agrees with GNU grep, ripgrep differs | 60 |
| exit code differs | 47 |
| both references abort (rc=2) on a pattern zgrep accepts | 28 |
| **zgrep alone, with both references agreeing on the same set** | **0** |

### Gates on the tagged commit `05f126b` (native Windows, baseline target)

| Gate | Result |
|---|---|
| `zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast` | 13/13 steps succeeded |
| `zig build test` | 167 pass / 1 skip (`io_uring`, Linux-only) |
| `zig run scripts/oracle.zig` (GNU grep 3.0 + ripgrep 15.0.0) | 31 PASSED, 0 FAILED |
| `zig build fuzz` | 100,001 ops, **0 anomalies** |
| `zig build cell-fuzz` | 1,000 cells, **0 anomalies** |
| `scripts/tri_fuzz.py` knobs 1-6, 250 cases each | all six knobs exit 0; knob 1 = `agree_all=250/250` |
| `zig build -Dtarget=x86_64-linux` | 13/13 steps succeeded |
| `zig build -Dtarget=aarch64-linux` | 13/13 steps succeeded |
| CI (PR #3, run `43374008421`) | Linux and Windows jobs, both green |

### The published `v0.3.3` assets

```
5cff7d1cc11c489f34cc0e9b8be3471ccce217d0a5a3b0e9c22ee1e37c220da4  zigrep-linux-x86_64.tar.gz
cc4a2914a4cc405b3ee93591b9fa37a3be05594981d3dfd060b97b07848e43bd  zigrep-linux-aarch64.tar.gz
9337d5ff723f2957f70995d4cc2a889054a4875a60aac436080b75d76d99b91e  zigrep-windows-x86_64.zip
```

3/3 assets re-downloaded and verified byte for byte against the published
`SHA256SUMS.txt`.

The Windows `.exe` was disassembled with `objdump -d`:

| | |
|---|---|
| Instructions | 208,398 |
| `zmm` registers (AVX-512) | **0** |
| Mask registers `%k0`-`%k7` | **0** |
| EVEX-prefixed `v*` instructions | **0** |

It starts and answers on this AVX2-only host: `zgrep 0.3.3` (exit 0).

The published installer was then run **for real**, with the one-liner the
user types, against the published release. The full transcript is in
[`GUIA.md`](../../GUIA.md#salida-real-del-instalador-publicado-v033); the
essentials: `exit=0`, `errores en la consola: 0` (no `RemoteException`),
`OK checksum matches (9337d5f…)` (the published hash), 2 executables plus
`install.ps1` installed, `--version` on stdout with an empty stderr, the
`-q -c` and `--pre` fixes confirmed **in the installed binary**, the
scenario that aborted in 0.3.0 (a pre-existing `$InstallDir`) installing
cleanly and leaving the user's variable untouched, and the machine restored
afterwards (no install dir, no `PATH` entry).

### NOT_DEMONSTRATED (this round)

* **Linux numbers**: not measured here; this campaign ran on Windows. The
  Linux figures are the CI's.
* **Windows performance**: not measured. This release is a fix release, not
  a benchmark release; `benchmark.json` in this folder is from the earlier
  campaign and is not re-measured.
* **`pwsh` (PowerShell Core), Windows ARM64 and `install.sh` (POSIX)**: not
  executed.
* **The Python binding** beyond its own test suite.

### Two false alarms that were NOT bugs (kept, so they are not re-investigated)

* `--exec` and `--pre` appeared to "do nothing" in the first harness of this
  round. The harness was wrong: the command line was missing the `PATTERN`.
  The correct order is `zgrep --exec CMD PATTERN PATH`; without the pattern,
  the file became the pattern and zgrep searched stdin, answering "no match"
  with exit code 1 — the correct behaviour for an empty stdin. With the
  right order, 11/11 `--exec`/`--pre` checks pass.
* The mojibake in `--setup` / `--cache` output (`m├maqu├¡na`) is **not** a
  binary bug: the bytes are valid UTF-8 (checked byte by byte). The Windows
  console defaults to code page 850 and decodes UTF-8 as cp850. `chcp 65001`
  fixes the display; a pipe is unaffected. Documented in `GUIA.md`.

