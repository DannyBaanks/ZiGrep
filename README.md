# ZiGrep ⚡

[![CI](https://github.com/DannyBaanks/ZiGrep/actions/workflows/ci.yml/badge.svg)](https://github.com/DannyBaanks/ZiGrep/actions/workflows/ci.yml)
[![Zig](https://img.shields.io/badge/Zig-0.16.0-orange.svg)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Ultra-fast, zero-libc, grep-compatible search engine written in pure Zig 0.16.**

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

## 🚀 Benchmark Results (Head-to-Head)

Measured on **Ubuntu 24.04 LTS (Kernel 7.0.0, 12 AMD/Intel CPUs, NVMe)**.  
Every figure represents the **median of repeated runs after warm-up** with ground-truth verification against GNU grep 3.11 and ripgrep 14.1.0.

| Workload / Benchmark Scenario | `zigrep` (Default Swarm) | `zigrep --sort` (Deterministic) | `ripgrep 14.1.0` | `GNU grep 3.11` | Speedup vs ripgrep | Speedup vs GNU grep |
|---|---:|---:|---:|---:|---:|---:|
| **Micro-dir (`src/`, 8 files)** | **1.43 ms** | 1.59 ms | 3.81 ms | 1.78 ms | **2.66× faster** | **1.24× faster** |
| **Early-Exit `-q` (`src/`)** | **1.38 ms** | **1.33 ms** | 3.62 ms | 1.48 ms | **2.71× faster** | **1.11× faster** |
| **Early-Exit `-q` ($HOME `~`)** | **7.72 ms** | 42.10 ms | 8.10 ms | 3.63 ms | **1.05× faster** | 2.12× slower |
| **Assembly Corpus (670 MB, 5,338 files)** | **32.61 ms** | 41.09 ms | 66.15 ms | 415.51 ms | **2.03× faster** | **12.74× faster** |
| **Monorepo Real (1.4 GB `CoEvoLang`)** | **29.40 ms** | 1.77 s | 49.40 ms | 4,878.99 ms | **1.68× faster** | **165.9× faster** |
| **Regex Engine (`def\s+\w+\(` in 1.4 GB)** | **32.36 ms** | 1.82 s | 32.84 ms | 4,676.77 ms | **1.01× faster** | **144.5× faster** |

> *Full raw logs, environment parameters, and SHA-256 hashes are preserved in [`evidence/REPORT.md`](evidence/REPORT.md).*

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

---

## 📦 Installation & Build

### Prerequisites
* [Zig](https://ziglang.org/download/) **0.16.0+**

### Compile & Install
```sh
git clone https://github.com/DannyBaanks/ZiGrep.git
cd ZiGrep

# Build optimized binary
zig build -Doptimize=ReleaseFast

# Run all unit tests (42/42)
zig build test --summary all

# Run pure Zig differential oracle against GNU grep & ripgrep (17/17)
zig build oracle
```

Binaries are installed at `zig-out/bin/zigrep` (and symlinked `zgrep`).

---

## 📖 CLI Usage

```text
zgrep — grep-compatible search (literal + regex) with concurrent kamikaze swarm, written in Zig

usage: zgrep [OPTIONS] PATTERN [PATH...]

options:
  -F                fixed-string pattern(s); without it PATTERN is a regex
  -E                extended regex (the default; kept for grep compat)
  -e PATTERN        search for PATTERN; repeat for several (any may match)
  -i                ignore case (ASCII + Latin-1 Unicode)
  -w                match whole words only
  -r                recurse into directories (always on; kept for grep compat)
  -n                print line numbers (always on; kept for grep compat)
  -c                print only a count of matching lines per file
  -l                print only the names of files with matches
  -q                quiet: no output, exit status only
  -H                print the file name with each result
  -h                do not print the file name with each result
  -a                treat binary files as text
  -j, --threads N   worker threads (default: number of CPUs)
  -k, --kamikaze, --dataflow
                    streaming dataflow with concurrent kamikaze swarm (default)
      --sort, --deterministic
                    emit results in deterministic order by path (disables streaming)
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
* **Unit Tests**: 42/42 tests covering memory allocators, VFS streams, AST parsing, regex compilation, UTF-16 BOM decoding, and SIMD shifts.
* **Differential Oracle (`zig build oracle`)**: 17 automated multi-way verification checks against GNU grep (`-rIF` / `-rIE`) and ripgrep.
* **Exit Codes**: Grep-compliant `0` (match found), `1` (no match), `2` (error).
* **Deterministic Output**: `--sort` / `--deterministic` mode preserves exact directory-entry emission order identical to GNU grep; default streaming mode provides high-throughput concurrent emission.

---

## 📄 License

MIT License. Designed and engineered for high-performance systems research.
