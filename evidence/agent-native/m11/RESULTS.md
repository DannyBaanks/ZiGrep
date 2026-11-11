# M11 — Agent Context Pack: results of the first evaluation (2026-11-11)

Status: **prototype evaluated, hypothesis partly supported, NOT ready for a
native port.** Nothing in `src/` changed for M11.

## What was built

- `prototype/zgrep_pack.py` (Python 3, stdlib only) on top of
  `zgrep --json --provenance -w -F`. For an identifier it delivers, in priority
  order: DEFINITION, REFERENCES (each with its link to a declaration **and the
  evidence for that link**, or `unresolved`), TESTS (candidates; coverage is
  always `NOT_DEMONSTRATED`), STRUCTURE, HISTORY (`git blame`/`git log`,
  uncommitted lines marked), DOCS, UNCERTAINTY and TRUNCATION. It uses a
  two-pass budget: every item first in brief form, then whole items in
  priority order. Anything not delivered whole goes to a spill JSON whose path
  and sha256 are printed.
- Every span carries a sha256. Blocks come from brace or indentation
  heuristics; nothing is called semantic analysis.

## Protocol (fixed before any model run: commit `22a99c1`)

- 12 questions about this repository (`bench/questions.json`): 7 dev (used
  while building the prototype) and 5 held out (not used to tune it). Each has
  a reference answer, required facts as regexes, and patterns of known-wrong
  conclusions.
- 5 conditions, all capped at 28,000 bytes:

  | Condition | What the reader gets |
  |---|---|
  | A | `zgrep -n -w -F` |
  | B | `zgrep -n -w -F -C 8` |
  | P1 | pack, blocks only |
  | P2 | pack, definitions + references + tests + uncertainty |
  | P3 | full pack |

- Reader: Claude Sonnet 5.5 through `claude -p --tools ""` from an empty
  directory. It had no tools, no repository and a fixed prompt
  (`bench/reader_prompt.txt`).
- Scoring:
  1. mechanical regexes (pre-registered);
  2. a blinded judge, a separate tool-less Sonnet session that sees question,
     reference and one answer, never the context or the condition, in shuffled
     order under opaque ids (`bench/judge.py`).
- Raw evidence: `bench/run_2026-11-11_sonnet/` holds the contexts with sha256
  in `manifest.json`, the answers, the judge outputs and `scores.txt`.
- Cost: reader $1.57, judge $0.39.

Change after pre-registration, not affecting the protocol: commands and spill
paths shown to the reader were made repository-relative (no local absolute
paths).

## Results

Blinded judge grades: 0 wrong, 1 partial, 2 correct.

| | A grep | B grep -C 8 | P1 blocks | P2 relations | P3 full |
|---|---:|---:|---:|---:|---:|
| mean grade, all 12 | 1.00 | 1.67 | 1.67 | 1.75 | **1.83** |
| mean grade, 7 dev | 0.86 | 1.57 | 1.71 | 1.86 | 1.86 |
| mean grade, 5 held out | 1.20 | **1.80** | 1.60 | 1.60 | **1.80** |
| answers graded wrong (0) | 3 | 1 | 0 | 0 | 0 |
| wrong claims flagged | 8 | **0** | 3 | 2 | 1 |
| mean delivered bytes | 1,137 | 11,199 | 11,356 | 14,323 | 15,837 |

Paired comparison by question (judge grade; wins/ties/losses; two-sided sign
test):

| | vs A | vs B |
|---|---|---|
| P1 | 7/5/0, p=0.016 | 1/10/1, p=1.00 |
| P2 | 7/5/0, p=0.016 | 1/10/1, p=1.00 |
| P3 | 7/5/0, p=0.016 | 2/9/1, p=1.00 |

The mechanical score agrees in direction (all 12 questions: A 0.515, B 0.810,
P1 0.865, P2 0.882, P3 0.924; P vs A 8/3/1, p=0.039; P vs B not significant)
and is in `bench/run_2026-11-11_sonnet/scores.txt`.

Adversarial controls C1-C8 on a generated fixture: **8/8**
(`adversarial/run2_output.txt`). The first run had C7 failing because the
control was misplaced, not because of the pack (`adversarial/run1_c7_misplaced.txt`).

