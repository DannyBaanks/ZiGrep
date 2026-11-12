# ZiGrep

[![CI](https://github.com/DannyBaanks/ZiGrep/actions/workflows/ci.yml/badge.svg)](https://github.com/DannyBaanks/ZiGrep/actions/workflows/ci.yml)
[![Zig](https://img.shields.io/badge/Zig-0.16.0-orange.svg)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

ZiGrep (`zigrep`, also installed as `zgrep`) is a grep-compatible search tool
written in Zig 0.16, with no libc dependency. It supports literal and regular
expression search, GNU grep and ripgrep option compatibility, and a structured
JSON output designed for programmatic consumers such as coding agents.

- **Linux:** directory traversal uses `getdents64` directly, work is spread over
  a lock-free work-stealing thread pool, and `io_uring` is available as an I/O
  engine.
- **Windows:** a native build using Zig's I/O layer. WSL is not required.
  Correctness is checked in CI against GNU grep and ripgrep. The benchmarks below
  are Linux-only and make no claim about Windows performance.

The latest release is `v0.3.2`. The `main` branch is `0.4.0-dev`.

```sh
zigrep "Searcher" src/                  # literal search over a tree
zigrep 'fn\s+\w+\(' /path/to/project    # regular expression (linear time)
zigrep -i "ñandú" docs/                 # case-insensitive literal, ASCII + Latin-1
zigrep --sort "pattern" .               # deterministic, GNU grep traversal order
zigrep --json "pattern" src/            # JSONL events (schema zgrep/1)
```

## Installation

### Linux

```sh
curl -sSfL https://raw.githubusercontent.com/DannyBaanks/ZiGrep/main/install.sh | bash
```

The script detects the architecture (`x86_64` or `aarch64`) and downloads a
static, stripped binary. It then links `zigrep` and `zgrep` into `~/.local/bin`,
or into `/usr/local/bin` when run as root. If the download is not possible, it
clones the repository and builds from source with Zig 0.16.0. CI does not cover
macOS.

### Windows

```powershell
irm https://raw.githubusercontent.com/DannyBaanks/ZiGrep/main/install.ps1 | iex
```

- The binary is a native `.exe` that uses the Win32 API directly. It needs
  neither WSL nor a C runtime.
- The installer checks the release `SHA256SUMS.txt` and refuses to install on a
  mismatch.
- No administrator rights are needed. The installer writes to
  `%LOCALAPPDATA%\Programs\ZiGrep` and adds that directory to the user `PATH`,
  including the current session. Restart the terminal so new shells pick it up.
- The Windows release targets baseline `x86_64-windows` (SSE2), so it runs on any
  x86_64 CPU.
- To pin a version, run
  `irm https://raw.githubusercontent.com/DannyBaanks/ZiGrep/v0.3.2/install.ps1 | iex`,
  or `install.ps1 -Version 0.3.2`. The URL on `main` installs whatever `main`
  contains at that moment.

### Release artifacts

| Artifact | Platform |
|---|---|
| `zigrep-linux-x86_64.tar.gz` | Linux x86_64 (static, stripped) |
| `zigrep-linux-aarch64.tar.gz` | Linux ARM64 (static, stripped) |
| `zigrep-windows-x86_64.zip` | Windows x86_64 (`zigrep.exe`, `zgrep.exe`, `install.ps1`) |
| `SHA256SUMS.txt` | Checksums for the three archives |

To make your AI coding agents search with ZiGrep, see
[level 3 of Usage](#level-3-for-ai-coding-agents).

## Building from source

Building requires [Zig](https://ziglang.org/download/) 0.16.0.

```sh
git clone https://github.com/DannyBaanks/ZiGrep.git
cd ZiGrep

zig build -Doptimize=ReleaseFast   # optimized binary in zig-out/bin/
zig build test --summary all       # unit tests
zig build oracle                   # differential oracle against GNU grep and ripgrep
zig build fuzz -- 100000           # adversarial fuzzer, 100,000 operations
zig build cell-fuzz -- --all       # exhaustive sweep of the option space
```

`zig build oracle` and a plain `zig build` install a Debug binary into
`zig-out/`. Rebuild with `-Doptimize=ReleaseFast` before measuring anything.

## Usage

The installer puts the binary on your `PATH` as `zigrep`, plus the alias
`zgrep`. On Linux, gzip ships a different tool called `zgrep`, so `zigrep` is
the safe name. `zigrep --help` lists every option for the build you have.

ZiGrep is used at three levels. Level 1 is all you need to replace grep.

### Level 1: like grep

If you know grep, you already know most of ZiGrep:

| What you want | grep | zigrep |
|---|---|---|
| search a tree | `grep -rn foo .` | `zigrep -n foo .` (recursion is always on) |
| ignore case | `grep -i foo` | `zigrep -i foo .` |
| whole word | `grep -w foo` | `zigrep -w foo .` |
| literal text, no regex | `grep -F 'a.b'` | `zigrep -F 'a.b' .` |
| several patterns | `grep -e foo -e bar` | `zigrep -e foo -e bar .` |
| patterns from a file | `grep -f pats.txt` | `zigrep -f pats.txt .` |
| lines that do NOT match | `grep -v foo` | `zigrep -v foo .` |
| count matching lines | `grep -c foo` | `zigrep -c foo .` |
| only file names | `grep -l foo` / `grep -L foo` | `zigrep -l foo .` / `zigrep -L foo .` |
| only the matched part | `grep -o 'v[0-9]+'` | `zigrep -o 'v[0-9]+' .` |
| context lines | `grep -A 2 -B 1 -C 3` | `zigrep -A 2 -B 1 -C 3 foo .` |
| stop after N matches | `grep -m 5` | `zigrep -m 5 foo .` |
| just the exit code | `grep -q foo` | `zigrep -q foo .` |
| whole line must match | `grep -x foo` | `zigrep -x foo .` |
| only some files | `grep --include='*.zig'` | `zigrep --include='*.{zig,py}' foo .` |
| skip files / dirs | `grep --exclude=… --exclude-dir=…` | same flags |
| grep's basic regex | `grep 'a\|b'` | `zigrep -G 'a\|b' .` |
| colour | `grep --color=always` | `zigrep --color=always foo .` |
| read standard input | `cat f \| grep foo` | `cat f \| zigrep foo` |

ripgrep users will also find `-t py`, `--type-not`, `-S` (smart case),
`--max-depth`, `--max-filesize`, `--replace`, `--column`, `--vimgrep`,
`--heading`, `-p` (pretty), `--passthru`, `-U` (multiline), `--pre`,
`--encoding`, `--crlf` and `-z` (NUL-separated records).

Four differences from grep are worth knowing before they surprise you:

1. **Always give a path** (`.` for the current directory). With no path,
   zigrep reads standard input like grep does. It does not search the current
   directory like ripgrep.
2. **Line numbers are off by default**, as in grep. Add `-n`.
3. **Patterns are extended regex**, as in ripgrep and `grep -E`. Alternation is
   `a|b`; `a\|b` means a literal `|`. Use `-G` for grep's basic syntax.
   Back-references and lookaround are rejected with an error, never
   approximated.
4. **Noise is skipped.** Binary files count as "no match". `.gitignore`,
   `.ignore`, `.dataignore` and a built-in list (`.git`, `node_modules`,
   `target`, `*.log`, `*.min.js`, …) are skipped too. Ignore files follow
   git's rules: nested files, `!` negation, anchored patterns (`/build`,
   `src/gen/`), directory-only rules, `**`, and the repository's
   `.git/info/exclude`; a CI test compares the result with `git ls-files`
   (`evidence/gitignore-semantics/`). Turn them off with `--no-ignore` or
   `--no-default-ignore`.

Exit status: `0` a match was found, `1` no match, `2` error.

### Level 2: what only ZiGrep does

These options have no grep equivalent. You never need them, but they explain
how ZiGrep works and let you tune it.

| Option | What it does |
|---|---|
| *(default)* `-k`, `--kamikaze` | **Kamikaze swarm.** Threads that both walk directories and search files, stealing work from each other. Results print as soon as each file finishes, so the order can change between runs. |
| `--sort` | Deterministic output, in the same order GNU grep uses. |
| *(automatic)* small-tree path | When the matching files total less than 2 MB, everything runs on one thread with no pool, with the same ignore rules as the swarm. `--force-swarm` always uses the swarm. |
| `-N`, `--nav SPEC` | **Befunge navigation.** Steers the walk like a pointer on a grid: `v^` searches only the files in the root, `^v` skips the root's files and searches only subdirectories, `<` walks siblings in reverse order. A plan that contradicts itself (`v^v`) is rejected. |
| `--io-engine=auto\|sync\|uring`, `--uring` | How files are read on Linux. `auto` probes the page cache with the first read and switches to `io_uring` when the tree is cold. |
| `--algo auto\|bmh\|memchr` | Picks the literal-search algorithm. |
| `--stats` | Prints timing, throughput and which path ran to stderr. |
| `--include-ext`, `--exclude-ext` | Filter by extension list (`--include-ext=zig,py`). |
| `-X`, `--exec CMD` | Runs `CMD` for every file with a match; `{}` is replaced by the path. |
| `--cache` | Finds Zig build caches on disk, says which are safe to delete, and asks before deleting (`--dry-run` only shows). |

### Level 3: for AI coding agents

ZiGrep is meant to be the search tool of coding agents such as Claude Code,
Codex, agy/Gemini, OpenISy and opencode.

**Make your agents use it, with one command:**

```sh
zigrep --setup
```

The command finds the agents installed on this machine and shows what it would
add to each agent's global instruction file. Only after you answer `s` does it
write the rule that tells them to search with ZiGrep. That rule also teaches
the four differences above. A copy `.bak-ziggrep` of every file it edits is
kept.

| Command | What it does |
|---|---|
| `zigrep --setup --dry-run` | only shows the changes |
| `zigrep --setup=claude,codex` | only these agents (`claude`, `codex`, `agy`, `openisy`, `opencode`) |
| `zigrep --setup --force` | applies without asking (scripts, or a model running it) |
| `zigrep --setup --undo` | removes exactly what it added |

**Output that a program can read.** Every event carries a schema identifier,
and the schemas only ever add fields.

| Option | Purpose |
|---|---|
| `--json` | JSONL events (`zgrep/1`) with path, line, column, byte offsets and text |
| `--json=compact` | The same information in positional rows (`zgrep/1c`) |
| `--provenance` | Per-file sha256, size and mtime of the bytes that were searched |
| `--queries-file FILE` | Many queries in one process, each event tagged with its query id |
| `--max-results N`, `--max-output-tokens N` | Output budget with explicit truncation; an event is never cut |
| `--spill[=DIR]` | Writes what the budget omits to a file and reports its sha256 |
| `--max-columns N` | Emits a long line as a window around the match, with offsets to recover the full line |

The contracts, and what each option was measured to save or cost, are in
[`GUIA.md`](GUIA.md) (sections 4k-4t) and in `evidence/agent-native/`.

## Performance

These benchmarks were run on Linux x86_64 (Ubuntu 24.04, 12 hardware threads,
NVMe). The timed builds included the `spinLoopHint`, zero-allocation path, 256 KB
buffer and `io_uring` changes. Each value is the arithmetic mean of 10 timed runs
after 3 warm-up rounds, with tools interleaved and rotated between rounds. The
comparison versions are GNU grep 3.11 and ripgrep 14.1.0. Individual runs,
standard deviations and raw data are in [`PRUEBAS.md`](PRUEBAS.md).

| Scenario | Size / files | `zigrep` | `zigrep --uring` | ripgrep 14.1.0 | GNU grep 3.11 | vs ripgrep | vs GNU grep |
|---|---|---:|---:|---:|---:|---:|---:|
| Small tree (`corpus_50`) | 50 files, 1.6 MB | 9.88 ms | 11.91 ms | 13.47 ms | 7.08 ms | 1.36x faster | 1.39x slower |
| Medium tree (`corpus_1000`) | 1,000 files, 32.8 MB | 23.41 ms | 35.74 ms | 22.65 ms | 22.30 ms | about equal | about equal |
| Synthetic tree | 254 files, 131 MB | 47.57 ms | 69.92 ms | 37.93 ms | 51.56 ms | 1.25x slower | 1.08x faster |
| Real monorepo (`assembly`) | 5,338 files, 655 MB | 85.31 ms | 109.24 ms | 108.67 ms | 535.84 ms | 1.27x faster | 6.28x faster |
| Regex `pub\s+fn\s+` | `assembly` | 95.63 ms | 120.05 ms | 120.33 ms | 1,257.67 ms | 1.26x faster | 13.15x faster |
| Early exit `-q` | `assembly` | 3.11 ms | 2.04 ms | 14.63 ms | 3.01 ms | 4.71x faster | 1.47x faster¹ |
| Files without match `-L` | `assembly` | 93.68 ms | 110.85 ms | 125.32 ms | 718.61 ms | 1.34x faster | 7.67x faster |
| Max count `-m 1` | `assembly` | 95.92 ms | 117.71 ms | 126.65 ms | 678.69 ms | 1.32x faster | 7.08x faster |
| Invert match `-v` | `assembly` | 482.19 ms | 514.64 ms | 500.22 ms | 1,213.38 ms | 1.04x faster | 2.52x faster |
| Multi-repo (BRE, globs) | 3 repositories, 124 MB | 32.33 ms | 35.67 ms | 23.90 ms | 68.88 ms | 1.35x slower | 2.13x faster |

¹ Copied as recorded. The default `zigrep` (3.11 ms) and GNU grep (3.01 ms) are
within noise of each other; the 1.47x figure matches `zigrep --uring` (2.04 ms).

### Small trees

A tree whose regular files total less than 2 MB is scanned on the calling
thread. No worker pool is started; the same `.gitignore`/`.dataignore` rules
as the swarm apply, so the size of the tree never changes the result (loading
them costs about 0-0.6 ms, see `evidence/micro-gitignore/`). The size check uses `statx` before any file is read, so a
larger tree is handed to the thread pool without wasted I/O. `--force-swarm`
always uses the thread pool, and `--stats` reports which path ran
(`micro_path=yes|no`).

The following medians come from `scripts/bench.zig`: `ReleaseFast`, `corpus_50`
(50 files, 1.64 MB, 69 directories), rounds interleaved and rotated. The host
had an external load average of 11-17 during the run.

| Command | Median (15 runs) |
|---|---:|
| `grep -rnIF` | 2.52 ms |
| `zigrep` (small-tree path) | 3.13 ms |
| `zigrep --force-swarm` | 3.18 ms |
| `zigrep -j 1` | 3.32 ms |
| `rg -nF` | 5.28 ms |
| `zigrep -q` (small-tree path) | 2.00 ms |
| `zigrep --force-swarm -q` | 3.35 ms |

On `corpus_1000` (32.8 MB) the size check hands the tree to the thread pool.
The check costs 0.23 ms: 6.82 ms in total, against 6.59 ms with
`--force-swarm`. In the same measurement, GNU grep took 11.91 ms and ripgrep
9.13 ms.

### Thread count

`-j N`, `--threads N` or the `ZIGREP_THREADS` environment variable set the
worker count. The default is the number of CPUs, and values above 1024 are
rejected. Measured on a 6-core, 12-thread Ryzen 5:

- **50 files, 1.6 MB:** the small-tree path (no threads) is fastest.
- **1,000 files, 32.8 MB:** 2-4 threads give about 90 % of the scaling (21 ms
  against 35 ms single-threaded).
- **5,338 files, 655 MB:** 5-6 threads are best (68.80 ms against 152 ms
  single-threaded). At 12 threads, contention between hyperthread pairs raises
  the time to about 84 ms.

## Design

- **Work-stealing traversal.** Workers act both as directory scanners and as file
  searchers, and traverse depth-first per branch. Output is streamed as results
  arrive, unless `--sort` is given. `--sort` keeps the GNU grep order through
  ordered tickets, and a file with no match releases its ticket with one atomic
  write instead of being buffered.
- **Direct directory reads.** On Linux, `getdents64` feeds 32 KB batches through
  a VFS layer (`src/vfs.zig`), with no `readdir()` or per-entry `stat()`. Ignore
  rules prune branches before `openat`/`statx`. Besides `.gitignore` and
  `.dataignore`, found by walking up to the repository root, a built-in list
  skips `.git`, `node_modules`, `target`, `.zig-cache` and `.venv`.
  `--no-default-ignore` disables that list.
- **Thread start-up.** A directory of at most 32 files is searched on the main
  thread without spawning workers. With `-q`, up to four files in the root are probed before the
  workers start, so an early match exits immediately. Paths are formatted into
  stack buffers during traversal, with no heap allocation per entry.
- **Literal search.** A 32-byte SIMD scan (`@Vector(32, u8)`) is anchored on the
  needle byte that is rarest according to a compile-time frequency table.
  Candidates are verified from `@ctz` bitmasks.
- **Regular expressions.** A Thompson NFA is compiled into a lazily built,
  thread-local DFA. Required literals feed the SIMD prefilter. Execution time is
  linear in the input, with no backtracking.
- **Text handling.** `-i` folds ASCII. For literal patterns it also folds the
  Latin-1 supplement (á/Á, ñ/Ñ); the regex engine folds ASCII only, so
  `-i 'ñand.'` does not match `ÑANDÚ` while `-i 'ñandú'` does. Files with a
  UTF-16 LE/BE byte order mark are decoded, and `--encoding` overrides the
  detection.
- **I/O.** Workers reuse 256 KB buffers and memory-map only files above 256 KB.
  `--io-engine=auto` makes the first read of a probed file a
  `preadv2(RWF_NOWAIT)` probe and switches to `io_uring` when the tree is not in
  the page cache.
- **Navigation plans.** `--nav SPEC` treats the tree as a plane: siblings on one
  axis, depth on the other. The tokens are `v`/`d` (descend), `^`/`u` (prune),
  `>`/`r` (siblings in forward order) and `<`/`l` (reverse order). Two
  combinations are defined: `v^` (or `du`) limits the search to the root's
  files, and `^v` (or `ud`) skips the root's files and searches only the
  subdirectories.

## Verification

Each commit runs CI on Linux and on native Windows:

- unit tests;
- the differential oracle against GNU grep and ripgrep. A case that GNU grep
  cannot express runs only against ripgrep, and is marked as such rather than
  skipped;
- on Windows, smoke tests on Unicode paths, paths containing spaces, the
  small-tree path and `.gitignore` filtering;
- on Linux, one differential per structured-output contract (batch, provenance,
  compact, spill, `--max-columns`), checked against the real files on disk. These
  differentials run against a ReleaseFast build and again against a Debug build,
  which has bounds checks enabled.

Pass counts come from each CI run, not from this document.

There are two fuzzers:

- `zig build fuzz` mutates regex grammars, option combinations and degenerate
  inputs (SIMD boundary sizes, truncated UTF-16, 1 MB lines, NUL floods). It
  checks invariants, for example that the matches of `P` plus the matches of
  `-v P` equal the total line count.
- `zig build cell-fuzz` enumerates every deterministic combination of mode,
  flags, I/O engine, grammar and input (the run prints how many cells). Each cell can be replayed with
  `--cell=N`, and any anomaly writes a standalone reproducer to
  `evidence/reproducers/`.

The history of past verification campaigns, the bugs they found and the Windows
release notes are in [`VERIFICATION.md`](VERIFICATION.md).

## License

MIT.
