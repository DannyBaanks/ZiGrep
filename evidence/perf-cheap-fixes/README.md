# Cheap fixes from the Gemini review (2026-11-12)

Each fix: same-output check against the previous binary, then `hyperfine -N`
with warmup 3 and 20 runs, on `bench-corpus/synthetic` (131 MB, 2,000 files,
warm page cache, `--io-engine=sync`). The run order is A-then-B, then
repeated with B-then-A. The host was loaded (load average 7-9), so only a
difference that survives both orders counts.

## Fix 4: line cursor in the fast path (`src/scan.zig`)

Before, every match walked each intermediate line with `findScalarPos`, even
with `-n` off (the default since 0.4.0). Now there is one backward
`findScalarLast` to find the line start, and the separators are counted with
`countScalar` only when line numbers are printed.

Output identical to the previous binary for `-c`, plain, `-n`, `-n -b` and
`--crlf -n` (compared with `--sort`).

| Query | Order A→B (before, after) | Order B→A (after, before) | Verdict |
|---|---|---|---|
| `-c ZGREP_PLANTED_TOKEN` (195,467 matching lines) | 13.8 → 10.1 ms (1.37×), user 49.9 → 20.8 ms | 14.5 → 9.5 ms (1.54×), user 50.7 → 19.4 ms | **faster, both orders** |
| `ZGREP_RARE_TOKEN` (few matches) | 11.8 → 9.4 ms (1.25×) | 8.9 → 8.9 ms (1.01 ± 0.06) | **no difference**; the first number was order/noise |
| `-n ZGREP_RARE_TOKEN` | 10.3 → 9.1 ms (1.14 ± 0.31) | not repeated | inside the noise |

Raw data: `h4_*.json` (A→B) and `h4r_*.json` (B→A).

## Fix 3: partial batches through io_uring (`src/kamikaze.zig`): NOT ADOPTED

The ring only took full batches of 16 (`start + BATCH_SIZE <= len`), so
directories with 1-15 files, and the tail of bigger ones, used the
synchronous path. The change sent partial batches through the ring as well
(`scanAsyncBatch` accepts up to 16). Output was identical in 6 combinations.

Measured COLD: every file's pages were evicted with
`posix_fadvise(POSIX_FADV_DONTNEED)` before each run (`evict.py` as
hyperfine `--prepare`). Forced `--io-engine=uring -c ZGREP_PLANTED_TOKEN`,
12 runs.

| Corpus | Order A→B (before, with fix) | Order B→A (with fix, before) | Verdict |
|---|---|---|---|
| synthetic (131 MB, 69 dirs) | 301.8 → 327.0 ms | 340.1 vs 311.0 ms | **fix 1.08-1.09× SLOWER, both orders** |
| corpus_1000 (33 MB) | 125.2 → 125.0 ms | 126.2 vs 121.7 ms | tie to 1.04× slower |

Partial batches through the ring cost more than they save on this host. The
change was reverted, and the original condition is probably deliberate even
though nothing documents it. Raw data: `h3_*.json`.

Not tested: the other half of the review's item 3. A file of 256 KB or more is
read again in full after the ring read its first 256 KB. The corpora's files
are about 65 KB, so that path is never exercised; it needs its own corpus.

## Fix 5: `vfs.stat` on Linux (`src/vfs.zig`)

- NUL-terminates the path in a stack buffer, falling back to
  `page_allocator` only for paths of `PATH_MAX` or more. Before, every call
  did an mmap and a munmap.
- Asks `statx` for `SIZE` as well as `TYPE`. `.size` was returned from a field
  the kernel is not obliged to fill. On this kernel it is filled anyway:
  `--cache` reported a 3,000,000-byte cache as 3M before and after.

No speed is claimed: `vfs.stat` runs only when the directory entry type is
unknown (rare on ext4), for the roots, and in `--cache`.

## Gates after fixes 4 and 5

| Gate | Result |
|---|---|
| unit tests | 146/147 |
| oracle | 34/34 |
| conformance | 40/40 |
| batch / provenance / compact / spill / m9 | 41 / 71 / 45 / 66 / 446 |
| m9 and compact on a Debug binary | 446 / 45 |
| glob parity | 17/17 |
| setup check | 18/18 |
| fuzz | 100,001 operations, 0 anomalies |
| cell-fuzz | 388,800 cells, 0 anomalies |
| x86_64-windows build | compiles |
