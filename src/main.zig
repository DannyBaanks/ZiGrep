//! zgrep — a grep-compatible fixed-string search tool.
//!
//! Pipeline: parse CLI → classify operands → `getdents64` walk (single
//! threaded, grep's traversal order) → parallel scan with a bounded run-ahead
//! window → the main thread emits results **in file order** and frees them
//! immediately, so output is deterministic and memory stays bounded.
//!
//! Concurrency model (no mutexes, no condition variables):
//!   * `next`        — workers `fetchAdd` here to claim a file index.
//!   * `emit_cursor` — how far the main thread has written. A worker holding
//!     index `i` spins only while `i - emit_cursor >= window`; the worker
//!     holding `emit_cursor` itself always sees a distance of 0 and therefore
//!     can never be blocked, which is what makes the scheme deadlock-free.
//!   * `ready`       — release/acquire flag per file slot.
const std = @import("std");
const linux = std.os.linux;
const platform = @import("platform.zig");
const search = @import("search.zig");
const walk = @import("walk.zig");
const scan = @import("scan.zig");
const kamikaze = @import("kamikaze.zig");
const filter = @import("filter.zig");
const nav = @import("nav.zig");
const vfs = @import("vfs.zig");

const Algo = search.Algo;
const Mode = scan.Mode;
const Allocator = std.mem.Allocator;

const version = "0.2.2";

/// Size budget for the zero-thread micro-tree fast path: a tree whose regular
/// files add up to less than this is scanned on the calling thread, with no
/// thread pool and without the upward `.dataignore`/`.gitignore` walk.
/// `--force-swarm` opts out and restores the concurrent swarm.
const micro_tree_max_bytes: usize = 2 * 1024 * 1024;

const usage =
    \\zgrep — grep-compatible search (literal + regex) with concurrent kamikaze swarm, written in Zig
    \\
    \\usage: zgrep [OPTIONS] PATTERN [PATH...]
    \\       zgrep [OPTIONS] [-e PATTERN...] [PATH...]
    \\       cat FILE | zgrep [OPTIONS] PATTERN
    \\
    \\options:
    \\  -F                fixed-string pattern(s); without it PATTERN is a regex
    \\  -E                extended regex (the default; kept for grep compat)
    \\  -e PATTERN        search for PATTERN; repeat for several (any may match)
    \\  -i, --ignore-case ignore case (ASCII + Latin-1 Unicode)
    \\  -v, --invert-match
    \\                    select non-matching lines
    \\  -w, --word-regexp match whole words only
    \\  -r                recurse into directories (always on; kept for grep compat)
    \\  -n                print line numbers (always on; kept for grep compat)
    \\  -c, --count       print only a count of matching lines per file
    \\  -l, --files-with-matches
    \\                    print only the names of files with matches
    \\  -L, --files-without-match
    \\                    print only the names of files without matches
    \\  -q, --quiet, --silent
    \\                    quiet: no output, exit status only
    \\  -m, --max-count=NUM
    \\                    stop after NUM matching lines per file
    \\  -H                print the file name with each result
    \\  -h                do not print the file name with each result
    \\  -a                treat binary files as text
    \\  -j, --threads N   worker threads (default: number of CPUs)
    \\  -k, --kamikaze, --dataflow
    \\                    streaming dataflow with concurrent kamikaze swarm (default)
    \\      --sort, --deterministic
    \\                    emit results in deterministic order by path (disables streaming)
    \\  -N, --nav, --befunge SPEC
    \\                    Befunge 2D vector navigation (^, v, >, <, u, d, r, l)
    \\                    combos: v^ / du (ceiling maxdepth 1), ^v / ud (trampoline root skip)
    \\      --exclude-dir=DIR
    \\                    skip directory matching DIR (comma-separated or globs)
    \\      --exclude-ext=EXT
    \\                    skip file extensions (e.g. log,tmp,lock)
    \\      --include-ext=EXT
    \\                    only search file extensions (e.g. zig,rs,py)
    \\      --exclude=GLOB
    \\                    skip files matching GLOB (e.g. *.min.js)
    \\      --include=GLOB
    \\                    only search files matching GLOB
    \\      --no-ignore   do not read .dataignore / .gitignore or apply defaults
    \\      --no-default-ignore
    \\                    do not apply built-in default ignore lists
    \\      --no-hidden   skip hidden files and directories
    \\      --force-swarm
    \\                    always use the concurrent kamikaze swarm (never the
    \\                    zero-thread micro-tree fast path)
    \\      --algo MODE   auto | bmh | memchr   (default: auto)
    \\      --stats       print timing and throughput to stderr
    \\      --uring       use Linux io_uring asynchronous batched I/O engine
    \\      --help        print this help
    \\  -V, --version     print the version
    \\
    \\regex dialect (same as rg): . [a-z] [^x] [[:alpha:]] \\d \\w \\s * + ? {n,m} | ( ) ^ $
    \\not supported (reported as an error): \\b, back-references, lookaround.
    \\a plain string with no metacharacters takes the fast literal path.
    \\patterns containing a newline are rejected.
    \\when no PATH is given or when PATH is '-', standard input is read.
    \\
    \\exit status: 0 match found, 1 no match, 2 error
    \\
;

pub const usage_error = error{Usage};

pub const Options = struct {
    mode: Mode = .lines,
    algo: Algo = .auto,
    threads: usize = 0, // 0 = auto (use the CPU count)
    show_path: ?bool = null,
    show_stats: bool = false,
    binary: bool = false,
    kamikaze: bool = true,
    sort: bool = false,
    use_uring: bool = false,
    invert_match: bool = false,
    max_count: ?usize = null,
    nav_plan: nav.NavPlan = .{},
    no_ignore: bool = false,
    no_default_ignore: bool = false,
    /// Always use the concurrent kamikaze swarm; never the zero-thread
    /// micro-tree fast path.
    force_swarm: bool = false,
    exclude_dirs: [64][]const u8 = undefined,
    exclude_dirs_count: usize = 0,
    exclude_exts: [64][]const u8 = undefined,
    exclude_exts_count: usize = 0,
    include_exts: [64][]const u8 = undefined,
    include_exts_count: usize = 0,
    exclude_patterns: [64][]const u8 = undefined,
    exclude_patterns_count: usize = 0,
    include_patterns: [64][]const u8 = undefined,
    include_patterns_count: usize = 0,
    skip_hidden: bool = false,
    fixed: bool = false,
    ignore_case: bool = false,
    word: bool = false,
    patterns: [16][]const u8 = undefined,
    patterns_count: usize = 0,
    /// Set when `parseArgs` fails so the caller can print one clean message.
    /// `parseArgs` itself never writes to a stream, which keeps it testable.
    fail: ?Failure = null,
    /// `--help` / `--version` were requested. They are answers, not
    /// diagnostics, so the caller prints them on stdout and exits with 0.
    print_help: bool = false,
    print_version: bool = false,
};

