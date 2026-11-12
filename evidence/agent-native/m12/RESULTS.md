# M12 pilot: results (2026-11-11)

Protocol: `PROTOCOL.md`, committed before the run (`49fe37a`). Raw data is in
`run_2026-11-11_minimax/`:
- `answers/agent/`: one record per run, with every tool call;
- `zlog/`: every ziggrep invocation the wrapper saw;
- `judge/agent/`: the blinded grades and `mapping.json`.

## Setup actually run

- **Agent:** OpenISy-v2 branch `ziggrep-grep` at `2679991`, in its own
  worktree. The user's checkout and the other agent's uncommitted work were
  not touched.
- **Model:** NVIDIA NIM `minimaxai/minimax-m3.1-flash`.
- **Run:** `openisy run --standalone`, without `--auto`, stdin closed, in a
  clone of ZiGrep `49fe37a`. The clone contains no reference answers;
  checked before the run.
- **Questions:** R02 R03 R05 R07 R10 R16 R19 R23 from M11 round 2
  (`questions_r2_from_m11.json`, a byte copy of the m11-context-pack file,
  sha256 `8d3f9f77…`).
- **Judge:** M11's blinded judge, unchanged except for the condition list
  (`judge_from_m11.py`). Sonnet via `claude -p --tools ""`, $0.12.

## Results

| | RG (ripgrep) | ZG (ZiGrep) |
|---|---:|---:|
| mean judge grade (0-2) | 1.88 | **2.00** |
| answers graded wrong (0) | 0 | 0 |
| wrong claims flagged | 2 | 0 |
| grep tool calls | 51 | 36 |
| grep calls with "No matches found" | 1 | 2 |
| grep tool errors | 0 | 0 |
| ziggrep invocations logged | 0 | 36 (= every grep call) |

Paired by question, ZG against RG: 1 win, 7 ties, 0 losses (sign test
p = 1.00).

Every "No matches found" was checked against rg with the same input: rg also
returns 0 for all three. None is an engine difference.

## Claims

| Claim | Status |
|---|---|
| With the adapter on, ZiGrep really serves the agent's grep tool | **DEMONSTRATED** (36/36 grep calls logged by the wrapper) |
| The engine swap does not break the tool (no errors, no spurious empty results) | **DEMONSTRATED** for these 16 runs |
| Answers are as good with ZiGrep as with ripgrep | **NOT_DEMONSTRATED as equivalence**; observed 1/7/0, a tie on 8 questions |
| ZiGrep makes the agent faster | **NOT_DEMONSTRATED**: ZG took 1,846 s against 2,319 s in total, but the agent made different calls (36 against 51 grep calls), so the time is not attributable to the engine |

## Failures preserved

1. **Harness wrapper path.** The first ZG attempt passed the logging wrapper as
   a relative path. The grep tool spawns it with cwd = the searched directory,
   so every ZG grep call failed and no ziggrep call happened. Those 5 records
   are kept in `invalid_relative_wrapper/`; the ZG runs were repeated with an
   absolute path.
2. **Run timeout.** The first run was cut by the harness's own
   `timeout 3000` (exit 143) after 10 of 16 runs. The pilot is resumable, and
   the remaining runs completed under a larger timeout.

## Not done

- No push or merge of the OpenISy branch.
- No change to any TUI config.

Rolling the engine out to the other TUIs needs a per-TUI manifest approved
first.

## Redaction

Agent records keep tool inputs and outputs verbatim, and those contained local
absolute paths. A first push (`9f9c6d3`) published them. They were then
replaced in `run_2026-11-11_minimax/` with these rules:

| Local path | Placeholder |
|---|---|
| the clone | `<clone>` |
| the scratch directory | `<scratch>` |
| other temp paths | `<tmp>` |
| ZiGrep | `<repo>` |
| the OpenISy worktree | `<openisy>` |
| `~/Development/ISyCo Git` | `<git>` |
| `~/Development/ISyCo` | `<isyco>` |
| the home directory | `~` |
| the file owner in `ls -la` output | `user` |

No credential appeared in any record (searched for `nvapi-` and `apiKey`).
The original paths remain in the history of commit `9f9c6d3` unless that
history is rewritten.

## Rollout (2026-11-11, approved by Danny: Claude Code, Codex, OpenISy, agy)

The canonical rule is `~/.config/ziggrep/agents.md`.

| TUI | How it gets the rule | Verified |
|---|---|---|
| OpenISy | main `a794ba4`: the launcher sets `OPENISY_GREP_ENGINE=ziggrep` when ziggrep is on PATH, so the grep tool runs on ZiGrep | a run without the variable: 1 ziggrep call logged, correct answer |
| Claude Code | `~/.claude/CLAUDE.md` imports the rule (`@~/.config/ziggrep/agents.md`) | asked, it states the rule; on a search task it ran `ziggrep -n 'fn batchQueryProblem' .` |
| Codex | the rule is written **inline** in `~/.codex/AGENTS.md`: Codex does not resolve `@` imports, which also means the RTK line there was never loaded as instructions | on a search task it ran `ziggrep -n -F 'batchQueryProblem' .`; backup in `~/.codex/AGENTS.md.bak-2026-11-11-pre-ziggrep` |
| agy | `~/.gemini/GEMINI.md`, a copy of the rule | NOT_DEMONSTRATED: agy's quota was exhausted ("Individual quota reached") |

Completed afterwards, the same day, at Danny's request ("haz todo"):
- `~/.openisy/config/AGENTS.md` created (a copy of the rule, covering bash
  searches inside OpenISy).
- OpenISy's background service restarted with `openisy service restart`. The
  new service process has `OPENISY_GREP_ENGINE=ziggrep` in its environment;
  the old one, which did not, is gone.
- OpenISy `main` pushed to GitHub as a fast-forward (`99a94c9..a794ba4`).

Still NOT_DEMONSTRATED: agy actually following the rule (quota exhausted).

## `ziggrep --setup` (2026-11-12)

The manual rollout above became a command: `ziggrep --setup`, in commits
`b656149` and `1cfcba0`, documented in GUIA §4t. It is verified against a fake
HOME by `evidence/setup/setup_check.py`, which the CI also runs.

Danny's machine was migrated to it:
1. The manual blocks were removed. Codex came back byte for byte to its
   original backup; the three files that held only the manual rule were
   deleted.
2. `ziggrep --setup=claude,codex,openisy,agy --force` was run. opencode was
   left out on purpose.
3. A second run reports "Nada que cambiar".

Claude Code and Codex, asked afterwards, both answer "use `ziggrep` and always
pass a path".
