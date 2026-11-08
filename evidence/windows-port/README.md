# Native Windows ZiGrep port evidence

**Status:** local native Windows verification passed; the added GitHub Actions
Windows job has not yet run remotely.

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
