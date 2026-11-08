# ZiGrep pruning stress test on Windows

## Source and environment

- Branch: `feature/zigrep-windows-port`
- ZiGrep HEAD and `origin/main`: `30662a3dd6fea3e7800ee4923ae73d76554f1472`
- OS: Windows 11 build 26200; Intel Xeon E5-2678 v3; 24 logical processors
- Zig: 0.16.0; ripgrep: 15.0.0; GNU grep: 3.0
- `HEAD` matches `origin/main`; the Windows port is still uncommitted.

## Validation

Native Windows validation after formatting:

| Check | Result |
|---|---|
| `zig build test --summary all` | 46/46 tests passed |
| `zig build -Doptimize=ReleaseFast --summary all` | 7/7 steps succeeded |
| `zig build -Doptimize=ReleaseFast oracle --summary all` | 19/19 passed against GNU grep and ripgrep |

Captured stdout and stderr are in `raw/unit-tests.*`, `raw/releasefast-build.*`,
and `raw/differential-oracle.*`.

## Aligned repository comparison

Commands were run natively from PowerShell, with hidden files excluded in both
tools and deterministic path sorting:

```powershell
zigrep.exe --no-hidden --sort --stats -l -F const <repository>
rg.exe --sort path -l -F -- const <repository>
```

Four alternating runs were made per tool and repository. Run 1 warmed the
filesystem; medians below use runs 2–4. Wall time includes process startup and
writing the path list. All runs exited 0.

| Repository | Files / bytes scanned | Matches | ZiGrep samples 2–4 (ms) | rg samples 2–4 (ms) | Median ZiGrep | Median rg | rg / ZiGrep |
|---|---:|---:|---:|---:|---:|---:|---:|
| `workspace/assembly` | 2,168 / 396,769,608 | 229 | 337.86, 292.15, 270.01 | 1,571.44, 1,511.84, 1,550.50 | 292.15 ms | 1,550.50 ms | 5.31x |
| `CoEvoLang` | 5,754 / 79,175,947 | 620 | 630.54, 753.13, 618.52 | 2,439.76, 2,417.71, 2,386.58 | 630.54 ms | 2,417.71 ms | 3.83x |

Both tools returned identical byte-for-byte sorted path lists in every run:

- `workspace/assembly`: SHA-256
  `2D35B48AD3934BD168B40A2696836DEC86C52A3E9F6AA4F912DEC0B798B30662`
- `CoEvoLang`: SHA-256
  `D4E14D7A1F14EAA87DA70E9E465941E57F88BDBB93EC6C26619DF65F8038D4DC`

Each raw stdout path list, its stderr, and the large-tree logs are retained in
`raw/`. Timings are the PowerShell `Stopwatch` measurements from the run; raw
ZiGrep stats are also present in its stderr capture.

## Large-tree and drive-root attempts

- ZiGrep completed a no-match scan of `C:\Development`: 174,017 files,
  10,986,282,400 bytes, zero matches, zero reported errors, 247.3678 seconds
  (44.4 MB/s). The original pattern string was not retained in the raw log.
- ripgrep on `C:\Development` had not completed at the 600-second command
  limit; stdout and stderr were empty when it was stopped. This is not a
  completed performance comparison.
- A bounded `-m v^` probe from `C:\` completed over 2 files / 21,446,962 bytes
  with no matches. A full recursive ZiGrep attempt failed immediately with
  `zgrep: C:\.: ACCES` and scanned zero files. The drive-wide scan is therefore
  **NOT_DEMONSTRATED**; an inaccessible path prevents this walker from
  continuing through the entire tree.
- A full `C:\` ripgrep scan also did not finish within its earlier 240-second
  bound. No full-drive ZiGrep-vs-ripgrep result is claimed.

## Scope

The repo timings are from one Windows host with a warm filesystem cache and
these two trees; they are not a general performance claim. The matching path
sets and native tests are demonstrated. Full-drive recursive completion and
the large `C:\Development` ripgrep comparison are not.
