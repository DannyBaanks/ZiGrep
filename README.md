# ZigGrep — `zgrep`

A grep-compatible fixed-string search tool written in Zig 0.16 (no libc, no
external dependencies), plus the benchmark harness that measured it against
GNU grep 3.11 and ripgrep 14.1.0 on two corpora.

```
zgrep [OPTIONS] PATTERN [PATH...]
```

Exit status is grep-compatible: `0` match found, `1` no match, `2` error.

## Build and test

```sh
zig build -Doptimize=ReleaseFast      # -> zig-out/bin/zgrep
zig build test --summary all          # 24/24 tests
```

## What it does

| Behaviour | Detail |
|---|---|
| Matching | fixed strings only (`-F`); patterns containing a newline are rejected with exit 2 |
| Recursion | always on (`-r` accepted as a no-op) |
| Line numbers | always on (`-n` accepted as a no-op) |
| Binary files | skipped when a NUL byte appears in the first 8192 bytes (like `grep -I`); `-a` searches them as text |
| Output | `path:line:text`; a single regular-file operand suppresses the path prefix |
| `-c` | prints `path:count` for **every** scanned file, including binary-skipped ones as `:0` (matches GNU grep; ripgrep omits them) |
| `-l` | prints the path only for files with at least one match |
| `-H` / `-h` | force / suppress the path prefix |
| `-q` | quiet: no output, exit status only |
| Traversal | `getdents64` walk in directory-entry order, so output order is byte-identical to GNU grep |

Flags `-F`, `-r`, `-n`, `-I` are accepted for command compatibility and are
always in effect. Clustered short flags (`-rnF`, `-cj4`) work.

### Tuning flags (not in grep)

| Flag | Meaning |
|---|---|
| `-j N`, `--threads N` | worker threads (default: CPU count) |
| `--algo=auto\|bmh\|memchr` | matcher (default `auto`) |
| `--stats` | timing and throughput to stderr |

`auto` picks `memchr` for patterns of ≤ 3 bytes and Boyer–Moore–Horspool
otherwise. **On the benchmark corpus this heuristic is measurably
suboptimal** — see `evidence/REPORT.md`, claim C8.

## Layout

```
build.zig              build script (ReleaseFast default for the exe)
src/main.zig           CLI, options, parallel scheduler, in-order emitter
src/walk.zig           raw getdents64 recursion in directory-entry order
src/scan.zig           file open/mmap, binary probe, line emission
src/search.zig         BMH and memchr matchers
src/root.zig           library root (re-exports the above)
scripts/gen_corpus.zig deterministic synthetic corpus + ground truth
scripts/check.zig      N-command output equivalence control
scripts/bench.zig      interleaved repeated timing, table + JSON
scripts/common.zig     shared raw-syscall/clock/process helpers
scripts/cli_controls.sh flag-level zgrep vs grep control
evidence/              raw outputs, benchmark tables, REPORT.md
```

## Reproduce the benchmark

```sh
# 1. build
zig build -Doptimize=ReleaseFast
zig build test --summary all

# 2. synthetic corpus (131 MB, 2000 files) + ground truth beside it
zig run scripts/gen_corpus.zig -- \
    --out=bench-corpus/synthetic --files=2000 --size=65536 --seed=20261107

# 3. correctness controls
zig run scripts/check.zig -- \
    --name=zgrep ./zig-out/bin/zgrep -rnF PATTERN CORPUS \
    --name=grep  grep -rnIF PATTERN CORPUS \
    --name=rg    rg -n -F --no-ignore --hidden PATTERN CORPUS

# 4. timing (rounds are interleaved across groups, order rotates each round)
zig run scripts/bench.zig -- --runs=10 --warmup=3 --bytes=<corpus bytes> \
    --out=result.json \
    --name=zgrep ./zig-out/bin/zgrep -rnF PATTERN CORPUS \
    --name=grep  grep -rnIF PATTERN CORPUS \
    --name=rg    rg -n -F --no-ignore --hidden PATTERN CORPUS
```

Corpora used:

* **real** — `ISyCo/workspace/assembly`, 5331 files, 654,899,262 bytes on disk
  (402,241,343 of them text; 1137 files carry a NUL inside the first 8 KB)
* **synthetic** — `bench-corpus/synthetic`, 2000 files, 131,128,199 bytes,
  generated from seed `20261107` with a planted token and an exact
  ground-truth file (`bench-corpus/synthetic.truth`)

`bench-corpus/` is git-ignored; regenerate it rather than committing 133 MB.

## Results in one line

On the 655 MB real corpus with pattern `const` (median of 10 interleaved
runs): `zgrep` **97.4 ms**, `zgrep --algo=memchr` **46.4 ms**,
`grep -rInF` **327.1 ms**, `rg` **61.4 ms** — i.e. 3.4× / 7.1× faster than
GNU grep, and the `memchr` variant 1.3× faster than ripgrep while the default
configuration is 1.6× slower than ripgrep.

Full numbers, controls, caveats and the claims table: **`evidence/REPORT.md`**.

## Human guide

See `GUIA.md` for the operating guide (install, common tasks, troubleshooting,
when *not* to use this tool).
