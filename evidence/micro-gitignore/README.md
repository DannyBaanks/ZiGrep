# Micro path: apply `.gitignore` / `.dataignore` (2026-11-12)

Question: the zero-thread micro path (trees under 2 MB) used to skip the upward
`.gitignore` / `.dataignore` lookup "for speed". Is that worth it?

Answer: no. The lookup costs ~0-0.6 ms, and without it the result depended on
the size of the tree. Since this change the micro path loads the same ignore
files as the swarm.

## Cost (hyperfine, ReleaseFast, 60 runs, both orders)

`zg-no-ignores` = binary before the change, `zg-with-ignores` = the same source
with `loadIgnoreFiles` called before the micro path. Pattern
`-c ZGREP_PLANTED_TOKEN`.

| Tree | Order | No ignores | With ignores |
|---|---|---|---|
| `bench-corpus/corpus_50` | A then B | 2.04 ± 0.35 ms | 2.61 ± 0.43 ms |
| `bench-corpus/corpus_50` | B then A | 2.07 ± 0.26 ms | 2.44 ± 0.44 ms |
| `src` | A then B | 1.03 ± 0.19 ms | 1.05 ± 0.21 ms |
| `src` | B then A | 1.04 ± 0.22 ms | 1.15 ± 0.26 ms |

Raw: `hmicro_*.json` (local paths rewritten to `./zg-*`).

## Correctness (survey.py)

```
python3 -I evidence/micro-gitignore/survey.py OLD_BIN NEW_BIN REPOS_DIR --out survey_results.json
```

Over a local directory of real repositories, every repo that the new binary
scans on the micro path is listed with `-l -e ''` three ways. The reference is
`--force-swarm` (not ripgrep: `rg --hidden` enters `.git/` and rg has no
built-in excludes, so it is not the same rule set). Result in
`survey_results.json`; exit 0 only if the new micro path equals the swarm in
every repo. Only aggregates are written; repo names stay local because this
repo is public.

What the old micro path returned on top of the swarm: `.pytest_cache/`,
`build/lib/` copies of the sources (duplicate hits for an agent), `*.egg-info/`,
`obj/`, `.ruff_cache/`, generated `results/` — the kind of noise the ignore
rules exist to hide.

## Not demonstrated

- Timing on Windows (CI only checks behaviour: the smoke now asserts the
  git-ignored `skip.txt` is excluded on the default path too).
- Cost on network filesystems, where the upward walk could be slower.
