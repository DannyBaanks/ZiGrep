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

Medido en **Ubuntu 24.04 LTS (Kernel 7.0.0, 12 AMD/Intel CPUs, NVMe)**.  
Cada valor representa la **media aritmética ($\mu$) de 10 corridas cronometradas consecutivas tras 3 rondas de calentamiento previo** en orden intercalado y rotativo para neutralizar jitter de CPU. Verificación contra GNU grep 3.11 y ripgrep 14.1.0.

| Escenario de Prueba | Tamaño / Archivos | `zigrep` (Default) | `zigrep --sort` (Ordenado) | `ripgrep 14.1.0` | `GNU grep 3.11` | Speedup vs ripgrep | Speedup vs GNU grep |
|---|---|---:|---:|---:|---:|---:|---:|
| **Micro-árbol (`corpus_50`)** | 50 archivos (1.6 MB) | **5.74 ms** | 6.76 ms | 7.95 ms | **3.92 ms** | **1.38× más rápido** | 1.46× más lento |
| **Árbol medio (`corpus_1000`)** | 1,000 archivos (32.8 MB) | **9.03 ms** | 15.68 ms | 11.49 ms | 13.58 ms | **1.27× más rápido** | **1.50× más rápido** |
| **Árbol sintético (`synthetic`)** | 2,000 archivos (131 MB) | **21.04 ms** | 27.24 ms | **18.57 ms** | 34.72 ms | 1.13× más lento | **1.65× más rápido** |
| **Monorepo Real (`assembly`)** | 5,338 archivos (655 MB) | **26.72 ms** | **41.42 ms** | 62.92 ms | 343.61 ms | **2.35× más rápido** | **12.86× más rápido** |
| **Monorepo Real (`CoEvoLang`)** | Árbol real (1.45 GB) | **21.71 ms** | 53.02 ms | **20.38 ms** | 2,146.80 ms | *Empate (~20 ms)* | **98.88× más rápido** |
| **Regex Engine (`pub\s+fn\s+`)** | `assembly` (655 MB) | **25.93 ms** | **41.84 ms** | 61.08 ms | 333.46 ms | **2.35× más rápido** | **12.86× más rápido** |
| **Early-Exit `-q` (Silencioso)** | `assembly` (655 MB) | **5.81 ms** | — | 4.99 ms | **2.23 ms** | ~A la par | 2.60× más lento |

> *El reporte exhaustivo de las 10 corridas individuales, desviaciones estándar y datos crudos está en [`PRUEBAS.md`](PRUEBAS.md). Los logs completos y hashes SHA-256 están en [`evidence/REPORT.md`](evidence/REPORT.md).*

---

## 🛠 Architectural Highlights

1. **Concurrent Kamikaze Swarm by Default**:
   Workers act symmetrically as Directory Scouts and File Scanners using a lock-free work-stealing pool. Traversals run depth-first per branch to maximize CPU L1/L2 cache locality. Just like ripgrep streams matches concurrently across threads by default, `zigrep` runs in swarm mode by default. For users needing exact deterministic GNU grep output order, `--sort` (or `--deterministic`) switches to per-directory sorted traversal.

2. **Direct Kernel VFS Navigation (`getdents64`)**:
   Bypasses standard C library `readdir()` and `stat()` overhead by streaming raw directory entries straight into batch buffers in 32 KB blocks. Dispatches through a clean VFS abstraction layer (`src/vfs.zig`).

3. **Lazy Thread Spawning & Instant Early-Exit**:
   For small directories ($\le 32$ files), execution completes on the main thread with 0 thread spawns, eliminating `clone()` syscall overhead. In `-q` mode, a 3-file probe runs prior to worker initialization for sub-millisecond exits.

4. **Rarest-Byte SIMD Vector Scanning**:
   Scans 32-byte chunks (`@Vector(32, u8)`) anchored on the statistically least frequent byte of the needle (using a compile-time frequency matrix) and verifies candidates with `@ctz` bitmasks.

5. **Unicode Latin-1 Case-Folding & UTF-16 Decoding**:
   `-i` applies SIMD bit-masking supporting both ASCII and Latin-1 supplement (Á/á, Ñ/ñ, Ü/ü, etc.) with zero throughput penalty on the critical path. Files with UTF-16 Little-Endian or Big-Endian Byte Order Marks (BOM `0xFF 0xFE` / `0xFE 0xFF`) are automatically detected and decoded transparently.

6. **Linear Regex Engine (Thompson NFA + Lazy DFA)**:
   Supports common extended regex syntax (`.`, `[a-z]`, `[^x]`, `\d`, `\w`, `\s`, `*`, `+`, `?`, `{n,m}`, `|`, `()`, `^`, `$`). Translates to a thread-local cached DFA with automatic transition interning and required literal SIMD pre-filtering. Guarantees $O(N)$ execution with zero catastrophic backtracking.

7. **Universal FilterEngine & Upward Gitignore Discovery**:
   Prunes branches directly at the `getdents64` syscall level. Discovers `.gitignore` and `.dataignore` by traversing upwards to the repository root, skipping build artifacts, caches (`.git`, `node_modules`, `target`, `.zig-cache`, `.venv`), and ignored files before `openat` or `statx`.

