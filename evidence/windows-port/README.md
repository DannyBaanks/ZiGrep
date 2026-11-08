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

## NOT_DEMONSTRATED (unchanged)

* **Linux runtime execution on this host**: the Docker daemon is not running,
  so only the Linux cross-compile was verified locally. The GitHub Actions
  `linux-build` job remains the authority for the Linux run.
* **Remote `windows-native` CI job**: configured, but it had not executed for
  this branch at the time of writing.

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

