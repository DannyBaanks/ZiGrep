# Rare literal: the SIMD anchor pair follows the buffer (2026-11-12)

Follow-up of `evidence/multi-exact` (same corpus, `big.txt`, 254 MB,
4 M lines). Open item there: `-c -F 'HIT kamikaze'` 70 ms vs rg 38 ms.

## Cause

The literal kernel (`findMemchr`) filters 32-byte blocks with a packed pair
of needle bytes chosen by a static table tuned for source code, where `z`
and `k` are among the rarest letters. For `HIT kamikaze` it anchored on
`z`+`k`, both inside "kamikaze", which fills 1.8 M lines here: every
"kamikaze" became a candidate verified for nothing. `NOPE kamikaze` (no
match at all) still cost 57 ms; `-F HIT` alone 35 ms.

## Fix

`Searcher.retunedFor(data)`: for a literal (not `-i`) with a pair, on a
buffer of 1 MiB or more, histogram 4 samples of 16 KiB spread over the
buffer and pick the pair by sampled count (static rank as tie-break).
`scanBuffer` calls it once per buffer and uses the copy. Any pair gives the
same answers (each candidate is fully verified); only the number of false
candidates changes.

## Results (medians, 10-15 runs, `--output=pipe`, warm cache)

| case | before | after | rg |
|---|---|---|---|
| `-c -F 'HIT kamikaze'` | 65 ms | **38 ms** | 29 ms |
| `-q -F 'NOPE kamikaze'` | 57 ms | **29 ms** | 24 ms |
| `-c -F kamikaze` | 130 ms | 127 ms | |
| `-c -w -F kamikaze` | 131 ms | 128 ms | |

(`before_after.json`.) Code corpus (96 MB of this repo's and ISyCo's
`.zig`/`.py`, `code_corpus.json`): `return`, `self.`, `const std`, `TODO`,
`allocator`, `json.dumps` all within 2 ms of before and of rg; `-n` output
byte-identical to rg for the first four.

## The remaining ~8 ms is the binary rule, not the search

With `-a` the gap closes: `-a -c -F 'HIT kamikaze'` 29.8 ms vs rg 29.5 ms
(`nul_pass.json`; single thread, `-F HIT`: 36.1 ms, with `-a` 27.7 ms).
When a large file has matches and the mode is not early-exit,
`searchBytes` scans the whole file once more for a late NUL (the rule of
d14f549: text only up to the line of the first NUL). That second pass is
the difference. Removing it changes semantics, so it is left as is and
reported (a fused NUL check in the kernel would be the way to keep both).

## Verification

`zig build test` 161 pass / 1 skip (new test: the pair follows the
histogram, identical answers from every start, no retune under 1 MiB or
with `-i`; negative control: disabling the retune makes it fail).
`zig build oracle` 34/34; conformances batch 41, provenance 71, compact 53,
spill 66, m9 446, glob 17, binary 46, gitignore 7, setup 18 (all pass).
`diff_fuzz_run.py` 3 000 000 (seed 101): 0 (its haystacks are < 1 MiB, so
it does not reach the retune; the unit test does).

## Not done

- `-i` literals (`findCi`, single anchor) and the regex prefilter
  `Searcher` are not retuned.
- One file of 254 MB still wakes 12 workers: same wall time, ~2.5x the CPU
  of `-j1` (55 vs 22 ms user).
