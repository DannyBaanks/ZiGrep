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

- Open: statement-level windows (RESULTS finding 3), a larger held-out set
  written before its run, local readers via `isyinfer serve`, an agentic
  control.
- Do not re-score the H1-H5 held-out questions after changing the pack: they
  have been seen. New held-out questions are needed.
- ZiGrep bug found during M11, not yet fixed: `--no-ignore` cancels
  `--no-hidden` and `--exclude-dir` (`src/filter.zig`, RESULTS finding 6).