pub const Failure = struct {
    what: []const u8,
    arg: []const u8,
};

pub const Parsed = struct {
    pattern: [:0]const u8,
    operands: []const [:0]const u8,
};

const Slot = struct {
    buf: std.ArrayList(u8) = .empty,
    done: bool = false,
    matched: bool = false,
    lines: usize = 0,
    bytes: usize = 0,
    err: ?linux.E = null,
    ready: std.atomic.Value(bool) = .init(false),
};

const Ctx = struct {
    io: std.Io,
    files: []const [:0]const u8,
    slots: []Slot,
    searcher: *const search.Searcher,
    mode: Mode,
    show_path: bool,
    binary: bool,
    scan_config: scan.ScanConfig,
    gpa: Allocator,
    window: usize,
    next: std.atomic.Value(usize) = .init(0),
    emit_cursor: std.atomic.Value(usize) = .init(0),
    found: std.atomic.Value(bool) = .init(false),
};

const default_scratch_bytes = 256 * 1024; // 256 KB covers ~99.5% of files

fn scanOne(ctx: *Ctx, idx: usize, scratch: ?[]u8) void {
    const slot = &ctx.slots[idx];
    const res = scan.scanFile(
        ctx.io,
        ctx.gpa,
        ctx.searcher,
        ctx.files[idx],
        ctx.show_path,
        ctx.mode,
        ctx.binary,
        ctx.scan_config,
        &slot.buf,
        scratch,
    );
    slot.done = true;
    slot.matched = res.matched;
    slot.lines = res.lines;
    slot.bytes = res.bytes;
    slot.err = res.err;
    const is_hit = if (ctx.mode == .files_without_match) !res.matched else res.matched;
    if (is_hit) ctx.found.store(true, .release);
    slot.ready.store(true, .release);
}

fn worker(ctx: *Ctx) void {
    const scratch = ctx.gpa.alloc(u8, default_scratch_bytes) catch null;
    defer if (scratch) |s| ctx.gpa.free(s);

    while (true) {
        if (ctx.mode == .quiet and ctx.found.load(.acquire)) return;
        const idx = ctx.next.fetchAdd(1, .monotonic);
        if (idx >= ctx.files.len) return;
        // Bounded run-ahead: keep at most `window` files' output alive.
        var spins: usize = 0;
        while (idx -| ctx.emit_cursor.load(.acquire) >= ctx.window) {
            spins += 1;
            if (spins >= 16) {
                sleepBrief(ctx.io);
                spins = 0;
            } else {
                std.Thread.yield() catch {};
            }
        }
        scanOne(ctx, idx, scratch);
    }
}

fn sleepBrief(io: std.Io) void {
    platform.sleepBrief(io);
}

const Out = struct {
    io: std.Io,
    buf: [1 << 16]u8 = undefined,
    len: usize = 0,
    err: ?linux.E = null,

    fn flush(self: *Out) void {
        if (self.err != null) {
            self.len = 0;
            return;
        }
        if (!platform.writeStdout(self.io, self.buf[0..self.len])) {
            self.err = .IO;
        }
        self.len = 0;
    }

    fn writeAll(self: *Out, bytes: []const u8) void {
        if (self.err != null) return;
        var b = bytes;
        while (b.len > 0) {
            const space = self.buf.len - self.len;
            if (space == 0) {
                self.flush();
                if (self.err != null) return;
                continue;
            }
            const n = @min(space, b.len);
            @memcpy(self.buf[self.len..][0..n], b[0..n]);
            self.len += n;
            b = b[n..];
        }
    }
};

fn nowMonotonicNs(io: std.Io) u64 {
    return platform.nowNs(io);
}