## Claims

| Claim | Status | Evidence |
|---|---|---|
| H1 — the pack improves answer accuracy over a single `grep` | **DEMONSTRATED** for this reader and corpus | 7/5/0 per question, p=0.016; 3 wrong answers and 8 wrong claims under A against 0-1 and 1-3 with the pack |
| H1 — the pack improves accuracy over `grep -C 8` | **NOT_DEMONSTRATED** | 2/9/1 at best; the held-out mean is equal (1.80 vs 1.80) |
| H2 — relational context helps | **INFERRED, weak** | P2/P3 ≥ P1 on dev; on held out P1 = P2 (1.60); the one question that needs history (H4) is only fully answered with P3 |
| H3 — fidelity: no heuristic relation presented as proven | **DEMONSTRATED** on the fixture | C1 homonyms, C2 comment/string, C3 misleading test, C4 dirty tree all pass; links always name their evidence |
| H4 — extra context does not induce errors | **DISPROVED in one case** | H1 (held out): the pack's ±6-line window in a 745-line function dropped the `ZIGREP_THREADS` line that `-C 8` delivered; the reader then hedged wrongly (grade 1 vs 2 for B) |
| Delivery: what is declared delivered was delivered | **DEMONSTRATED** | no harness truncation; 6 pack truncations, all declared, spill hash checked by C6 |
| History adds knowledge a grep cannot give | **DEMONSTRATED on 1 question** | H4: only P3 contains `53c34ef`; P3 grade 2, others 0-1 |

## Findings

1. **A plain grep is not enough, and the pack fixes most of it.** With A, the
   reader concluded that `--max-columns 0` disables the window (D1). That is
   wrong: it is a usage error. Every pack condition got it right.
2. **`grep -C 8` is a strong baseline.** On this corpus a strong reader gets
   almost everything from it. The pack's advantage over B is limited to the
   questions where whole blocks, labels or history matter (D6, H4).
3. **A defect found by the held-out set:** inside functions longer than 60
   lines the pack shows ±6 lines around each hit, which is less than `-C 8`.
   The fix is to cut at the innermost enclosing block (statement level) when
   the declaration is too long. It is **not** applied here, so H1 stays a clean
   held-out result.
4. **A defect found on the dev set and fixed (D4):** when the symbol only
   appeared inside strings (a JSON field name), P2 dropped the code that emits
   it. Textual mentions now bring their block, labelled as not a dependency,
   at lower priority.
5. **Limits of the scoring:** the pre-registered regexes were too literal for
   D6 (they required the names `win_start`/`line_len`; a correct answer said
   "start offset"/"line length"). They were not changed after the fact; the
   judge is the semantic measure. D7's reference states rc 2, which no
   condition shows explicitly, so every condition got grade 1.
6. **A real ZiGrep bug surfaced through the pack (H3, condition P3):**
   `FilterEngine.isDirExcluded`/`isFileExcluded` return early when
   `no_ignore` is set (`src/filter.zig`). `--no-ignore` therefore also cancels
   `--no-hidden` and `--exclude-dir`. Reproduced: with `--no-ignore`, hidden
   files and an `--exclude-dir` directory are searched. ripgrep keeps
   explicit globs under `--no-ignore`. Not fixed in M11.

## NOT_DEMONSTRATED

- Any result for a second reader (local ISyInfer models are the next run) or a
  weaker model, where structure may matter more.
- An agentic control (a reader WITH search and read tools). These results
  compare single deliveries, which is the M11 goal of "better context from one
  command", not free exploration.
- Statistical power: 12 questions, one reader, one judge, from the same model
  family. The judge is condition-blind but not model-independent.
- Contradiction detection between docs and code: not implemented.
- Indirect references (aliases, `@field`, comptime): not analysed, and said so
  in every pack.

## Recommendation

Do not port to Zig yet. Next, in order:

1. Statement-level windows for long declarations (finding 3).
2. A larger held-out set (at least 30 questions), with more cross-file and
   history questions, written before the run.
3. The same benchmark with local readers through `isyinfer serve`.
4. An agentic control.

The parts that already look worth keeping:

- the relation labels with their evidence;
- HISTORY;
- the delivery contract (brief/full, declared truncation, verifiable spill).
