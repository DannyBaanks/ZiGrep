# Binary rule (2026-11-12)

## The rule (`src/scan.zig`, `searchBytes`)

Unless `-a`, `--null-data` (NUL is the record separator) or a UTF-16
decoding is in force:

- a NUL in the first 8 KiB: the file is binary and is not searched (as
  before; `grep -I` and rg skip it too);
- a NUL further in: the file is text up to the start of the line that holds
  the first NUL; nothing from that line on is printed or counted.

So `-l`, `-L`, `-c`, `--count-matches`, `--json` and the printed lines always
agree, and no binary byte reaches the output. The extra check only runs for
files that matched, and for `-l`/`-q`/`-L` only up to the first match.

## What was wrong before

- A NUL after the 8 KiB window went unnoticed: the file was searched as text
  and its binary lines were printed. On a broad search over a local tree of
  140 repositories (`zgrep -n -e e .`), the output of 96c6fbb carried 47 076
  NUL bytes (~14.5 MB of binary data); this version prints none.
- `-l` and `-c` could disagree with the printed lines on such files.
- Six copies of the probe had drifted apart: the io_uring path ignored
  `--null-data` and `--encoding`, and the large-file (mmap) and io_uring
  paths lost `--count-matches` (it printed 0 for any file over 256 KiB;
  rg says 2 on the same file). All paths now call `searchBytes`.

rg is not the reference here: it decides per read block, so a file whose NUL
falls in the first block is skipped whole, and the same file can be listed or
not depending on how it is read (seen on a PDF: listed when its directory is
the root, not from the repository root).

## Test (`binary_consistency.py`, also in CI, ReleaseFast and Debug)

A generated tree with NUL positions (none, in the window, after it,
before/after the matches, mid-line) and sizes that take each read path
(scratch buffer, mmap > 256 KiB, io_uring), plus enough files to start the
swarm. For `--io-engine=sync`, `--io-engine=uring`, `--force-swarm` and `-j1`
the output of lines, `-c`, `-l`, `-L`, `--count-matches` and `--json` must
equal a Python model of the rule, with no NUL in the output; `-a` must read
past the NUL. 96c6fbb: 4 pass / 33 fail. This version: 37 / 37.

## Cost

`hbin3_*.json`: `-c const` over a real repo (~8 600 files, ~4 500 matching),
150 runs, three binaries in two orders, on a loaded machine (load ~7):
medians 23.1 / 21.5 / 23.7 ms and 23.9 / 23.7 / 23.0 ms for before /
after-without-the-late-check / after. The order flips between runs, so the
cost is below the noise floor (at most about 1 ms here).

## Not demonstrated / not done

- No notice for skipped binary files (grep prints "binary file matches", rg
  does for files named explicitly). Reporting it would mean searching every
  binary file past the probe; not done.
- `--pre` output is searched without the binary rule (as before).
