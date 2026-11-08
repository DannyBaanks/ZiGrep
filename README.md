# zigrep (`zgrep`) ⚡

**Ultra-fast, zero-libc, grep-compatible search engine written in pure Zig 0.16.**

`zigrep` combines direct Linux kernel syscalls (`getdents64`), lock-free work-stealing swarms, rarest-byte SIMD vectorization, and a linear regex engine with lazy DFA caching to achieve state-of-the-art search throughput across tiny folders, massive monorepos, and whole drives.

```sh
# Search with SIMD acceleration
zigrep "Searcher" src/

# Regular expressions (linear-time, no backtracking)
zigrep 'fn\s+\w+\(' /path/to/project

# Concurrent streaming swarm with automatic gitignore pruning
zigrep -k --stats "pattern" ~
```

---

## 🚀 Benchmark Results (Head-to-Head)

Measured on **Ubuntu 24.04 LTS (Kernel 7.0.0, 12 AMD/Intel CPUs, NVMe)**.  
Every figure represents the **median of repeated runs after warm-up** with ground-truth verification against GNU grep 3.11 and ripgrep 14.1.0.

| Workload / Benchmark Scenario | `zigrep -k` (Swarm) | `zigrep` (Standard) | `ripgrep 14.1.0` | `GNU grep 3.11` | Speedup vs ripgrep | Speedup vs GNU grep |
|---|---:|---:|---:|---:|---:|---:|
| **Micro-dir (`src/`, 8 files)** | **1.43 ms** | 1.59 ms | 3.81 ms | 1.78 ms | **2.66× faster** | **1.24× faster** |
| **Early-Exit `-q` (`src/`)** | **1.38 ms** | **1.33 ms** | 3.62 ms | 1.48 ms | **2.71× faster** | **1.11× faster** |
| **Early-Exit `-q` ($HOME `~`)** | **7.72 ms** | *(legacy timeout)* | 8.10 ms | 3.63 ms | **1.05× faster** | 2.12× slower |
| **Assembly Corpus (670 MB, 5,338 files)** | **32.61 ms** | 41.09 ms | 66.15 ms | 415.51 ms | **2.03× faster** | **12.74× faster** |
| **Monorepo Real (1.4 GB `CoEvoLang`)** | **32.62 ms** | *(legacy timeout)* | 35.20 ms | 4,878.99 ms | **1.08× faster** | **149.5× faster** |
| **Regex Engine (`def\s+\w+\(` in 1.4 GB)** | **32.36 ms** | *(legacy timeout)* | 32.84 ms | 4,676.77 ms | **1.01× faster** | **144.5× faster** |

> *Full raw logs, environment parameters, and SHA-256 hashes are preserved in [`evidence/REPORT.md`](evidence/REPORT.md).*

---

## 🛠 Architectural Highlights

1. **Direct Kernel VFS Navigation (`getdents64`)**:
   Bypasses standard C library `readdir()` and `stat()` overhead by streaming raw directory entries straight into batch buffers.

2. **Concurrent Kamikaze Swarm (`-k`)**:
   Unified work-stealing pool where any idle worker thread acts symmetrically as either a Directory Scout or a File Scanner. Tree traversal is depth-first per branch to maximize CPU L1/L2 cache locality.

3. **Lazy Thread Spawning & Instant Early-Exit**:
   For small directories ($\le 32$ files), execution completes on the main thread with 0 thread spawns, eliminating `clone()` syscall overhead. In `-q` mode, a 3-file probe runs prior to worker initialization for sub-millisecond exits.

4. **Rarest-Byte SIMD Vector Scanning**:
   Scans 32-byte chunks (`@Vector(32, u8)`) anchored on the statistically least frequent byte of the needle (using a compile-time code/prose frequency matrix) and verifies candidates with `@ctz` bitmasks.

5. **Linear Regex Engine (Thompson NFA + Lazy DFA)**:
   Supports common extended regex syntax (`.`, `[a-z]`, `[^x]`, `\d`, `\w`, `\s`, `*`, `+`, `?`, `{n,m}`, `|`, `()`, `^`, `$`). Translates to a thread-local cached DFA with automatic transition interning and required literal SIMD pre-filtering. Guarantees $O(N)$ execution with zero catastrophic backtracking.

6. **Universal FilterEngine**:
   Fast comptime-optimized pruning in raw dirent buffers. Automatically respects `.dataignore`, `.gitignore`, and sensible defaults (skipping `.git`, `.zig-cache`, `node_modules`, `.venv`, binaries, and temporary files) without walking millions of ignored files.

---

## 📦 Installation & Build

### Prerequisites
* [Zig](https://ziglang.org/download/) **0.16.0+**

### Compile & Install
```sh
git clone https://github.com/DannyBaanks/ZigGrep.git
cd ZigGrep

# Build optimized binaries (zigrep and zgrep)
zig build -Doptimize=ReleaseFast

# Run all unit tests (40/40)
zig build test --summary all
```

Binaries will be available at `zig-out/bin/zigrep` and `zig-out/bin/zgrep`.

---

## 📖 CLI Usage

```text
zgrep — grep-compatible search (literal + regex) with concurrent kamikaze swarm, written in Zig

usage: zgrep [OPTIONS] PATTERN [PATH...]

options:
  -F                fixed-string pattern(s); without it PATTERN is a regex
  -E                extended regex (the default; kept for grep compat)
  -e PATTERN        search for PATTERN; repeat for several (any may match)
  -i                ignore ASCII case
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
                    streaming dataflow with concurrent kamikaze swarm
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

## 🧪 Ground Truth & Verification

Every feature is backed by strict correctness controls:
* **Differential Oracles**: Continuous verification against GNU grep (`-rIF` / `-rIE`) and ripgrep across thousands of synthetic and production source files.
* **Exit Codes**: Grep-compliant `0` (match found), `1` (no match), `2` (error).
* **Deterministic Output**: Standard mode preserves exact directory-entry emission order identical to GNU grep; streaming mode (`-k`) provides high-throughput concurrent emission.

---

## 📄 License

MIT License. Designed and engineered for high-performance systems research.
