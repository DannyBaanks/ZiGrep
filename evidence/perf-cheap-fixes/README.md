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