fn eName(err: linux.E) []const u8 {
    return @tagName(err);
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

fn parseCount(value: []const u8) ?usize {
    return std.fmt.parseInt(usize, value, 10) catch null;
}

/// Hard limit for the worker pool (mirrors `kamikaze.max_threads`).
pub const max_threads: usize = kamikaze.max_threads;

/// Parses a worker-thread count and rejects values that would blow the pool
/// up. Every worker is an OS thread with its own stack, so an absurd value
/// (`-j 18446744073709551615`) turns the spawn loop into an endless
/// create-and-exit cycle that pins the machine at 100% CPU.
///
/// `what` names the offending option so the usage message stays specific.
fn parseThreadCount(opts: *Options, value: []const u8, what: []const u8) usage_error!usize {
    const n = parseCount(value) orelse {
        opts.fail = .{ .what = what, .arg = value };
        return error.Usage;
    };
    if (n > max_threads) {
        opts.fail = .{
            .what = std.fmt.comptimePrint("thread count out of range (max {d})", .{max_threads}),
            .arg = value,
        };
        return error.Usage;
    }
    return n;
}

fn trimQuotes(s: []const u8) []const u8 {
    var res = s;
    if (res.len >= 2 and ((res[0] == '"' and res[res.len - 1] == '"') or (res[0] == '\'' and res[res.len - 1] == '\''))) {
        res = res[1 .. res.len - 1];
    }
    return res;
}

/// Splits argv into options, the pattern and the path operands.
/// `opts` is mutated in place; on a usage problem the caller exits with 2.
pub fn parseArgs(allocator: Allocator, args: []const [:0]const u8, opts: *Options) usage_error!Parsed {
    var i: usize = 1;
    var end_of_opts = false;
    var positionals: std.ArrayList([:0]const u8) = .empty;
    errdefer positionals.deinit(allocator);

    while (i < args.len) : (i += 1) {
        const a = args[i];
        const is_option = !end_of_opts and a.len >= 2 and a[0] == '-';
        if (!is_option) {
            positionals.append(allocator, a) catch return error.Usage;
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            end_of_opts = true;
            continue;
        }

        if (a[1] == '-') {
            const body = a[2..];
            if (std.mem.eql(u8, body, "help")) {
                opts.print_help = true;
                return .{ .pattern = "", .operands = &[_][:0]const u8{} };
            } else if (std.mem.eql(u8, body, "version")) {
                opts.print_version = true;
                return .{ .pattern = "", .operands = &[_][:0]const u8{} };
            } else if (std.mem.eql(u8, body, "stats")) {
                opts.show_stats = true;
            } else if (std.mem.startsWith(u8, body, "algo=")) {
                const v = body["algo=".len..];
                opts.algo = if (std.mem.eql(u8, v, "auto"))
                    .auto
                else if (std.mem.eql(u8, v, "bmh"))
                    .bmh
                else if (std.mem.eql(u8, v, "memchr"))
                    .memchr
                else {
                    opts.fail = .{ .what = "unknown --algo (want auto|bmh|memchr)", .arg = v };
                    return error.Usage;
                };
            } else if (std.mem.eql(u8, body, "algo")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                const v = args[i];
                opts.algo = if (std.mem.eql(u8, v, "auto"))
                    .auto
                else if (std.mem.eql(u8, v, "bmh"))
                    .bmh
                else if (std.mem.eql(u8, v, "memchr"))
                    .memchr
                else {
                    opts.fail = .{ .what = "unknown --algo (want auto|bmh|memchr)", .arg = v };
                    return error.Usage;
                };
            } else if (std.mem.startsWith(u8, body, "threads=")) {
                const v = body["threads=".len..];
                opts.threads = try parseThreadCount(opts, v, "bad value for --threads");
            } else if (std.mem.eql(u8, body, "threads")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                opts.threads = try parseThreadCount(opts, args[i], "bad value for --threads");
            } else if (std.mem.eql(u8, body, "kamikaze") or std.mem.eql(u8, body, "dataflow")) {
                opts.kamikaze = true;
                opts.sort = false;
            } else if (std.mem.eql(u8, body, "uring") or std.mem.eql(u8, body, "io-uring")) {
                opts.use_uring = true;
            } else if (std.mem.eql(u8, body, "sort") or std.mem.eql(u8, body, "deterministic")) {
                opts.sort = true;
                opts.kamikaze = false;
            } else if (std.mem.startsWith(u8, body, "nav=") or std.mem.startsWith(u8, body, "befunge=")) {
                const spec = if (std.mem.startsWith(u8, body, "nav="))
                    body["nav=".len..]
                else
                    body["befunge=".len..];
                opts.nav_plan = nav.NavPlan.parse(spec) catch {
                    opts.fail = .{ .what = "invalid Befunge navigation spec (use ^, v, >, <, u, d, r, l)", .arg = spec };
                    return error.Usage;
                };
            } else if (std.mem.eql(u8, body, "nav") or std.mem.eql(u8, body, "befunge")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                opts.nav_plan = nav.NavPlan.parse(args[i]) catch {
                    opts.fail = .{ .what = "invalid Befunge navigation spec (use ^, v, >, <, u, d, r, l)", .arg = args[i] };
                    return error.Usage;
                };
            } else if (std.mem.eql(u8, body, "ignore-case")) {
                opts.ignore_case = true;
            } else if (std.mem.eql(u8, body, "invert-match")) {
                opts.invert_match = true;
            } else if (std.mem.eql(u8, body, "files-without-match")) {
                opts.mode = .files_without_match;
            } else if (std.mem.eql(u8, body, "files-with-matches")) {
                opts.mode = .files;
            } else if (std.mem.eql(u8, body, "count")) {
                opts.mode = .count;
            } else if (std.mem.eql(u8, body, "quiet") or std.mem.eql(u8, body, "silent")) {
                opts.mode = .quiet;
            } else if (std.mem.startsWith(u8, body, "max-count=")) {
                const v = body["max-count=".len..];
                opts.max_count = parseCount(v) orelse {
                    opts.fail = .{ .what = "bad value for --max-count", .arg = v };
                    return error.Usage;
                };
            } else if (std.mem.eql(u8, body, "max-count")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                opts.max_count = parseCount(args[i]) orelse {
                    opts.fail = .{ .what = "bad value for --max-count", .arg = args[i] };
                    return error.Usage;
                };
            } else if (std.mem.eql(u8, body, "word-regexp")) {
                opts.word = true;
            } else if (std.mem.eql(u8, body, "fixed-strings")) {
                opts.fixed = true;
            } else if (std.mem.eql(u8, body, "extended-regexp")) {
                // default dialect
            } else if (std.mem.startsWith(u8, body, "regexp=")) {
                if (opts.patterns_count >= opts.patterns.len) {
                    opts.fail = .{ .what = "too many -e patterns (max 16)", .arg = a };
                    return error.Usage;
                }
                opts.patterns[opts.patterns_count] = body["regexp=".len..];
                opts.patterns_count += 1;
            } else if (std.mem.eql(u8, body, "regexp")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                if (opts.patterns_count >= opts.patterns.len) {
                    opts.fail = .{ .what = "too many -e patterns (max 16)", .arg = a };
                    return error.Usage;
                }
                opts.patterns[opts.patterns_count] = args[i];
                opts.patterns_count += 1;
            } else if (std.mem.eql(u8, body, "no-hidden")) {
                opts.skip_hidden = true;
            } else if (std.mem.eql(u8, body, "no-ignore")) {
                opts.no_ignore = true;
            } else if (std.mem.eql(u8, body, "no-default-ignore")) {
                opts.no_default_ignore = true;
            } else if (std.mem.eql(u8, body, "force-swarm") or std.mem.eql(u8, body, "swarm")) {
                opts.force_swarm = true;
            } else if (std.mem.startsWith(u8, body, "exclude-dir=")) {
                if (opts.exclude_dirs_count < opts.exclude_dirs.len) {
                    opts.exclude_dirs[opts.exclude_dirs_count] = trimQuotes(body["exclude-dir=".len..]);
                    opts.exclude_dirs_count += 1;
                }
            } else if (std.mem.eql(u8, body, "exclude-dir")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                if (opts.exclude_dirs_count < opts.exclude_dirs.len) {
                    opts.exclude_dirs[opts.exclude_dirs_count] = trimQuotes(args[i]);
                    opts.exclude_dirs_count += 1;
                }
            } else if (std.mem.startsWith(u8, body, "exclude-ext=")) {
                if (opts.exclude_exts_count < opts.exclude_exts.len) {
                    opts.exclude_exts[opts.exclude_exts_count] = trimQuotes(body["exclude-ext=".len..]);
                    opts.exclude_exts_count += 1;
                }
            } else if (std.mem.eql(u8, body, "exclude-ext")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                if (opts.exclude_exts_count < opts.exclude_exts.len) {
                    opts.exclude_exts[opts.exclude_exts_count] = trimQuotes(args[i]);
                    opts.exclude_exts_count += 1;
                }
            } else if (std.mem.startsWith(u8, body, "include-ext=")) {
                if (opts.include_exts_count < opts.include_exts.len) {
                    opts.include_exts[opts.include_exts_count] = trimQuotes(body["include-ext=".len..]);
                    opts.include_exts_count += 1;
                }
            } else if (std.mem.eql(u8, body, "include-ext")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                if (opts.include_exts_count < opts.include_exts.len) {
                    opts.include_exts[opts.include_exts_count] = trimQuotes(args[i]);
                    opts.include_exts_count += 1;
                }
            } else if (std.mem.startsWith(u8, body, "exclude=")) {
                if (opts.exclude_patterns_count < opts.exclude_patterns.len) {
                    opts.exclude_patterns[opts.exclude_patterns_count] = trimQuotes(body["exclude=".len..]);
                    opts.exclude_patterns_count += 1;
                }
            } else if (std.mem.eql(u8, body, "exclude")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                if (opts.exclude_patterns_count < opts.exclude_patterns.len) {
                    opts.exclude_patterns[opts.exclude_patterns_count] = trimQuotes(args[i]);
                    opts.exclude_patterns_count += 1;
                }
            } else if (std.mem.startsWith(u8, body, "include=")) {
                if (opts.include_patterns_count < opts.include_patterns.len) {
                    opts.include_patterns[opts.include_patterns_count] = trimQuotes(body["include=".len..]);
                    opts.include_patterns_count += 1;
                }
            } else if (std.mem.eql(u8, body, "include")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                if (opts.include_patterns_count < opts.include_patterns.len) {
                    opts.include_patterns[opts.include_patterns_count] = trimQuotes(args[i]);
                    opts.include_patterns_count += 1;
                }
            } else {
                opts.fail = .{ .what = "unrecognized option", .arg = a };
                return error.Usage;
            }
            continue;
        }

        // Clustered short options: -rnF, -cj4, -Hh ...
        const chars = a[1..];
        var ci: usize = 0;
        while (ci < chars.len) : (ci += 1) {
            switch (chars[ci]) {
                // Accepted no-ops: zgrep is always recursive, fixed-string
                // and line-numbered, never follows symlinks, and already
                // skips binary files the way `-I` asks for.
                'r', 'n', 'I', 'E', 'G', 's' => {},
                'F' => opts.fixed = true,
                'i', 'y' => opts.ignore_case = true,
                'v' => opts.invert_match = true,
                'w' => opts.word = true,
                'm' => {
                    const rest = chars[ci + 1 ..];
                    const value: []const u8 = if (rest.len > 0) rest else blk: {
                        i += 1;
                        if (i >= args.len) {
                            opts.fail = .{ .what = "option requires an argument", .arg = a };
                            return error.Usage;
                        }
                        break :blk args[i];
                    };
                    if (parseCount(value)) |mc| {
                        opts.max_count = mc;
                    } else {
                        opts.nav_plan = nav.NavPlan.parse(value) catch {
                            opts.fail = .{ .what = "invalid Befunge navigation spec or max-count number", .arg = value };
                            return error.Usage;
                        };
                    }
                    ci = chars.len;
                },
                'N' => {
                    const rest = chars[ci + 1 ..];
                    const value: []const u8 = if (rest.len > 0) rest else blk: {
                        i += 1;
                        if (i >= args.len) {
                            opts.fail = .{ .what = "option requires an argument", .arg = a };
                            return error.Usage;
                        }
                        break :blk args[i];
                    };
                    opts.nav_plan = nav.NavPlan.parse(value) catch {
                        opts.fail = .{ .what = "invalid Befunge navigation spec", .arg = value };
                        return error.Usage;
                    };
                    ci = chars.len;
                },
                'k' => {
                    opts.kamikaze = true;
                    opts.sort = false;
                },
                'c' => opts.mode = .count,
                'l' => opts.mode = .files,
                'L' => opts.mode = .files_without_match,
                'q' => opts.mode = .quiet,
                'H' => opts.show_path = true,
                'h' => opts.show_path = false,
                'a' => opts.binary = true,
                'V' => {
                    opts.print_version = true;
                    return .{ .pattern = "", .operands = &[_][:0]const u8{} };
                },
                'e' => {
                    const rest = chars[ci + 1 ..];
                    const value: []const u8 = if (rest.len > 0) rest else blk: {
                        i += 1;
                        if (i >= args.len) {
                            opts.fail = .{ .what = "option requires an argument", .arg = a };
                            return error.Usage;
                        }
                        break :blk args[i];
                    };
                    if (opts.patterns_count >= opts.patterns.len) {
                        opts.fail = .{ .what = "too many -e patterns (max 16)", .arg = value };
                        return error.Usage;
                    }
                    opts.patterns[opts.patterns_count] = value;
                    opts.patterns_count += 1;
                    ci = chars.len;
                },
                'j' => {
                    const rest = chars[ci + 1 ..];
                    const value: []const u8 = if (rest.len > 0) rest else blk: {
                        i += 1;
                        if (i >= args.len) {
                            opts.fail = .{ .what = "option requires an argument", .arg = a };
                            return error.Usage;
                        }
                        break :blk args[i];
                    };
                    opts.threads = try parseThreadCount(opts, value, "bad value for -j");
                    ci = chars.len; // value consumed the rest of this cluster
                },
                else => {
                    opts.fail = .{ .what = "unrecognized option", .arg = a };
                    return error.Usage;
                },
            }
        }
    }

    if (opts.patterns_count > 0) {
        // Patterns came from -e / --regexp: all positionals are operands (paths).
        const ops = positionals.toOwnedSlice(allocator) catch return error.Usage;
        return .{ .pattern = "", .operands = ops };
    }
    if (positionals.items.len == 0) {
        opts.fail = .{ .what = "missing PATTERN", .arg = "" };
        return error.Usage;
    }
    const p = positionals.items[0];
    const ops = if (positionals.items.len > 1)
        allocator.dupe([:0]const u8, positionals.items[1..]) catch return error.Usage
    else
        allocator.alloc([:0]const u8, 0) catch return error.Usage;
    positionals.deinit(allocator);
    return .{ .pattern = p, .operands = ops };
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var opts: Options = .{};
    const parsed = parseArgs(arena, args, &opts) catch {
        if (opts.fail) |f| {
            if (f.arg.len > 0) {
                std.debug.print("zgrep: {s}: '{s}'\n", .{ f.what, f.arg });
            } else {
                std.debug.print("zgrep: {s}\n", .{f.what});
            }
        } else {
            std.debug.print("zgrep: invalid arguments\n", .{});
        }
        std.debug.print("try 'zgrep --help' for usage\n", .{});
        std.process.exit(2);
    };
    const pattern = parsed.pattern;
    const operands = parsed.operands;

    // `--help` and `--version` are answers, not diagnostics: they go to
    // stdout, like every other grep. Printing them to stderr made PowerShell
    // show a red RemoteException on a perfectly healthy run, and it aborted
    // the installer (which runs with $ErrorActionPreference = "Stop", where a
    // native command writing to stderr raises a terminating error).
    if (opts.print_help or opts.print_version) {
        if (opts.print_version) {
            _ = platform.writeStdout(init.io, std.fmt.comptimePrint("zgrep {s}\n", .{version}));
        } else {
            _ = platform.writeStdout(init.io, usage);
        }
        std.process.exit(0);
    }

    if (opts.threads == 0) {
        if (init.environ_map.get("ZIGREP_THREADS") orelse
            init.environ_map.get("ZGREP_THREADS") orelse
            init.environ_map.get("THREADS")) |val|
        {
            if (parseCount(val)) |t| {
                // An out-of-range value is a hard error, not something to
                // silently ignore: it would explode the worker pool.
                if (t > max_threads) {
                    std.debug.print("zgrep: {s}: thread count out of range (max {d})\n", .{ val, max_threads });
                    std.process.exit(2);
                }
                opts.threads = t;
            }
        }
    }

    const pattern_list: []const []const u8 = if (opts.patterns_count > 0)
        opts.patterns[0..opts.patterns_count]
    else
        @as([*]const []const u8, @ptrCast(&pattern))[0..1];
    for (pattern_list) |pp| {
        if (std.mem.indexOfScalar(u8, pp, '\n') != null) {
            std.debug.print("zgrep: patterns containing a newline are not supported\n", .{});
            std.process.exit(2);
        }
    }
    // No path operand means "read standard input" (GNU grep semantics, added
    // upstream with the Grupo 1 work). When stdin is an interactive terminal
    // there is nothing to read, so report the usage error instead of hanging.
    if (operands.len == 0) {
        const stdin_is_tty = std.Io.File.stdin().isTty(init.io) catch false;
        if (stdin_is_tty) {
            std.debug.print("{s}zgrep: no path\n", .{usage});
            std.process.exit(2);
        }
    }

    const show_path: bool = if (opts.show_path) |v|
        v
    else
        !(operands.len == 1 and isRegularFile(init.io, operands[0]));

    const t0 = nowMonotonicNs(init.io);

    const searcher = search.build(gpa, pattern_list, .{
        .algo = opts.algo,
        .fixed = opts.fixed,
        .icase = opts.ignore_case,
        .word = opts.word,
    }) catch |e| switch (e) {
        error.BadRegex => {
            std.debug.print("zgrep: invalid regex: {s}\n", .{@import("regex.zig").last_error});
            std.process.exit(2);
        },
        error.OutOfMemory => {
            std.debug.print("zgrep: out of memory\n", .{});
            std.process.exit(2);
        },
    };

    const is_stdin = operands.len == 0 or (operands.len == 1 and std.mem.eql(u8, operands[0], "-"));
    if (is_stdin) {
        var stdin_buf: std.ArrayList(u8) = .empty;
        defer stdin_buf.deinit(gpa);
        // Pre-reserve capacity if stdin is redirected from a file with known size
        if (std.Io.File.stdin().stat(init.io) catch null) |st| {
            if (st.size > 0) stdin_buf.ensureTotalCapacity(gpa, @intCast(st.size)) catch {};
        }

        const stdin_file = std.Io.File.stdin();
        var chunk: [128 * 1024]u8 = undefined;
        while (true) {
            const rr = stdin_file.readStreaming(init.io, &.{chunk[0..]}) catch break;
            if (rr == 0) break;
            // Zero-latency early abort for quiet mode:
            if (opts.mode == .quiet and !opts.invert_match) {
                if (searcher.find(chunk[0..rr], 0) != null) {
                    std.process.exit(0);
                }
            }
            try stdin_buf.appendSlice(gpa, chunk[0..rr]);
        }

        const scan_cfg = scan.ScanConfig{
            .invert = opts.invert_match,
            .max_count = opts.max_count,
        };
        const path_label = "(standard input)";
        const show_p = opts.show_path orelse false;

        const data = stdin_buf.items;
        const probe = @min(data.len, scan.binary_probe_bytes);
        const utf16_bom = scan.isUtf16Bom(data);
        const is_bin = !opts.binary and utf16_bom == null and std.mem.findScalar(u8, data[0..probe], 0) != null;
        if (is_bin) {
            if (opts.mode == .lines) {
                std.debug.print("Binary file (standard input) matches\n", .{});
            }
            std.process.exit(0);
        }

        var utf8_data: ?[]u8 = null;
        defer if (utf8_data) |u| gpa.free(u);
        const search_data = if (utf16_bom) |bom| blk: {
            if (scan.decodeUtf16ToUtf8(gpa, data, bom == .le)) |decoded| {
                utf8_data = decoded;
                break :blk decoded;
            } else |_| break :blk data;
        } else data;

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);

        const br = scan.scanBuffer(gpa, search_data, &searcher, path_label, show_p, opts.mode, scan_cfg, &out) catch {
            std.process.exit(2);
        };

        if (opts.mode == .count) {
            if (show_p) {
                try out.appendSlice(gpa, path_label);
                try out.append(gpa, ':');
            }
            var num_buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&num_buf, "{d}\n", .{br.lines}) catch unreachable;
            try out.appendSlice(gpa, s);
        } else if (opts.mode == .files and br.matched) {
            try out.appendSlice(gpa, path_label);
            try out.append(gpa, '\n');
        } else if (opts.mode == .files_without_match and !br.matched) {
            try out.appendSlice(gpa, path_label);
            try out.append(gpa, '\n');
        }

        if (out.items.len > 0 and opts.mode != .quiet) {
            _ = platform.writeStdout(init.io, out.items);
        }

        const is_hit = if (opts.mode == .files_without_match) !br.matched else br.matched;
        std.process.exit(if (is_hit) 0 else 1);
    }

    const cpu_count: usize = @max(1, std.Thread.getCpuCount() catch 4);
    const worker_count: usize = if (opts.threads != 0) @max(1, opts.threads) else cpu_count;

    // Check operands validity
    var valid_operands: std.ArrayList([:0]const u8) = .empty;
    var had_error = false;
    for (operands) |op| {
        const info = vfs.statFile(init.io, op, .{}) catch |err| {
            std.debug.print("zgrep: {s}: {s}\n", .{ op, @errorName(err) });
            had_error = true;
            continue;
        };
        if (info.kind != .directory and info.kind != .file) continue;
        try valid_operands.append(arena, op);
    }

    if (valid_operands.items.len == 0 and had_error) {
        std.process.exit(2);
    }

    // --- Kamikaze Scout & Streaming Dataflow Path (Default) ----------------
    if (!opts.sort) {
        var k_stats: kamikaze.KamikazeStats = .{};
        var filter_engine = filter.FilterEngine.init(gpa);
        defer filter_engine.deinit();

        filter_engine.no_ignore = opts.no_ignore;
        filter_engine.use_defaults = !opts.no_default_ignore and !opts.no_ignore;
        filter_engine.skip_hidden = opts.skip_hidden;

        for (opts.exclude_dirs[0..opts.exclude_dirs_count]) |d| {
            try filter_engine.addExcludedDirs(d);
        }
        for (opts.exclude_exts[0..opts.exclude_exts_count]) |e| {
            try filter_engine.addExcludedExts(e);
        }
        for (opts.include_exts[0..opts.include_exts_count]) |e| {
            try filter_engine.addIncludedExts(e);
        }
        for (opts.exclude_patterns[0..opts.exclude_patterns_count]) |p| {
            try filter_engine.addExcludedPattern(p);
        }
        for (opts.include_patterns[0..opts.include_patterns_count]) |p| {
            try filter_engine.addIncludedPattern(p);
        }

        // The upward `.dataignore` / `.gitignore` walk is *not* done here: the
        // pipeline defers it until it knows the tree is too big for the
        // zero-thread micro-tree fast path.

        const scan_cfg = scan.ScanConfig{
            .invert = opts.invert_match,
            .max_count = opts.max_count,
        };

        const matched = kamikaze.runKamikazePipeline(
            init.io,
            gpa,
            &searcher,
            valid_operands.items,
            &filter_engine,
            opts.nav_plan,
            opts.mode,
            opts.binary,
            show_path,
            scan_cfg,
            worker_count,
            &k_stats,
            opts.use_uring,
            opts.force_swarm,
            micro_tree_max_bytes,
        ) catch |err| {
            std.debug.print("zgrep: kamikaze failed: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };

        const t1 = nowMonotonicNs(init.io);
        if (opts.show_stats) {
            const elapsed_ns: u64 = if (t1 > t0) @intCast(t1 - t0) else 1;
            const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
            const mb_s: f64 = if (elapsed_s > 0)
                (@as(f64, @floatFromInt(k_stats.bytes_scanned)) / (1024.0 * 1024.0)) / elapsed_s
            else
                0;
            std.debug.print(
                "kamikaze: dirs={d} files={d} bytes={d} matched_files={d} matched_lines={d} threads={d} micro_path={s} elapsed_s={d:.4} throughput_MBps={d:.1}\n",
                .{
                    k_stats.dirs_scouted,
                    k_stats.files_scanned,
                    k_stats.bytes_scanned,
                    k_stats.matched_files,
                    k_stats.matched_lines,
                    worker_count,
                    if (k_stats.micro_path) "yes" else "no",
                    elapsed_s,
                    mb_s,
                },
            );
        }

        if (had_error) std.process.exit(2);
        if (matched) std.process.exit(0);
        std.process.exit(1);
    }

    // --- collect the file list (deterministic sorted walk with filter engine) -
    var filter_engine = filter.FilterEngine.init(gpa);
    defer filter_engine.deinit();

    filter_engine.no_ignore = opts.no_ignore;
    filter_engine.use_defaults = !opts.no_default_ignore and !opts.no_ignore;
    filter_engine.skip_hidden = opts.skip_hidden;

    for (opts.exclude_dirs[0..opts.exclude_dirs_count]) |d| {
        try filter_engine.addExcludedDirs(d);
    }
    for (opts.exclude_exts[0..opts.exclude_exts_count]) |e| {
        try filter_engine.addExcludedExts(e);
    }
    for (opts.include_exts[0..opts.include_exts_count]) |e| {
        try filter_engine.addIncludedExts(e);
    }
    for (opts.exclude_patterns[0..opts.exclude_patterns_count]) |p| {
        try filter_engine.addExcludedPattern(p);
    }
    for (opts.include_patterns[0..opts.include_patterns_count]) |p| {
        try filter_engine.addIncludedPattern(p);
    }

    filter_engine.loadIgnoreFiles(init.io, valid_operands.items);

    var files: std.ArrayList([:0]const u8) = .empty;
    for (valid_operands.items) |op| {
        const info = vfs.statFile(init.io, op, .{}) catch |err| {
            std.debug.print("zgrep: {s}: {s}\n", .{ op, @errorName(err) });
            had_error = true;
            continue;
        };
        if (info.kind == .directory) {
            walk.walk(init.io, arena, &.{op}, &files, &filter_engine, opts.nav_plan) catch |err| {
                std.debug.print("zgrep: {s}: {s}\n", .{ op, walkErrName(err) });
                had_error = true;
            };
        } else if (info.kind == .file) {
            files.append(arena, op) catch {
                std.debug.print("zgrep: {s}: {s}\n", .{ op, eName(.NOMEM) });
                had_error = true;
            };
        }
    }

    const slots: []Slot = try gpa.alloc(Slot, files.items.len);
    defer gpa.free(slots);
    for (slots) |*s| s.* = .{};

    // Lazy thread spawning: clone()ing a pool costs more than reading a small
    // tree (measured: ~2 ms vs ~0.3 ms for 8 files), so the main thread runs
    // small jobs alone and only wakes the pool past this many files.
    const spawn_threshold = 32;
    const use_threads = worker_count > 1 and files.items.len > spawn_threshold;
    // Quiet mode buffers no output, so it needs no run-ahead limit at all —
    // otherwise the cursor would never advance and the workers would deadlock.
    const window: usize = if (opts.mode == .quiet) std.math.maxInt(usize) else 128;

    var ctx: Ctx = .{
        .io = init.io,
        .files = files.items,
        .slots = slots,
        .searcher = &searcher,
        .mode = opts.mode,
        .show_path = show_path,
        .binary = opts.binary,
        .scan_config = .{
            .invert = opts.invert_match,
            .max_count = opts.max_count,
        },
        .gpa = gpa,
        .window = window,
    };

    var out: Out = .{ .io = init.io };
    const main_scratch = gpa.alloc(u8, default_scratch_bytes) catch null;
    defer if (main_scratch) |s| gpa.free(s);

    if (!use_threads) {
        var idx: usize = 0;
        while (idx < files.items.len) : (idx += 1) {
            if (opts.mode == .quiet and ctx.found.load(.acquire)) break;
            scanOne(&ctx, idx, main_scratch);
            if (opts.mode != .quiet) {
                out.writeAll(slots[idx].buf.items);
                slots[idx].buf.deinit(gpa);
                slots[idx].buf = .empty;
            }
        }
        out.flush();
    } else {
        // -q probe: scan the first few files on this thread while nothing
        // else exists yet; a hit exits without ever spawning a worker.
        if (opts.mode == .quiet) {
            const probe = @min(@as(usize, 3), files.items.len);
            var k: usize = 0;
            while (k < probe and !ctx.found.load(.acquire)) : (k += 1) scanOne(&ctx, k, main_scratch);
            ctx.next.store(k, .release);
            if (ctx.found.load(.acquire)) std.process.exit(0);
        }
        var threads: std.ArrayList(std.Thread) = .empty;
        defer threads.deinit(gpa);
        var spawned: usize = 0;
        while (spawned < worker_count) : (spawned += 1) {
            const t = std.Thread.spawn(.{}, worker, .{&ctx}) catch break;
            threads.append(gpa, t) catch break;
        }

        if (opts.mode == .quiet) {
            for (threads.items) |t| t.join();
        } else {
            // Emit in file order while workers run ahead, helping with the
            // work instead of idling.
            var w: usize = 0;
            var miss: usize = 0;
            while (w < slots.len) {
                if (slots[w].ready.load(.acquire)) {
                    out.writeAll(slots[w].buf.items);
                    slots[w].buf.deinit(gpa);
                    slots[w].buf = .empty;
                    ctx.emit_cursor.store(w + 1, .release);
                    w += 1;
                    miss = 0;
                    continue;
                }
                // Only claim an index we are actually going to scan: a
                // claimed-but-skipped index would never become ready.
                if (ctx.next.load(.monotonic) -| ctx.emit_cursor.load(.acquire) < window) {
                    const idx = ctx.next.fetchAdd(1, .monotonic);
                    if (idx < slots.len) {
                        scanOne(&ctx, idx, main_scratch);
                        miss = 0;
                        continue;
                    }
                }
                miss += 1;
                if (miss >= 8) {
                    sleepBrief(init.io);
                    miss = 0;
                } else {
                    std.Thread.yield() catch {};
                }
            }
            out.flush();
            for (threads.items) |t| t.join();
        }
    }

    if (out.err) |e| {
        std.debug.print("zgrep: write: {s}\n", .{eName(e)});
        had_error = true;
    }

    // --- aggregate ---------------------------------------------------------
    var stats_err: usize = 0;
    var stats_files: usize = 0;
    var stats_bytes: usize = 0;
    var stats_matched_files: usize = 0;
    var stats_matched_lines: usize = 0;
    for (slots, 0..) |*s, i| {
        if (s.err) |e| {
            std.debug.print("zgrep: {s}: {s}\n", .{ ctx.files[i], eName(e) });
            stats_err += 1;
        } else if (s.done) {
            stats_files += 1;
            stats_bytes += s.bytes;
            const is_hit = if (ctx.mode == .files_without_match) !s.matched else s.matched;
            if (is_hit) {
                stats_matched_files += 1;
                stats_matched_lines += s.lines;
            }
        }
        s.buf.deinit(gpa);
        s.buf = .empty;
    }

    const t1 = nowMonotonicNs(init.io);
    if (opts.show_stats) {
        const elapsed_ns: u64 = t1 -| t0;
        const secs = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
        const mbps = if (secs > 0) @as(f64, @floatFromInt(stats_bytes)) / secs / 1e6 else 0;
        std.debug.print(
            "zgrep-stats: files={d} bytes={d} matched_files={d} matched_lines={d} errors={d} threads={d} elapsed_s={d:.4} throughput_MBps={d:.1}\n",
            .{ stats_files, stats_bytes, stats_matched_files, stats_matched_lines, stats_err, worker_count, secs, mbps },
        );
    }

    if (had_error or stats_err > 0) std.process.exit(2);
    if (stats_matched_files > 0) std.process.exit(0);
    std.process.exit(1);
}

fn walkErrName(err: walk.Error) []const u8 {
    return switch (err) {
        error.OutOfMemory => eName(.NOMEM),
        error.OpenFailed => eName(.ACCES),
        error.ReadFailed => eName(.IO),
        error.TooDeep => eName(.LOOP),
    };
}

fn isRegularFile(io: std.Io, path: [:0]const u8) bool {
    const info = vfs.statFile(io, path, .{}) catch return false;
    return info.kind == .file;
}

// ---------------------------------------------------------------------------

test "parseArgs: pattern and operands after clustered short options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var opts: Options = .{};
    const args = [_][:0]const u8{ "zgrep", "-rnF", "pat", "dir1", "dir2" };
    const p = try parseArgs(arena.allocator(), &args, &opts);
    try std.testing.expectEqualStrings("pat", p.pattern);
    try std.testing.expectEqual(@as(usize, 2), p.operands.len);
    try std.testing.expectEqual(Mode.lines, opts.mode);
    try std.testing.expectEqual(Algo.auto, opts.algo);
}

