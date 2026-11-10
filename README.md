# ZiGrep ⚡

[![CI](https://github.com/DannyBaanks/ZiGrep/actions/workflows/ci.yml/badge.svg)](https://github.com/DannyBaanks/ZiGrep/actions/workflows/ci.yml)
[![Zig](https://img.shields.io/badge/Zig-0.16.0-orange.svg)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Ultra-fast, zero-libc, grep-compatible search engine written in pure Zig 0.16.**

The Linux build keeps its direct-syscall fast path. Windows uses native Zig I/O for directory traversal, file reads, memory mapping, clocks, and output; it does not require WSL. Native Windows correctness is checked in CI against GNU grep and ripgrep. The benchmark results below are Linux-only and do not claim Windows performance parity.

`ZiGrep` (`zigrep` / `zgrep`) combines direct Linux kernel syscalls (`getdents64`), lock-free work-stealing swarms, rarest-byte SIMD vectorization, Latin-1 Unicode case-folding, and a linear regex engine with lazy DFA caching to achieve state-of-the-art search throughput across tiny folders, massive monorepos, and whole drives.

```sh
# Search with SIMD acceleration (Kamikaze swarm default)
zigrep "Searcher" src/

# Regular expressions (linear Thompson NFA + lazy DFA, no catastrophic backtracking)
zigrep 'fn\s+\w+\(' /path/to/project

# Case-insensitive with full Latin-1 Unicode folding (á/Á, ñ/Ñ, etc.)
zigrep -i "ñandú" docs/

# Deterministic GNU grep-compatible traversal order
zigrep --sort "pattern" .
```

---

## 🚀 Benchmark Results (Head-to-Head: 10 Corridas Controladas)

Medido en **Ubuntu 24.04 LTS (Kernel Linux x86_64, 12 hilos CPU, NVMe)** tras las optimizaciones de `spinLoopHint`, zero-alloc paths, 256 KB buffers e `io_uring`.  
Cada valor representa la **media aritmética ($\mu$) de 10 corridas cronometradas consecutivas tras 3 rondas de calentamiento previo** en orden intercalado y rotativo para neutralizar jitter de CPU. Verificación contra GNU grep 3.11 y ripgrep 14.1.0.

| Escenario de Prueba | Tamaño / Archivos | `zigrep` (Kamikaze) | `zigrep --uring` | `ripgrep 14.1.0` | `GNU grep 3.11` | Speedup vs ripgrep | Speedup vs GNU grep |
|---|---|---:|---:|---:|---:|---:|---:|
| **Micro-árbol (`corpus_50`)** | 50 archivos (1.6 MB) | **9.88 ms** | 11.91 ms | 13.47 ms | **7.08 ms** | **1.36× más rápido** | 1.39× más lento |
| **Árbol medio (`corpus_1000`)** | 1,000 archivos (32.8 MB) | **23.41 ms** | 35.74 ms | **22.65 ms** | **22.30 ms** | ~Empate | ~Empate |
| **Árbol sintético (`synthetic`)** | 254 archivos (131 MB) | 47.57 ms | 69.92 ms | **37.93 ms** | 51.56 ms | 1.25× más lento | **1.08× más rápido** |
| **Monorepo Real (`assembly`)** | 5,338 archivos (655 MB) | **85.31 ms** | 109.24 ms | 108.67 ms | 535.84 ms | **1.27× más rápido** | **6.28× más rápido** |
| **Regex DFA (`pub\s+fn\s+`)** | `assembly` (655 MB) | **95.63 ms** | 120.05 ms | 120.33 ms | 1,257.67 ms | **1.26× más rápido** | **13.15× más rápido** |
| **Early-Exit `-q` (Silencioso)** | `assembly` (655 MB) | **3.11 ms** | **2.04 ms** | 14.63 ms | 3.01 ms | **4.71× más rápido** | **1.47× más rápido** |
| **Files Without Match `-L`** | `assembly` (655 MB) | **93.68 ms** | 110.85 ms | 125.32 ms | 718.61 ms | **1.34× más rápido** | **7.67× más rápido** |
| **Max Count `-m 1`** | `assembly` (655 MB) | **95.92 ms** | 117.71 ms | 126.65 ms | 678.69 ms | **1.32× más rápido** | **7.08× más rápido** |
| **Invert Match `-v`** | `assembly` (655 MB) | **482.19 ms** | 514.64 ms | 500.22 ms | 1,213.38 ms | **1.04× más rápido** | **2.52× más rápido** |
| **Multi-Repo Real (BRE/Globs)** | 3 repositorios (124 MB) | 32.33 ms | 35.67 ms | **23.90 ms** | 68.88 ms | 1.35× más lento | **2.13× más rápido** |

> *El reporte exhaustivo de las 10 corridas individuales, desviaciones estándar y datos crudos está en [`PRUEBAS.md`](PRUEBAS.md).*

### 🧬 Micro-Tree Fast Path vs Swarm (medición dedicada)

Medido con `scripts/bench.zig` (medianas, rondas intercaladas y rotativas, host con
carga externa: `loadavg` 11–17). Binario `ReleaseFast`, corpus `corpus_50`
(50 archivos, 1.64 MB, 69 directorios):

| Herramienta | Mediana (15 corridas) | Ruta usada |
|---|---:|---|
| `GNU grep -rnIF` | **2.52 ms** | — |
| `zigrep` (por defecto → micro path) | 3.13 ms | `micro_path=yes` |
| `zigrep --force-swarm` | 3.18 ms | 12 hilos + walk de ignores |
| `zigrep -j 1` | 3.32 ms | 1 hilo (pool) |
| `ripgrep -nF` | 5.28 ms | — |

Con **sin salida** (búsqueda muda, `-q`), donde el coste de formato de líneas
desaparece y sólo queda el trabajo de E/S + arranque, la diferencia sí es
estructural:

| Comando | Mediana |
|---|---:|
| `zigrep -q` (micro path, 0 hilos) | **2.00 ms** |
| `zigrep --force-swarm -q` (12 hilos) | 3.35 ms |

En el árbol medio (`corpus_1000`, 1.000 archivos, 32.8 MB) la micro path
*mide* el presupuesto de tamaño y entrega el árbol al enjambre: el sondeo
cuesta **+0.23 ms** frente a `--force-swarm` (6.82 ms vs 6.59 ms), y el
enjambre sigue siendo 4,3× más rápido que `GNU grep` (11.91 ms) y 1,3× más
rápido que `ripgrep` (9.13 ms).

---

## 🛠 Architectural Highlights

1. **Concurrent Kamikaze Swarm by Default**:
   Workers act symmetrically as Directory Scouts and File Scanners using a lock-free work-stealing pool. Traversals run depth-first per branch to maximize CPU L1/L2 cache locality. Just like ripgrep streams matches concurrently across threads by default, `zigrep` runs in swarm mode by default. For users needing exact deterministic GNU grep output order, `--sort` (or `--deterministic`) switches to per-directory sorted traversal.

2. **Direct Kernel VFS Navigation (`getdents64`)**:
   Bypasses standard C library `readdir()` and `stat()` overhead by streaming raw directory entries straight into batch buffers in 32 KB blocks. Dispatches through a clean VFS abstraction layer (`src/vfs.zig`).

3. **Lazy Thread Spawning & Instant Early-Exit**:
   For small directories ($\le 32$ files), execution completes on the main thread with 0 thread spawns, eliminating `clone()` syscall overhead. In `-q` mode, a 3-file probe runs prior to worker initialization for sub-millisecond exits.

4. **Zero-Thread Micro-Tree Fast Path (default)**:
   A tree whose regular files add up to **less than 2 MB** is scanned entirely on the calling thread: **0 worker threads, 0 mutexes, 0 `clone()` syscalls**, and — because ignore-file upkeep is pointless in a tree that small — **no upward `.dataignore`/`.gitignore` inspection either**. The size budget is measured with `statx` *before* any byte is read, so a tree that is too big is handed to the swarm without any wasted I/O. `--force-swarm` restores the old swarm-only behaviour (threads + upward ignore walk) for every tree size.

5. **Rarest-Byte SIMD Vector Scanning**:
   Scans 32-byte chunks (`@Vector(32, u8)`) anchored on the statistically least frequent byte of the needle (using a compile-time frequency matrix) and verifies candidates with `@ctz` bitmasks.

6. **Unicode Latin-1 Case-Folding & UTF-16 Decoding**:
   `-i` applies SIMD bit-masking supporting both ASCII and Latin-1 supplement (Á/á, Ñ/ñ, Ü/ü, etc.) with zero throughput penalty on the critical path. Files with UTF-16 Little-Endian or Big-Endian Byte Order Marks (BOM `0xFF 0xFE` / `0xFE 0xFF`) are automatically detected and decoded transparently.

7. **Linear Regex Engine (Thompson NFA + Lazy DFA)**:
   Supports common extended regex syntax (`.`, `[a-z]`, `[^x]`, `\d`, `\w`, `\s`, `*`, `+`, `?`, `{n,m}`, `|`, `()`, `^`, `$`). Translates to a thread-local cached DFA with automatic transition interning and required literal SIMD pre-filtering. Guarantees $O(N)$ execution with zero catastrophic backtracking.

8. **Universal FilterEngine & Upward Gitignore Discovery**:
   Prunes branches directly at the `getdents64` syscall level. Discovers `.gitignore` and `.dataignore` by traversing upwards to the repository root, skipping build artifacts, caches (`.git`, `node_modules`, `target`, `.zig-cache`, `.venv`), and ignored files before `openat` or `statx`. The upward walk is **deferred**: micro-trees (< 2 MB) skip it entirely, and every other tree pays for it exactly once, right before the swarm starts.

9. **Befunge 2D Vector Scout Navigation (`-m`, `--nav`, `--befunge SPEC`)**:
   Treats the filesystem hierarchy as a 2D Cartesian plane ($X$ = sibling directory entries, $Y$ = filesystem depth) using 2-bit navigation tokens:
   * `v` / `d` (down): descend `openat` into child subdirectories.
   * `^` / `u` (up): ascend / prune subtree traversal.
   * `>` / `r` (right): forward sibling traversal ($0 \to N$).
   * `<` / `l` (left): reverse sibling traversal ($N \to 0$).
   * **Contraposition Combos**:
     * `v^` / `du` (**Depth Ceiling**): Scans depth 0 root files and bounces child subdirectories without descending.
     * `^v` / `ud` (**Trampoline / Leapfrog**): Skips shallow root clutter entirely and dives straight into child subdirectories.

10. **Topological Ticket Pruning ("Poda en Decremento")**:
   Standard grep utilities stall threads and buffer entire output streams in memory when sorting (`--sort path`). `ZiGrep` implements a speculative, lock-free order-preserving pipeline:
   * The Scout assigns monotonic sequence tickets ($0, 1, 2, \dots$) as directory entries stream in from `getdents64`.
   * Workers run SIMD scans on their assigned batches in parallel.
   * Files yielding zero matches are pruned instantaneously with a single atomic memory write (`ready = true, matched = false`), advancing the emission window without memory buffering.
   * Matching results stream out in exact ticket order at bus speeds without latency spikes.

11. **Zero-Allocation Stack Path Formatting**:
   Path formatting in directory walks formats directly into stack-allocated buffers (`formatPathBuf`) with zero heap allocations (`joinPathSentinel` / `allocPrintSentinel`), reducing allocator pressure and cache pollution to zero during deep monorepo scans.

12. **256 KB Reusable Scratch Buffers & Elevated MMAP Threshold**:
   Worker thread scratch buffers are sized at 256 KB and the file memory-mapping threshold is elevated to 256 KB, completely eliminating `mmap`/`munmap` syscall churn on small-to-medium files.

13. **Native Linux `io_uring` Asynchronous Dispatch Engine (`--uring`)**:
   Direct submission/completion queue engine interfacing with the Linux NVMe/filesystem kernel driver via `io_uring_setup` and `io_uring_enter` with zero external libc dependencies. Batches up to 16 asynchronous file reads in a single kernel syscall, falling back gracefully to synchronous workers when files exceed buffer capacity or on unsupported environments.

---

## ⚡ Quick Install (Zero Dependencies, Direct to `$PATH`)

### Linux / macOS

```sh
curl -sSfL https://raw.githubusercontent.com/DannyBaanks/ZiGrep/main/install.sh | bash
```

* **Zero libc / Zero external dependencies**: Self-contained, statically linked pure ELF binary.
* **Auto-detects Architecture**: Instant download of stripped native binaries for `x86_64` (272 KB) and `aarch64` (1.2 MB).
* **Instant `$PATH` Integration**: Automatically symlinks both `zigrep` and `zgrep` into `~/.local/bin` (or `/usr/local/bin` if root), ready for immediate invocation by human developers, shell scripts, and AI coding agents.
* **Offline / Source Fallback**: If offline or building from source, automatically clones and builds using `zig 0.16.0+`.

### Windows (native, no WSL required)

```powershell
irm https://raw.githubusercontent.com/DannyBaanks/ZiGrep/main/install.ps1 | iex
```

* **Native `.exe`, no WSL and no C runtime**: a real Windows build that uses the Win32 API directly.
* **SHA-256 verified**: the installer downloads the release `SHA256SUMS.txt` and refuses to install if the checksum does not match.
* **No admin rights required**: installs to `%LOCALAPPDATA%\Programs\ZiGrep` and appends it to the **user** `PATH` (the current session is updated too, so `zigrep` works immediately).
* **Pinned version**: `irm https://raw.githubusercontent.com/DannyBaanks/ZiGrep/v0.3.0/install.ps1 | iex` installs the current release; `irm https://raw.githubusercontent.com/DannyBaanks/ZiGrep/main/install.ps1 | iex` installs the latest one (it starts working once this PR is merged). Use `install.ps1 -Version 0.3.0` for a specific one.
* **Manual download**: the prebuilt archive is also attached to every GitHub Release as `zigrep-windows-x86_64.zip` (it contains `zigrep.exe`, `zgrep.exe` and `install.ps1`).
* **Runs on every x86_64 Windows machine**: the Windows release is built for the baseline `x86_64-windows` target (SSE2), not for the build machine's CPU. `v0.2.0` was built for `native` on an AVX-512 runner and could not start on older CPUs; `v0.2.1` is the first release with the baseline binary and `v0.2.2` is the first one whose installer completes cleanly (`--version` on stdout, no abort on the child's stderr). The current release is **`v0.3.0`**: its `.exe` disassembles to **0 AVX-512 instructions out of 158,681** (`zmm` registers: 0, mask registers: 0), it runs on this AVX2-only host (Xeon E5-2678 v3), and it passes the 97/98 unit tests and the 29-case differential oracle both natively and for the baseline target. The end-to-end check against the published assets (checksums 3/3 and the real `irm ... | iex` run) is recorded in [`GUIA.md`](GUIA.md#salida-real-del-instalador-publicado-v030).

> Restart your terminal after the installer finishes so the new `PATH` entry is picked up by the shell.

### Release artifacts

Every release ships the same four artifacts, so a build can be audited on any platform:

| Artifact | Platform |
|---|---|
| `zigrep-linux-x86_64.tar.gz` | Linux x86_64 (static, stripped) |
| `zigrep-linux-aarch64.tar.gz` | Linux ARM64 (static, stripped) |
| `zigrep-windows-x86_64.zip` | Windows x86_64 (native `.exe`) |
| `SHA256SUMS.txt` | Checksums for all three archives |

---

## 📦 Manual Build from Source

### Prerequisites
* [Zig](https://ziglang.org/download/) **0.16.0**

### Compile & Install
```sh
git clone https://github.com/DannyBaanks/ZiGrep.git
cd ZiGrep

# Build optimized binary
zig build -Doptimize=ReleaseFast

# Run all unit tests (97/98 pass, 1 skipped, on native Windows with Zig 0.16.0)
zig build test --summary all

# Run pure Zig differential oracle against GNU grep & ripgrep (29/29 on native Windows)
zig build oracle

# Run the Adversarial Entropic Fuzzer Swarm (100k+ permutations across CPU cores)
zig build fuzz -- 100000
```

Binaries are installed at `zig-out/bin/zigrep` (and `zgrep`; on Windows both are `.exe` files).

---

## 🧵 Thread Scaling, Micro-Trees & Environment Variable (`ZIGREP_THREADS`)

### Micro-trees are zero-thread by default

A tree whose regular files add up to **less than 2 MB** is served by the
zero-thread fast path: the search runs on the calling thread, with no worker
pool and without the upward `.dataignore`/`.gitignore` walk. No flag is
needed for it.

```sh
# Micro-tree (< 2 MB): zero threads, no ignore-file walk — this is the default
zigrep "pattern" micro_folder/

# Same tree, old swarm behaviour restored: 12 workers + upward ignore walk
zigrep --force-swarm "pattern" micro_folder/
```

`--stats` reports which path served the run (`micro_path=yes|no`).

### Thread count for everything else

You can control worker threads either via CLI flag (`-j N`, `--threads N`) or dynamically in front of any command with environment variables:

```sh
# Force single-threaded execution on a big tree (rarely useful):
ZIGREP_THREADS=1 zigrep "pattern" /large/monorepo/

# Optimal physical core scaling for large monorepos (5-6 threads on 6-core Ryzen):
ZIGREP_THREADS=6 zigrep "pattern" /large/monorepo/
```

### Empirical Thread Scaling Curve (Ryzen 5: 6 Cores / 12 SMT Threads):
* **Micro-trees (`corpus_50`: 50 files, 1.6 MB)**: **0 threads is optimal** — the zero-thread micro path avoids the `clone()`/join overhead entirely (the old `-j 1` pool measured 3.32 ms, the micro path 3.13 ms, and the 12-thread swarm 3.18 ms on the same corpus).
* **Medium-trees (`corpus_1000`: 1,000 files, 32.8 MB)**: **2–4 Threads** achieve 90% of scaling (21 ms vs 35 ms single-threaded). The micro path measures the size budget and hands the tree to the swarm automatically (+0.23 ms of probing).
* **Large Monorepos (`assembly`: 5,338 files, 655 MB)**: **5–6 Threads is optimal (68.80 ms vs 152 ms single-threaded)**. Beyond 6 threads, SMT cache/execution port contention between paired hyperthreads starts adding slight overhead (~84 ms at 12 threads).

---

## 📖 CLI Usage

```text
zgrep — grep-compatible search (literal + regex) with concurrent kamikaze swarm, written in Zig

usage: zgrep [OPTIONS] PATTERN [PATH...]
       zgrep [OPTIONS] [-e PATTERN...] [PATH...]
       cat FILE | zgrep [OPTIONS] PATTERN

options:
  -F                fixed-string pattern(s); without it PATTERN is a regex
  -E                extended regex (the default; kept for grep compat)
  -G, --basic-regexp
                    basic regex (grep's default). zgrep speaks ERE, so
                    the pattern is TRANSLATED, not ignored
  -e PATTERN        search for PATTERN; repeat for several (any may match)
  -f, --file=FILE   read patterns from FILE (one per line, repeatable)
  -x, --line-regexp match whole lines only
  -i, --ignore-case ignore case (ASCII + Latin-1 Unicode)
  -v, --invert-match
                    select non-matching lines
  -w, --word-regexp match whole words only
  -r                recurse into directories (always on; kept for grep compat)
  -n                print line numbers (always on; kept for grep compat)
      --no-line-number
                    do not print line numbers
  -c, --count       print only a count of matching lines per file
  -l, --files-with-matches
                    print only the names of files with matches
  -L, --files-without-match
                    print only the names of files without matches
  -q, --quiet, --silent
                    quiet: no output, exit status only
  -m, --max-count=NUM
                    stop after NUM matching lines per file
  -A, --after-context=NUM
                    print NUM lines of context after a match
  -B, --before-context=NUM
                    print NUM lines of context before a match
  -C, --context=NUM print NUM lines of context around a match
  -H                print the file name with each result
  -h                do not print the file name with each result
  -a                treat binary files as text
  -Z, -0, --null    print a NUL after each file name
  -o, --only-matching
                    print only the matched part of each line
      --count-matches
                    like --count, but counting matches instead of lines
      --column     print the 1-based byte column of the first match (rg)
      --color[=WHEN]
                    highlight matches (always|never|auto; auto = never)
      --replace=TEXT
                    with -o semantics, print TEXT instead of each match (rg)
      --passthru   also print the lines that do not match (with -r)
      --exec, --execute, -X CMD
                    run CMD for every file with a match; {} is the path.
                    Without {} the path is appended (find -exec style)
  -s, --no-messages suppress error messages about unreadable files
  -j, --threads N   worker threads (default: number of CPUs)
  -S, --smart-case  case-insensitive unless PATTERN has an uppercase
  -t, --type NAME   restrict to a file type (py, zig, md, ...)
      --type-not NAME
                    skip a file type instead
      --type-list    list every known type and exit
      --max-depth=N  do not descend below N levels (rg; long only)
      --max-filesize=N[KMGT]
                    skip files larger than N (rg)
  -b, --byte-offset print the byte offset of each match in the file
      --crlf        treat CRLF as the line terminator, not just \n
  -z, --null-data  NUL separates records instead of \n (grep -z)
  -U, --multiline   a match may span newlines (rg)
      --multiline-dotall
                    with -U, `.` also crosses a newline
      --stop-on-nonmatch
                    stop once a non-matching line follows a matching one
      --pre=CMD    search the stdout of CMD instead of the file (rg);
                    {} in CMD is the file path
      --encoding=ENC
                    auto | none | utf-8 | utf-16 | utf-16le | utf-16be |
                    latin1  (default auto: BOM sniff only)
      --pre-glob=GLOB
                    only apply --pre to files matching GLOB
      --heading     print the file path above each file's matches (rg)
      --no-heading  print it as a per-line prefix instead (default)
  -p, --pretty       alias for --color=always --heading --line-number
      --vimgrep     one line per match, with line and column (rg)
      --binary-files=TYPE
                    text | without-match (zgrep never prints binary
                    content, so 'binary' is rejected, not faked)
  -k, --kamikaze, --dataflow
                    streaming dataflow with concurrent kamikaze swarm (default)
      --sort, --deterministic
                    emit results in deterministic order by path (disables streaming)
  -N, --nav, --befunge SPEC
                    Befunge 2D vector navigation (^, v, >, <, u, d, r, l)
                    combos: v^ / du (ceiling maxdepth 1), ^v / ud (trampoline root skip)
      --exclude-dir=DIR
                    skip directory matching DIR (comma-separated or globs)
      --exclude-ext=EXT
                    skip file extensions (e.g. log,tmp,lock)
      --include-ext=EXT
                    only search file extensions (e.g. zig,rs,py)
      --exclude=GLOB
                    skip files matching GLOB (e.g. *.min.js)
      --exclude-from=FILE
                    read more --exclude globs from FILE, one per line
      --include=GLOB
                    only search files matching GLOB
      --no-ignore   do not read .dataignore / .gitignore or apply defaults
      --no-default-ignore
                    do not apply built-in default ignore lists
      --no-hidden   skip hidden files and directories
      --force-swarm
                    always use the concurrent kamikaze swarm (never the
                    zero-thread micro-tree fast path)
      --algo MODE   auto | bmh | memchr   (default: auto)
      --stats       print timing and throughput to stderr
      --uring       use Linux io_uring asynchronous batched I/O engine
                     (exact alias of --io-engine=uring)
      --io-engine=  sync | uring | auto   (default: auto). auto makes the
                     first read of each probed file a preadv2(RWF_NOWAIT)
                     probe: if the page is in RAM its bytes are scanned
                     directly; if the tree is cold it promotes to
                     io_uring. sync is the old behaviour, byte for byte
      --help        print this help
  -V, --version     print the version

regex dialect (same as rg): . [a-z] [^x] [[:alpha:]] \d \w \s * + ? {n,m} | ( ) ^ $
word boundaries \b and \B are supported (zero-width assertions).
not supported (reported as an error): back-references, lookaround.
a plain string with no metacharacters takes the fast literal path.
patterns containing a newline are rejected.
when no PATH is given or when PATH is '-', standard input is read.

exit status: 0 match found, 1 no match, 2 error
```

---

## 🧪 Ground Truth & CI Verification

Every commit is tested via GitHub Actions CI in pure Zig:
* **Unit Tests**: **97/98 pass, 1 skipped** on native Windows with Zig 0.16.0; the same suite passes when cross-compiled for the baseline `x86_64-windows` target, which is the one the release ships. The single skip is the Linux-only `io_uring` test. They cover memory allocators, VFS streams, AST parsing, regex compilation (with both ERE `|` and GNU BRE `\|` alternation), Latin-1 Unicode folding, UTF-16 BOM decoding, Befunge 2D vector navigation plans, inverted matching (`-v`), file omission listings (`-L`), match caps (`--max-count`), multi-pattern globs (`--include`), `--crlf` line counting, NUL-separated records (`--null-data`), SIMD shifts, and native Linux `io_uring` batched asynchronous I/O.
* **Differential Oracle (`zig build oracle`)**: **29 checks pass with 0 failures** on native Windows, and the same 29 pass for the baseline target. Each case is compared against GNU grep where grep 3.0 can express it and against ripgrep otherwise (three cases — `--count-matches`, `--replace`, `--column` — exist only in ripgrep and are marked `grep_args = null` instead of being silently skipped). Coverage includes navigation ceiling, trampoline modes, `io_uring` asynchronous batched engine `--uring`, invert match `-v`, non-matching file listings `-L`, match caps `-m NUM`, `--exclude-from`, and piped standard input (POSIX-only; the runner skips that one case on Windows, so Linux counts one more).
* **Native Windows job**: builds ReleaseFast, runs the same unit tests and differential oracle, then smoke-tests Unicode/space-containing paths, the zero-thread micro-tree path, and `.gitignore` filtering under `--force-swarm`.
* **Adversarial Entropic Fuzzer Swarm (`zig build fuzz`)**: A parallel multi-core stress testing swarm featuring 4 specialized adversaries:
  1. **The Grammar Shatterer**: Mutates regex grammars, unbalanced groups, quantifier overflows, nested alternations, control bytes, and catastrophic backtracking patterns.
  2. **The Chaos CLI Permutator**: Generates combinatorial, conflicting, and edge-case CLI flags (`-v`, `-c`, `-l`, `-L`, `-q`, extreme numeric counts, Befunge navigation specs) running against an isolated dummy sandbox sink.
  3. **The Toxic Payload Injector**: Generates degenerate buffers (SIMD boundary alignments at 15/16/31/32/64 bytes, truncated UTF-16 BOMs with odd byte lengths, 1 MB single lines, and NUL floods).
  4. **The Differential Oracle Auditor**: Enforces mathematical invariants across search modes (invert match partition: `matches(P) + matches(-v P) == total_lines`, quiet mode exit code equivalence, line count invariants, and BMH vs memchr equivalence).
  * Validated against **100,000+ continuous operations** at **> 12,000 ops/second** with **0 crashes, 0 panics, and 0 anomalies**.
* **N-Dimensional Discrete Cell Space Fuzzer (`zig build cell-fuzz`)**:
  Maps the entire combinatorial universe of CLI options, execution engines, pattern grammars, and payloads into a 5-dimensional coordinate manifold of **373,248 distinct deterministic cells** ($9 \text{ modes} \times 16 \text{ flag masks} \times 9 \text{ engines} \times 24 \text{ grammars} \times 12 \text{ haystacks}$):
  * **Bijective Coprime Weyl Dispersion**: Traversal uses a full-period coprime permutation cycle (`(k * 137329) % 373248`) where consecutive integers jump across all 5 dimensions simultaneously while guaranteeing 100% space coverage with zero duplicate or skipped cells.
  * **Single-Cell Diagnostic Inspector**: Any cell index (e.g. `zig build cell-fuzz -- --cell=48291`) decompiles the exact coordinates and executes an isolated invariant audit.
  * **Linear & Range Sweeps**: Execute custom ranges (e.g. `zig build cell-fuzz -- 1 1000` or `--linear 1 5000`) or exhaustively verify the entire manifold with `zig build cell-fuzz -- --all`.
  * **Automated Standalone Reproducer Generation**: Any discrepancy or anomaly dumps an executable standalone reproducer script directly to `evidence/reproducers/cell_<id>.sh`.
  * **Empirical Verification**: Exhaustively tested across all **373,248 cells** in **26 seconds** (> 14,300 cells/sec) on 12 threads with **0 invariant violations, 0 crashes, and 0 panics**.
  * **Windows status**: the cell fuzzer was **ported to Windows in this branch** (upstream's version called the pre-port `scripts/common.zig` API, which no longer exists after the Windows port: the io-first API needs an explicit `std.Io` handle). It was then executed natively on Windows 11 build 26200 with Zig 0.16.0. A single-cell diagnostic (`--cell=48291`) passed all invariants, a 20,000-cell sweep finished in **0.639 s (31,297 cells/sec)**, and the **exhaustive sweep of all 373,248 cells** finished in **10.84 s (34,433 cells/sec)** on 24 workers with **0 anomalies, 0 invariant violations and 0 crashes**. The exhaustive run is therefore **DEMONSTRATED on native Windows**, not just on upstream's Linux.
* **Windows fuzzing results (native, this branch)**: the swarm and the tri-way differential fuzzer (`scripts/tri_fuzz.py`, ZiGrep vs ripgrep vs GNU grep) were ported to Windows and executed locally on Windows 11 build 26200 with Zig 0.16.0. A run of 3,001 operations (all adversaries, entropy knob 3) reported **0 anomalies, 0 crashes, 0 invalid exit codes, 0 invariant violations**. The tri-way fuzzer was run at entropy knobs 3, 4 (ReDoS bait) and 5 (chaos) for 40-250 permutations each: **0 crashes, 0 timeouts, 0 anomalous discrepancies** for all three engines. The tri-way fuzzer compares exit codes, crashes, timeouts **and** the matched file/line sets; the full-content parity is what the differential oracle above verifies.
* **Windows-specific adversarial probe (`scripts/adversarial_windows.py`)**: a targeted probe builds a hostile tree (Unicode + spaces in directory and file names, deep nesting, > 260-character paths, CRLF files, UTF-16 BOM files, NUL-containing binaries, `.gitignore`, symlinks, empty directories) and compares ZiGrep against GNU grep case by case across the `ScanConfig` surface (`-v`, `-m`, `-L`, `-c`, `-q`) and the Windows path surfaces.
* **Bug found by the Windows fuzzing and fixed in this branch**: an absurd worker count (`-j 18446744073709551615`, `--threads=...`, or the `ZIGREP_THREADS` environment variable) reached the thread-spawn loop and turned it into an endless create-and-exit cycle that pinned the machine at 100% CPU. The CLI now rejects any count above **1024** with exit code 2 and a clear message (`thread count out of range (max 1024)`), and `kamikaze.zig` clamps the pool defensively as a second line of defence. Two regression tests cover the boundary.
* **Fifth bug found while verifying the installer end to end (in `install.ps1`, not in `zigrep`)**: the installer **aborted on a successful install**. Its last step runs `zigrep.exe --version`, and `zigrep` printed the version on **stderr**. With `$ErrorActionPreference = "Stop"` (which the installer sets to fail closed on a checksum mismatch) a native command writing to stderr raises a terminating `NativeCommandError` in Windows PowerShell, so the installer died right after installing, before printing "ZiGrep is ready.". The installer now runs native commands through a helper that cannot be aborted by their stderr, and `zigrep --version` / `--help` now print on **stdout** (like `grep` and `ripgrep`), which is the conventional place for an answer rather than a diagnostic.
* **Third bug found while verifying the release (in the release workflow, not in `zigrep`)**: the published Windows `.exe` did not start on CPUs without AVX-512. The release workflow built with the default target, which means `native` — "whatever CPU this runner happens to have". The `windows-latest` runner reports AVX-512, so the published binary contained **3,499 EVEX (AVX-512) instruction prefixes** and died at load time with `STATUS_ILLEGAL_INSTRUCTION` (`0xC000001D`) on every x86_64 CPU without AVX-512 (Haswell, Broadwell, Zen 1, ...). The release workflow now builds for the explicit baseline target `x86_64-windows` (SSE2), which runs everywhere. Measured cost on this host (Xeon E5-2678 v3, 2,639 files / 522 MB, 10 timed runs): **143.4 ms baseline vs 141.2 ms native** — 1.6%, inside the noise, because the workload is I/O bound. `v0.2.1` is the first release with the corrected binary; `v0.2.0` is superseded. *(Measurement note, 0.3.0: counting raw `0x62` bytes is **not** a valid EVEX check — it also counts ordinary data bytes. The `v0.3.0` baseline binary contains 530 such bytes but **zero** AVX-512 instructions once disassembled: 0 `zmm` operands and 0 mask registers in 158,681 instructions. Use `objdump -d` and look for `zmm`/`%k1`, or just run the binary on an AVX2-only CPU.)*
* **Second bug found by the Windows fuzzing (in the fuzzer itself, not in `zigrep`)**: the swarm could deadlock on Windows. It captured the child's output with a 4 KB limit, but `std.process.run` stops reading once the limit is exceeded while the child keeps writing; with an 8 KB Windows pipe the child blocks forever and the swarm never returns. Measured: **4 hangs in 12 campaigns** before the fix, **0 in 18** after it. The swarm now drains the child's streams to EOF (`--cli-timeout-ms=N` remains as a watchdog) and the fuzzer gained a `--trace-cli` diagnostic that prints every spawned argv with paired `START`/`END` markers, so a child that never finishes is identifiable instead of guessed at.
* **Seven bugs found by the 0.3.0 Windows re-audit (differential probe against ripgrep 15.0.0 and GNU grep 3.0), all fixed and pinned by tests**:
  1. `--count-matches` always printed **0**: the counter was incremented on a code path the reporting layer never read.
  2. `-z` / `--null-data` wrote **NUL as the field separator** between the line number and the text, so `1\0text` came out where `1:text` belongs (the NUL is the *record* separator, not the field one).
  3. `--crlf` numbered the matches **1, 3, 5, ...** and stripped the CR from the output, because each CRLF was counted as two line terminators.
  4. `--exclude-from` was **ignored on the streaming path** (it only filtered the sorted/`--sort` walk), so the same command excluded different files depending on `-j`.
  5. `--heading` was a **no-op when the operand was a directory**: the rule was `valid_operands.len > 1`, which asks how many arguments were typed instead of whether a path is going to be printed, so `zigrep --heading foo src/` produced no headers at all.
  6. `--replace` replaced the match and **discarded the rest of the line** instead of substituting in place.
  7. `--help` stated that `\b` / `\B` were **not supported**, which was false since the word-boundary nodes landed; a wrong help string sends the reader looking for a bug in their own pattern.
  The `--crlf` fix also corrected a latent guard in `firstMatchingLine` (`i + 1 < to` never sees the CRLF pair when the prefiltered path passes `to` = index of the `\n`), which is why the bug only showed up through the regex path.
* **One bug found in the Python bindings (not in `zigrep`)**: on Windows, 8 parity tests errored with `ValueError: the environment variable is longer than 32767 characters`. pytest derives the test id from the parameter, and the parameters are 200 KB buffers; `PYTEST_CURRENT_TEST` then hits `SetEnvironmentVariable`'s limit. The tests are correct — the *id* was not portable. Explicit short ids (`ids=IDS`) fixed it: **42/42 pass** on native Windows.
* **Exit Codes**: Grep-compliant `0` (match found), `1` (no match), `2` (error).
* **Deterministic Output**: `--sort` / `--deterministic` mode preserves exact directory-entry emission order identical to GNU grep; default streaming mode provides high-throughput concurrent emission.

---

## 📄 License

MIT License. Designed and engineered for high-performance systems research.
