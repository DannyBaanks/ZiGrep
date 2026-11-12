# M12 pilot: can ZiGrep replace ripgrep behind an agent's grep tool?

Fixed before the run (2026-11-11).

- **Agent:** OpenISy-v2, branch `ziggrep-grep`, with an opt-in adapter
  (`OPENISY_GREP_ENGINE=ziggrep`). The adapter's parity with ripgrep is
  checked by `packages/core/test/ripgrep-ziggrep.test.ts`: 11/11, plus a
  negative control.
- **Model:** NVIDIA NIM `minimaxai/minimax-m3.1-flash`.
- **Run:** `openisy run --standalone`, without `--auto` (read-only tools
  only), stdin closed, in a throwaway clone of ZiGrep `main`.
- **Questions:** M11 round 2, the 8 whose answers did not change with the
  2026-11-11 fixes: R02, R03, R05, R07, R10, R16, R19, R23.
- **Conditions:** RG (unset, ripgrep) and ZG (ziggrep, every call logged by
  a wrapper).
- **Measures:**
  - the blinded judge grade (M11's `judge.py`, condition hidden);
  - grep tool calls;
  - grep calls that returned "No matches found";
  - tool errors;
  - ziggrep calls in ZG, which must be > 0 whenever ZG used the grep tool;
    otherwise the engine was not exercised.
- **Pre-declared reading:** ZG is a viable replacement if it is not worse than
  RG on judge grade (paired, sign test) and has no extra empty results or tool
  errors attributable to the engine. 8 questions are a pilot: a tie is the
  expected outcome, and it does not prove equivalence.
