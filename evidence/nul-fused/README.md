# Late-NUL check fused into the literal kernel + histogram for regex/-i (2026-11-12)

Follow-up of `evidence/rare-pair-retune`, same corpus (`big.txt`, 254 MB,
4 M lines; generator in `evidence/multi-exact/README.md`) and a 96 MB code
corpus (`code.txt`, this repo's and ISyCo's `.zig`/`.py` concatenated).
Medians, `--output=pipe`, warm cache. Machine load changed during the day
(the same binary measured 24-38 ms on one case), so compare columns of the
SAME table only.

## 1. The binary rule's late-NUL check, fused

The rule (d14f549): a NUL past the 8 KiB probe ends the text at the start
of its line. It was a second pass over the whole file after the search,
whenever the file matched (not for -l/-q/-L).

- **First attempt, dropped (`segments_attempt.json`):** check each 256 KiB
  segment for a NUL right before searching it (so the search reads it from
  cache). No gain: `-j1 -c -F 'HIT kamikaze'` 20.9 -> 21.5 ms, still ~5.5 ms
  above `-a`. The pass was compute-bound, not memory-bound.
- **Kept:** `Searcher.findOrNul` (literal, packed pair, no -i/-w): the
  kernel's 32-byte loads at the anchor offset are compared with 0 too (one
  compare per block); a head of < n bytes is checked byte by byte, the tail
  with `findScalarPos`. It returns the first occurrence or the first NUL,
  whichever comes first. In `scanBuffer` the end of a matching line and a
  NUL in its rest are found in one SIMD walk (`lineEndOrNul`). Other kernels
  (regex, -i, -w, MultiLit) keep the second pass.

`fused_kernel.json`:

| case | before (540c976) | after | `-a` (no check) | rg |
|---|---|---|---|---|
| `-j1 -c -F kamikaze` (1.8 M matches) | 115 ms | **90 ms** | 110 ms | |
| `-c -F kamikaze` | 122 ms | **97 ms** | | |
| `-n -F kamikaze` | 321 ms | **294 ms** | | |
| `-j1 -c -F 'HIT kamikaze'` | 25.7 ms | **22.1 ms** | | |
| `-c -F 'HIT kamikaze'` | 28.7 ms | **24.2 ms** | | 20.7 ms |

The frequent case ends up faster than `-a` was: `lineEndOrNul` (two
compares per 32 bytes) beats the std `findScalarPos` it replaces there. An
intermediate version that checked the line rest with a separate
`findScalarPos` was 6 % SLOWER on 1.8 M matches (118 -> 128 ms); measured
and replaced.

## 2. The histogram (`retunedFor`) for regex and -i

- Regex: `Searcher.retunedRegex` retunes the regex's literal `prefilter`;
  `scanBuffer` keeps the copy on its stack.
- `-i` literal: one anchor (`findCi`), chosen by the count of both cases.

`final.json` (same session, ReleaseFast):

| case | before | after | rg |
|---|---|---|---|
| `-c -E 'HIT kamikaze[0-9]*'` | 69 ms | **42 ms** | 28 ms |
| `-c -i -F 'hit kamikaze'` | 59 ms | 59 ms | 39 ms |
| `-c -F 'HIT kamikaze'` | 35 ms | **30 ms** | 27 ms |
| `-c -F kamikaze` | 128 ms | **101 ms** | 130 ms |
| `-n -F kamikaze` | 319 ms | **288 ms** | 290 ms |
| code: `return`, `self.`, `const std`, `TODO`, `allocator` | 16/19/11/11/12 | 13/15/9/9/11 | 19/22/12/13/13 |

`-i` does not improve and that is expected: folded, every letter of
"hit kamikaze" is common in this corpus (`the`, `thread`, `state`...), so
no SINGLE anchor is rare. It needs a case-insensitive packed pair (not
done). `-n` outputs are byte-identical to rg (`return`, `self.`, `TODO`,
`kamikaze`).

## Verification

- Behaviour vs the deployed 540c976 (`ZGREP_OLD=<old> python3 X.py <new>`):
  `cmpnul.py`, 7 files of 0.6-3 MB with a NUL at 9 000, 262 143, 262 144,
  1.5 M, near the end, or none x 20 modes (`-c -n -b -l -q -m -o -v -x -w -i`,
  `--count-matches`, `--json`, `--binary-files=binary`, empty pattern, `^`,
  `$`): 140/140 identical stdout, stderr and rc. `randnul.py` (random files
  1-3 MB, 0-5 random NULs, 20 % with a NUL in or next to a match, 9
  literals x 6 modes), seeds 1-4: 1 800 runs, 0 differences. (The n*.txt
  generator was inline; same scheme as `randnul.py`.)
- `zig build test`: 162 pass / 1 skip. New: "findOrNul: the first
  occurrence or the first NUL, against a naive scan" (4 000 random
  haystacks x 5 needles; negative control: breaking `beforeNul` fails it)
  and the retune test now covers `-i` and the regex prefilter.
- `zig build oracle` 34/34; batch 41, provenance 71, compact 53, spill 66,
  m9 446, glob 17, binary 46, gitignore 7, setup 18: all pass.
  `diff_fuzz_run.py` 3 000 000 (seed 202): 0.

## Not done

- `-i` rare literals: needs a case-insensitive packed pair.
- Regex/-i/-w/MultiLit keep the second NUL pass.
- One big file still wakes 12 workers (same wall time, more CPU).
