# `.gitignore` with git's semantics (2026-11-12)

Until this change every line of every ignore file went into one flat list and
was compared with the entry NAME only. So `/build`, `src/gen/`, `docs/**/*.tmp`
never matched anything, `!keep.log` was a literal file name, the `.gitignore`
files inside the tree were never read, and `.git/info/exclude` / `.ignore`
were unknown. `src/gitignore.zig` replaces that list with git's rules:

- nested ignore files, read as the walk enters each directory, chained so
  that deeper files win and, inside one file, the last matching line wins;
- `!` negation, `\#` / `\!` escapes, trailing spaces;
- a '/' at the start or in the middle anchors the pattern to its file's
  directory; `dir/` matches directories only; `**` spans directories, `*` not;
- the files of every ancestor of the search root up to the repository root
  (with the path prefix from there down to the root), plus
  `.git/info/exclude`;
- `.ignore` (shared by rg, ag and fd; ranked above `.gitignore` like rg).
  `.rgignore` and git's global `core.excludesFile` are not read.

The chain is immutable and every directory task carries a pointer to it, so
the swarm's threads share it without locks. Walkers list a directory before
applying the rules, so a directory without ignore files costs no extra
`openat`.

## Oracle: git itself (`gitignore_parity.py`, also in CI)

A generated repository with every rule kind above; for six roots (`.`,
subdirectories, an absolute root, a different cwd) the files ZiGrep searches
must equal `git ls-files --cached --others --exclude-standard`. `.ignore` is
compared with rg. Before the change all 7 cases failed; after, all pass.

## Real repositories (`rg_survey.py`, aggregates only)

`survey_repo_roots_before.txt` / `survey_repo_roots.txt` (every git repo of a
local directory, root `.`) and `survey_subdir_roots.txt` (three subdirectories
of each, relative and absolute). Reference: rg with `--hidden -g '!.git/'`
against ZiGrep with `--no-default-ignore --exclude-dir=.git`.

Every remaining difference was inspected by hand:

- **binary detection**, not ignore rules: rg reports a match found before the
  first NUL, ZiGrep skips the file as binary, or the other way round; rg is not
  even consistent with itself (one PDF is listed when its directory is the
  root and not from the repository root: mmap vs buffered reads);
- **an rg bug**: with root `evidence`, rg applies the parent rule
  `evidence/*.log` to `evidence/sub/x.log`. In gitignore `*` does not cross
  '/', and `git check-ignore --no-index` confirms git does NOT ignore that
  file. ZiGrep follows git.

## Cost (hyperfine, ReleaseFast, both orders, 60 runs)

`hgi3_*.json` (two real repos, ~1000 / ~650 directories) and `hgi3m_*.json`
(micro path): `zg-before` = d9a895d, `zg-after` = this change. Wall time is
the same within noise in both orders; user CPU is ~4 ms higher on the large
trees (rule evaluation, spread over the worker threads).

## Not demonstrated

- Windows: CI builds and runs the unit tests there; the git-oracle test runs
  only on Linux (its fixture has a file name with a trailing space).
- Nested git repositories (submodules): ZiGrep keeps applying the parent's
  rules inside them. What git and rg do there was not compared.
- `.gitignore` files bigger than 1 MiB are read up to 1 MiB.
