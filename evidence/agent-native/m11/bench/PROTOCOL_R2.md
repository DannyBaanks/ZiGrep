# M11 round 2: protocol (fixed before the run)

- **Questions:** `questions_r2.json`, 30 questions, all held out (`heldout2`).
  They were written by reading `src/` with grep/sed and by running the binary;
  the pack was not run on any of these 30 symbols before this commit. The
  12 round-1 questions are now dev-only.
- **Pack under test:** the prototype at this commit, which adds statement-level
  windows for long declarations (never narrower than ±8). No change to the
  prototype between this commit and the run. If one is needed, it is a new
  round with new questions.
- **Unchanged from round 1:** the 5 conditions, the 28,000-byte budget, the
  reader prompt (`reader_prompt.txt`), the tool-less Sonnet reader, the
  blinded Sonnet judge and the mechanical scoring.
- **Frozen source:** the references describe the code as it is at this commit.
  Five of them are real bugs found while writing the questions (R18, R20, R24,
  R28, R29) and three are doc/code contradictions (R13, R14, R17). None of them
  is fixed before the round-2 run, so the ground truth does not move.
- **Pre-declared primary comparison:** P3 against B, by blinded judge grade,
  paired by question, two-sided sign test. Secondary: P2 against B, every pack
  condition against A, and the mechanical scores.