test "parseArgs: -c, -l, -q select modes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-c", "p", "d" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(Mode.count, o.mode);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-l", "p", "d" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(Mode.files, o.mode);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-q", "p", "d" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(Mode.quiet, o.mode);
    }
}

test "parseArgs: -j takes the rest of the cluster or the next argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-cj4", "p", "d" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(usize, 4), o.threads);
        try std.testing.expectEqual(Mode.count, o.mode);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-j", "7", "p", "d" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(usize, 7), o.threads);
    }
}

test "parseArgs: long options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var o: Options = .{};
    const a = [_][:0]const u8{ "zgrep", "--algo=bmh", "--threads=3", "--stats", "p", "d" };
    _ = try parseArgs(arena.allocator(), &a, &o);
    try std.testing.expectEqual(Algo.bmh, o.algo);
    try std.testing.expectEqual(@as(usize, 3), o.threads);
    try std.testing.expect(o.show_stats);
}

test "parseArgs: an absurd thread count is a usage error, not a worker-pool bomb" {
    // Regression: `-j 18446744073709551615` used to reach the spawn loop,
    // which then created and joined threads forever, pinning the machine at
    // 100% CPU. Found by the adversarial fuzzer on Windows.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const cases = [_][]const [:0]const u8{
        &.{ "zgrep", "-j", "18446744073709551615", "p", "d" },
        &.{ "zgrep", "--threads=18446744073709551615", "p", "d" },
        &.{ "zgrep", "--threads", "999999", "p", "d" },
        &.{ "zgrep", "-j999999", "p", "d" },
    };
    for (cases) |a| {
        var o: Options = .{};
        try std.testing.expectError(error.Usage, parseArgs(alloc, a, &o));
        const f = o.fail orelse return error.TestExpectedEqual;
        try std.testing.expectEqualStrings("thread count out of range (max 1024)", f.what);
    }
    // The boundary itself stays valid.
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-j", "1024", "p", "d" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(usize, 1024), o.threads);
    }
}

