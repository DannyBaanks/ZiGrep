# Exact literal alternations skip the DFA (2026-11-12)

Prompted by an external audit (Grok) that measured `kamikaze|function` at
~0.6 s in ZiGrep vs ~0.2 s in rg on a 281 MB file. Reproduced here.

## Corpus

`big.txt`, 254 MB, 4 000 000 lines of 6-14 words drawn (seed 1) from
`the quick function return error value buffer kamikaze swarm thread line
parse token index state match regex`, plus `HIT kamikaze` every 200 lines
(20 000). Generator: the Python snippet at the end. Warm page cache.

Counts agree across zgrep, rg 14.1.0 and `LC_ALL=C grep` 3.11:
`kamikaze` 1 803 090, `HIT kamikaze` 20 000, `kamikaze|function` 2 802 122.

## Measurement trap

`hyperfine -N` sends stdout to `/dev/null`, and GNU grep detects that and
stops at the first match (as if `-q`): it "took" 1.4 ms. That is where the
audit's "~0.00 s" grep timings came from. All numbers here use
`--output=pipe`. Medians of 10 runs, 2 warm-ups, 12 cores, ~3-5 GB free.

## Baseline (deployed edd4ad2)

| case | zgrep | rg | grep |
|---|---|---|---|
| `-c -F kamikaze` | 135 ms | 134 ms | 171 ms |
| `-c -F 'HIT kamikaze'` | 70 ms | 38 ms | 134 ms |
| `-c -i KAMIKAZE` | 172 ms | 260 ms | 179 ms |
| `-c -E 'kamikaze\|function'` | 548 ms | 271 ms | 290 ms |

(`baseline_*.json`.)

## Cause and fix

`findRegex` with the `MultiLit` prefilter found a line holding one of the
literals and then ran the DFA over that line to confirm. When every branch
IS its literal (`foo|bar`, `-F -e a -e b`, `-i` with ASCII case pairs) and
there is no `-w`/`-x`, the literal hit already is the match: 2.8 M lines
were verified for nothing. `Searcher.multi_exact` (set in `build` by
`isWholeLiteral`) returns the line start directly.

| case | before | after | rg | grep |
|---|---|---|---|---|
| `-c -E 'kamikaze\|function'` | 547 ms | **191 ms** | 259 ms | 289 ms |
| `-c -F -e kamikaze -e function` | 562 ms | **200 ms** | 266 ms | 301 ms |
| `-c -i -E 'kamikaze\|function'` | 570 ms | **205 ms** | 403 ms | 322 ms |
| `-n -E 'kamikaze\|function'` | 867 ms | **484 ms** | 517 ms | 519 ms |
| `-c -w -E 'kamikaze\|function'` | 569 ms | 561 ms | 465 ms | 356 ms |

(`b_*.json`; `-w` keeps the DFA on purpose.) `-n` output is byte-identical
to rg's (md5 `0f06946d`).

## Verification

- `zig build test`: 160 pass / 1 skip. The differential test "alternation
  prefilter gives the same lines as the plain DFA" now also runs `-F` and
  `-F -i`, and asserts when `multi_exact` is (not) set. Negative control:
  forcing `multi_exact = true` with `-w` makes it fail.
- `zig build oracle` 34/34; batch 41/41, provenance 71/71, compact 53/53,
  spill 66/66, m9 446/446, glob 17/17, binary 46/46, gitignore 7/7,
  setup 18/18.
- `diff_fuzz_run.py`: 300 000 (seed 20261112) and 3 000 000 (seed 99): 0.

## Still open (NOT_DEMONSTRATED / not done)

- Rare literal (`HIT kamikaze`): rg ~1.8x faster (38 vs 70 ms). Not
  investigated.
- `-w` alternations: still DFA-verified, ~1.2x behind rg, ~1.6x behind grep.
- RSS: zgrep and rg map the whole file; grep streams.

```python
import random
r=random.Random(1)
words="the quick function return error value buffer kamikaze swarm thread line parse token index state match regex".split()
with open("big.txt","w") as f:
    for i in range(4_000_000):
        w=[r.choice(words) for _ in range(r.randint(6,14))]
        if i%200==0: w.insert(r.randint(0,len(w)),"HIT kamikaze")
        f.write(" ".join(w)+"\n")
```