8. **Befunge 2D Vector Scout Navigation (`-m`, `--nav`, `--befunge SPEC`)**:
   Treats the filesystem hierarchy as a 2D Cartesian plane ($X$ = sibling directory entries, $Y$ = filesystem depth) using 2-bit navigation tokens:
   * `v` / `d` (down): descend `openat` into child subdirectories.
   * `^` / `u` (up): ascend / prune subtree traversal.
   * `>` / `r` (right): forward sibling traversal ($0 \to N$).
   * `<` / `l` (left): reverse sibling traversal ($N \to 0$).
   * **Contraposition Combos**:
     * `v^` / `du` (**Depth Ceiling**): Scans depth 0 root files and bounces child subdirectories without descending.
     * `^v` / `ud` (**Trampoline / Leapfrog**): Skips shallow root clutter entirely and dives straight into child subdirectories.

9. **Topological Ticket Pruning ("Poda en Decremento")**:
   Standard grep utilities stall threads and buffer entire output streams in memory when sorting (`--sort path`). `ZiGrep` implements a speculative, lock-free order-preserving pipeline:
   * The Scout assigns monotonic sequence tickets ($0, 1, 2, \dots$) as directory entries stream in from `getdents64`.
   * Workers run SIMD scans on their assigned batches in parallel.
   * Files yielding zero matches are pruned instantaneously with a single atomic memory write (`ready = true, matched = false`), advancing the emission window without memory buffering.
   * Matching results stream out in exact ticket order at bus speeds without latency spikes.

---

## 📦 Installation & Build

### Prerequisites
* [Zig](https://ziglang.org/download/) **0.16.0**

### Compile & Install
```sh
git clone https://github.com/DannyBaanks/ZiGrep.git
cd ZiGrep

# Build optimized binary
zig build -Doptimize=ReleaseFast

# Run all unit tests (52/52 on native Windows, Zig 0.16.0)
zig build test --summary all

# Run pure Zig differential oracle against GNU grep & ripgrep (24/24 on native Windows)
zig build oracle
```

Binaries are installed at `zig-out/bin/zigrep` (and `zgrep`; on Windows both are `.exe` files).

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
  -e PATTERN        search for PATTERN; repeat for several (any may match)
  -i, --ignore-case ignore case (ASCII + Latin-1 Unicode)
  -v, --invert-match
                    select non-matching lines
  -w, --word-regexp match whole words only
  -r                recurse into directories (always on; kept for grep compat)
  -n                print line numbers (always on; kept for grep compat)
  -c, --count       print only a count of matching lines per file
  -l, --files-with-matches
                    print only the names of files with matches
  -L, --files-without-match
                    print only the names of files without matches
  -q, --quiet, --silent
                    quiet: no output, exit status only
  -m, --max-count=NUM
                    stop after NUM matching lines per file
  -H                print the file name with each result
  -h                do not print the file name with each result
  -a                treat binary files as text
  -j, --threads N   worker threads (default: number of CPUs)
  -k, --kamikaze, --dataflow
                    streaming dataflow with concurrent kamikaze swarm (default)
      --sort, --deterministic
                    emit results in deterministic order by path (disables streaming)
  -m, --nav SPEC    Befunge 2D vector navigation (^, v, >, <, u, d, r, l)
                    combos: v^ / du (ceiling maxdepth 1), ^v / ud (trampoline root skip)
      --exclude-dir=DIR
                    skip directory matching DIR (comma-separated or globs)
      --exclude-ext=EXT
                    skip file extensions (e.g. log,tmp,lock)
      --include-ext=EXT
                    only search file extensions (e.g. zig,rs,py)
      --exclude=GLOB
                    skip files matching GLOB (e.g. *.min.js)
      --include=GLOB
                    only search files matching GLOB
      --no-ignore   do not read .dataignore / .gitignore or apply defaults
      --no-default-ignore
                    do not apply built-in default ignore lists
      --no-hidden   skip hidden files and directories
      --algo MODE   auto | bmh | memchr (default: auto)
      --stats       print timing and throughput to stderr
  -V, --version     print version
      --help        print help
```

---

## 🧪 Ground Truth & CI Verification

Every commit is tested via GitHub Actions CI in pure Zig:
* **Unit Tests**: 52/52 tests on native Windows (Zig 0.16.0), covering memory allocators, VFS streams, AST parsing, regex compilation (with both ERE `|` and GNU BRE `\|` alternation), Latin-1 Unicode folding, UTF-16 BOM decoding, Befunge 2D vector navigation plans, inverted matching (`-v`), file omission listings (`-L`), match caps (`--max-count`), multi-pattern globs (`--include`), and SIMD shifts.
* **Differential Oracle (`zig build oracle`)**: 24/24 automated multi-way verification checks on native Windows against GNU grep (`-rIF` / `-rIE`) and ripgrep (including navigation ceiling, trampoline modes, invert match `-v`, non-matching file listings `-L`, and match caps `-m NUM`). The POSIX-only piped-stdin case is skipped on Windows (it needs `sh -c`); Linux runs the full 25 checks.
* **Native Windows job**: builds ReleaseFast, runs the same unit tests and differential oracle, then smoke-tests Unicode/space-containing paths and `.gitignore` filtering.
* **Exit Codes**: Grep-compliant `0` (match found), `1` (no match), `2` (error).
* **Deterministic Output**: `--sort` / `--deterministic` mode preserves exact directory-entry emission order identical to GNU grep; default streaming mode provides high-throughput concurrent emission.

---

## 📄 License

MIT License. Designed and engineered for high-performance systems research.