test "parseArgs: a non-numeric thread count is still a usage error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var o: Options = .{};
    const a = [_][:0]const u8{ "zgrep", "-j", "abc", "p", "d" };
    try std.testing.expectError(error.Usage, parseArgs(arena.allocator(), &a, &o));
    const f = o.fail orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("bad value for -j", f.what);
}

test "parseArgs: -- ends option parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var o: Options = .{};
    const a = [_][:0]const u8{ "zgrep", "--", "-not-a-flag", "d" };
    const p = try parseArgs(arena.allocator(), &a, &o);
    try std.testing.expectEqualStrings("-not-a-flag", p.pattern);
    try std.testing.expectEqual(@as(usize, 1), p.operands.len);
}

test "parseArgs: --version and -V ask for the version instead of searching" {
    // The version is an answer, not a diagnostic: it goes to stdout, so
    // PowerShell does not show a red RemoteException on a healthy run (and
    // the installer, which runs with $ErrorActionPreference = "Stop", does
    // not abort on it).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--version" };
        _ = try parseArgs(arena.allocator(), &a, &o);
        try std.testing.expect(o.print_version);
        try std.testing.expect(!o.print_help);
        try std.testing.expect(o.fail == null);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-V" };
        _ = try parseArgs(arena.allocator(), &a, &o);
        try std.testing.expect(o.print_version);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--help" };
        _ = try parseArgs(arena.allocator(), &a, &o);
        try std.testing.expect(o.print_help);
        try std.testing.expect(!o.print_version);
    }
}

