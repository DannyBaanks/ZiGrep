# M11 — Agent Context Pack (experimental)

Results and verdict: [`RESULTS.md`](RESULTS.md).

## Use

```sh
python3 evidence/agent-native/m11/prototype/zgrep_pack.py SYMBOL [PATH ...] \
    --zgrep zig-out/bin/zgrep [--sections all|tests|refs|blocks|lexical] \
    [--budget-bytes 28000] [--spill-dir DIR] [--format text|json]
```

Run it from inside the repository (or pass `--repo`). It takes an identifier.
It reads only what git would show, skips secret-looking names, refuses paths
outside the repository, executes nothing it retrieves, and prints the spill
path and sha256 when the budget truncates.

## Reproduce

```sh
python3 evidence/agent-native/m11/adversarial/adversarial_checks.py --zgrep zig-out/bin/zgrep --work /tmp/m11adv
python3 evidence/agent-native/m11/bench/build_contexts.py --zgrep zig-out/bin/zgrep --out <new run dir>
python3 evidence/agent-native/m11/bench/run_reader.py --contexts <run dir> --label <name> \
    --backend claude --model sonnet --workdir <empty dir>      # or --backend openai --url http://127.0.0.1:8099/v1/chat/completions
python3 evidence/agent-native/m11/bench/judge.py --contexts <run dir> --label <name> --workdir <empty dir>
python3 evidence/agent-native/m11/bench/score.py --contexts <run dir> --label <name> --out <run dir>/scores.json
```

Never reuse a run directory: each run gets its own.

## Handoff

- Done: round 1 (12 questions) and round 2 (30 held-out questions). Verdict in
  RESULTS.md: the pack beats a bare grep, and ties `grep -C 8` for a strong
  tool-less reader.
- All 42 questions have now been seen. Any new round needs new held-out
  questions, written and committed before it runs.
- Known pack defects, not fixed (prototype frozen for round 2):
  - array and constant initialisers are not shown in DEFINITION;
  - TRUNCATION sits at the end, so a harness cut can remove it;
  - the budget estimate can overrun by a few hundred bytes.
- Open: a weaker local reader via `isyinfer serve`, an agentic control, a
  narrower native `-C` that extends to the enclosing statement, and M12.
- ZiGrep bugs found during M11: `--no-ignore` was fixed in main `8a8bf80`.
  Five more and three doc contradictions are listed in RESULTS.md, round 2,
  and are pending.
