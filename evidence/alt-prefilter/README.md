# Alternation prefilter (Gemini review, item 2), 2026-11-12

Before, an alternation (`a|b|c`, or several `-e`) had no required literal
(`requiredLiteral` returns null for `.alt`, and the literal prefilter was only
built for a single pattern). The lazy DFA ran over every byte of every file.

Now `search.build` collects the branches of the alternation and takes one
required literal per branch. It does so on the patterns BEFORE `-w` / `-x`
wrapping, because wrapping only adds conditions. When all branches have a
literal of 2+ bytes, and there are at most 16, it installs a `MultiLit`
prefilter. A SIMD filter on the first two bytes of each literal over 32-byte
blocks, then a full compare, returns the LEFTMOST occurrence of any literal.
The line containing it goes to the DFA, as with the single-literal prefilter.
Anchoring on the first byte is what guarantees the leftmost occurrence, so no
line with a match is skipped.

Scope of this first version: case-sensitive line search. With `-i`, `-U` or
`-z`, or when a branch has no literal of 2+ bytes, the DFA runs as before.

## Correctness

- Output identical to the deployed binary (de04879) on `<assembly>` (634 MB,
  4,008 files) for 12 queries. They cover `-c`, `-n`, several `-e`, `-w`,
  `-x`, `-l`, `-o`, `--color`, regex branches (`return [0-9]+;|exit\(1\)`),
  four branches and `-v`.
- Two unit tests:
  - `MultiLit.find` against a naive "leftmost of any literal" over 2,000
    random cases;
  - the full searcher with and without the prefilter over random texts, for
    8 patterns × {plain, `-w`, `-x`}.
- Negative control: visiting the candidates high-to-low (breaking
  "leftmost") makes both tests fail. The searcher-level one shows the prefilter
  SKIPPING a matching line (`multi=62`, `dfa=53`).
- All gates pass:

  | Gate | Result |
  |---|---|
  | unit tests | 149/150 |
  | oracle | 34/34 |
  | conformance | 40/40 |
  | batch / provenance / compact / spill / m9 | 41 / 71 / 45 / 66 / 446 (m9 also on Debug) |
  | glob parity | 17/17 |
  | setup check | 18/18 |
  | fuzz | 100,001 operations, 0 anomalies |
  | cell-fuzz | 388,800 cells, 0 anomalies |
  | x86_64-windows build | compiles |

## Speed (`<assembly>`, warm, 12 threads, `-c`, 10 runs, both orders)

| Query | Before (A→B / B→A) | After (A→B / B→A) | Speed-up | rg 14.x (same host) |
|---|---:|---:|---:|---:|
| `webgpu\|wgpu\|dawn` (absent) | 310.0 / 313.0 ms | 32.4 / 32.2 ms | **9.7×** | 56.7 ms |
| `malloc\|calloc\|realloc` (rare) | 317.1 / 320.7 ms | 33.1 / 33.6 ms | **9.6×** | 56.0 ms |
| `TODO\|FIXME\|XXX` | 314.3 / 323.7 ms | 33.0 / 32.3 ms | **9.8×** | 54.6 ms |
| `printf\|fprintf\|sprintf\|snprintf` (frequent) | 304.4 / 344.4 ms | 34.2 / 35.3 ms | **9.4×** | 57.7 ms |

Single thread (`-j 1`, `malloc|calloc|realloc`): 1.341 s → 94.8 ms,
**14.1×** faster (`halt_j1.json`).

Before, rg was about 6× faster than zgrep on alternations. Now zgrep is about
1.7× faster than rg on these queries. Raw data: `halt_*.json`.

## `-i` (added the same day)

With `-i`, the literals come lower-case: `requiredLiteral` folds ASCII pairs,
as the DFA does. `MultiLit` compares each of the first two bytes with BOTH
cases and verifies with `std.ascii.eqlIgnoreCase`.

- Output identical to the deployed 953f76b on `<assembly>` for 9 queries,
  covering `-i`, several `-e` in mixed case, `-i -w`, `-S` (both smart-case
  outcomes), `-i -o`, `-i -l` and regex branches.
- Unit tests:
  - a new naive case-insensitive test (2,000 cases);
  - the searcher-level differential now also runs `-i` and `-i -w`, on
    mixed-case text.
- Negative control: dropping the upper-case compare of the first byte makes
  both fail.

| Query (`-i -c`) | Before (A→B / B→A) | After (A→B / B→A) | Speed-up |
|---|---:|---:|---:|
| `malloc\|calloc\|realloc` | 330.4 / 327.7 ms | 29.0 / 31.5 ms | **10.9×** |
| `todo\|fixme\|xxx` | 362.4 / 333.7 ms | 33.5 / 31.5 ms | **10.7×** |
| `printf\|fprintf\|sprintf\|snprintf` | 352.9 / 317.3 ms | 30.4 / 31.1 ms | **10.9×** |

`rg -i -c malloc|calloc|realloc` on the same host: 56.3 ms. Raw data:
`hialt_*.json`.

## NOT_DEMONSTRATED / next
- More than 16 branches, or a branch whose required literal is a single byte,
  keeps the DFA path.