test "parseArgs: unknown option is a usage error with a reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var o: Options = .{};
    const a = [_][:0]const u8{ "zgrep", "-z", "p", "d" };
    try std.testing.expectError(error.Usage, parseArgs(arena.allocator(), &a, &o));
    const f = o.fail orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("unrecognized option", f.what);
    try std.testing.expectEqualStrings("-z", f.arg);
}

test "parseArgs: missing pattern is a usage error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var o: Options = .{};
    const a = [_][:0]const u8{"zgrep"};
    try std.testing.expectError(error.Usage, parseArgs(arena.allocator(), &a, &o));
}

test "parseArgs: -k, --kamikaze, --dataflow, --exclude-dir, --no-hidden" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-k", "pat", "dir" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.kamikaze);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--dataflow", "--exclude-dir=.git", "--no-hidden", "pat", "dir" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.kamikaze);
        try std.testing.expect(o.skip_hidden);
        try std.testing.expectEqual(@as(usize, 1), o.exclude_dirs_count);
        try std.testing.expectEqualStrings(".git", o.exclude_dirs[0]);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--exclude-ext=log,tmp", "--include-ext=zig", "--no-ignore", "--no-default-ignore", "pat", "dir" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.no_ignore);
        try std.testing.expect(o.no_default_ignore);
        try std.testing.expectEqual(@as(usize, 1), o.exclude_exts_count);
        try std.testing.expectEqualStrings("log,tmp", o.exclude_exts[0]);
        try std.testing.expectEqual(@as(usize, 1), o.include_exts_count);
        try std.testing.expectEqualStrings("zig", o.include_exts[0]);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--sort", "pat", "dir" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.sort);
        try std.testing.expect(!o.kamikaze);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-m", "^v", "pat", "dir" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.nav_plan.has_trampoline);
        try std.testing.expect(!o.nav_plan.has_ceiling);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--nav=v^", "pat", "dir" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.nav_plan.has_ceiling);
        try std.testing.expect(!o.nav_plan.has_trampoline);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--deterministic", "pat", "dir" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.sort);
        try std.testing.expect(!o.kamikaze);
    }
}

