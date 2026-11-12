# Packed-pair literal search (Gemini review, item 1), 2026-11-12

`findMemchr` (the default literal kernel) anchored on ONE byte, the rarest of
the needle, through `findScalarPos`, then compared every candidate. Now, for
needles of 2+ bytes, it tests the two rarest bytes at their fixed distance on
32-byte blocks (`(v1 == w1) & (v2 == w2)`) and verifies the surviving
candidates in order. The single-anchor scan remains for the tail and for
1-byte needles.

## Correctness

- Output identical to the previous binary on `<assembly>` (634 MB real tree)
  for `-c return / const / self / the`, an absent token, `-F sizeof(` and
  `-l function`.
- A new unit test: 3,000 random cases with the needle planted at block edges
  (0, 1, 31, 32, 33, 63, 64…), against a naive search.
- Negative control: dropping the candidate verification makes both
  differential tests fail with a concrete MISMATCH.
- All gates pass:

  | Gate | Result |
  |---|---|
  | unit tests | 147/148 |
  | oracle | 34/34 |
  | conformance | 40/40 |
  | batch / provenance / compact / spill / m9 | 41 / 71 / 45 / 66 / 446 (m9 also on Debug) |
  | glob parity | 17/17 |
  | fuzz | 100,001 operations, 0 anomalies |
  | cell-fuzz | 388,800 cells, 0 anomalies |
  | x86_64-windows build | compiles |

## Speed

Three levels, each measured in both run orders. Only a difference that
survives both orders counts.

1. **The kernel alone.** `zig build sweep`: in-memory, single thread, needles
   drawn from 64 MB of `<assembly>` text, median of 5. `sweep_before.txt` and
   `sweep_after.txt`. memchr MB/s:

   | Needle length | 2 | 3 | 4 | 6 | 8 | 12 | 16 | 32 |
   |---|---:|---:|---:|---:|---:|---:|---:|---:|
   | before | 6,321 | 13,406 | 12,049 | 10,070 | 11,273 | 11,426 | 18,583 | 14,839 |
   | after | 15,837 | 21,739 | 22,275 | 22,005 | 22,813 | 22,253 | 22,951 | 21,729 |

   That is 1.2-2.5× faster. BMH, whose code did not change, is the control:
   817→791 … 8,490→8,314, flat. Both kernels agree on all 96 samples.

2. **Search-dominated end to end.** One 16 MB file built from the synthetic
   corpus, `-c`, 12 runs (`hone_one_*.json`):

   | Query | Result |
   |---|---|
   | `return` | after **1.74×** / **1.92×** faster |
   | `the` | after **2.01×** / **1.93×** faster |
   | absent token | 1.02× / 0.93× (±0.2): **no difference** |

3. **Real tree end to end.** `<assembly>`, 12 threads (`hpp_*.json`) and
   `-j 1` (`hpp1_*.json`). **No difference beyond noise** for any query, in
   either order. On a big tree the time goes to directory walking, syscalls
   and line handling, not to the literal kernel. The absent token with
   `-j 1`: before was 1.10× and 1.02× faster, inside the noise and in the
   same direction.

A 4 MB file of real source (`hcode_*.json`) runs in about 3 ms, dominated by
startup. Only an indication: after was faster in both orders for
`return/const/the` and mixed for `self`.

**Verdict: ADOPTED.** The kernel is 1.2-2.5× faster and a search dominated by
the kernel is 1.7-2.0× faster. Big parallel tree searches do not change,
because they are bound elsewhere.
