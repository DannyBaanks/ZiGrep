# The three items left open by `evidence/nul-fused` (2026-11-12)

Same corpora (`big.txt` 254 MB / 4 M lines; `code.txt` 96 MB of `.zig`/`.py`).
Medians, `--output=pipe`, warm cache; `(Nu)` = user CPU ms. Compare columns
of one table only (machine load moved during the day).

## 1. One big file no longer wakes every worker

`runKamikazePipeline` spawned `threads_count` workers even when the only
work was one file operand. Now: no directory among the roots => at most one
worker per file (one file: the calling thread). The ordered path (several
file operands) never spawned more than 1 thread for <= 32 files, but
`--stats` said `threads=12`; it now reports the workers that really ran
(both paths), and caps them at the file count.

`threads.json`: `-c -F 'HIT kamikaze'` 30.2 -> 26.8 ms, user 40 -> 12.6 ms;
`-c -F kamikaze` 99.9 -> 95.0 ms, user 187 -> 79 ms.

## 2. `-i` packed pair

`findCi` anchored on ONE byte with `scanCi`; folded, every letter of
`hit kamikaze` is common here. `findCiPair` compares two bytes per 32-byte
block, case-folded exactly like `scanCi` (`(v | 0x20) == lower` for a
foldable byte), then `verifyCi` (the old per-candidate check, unchanged);
the histogram (`retunedFor`) now picks both bytes for `-i` too.

`icase_pair.json`: `-c -i -F 'hit kamikaze'` 58 -> 34 ms (rg 38);
code `-i 'const std'` 30 -> 11 (rg 19), `-i return` 32 -> 17 (rg 32).
Counts equal rg's; `-n -i` output byte-identical on code.

## 3. The late-NUL check fused into the other kernels

`Searcher.findOrNul` now serves `-i` (`ciOrNul`), `-w` (raw hits until one
is delimited), MultiLit alternations (`MultiLit.findOrNul`, the `v0` loads)
and regexes found through a literal (`regexOrNul`: `multi` or `prefilter`,
candidate line walked once with `lineEndOrNul`). Only a regex with no
required literal (DFA over every byte), `-U` and `-z` keep the second pass.

MultiLit first tested the NUL with its own early branch per block: 2 %
slower than before on 2.8 M matches (`multilit_early_branch.json`, 177.6 ->
181.4 ms). One branch for `mask | zero` fixed it (`multilit_one_branch.json`:
179.0 -> 164.2 ms, below `-a`'s 173.7).

## Final (`final.json`, default threads)

| case | before (4493d0d) | after | rg | grep |
|---|---|---|---|---|
| `-c -F 'HIT kamikaze'` | 30 (44u) | 28 (14u) | 27 | 131 |
| `-c -i -F 'hit kamikaze'` | 61 (72u) | **33** (18u) | 41 | 158 |
| `-c -F kamikaze` | 123 (124u) | 122 (105u) | 127 | 170 |
| `-c -w -F kamikaze` | 130 (260u) | **106** (89u) | 225 | 285 |
| `-c -E 'kamikaze\|function'` | 193 (392u) | **162** (148u) | 253 | 278 |
| `-c -E 'HIT kamikaze[0-9]*'` | 42 (72u) | **31** (17u) | 27 | 129 |
| `-n -F kamikaze` | 287 (400u) | 293 (161u) | 291 | 308 |
| code `-c -i -F 'const std'` | 30 (53u) | **11** (5u) | 20 | 47 |
| code `-c -i -F return` | 35 (55u) | **16** (11u) | 36 | 61 |
| code `-c -F return` | 15 (21u) | 16 (11u) | 22 | 55 |

`-n` outputs byte-identical to rg for `-i -F hit`, `-w -F kamikaze`,
`HIT.kamikaze`, `kamikaze|function`.

## Verification

- `zig build test`: 163 pass / 1 skip. New: "findOrNul: -i and -w
  literals, against find on the NUL-free prefix" (3 option sets x 4
  needles x 800 random haystacks; negative control: breaking
  `ciBeforeNul` fails it).
- Behaviour vs the deployed 4493d0d: `randnul2.py` (random 1-2.5 MB
  files, 0-5 random NULs, 30 % with a NUL in or next to a match; 15
  patterns: -F, -i, -w, -w -i, alternations, prefiltered regexes, `$`, `^`,
  -F with two -e; 5 modes), seeds 11, 21, 22: 1 800 runs, 0 differences.
  `nul-fused/cmpnul.py`: 140/140 identical.
- `zig build oracle` 34/34; conformances batch 41, provenance 71, compact
  53, spill 66, m9 446, glob 17, binary 46, gitignore 7, setup 18.
  `diff_fuzz_run.py` 3 000 000 (seed 303): 0.

## Not done

- A regex with no required literal still runs the second NUL pass.
- `-n` on 1.8 M matching lines is output-bound (all four tools ~290-310 ms).