test "parseArgs: --force-swarm opts out of the zero-thread micro-tree path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--force-swarm", "pat", "dir" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.force_swarm);
        try std.testing.expect(o.kamikaze); // the swarm stays the engine
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--swarm", "pat", "dir" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.force_swarm);
    }
    {
        // The micro-tree fast path is the default: no flag means no swarm.
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "pat", "dir" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(!o.force_swarm);
    }
}

test "parseArgs: -i -w -e collect patterns and keep every positional as a path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = [_][:0]const u8{ "zgrep", "-iw", "-e", "foo", "-ebar", "dir1", "dir2" };
    var o: Options = .{};
    const p = try parseArgs(arena.allocator(), &a, &o);
    try std.testing.expect(o.ignore_case and o.word and !o.fixed);
    try std.testing.expectEqual(@as(usize, 2), o.patterns_count);
    try std.testing.expectEqualStrings("foo", o.patterns[0]);
    try std.testing.expectEqualStrings("bar", o.patterns[1]);
    try std.testing.expectEqual(@as(usize, 2), p.operands.len);
    try std.testing.expectEqualStrings("dir1", p.operands[0]);
}

test "parseArgs: -v, -L, -m NUM, --max-count=NUM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    {
        const a = [_][:0]const u8{ "zgrep", "-v", "foo", "dir" };
        var o: Options = .{};
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.invert_match);
    }
    {
        const a = [_][:0]const u8{ "zgrep", "--invert-match", "foo", "dir" };
        var o: Options = .{};
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.invert_match);
    }
    {
        const a = [_][:0]const u8{ "zgrep", "-L", "foo", "dir" };
        var o: Options = .{};
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(Mode.files_without_match, o.mode);
    }
    {
        const a = [_][:0]const u8{ "zgrep", "--files-without-match", "foo", "dir" };
        var o: Options = .{};
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(Mode.files_without_match, o.mode);
    }
    {
        const a = [_][:0]const u8{ "zgrep", "-m", "5", "foo", "dir" };
        var o: Options = .{};
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(?usize, 5), o.max_count);
        try std.testing.expectEqual(@as(usize, 0), o.nav_plan.len);
    }
    {
        const a = [_][:0]const u8{ "zgrep", "--max-count=42", "foo", "dir" };
        var o: Options = .{};
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(?usize, 42), o.max_count);
    }
    {
        const a = [_][:0]const u8{ "zgrep", "-N", "v^", "foo", "dir" };
        var o: Options = .{};
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(usize, 2), o.nav_plan.len);
        try std.testing.expectEqual(nav.NavOp.down, o.nav_plan.ops[0]);
        try std.testing.expectEqual(nav.NavOp.up, o.nav_plan.ops[1]);
    }
}

test "parseArgs: options after pattern and mixed include globs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var o: Options = .{};
    const a = [_][:0]const u8{
        "zgrep",
        "-ril",
        "webgpu\\|wgpu\\|dawn",
        "--include=*.md",
        "--include=*.zig",
        "dir1",
        "dir2",
    };
    const p = try parseArgs(arena.allocator(), &a, &o);
    try std.testing.expectEqualStrings("webgpu\\|wgpu\\|dawn", p.pattern);
    try std.testing.expectEqual(Mode.files, o.mode);
    try std.testing.expect(o.ignore_case);
    try std.testing.expectEqual(@as(usize, 2), o.include_patterns_count);
    try std.testing.expectEqualStrings("*.md", o.include_patterns[0]);
    try std.testing.expectEqualStrings("*.zig", o.include_patterns[1]);
    try std.testing.expectEqual(@as(usize, 2), p.operands.len);
    try std.testing.expectEqualStrings("dir1", p.operands[0]);
    try std.testing.expectEqualStrings("dir2", p.operands[1]);
}
