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
const search = @import("search.zig");
const walk = @import("walk.zig");
const scan = @import("scan.zig");
const kamikaze = @import("kamikaze.zig");
const filter = @import("filter.zig");

const Algo = search.Algo;
const Mode = scan.Mode;
const Allocator = std.mem.Allocator;

const version = "0.1.0";

const usage =
    \\zgrep — grep-compatible fixed-string search with concurrent kamikaze swarm, written in Zig
    \\
    \\usage: zgrep [OPTIONS] PATTERN [PATH...]
    \\
    \\options:
    \\  -F                fixed-string pattern (the only mode; kept for grep compat)
    \\  -r                recurse into directories (always on; kept for grep compat)
    \\  -n                print line numbers (always on; kept for grep compat)
    \\  -c                print only a count of matching lines per file
    \\  -l                print only the names of files with matches
    \\  -q                quiet: no output, exit status only
    \\  -H                print the file name with each result
    \\  -h                do not print the file name with each result
    \\  -a                treat binary files as text
    \\  -j, --threads N   worker threads (default: number of CPUs)
    \\  -k, --kamikaze, --dataflow
    \\                    streaming dataflow with concurrent kamikaze swarm
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
    \\      --algo MODE   auto | bmh | memchr   (default: auto)
    \\      --stats       print timing and throughput to stderr
    \\      --help        print this help
    \\  -V, --version     print the version
    \\
    \\patterns containing a newline are rejected (zgrep reports one line at a
    \\time, like grep -F with a single pattern).
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
    kamikaze: bool = false,
    no_ignore: bool = false,
    no_default_ignore: bool = false,
    exclude_dirs: [32][]const u8 = undefined,
    exclude_dirs_count: usize = 0,
    exclude_exts: [32][]const u8 = undefined,
    exclude_exts_count: usize = 0,
    include_exts: [32][]const u8 = undefined,
    include_exts_count: usize = 0,
    exclude_patterns: [32][]const u8 = undefined,
    exclude_patterns_count: usize = 0,
    include_patterns: [32][]const u8 = undefined,
    include_patterns_count: usize = 0,
    skip_hidden: bool = false,
    /// Set when `parseArgs` fails so the caller can print one clean message.
    /// `parseArgs` itself never writes to a stream, which keeps it testable.
    fail: ?Failure = null,
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
    files: []const [:0]const u8,
    slots: []Slot,
    searcher: *const search.Searcher,
    mode: Mode,
    show_path: bool,
    binary: bool,
    gpa: Allocator,
    window: usize,
    next: std.atomic.Value(usize) = .init(0),
    emit_cursor: std.atomic.Value(usize) = .init(0),
    found: std.atomic.Value(bool) = .init(false),
};

const default_scratch_bytes = 128 * 1024; // 128 KB covers ~97% of files

fn scanOne(ctx: *Ctx, idx: usize, scratch: ?[]u8) void {
    const slot = &ctx.slots[idx];
    const res = scan.scanFile(
        ctx.gpa,
        ctx.searcher,
        ctx.files[idx],
        ctx.show_path,
        ctx.mode,
        ctx.binary,
        &slot.buf,
        scratch,
    );
    slot.done = true;
    slot.matched = res.matched;
    slot.lines = res.lines;
    slot.bytes = res.bytes;
    slot.err = res.err;
    if (res.matched) ctx.found.store(true, .release);
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
                sleepBrief();
                spins = 0;
            } else {
                std.Thread.yield() catch {};
            }
        }
        scanOne(ctx, idx, scratch);
    }
}

fn sleepBrief() void {
    const ts = linux.timespec{ .sec = 0, .nsec = 50_000 }; // 50 µs
    _ = linux.nanosleep(&ts, null);
}

const Out = struct {
    buf: [1 << 16]u8 = undefined,
    len: usize = 0,
    err: ?linux.E = null,

    fn flush(self: *Out) void {
        if (self.err != null) {
            self.len = 0;
            return;
        }
        var off: usize = 0;
        while (off < self.len) {
            const r = linux.write(linux.STDOUT_FILENO, self.buf[0..].ptr + off, self.len - off);
            const e = linux.errno(r);
            if (e == .INTR) continue;
            if (e != .SUCCESS or r == 0) {
                self.err = if (e == .SUCCESS) .IO else e;
                self.len = 0;
                return;
            }
            off += r;
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

fn nowMonotonicNs() u64 {
    var ts: linux.timespec = undefined;
    if (linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    if (ts.sec < 0 or ts.nsec < 0) return 0;
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec * 1_000_000_000 + nsec;
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

/// Splits argv into options, the pattern and the path operands.
/// `opts` is mutated in place; on a usage problem the caller exits with 2.
pub fn parseArgs(args: []const [:0]const u8, opts: *Options) usage_error!Parsed {
    var i: usize = 1;
    var end_of_opts = false;
    var pattern: ?[:0]const u8 = null;
    var pattern_idx: usize = 0;

    while (i < args.len) : (i += 1) {
        const a = args[i];
        const is_option = !end_of_opts and a.len >= 2 and a[0] == '-';
        if (!is_option) {
            if (pattern == null) {
                pattern = a;
                pattern_idx = i;
            }
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            end_of_opts = true;
            continue;
        }

        if (a[1] == '-') {
            const body = a[2..];
            if (std.mem.eql(u8, body, "help")) {
                std.debug.print("{s}", .{usage});
                std.process.exit(0);
            } else if (std.mem.eql(u8, body, "version")) {
                std.debug.print("zgrep {s}\n", .{version});
                std.process.exit(0);
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
            } else if (std.mem.startsWith(u8, body, "threads=")) {
                const v = body["threads=".len..];
                opts.threads = parseCount(v) orelse {
                    opts.fail = .{ .what = "bad value for --threads", .arg = v };
                    return error.Usage;
                };
            } else if (std.mem.eql(u8, body, "threads")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                opts.threads = parseCount(args[i]) orelse {
                    opts.fail = .{ .what = "bad value for --threads", .arg = args[i] };
                    return error.Usage;
                };
            } else if (std.mem.eql(u8, body, "kamikaze") or std.mem.eql(u8, body, "dataflow")) {
                opts.kamikaze = true;
            } else if (std.mem.eql(u8, body, "no-hidden")) {
                opts.skip_hidden = true;
            } else if (std.mem.eql(u8, body, "no-ignore")) {
                opts.no_ignore = true;
            } else if (std.mem.eql(u8, body, "no-default-ignore")) {
                opts.no_default_ignore = true;
            } else if (std.mem.startsWith(u8, body, "exclude-dir=")) {
                if (opts.exclude_dirs_count < opts.exclude_dirs.len) {
                    opts.exclude_dirs[opts.exclude_dirs_count] = body["exclude-dir=".len..];
                    opts.exclude_dirs_count += 1;
                }
            } else if (std.mem.eql(u8, body, "exclude-dir")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                if (opts.exclude_dirs_count < opts.exclude_dirs.len) {
                    opts.exclude_dirs[opts.exclude_dirs_count] = args[i];
                    opts.exclude_dirs_count += 1;
                }
            } else if (std.mem.startsWith(u8, body, "exclude-ext=")) {
                if (opts.exclude_exts_count < opts.exclude_exts.len) {
                    opts.exclude_exts[opts.exclude_exts_count] = body["exclude-ext=".len..];
                    opts.exclude_exts_count += 1;
                }
            } else if (std.mem.startsWith(u8, body, "include-ext=")) {
                if (opts.include_exts_count < opts.include_exts.len) {
                    opts.include_exts[opts.include_exts_count] = body["include-ext=".len..];
                    opts.include_exts_count += 1;
                }
            } else if (std.mem.startsWith(u8, body, "exclude=")) {
                if (opts.exclude_patterns_count < opts.exclude_patterns.len) {
                    opts.exclude_patterns[opts.exclude_patterns_count] = body["exclude=".len..];
                    opts.exclude_patterns_count += 1;
                }
            } else if (std.mem.startsWith(u8, body, "include=")) {
                if (opts.include_patterns_count < opts.include_patterns.len) {
                    opts.include_patterns[opts.include_patterns_count] = body["include=".len..];
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
                'r', 'F', 'n', 'I' => {},
                'k' => opts.kamikaze = true,
                'c' => opts.mode = .count,
                'l' => opts.mode = .files,
                'q' => opts.mode = .quiet,
                'H' => opts.show_path = true,
                'h' => opts.show_path = false,
                'a' => opts.binary = true,
                'V' => {
                    std.debug.print("zgrep {s}\n", .{version});
                    std.process.exit(0);
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
                    opts.threads = parseCount(value) orelse {
                        opts.fail = .{ .what = "bad value for -j", .arg = value };
                        return error.Usage;
                    };
                    ci = chars.len; // value consumed the rest of this cluster
                },
                else => {
                    opts.fail = .{ .what = "unrecognized option", .arg = a };
                    return error.Usage;
                },
            }
        }
    }

    const p = pattern orelse {
        opts.fail = .{ .what = "missing PATTERN", .arg = "" };
        return error.Usage;
    };
    return .{ .pattern = p, .operands = args[pattern_idx + 1 ..] };
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var opts: Options = .{};
    const parsed = parseArgs(args, &opts) catch {
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

    if (std.mem.indexOfScalar(u8, pattern, '\n') != null) {
        std.debug.print("zgrep: patterns containing a newline are not supported\n", .{});
        std.process.exit(2);
    }
    if (operands.len == 0) {
        std.debug.print("{s}zgrep: no path\n", .{usage});
        std.process.exit(2);
    }

    const show_path: bool = if (opts.show_path) |v|
        v
    else
        !(operands.len == 1 and isRegularFile(operands[0]));

    const t0 = nowMonotonicNs();

    const searcher = search.Searcher.init(pattern, opts.algo);
    const cpu_count: usize = @max(1, std.Thread.getCpuCount() catch 4);
    const worker_count: usize = if (opts.threads != 0) @max(1, opts.threads) else cpu_count;

    // Check operands validity
    var valid_operands: std.ArrayList([:0]const u8) = .empty;
    var had_error = false;
    for (operands) |op| {
        var stx: linux.Statx = undefined;
        const se = linux.errno(linux.statx(linux.AT.FDCWD, op, 0, .{ .TYPE = true }, &stx));
        if (se != .SUCCESS) {
            std.debug.print("zgrep: {s}: {s}\n", .{ op, eName(se) });
            had_error = true;
            continue;
        }
        try valid_operands.append(arena, op);
    }

    if (valid_operands.items.len == 0 and had_error) {
        std.process.exit(2);
    }

    // --- Kamikaze Scout & Streaming Dataflow Path -------------------------
    if (opts.kamikaze or opts.exclude_dirs_count > 0 or opts.skip_hidden or
        opts.exclude_exts_count > 0 or opts.include_exts_count > 0 or
        opts.exclude_patterns_count > 0 or opts.include_patterns_count > 0 or
        opts.no_ignore or opts.no_default_ignore)
    {
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

        // Look for .dataignore and .gitignore in current dir and search roots:
        if (!opts.no_ignore) {
            filter_engine.loadIgnoreFile(".", ".dataignore");
            filter_engine.loadIgnoreFile(".", ".gitignore");
            for (valid_operands.items) |root| {
                filter_engine.loadIgnoreFile(root, ".dataignore");
                filter_engine.loadIgnoreFile(root, ".gitignore");
            }
        }

        const matched = kamikaze.runKamikazePipeline(
            gpa,
            &searcher,
            valid_operands.items,
            &filter_engine,
            opts.mode,
            opts.binary,
            show_path,
            worker_count,
            &k_stats,
        ) catch |err| {
            std.debug.print("zgrep: kamikaze failed: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };

        const t1 = nowMonotonicNs();
        if (opts.show_stats) {
            const elapsed_ns: u64 = if (t1 > t0) @intCast(t1 - t0) else 1;
            const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
            const mb_s: f64 = if (elapsed_s > 0)
                (@as(f64, @floatFromInt(k_stats.bytes_scanned)) / (1024.0 * 1024.0)) / elapsed_s
            else
                0;
            std.debug.print(
                "kamikaze: dirs={d} files={d} bytes={d} matched_files={d} matched_lines={d} threads={d} elapsed_s={d:.4} throughput_MBps={d:.1}\n",
                .{
                    k_stats.dirs_scouted,
                    k_stats.files_scanned,
                    k_stats.bytes_scanned,
                    k_stats.matched_files,
                    k_stats.matched_lines,
                    worker_count,
                    elapsed_s,
                    mb_s,
                },
            );
        }

        if (had_error) std.process.exit(2);
        if (matched) std.process.exit(0);
        std.process.exit(1);
    }

    // --- collect the file list (standard sequential walk) -----------------
    var files: std.ArrayList([:0]const u8) = .empty;
    for (valid_operands.items) |op| {
        var stx: linux.Statx = undefined;
        _ = linux.statx(linux.AT.FDCWD, op, 0, .{ .TYPE = true }, &stx);
        const m = stx.mode & linux.S.IFMT;
        if (m == linux.S.IFDIR) {
            walk.walk(arena, &.{op}, &files) catch |err| {
                std.debug.print("zgrep: {s}: {s}\n", .{ op, walkErrName(err) });
                had_error = true;
            };
        } else if (m == linux.S.IFREG) {
            files.append(arena, op) catch {
                std.debug.print("zgrep: {s}: {s}\n", .{ op, eName(.NOMEM) });
                had_error = true;
            };
        }
    }

    const slots: []Slot = try gpa.alloc(Slot, files.items.len);
    defer gpa.free(slots);
    for (slots) |*s| s.* = .{};

    const use_threads = worker_count > 1 and files.items.len > 1;
    // Quiet mode buffers no output, so it needs no run-ahead limit at all —
    // otherwise the cursor would never advance and the workers would deadlock.
    const window: usize = if (opts.mode == .quiet) std.math.maxInt(usize) else 128;

    var ctx: Ctx = .{
        .files = files.items,
        .slots = slots,
        .searcher = &searcher,
        .mode = opts.mode,
        .show_path = show_path,
        .binary = opts.binary,
        .gpa = gpa,
        .window = window,
    };

    var out: Out = .{};
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
                    sleepBrief();
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
            if (s.matched) {
                stats_matched_files += 1;
                stats_matched_lines += s.lines;
            }
        }
        s.buf.deinit(gpa);
        s.buf = .empty;
    }

    const t1 = nowMonotonicNs();
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

fn isRegularFile(path: [:0]const u8) bool {
    var stx: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, path, 0, .{ .TYPE = true }, &stx)) != .SUCCESS) return false;
    return (stx.mode & linux.S.IFMT) == linux.S.IFREG;
}

// ---------------------------------------------------------------------------

test "parseArgs: pattern and operands after clustered short options" {
    var opts: Options = .{};
    const args = [_][:0]const u8{ "zgrep", "-rnF", "pat", "dir1", "dir2" };
    const p = try parseArgs(&args, &opts);
    try std.testing.expectEqualStrings("pat", p.pattern);
    try std.testing.expectEqual(@as(usize, 2), p.operands.len);
    try std.testing.expectEqual(Mode.lines, opts.mode);
    try std.testing.expectEqual(Algo.auto, opts.algo);
}

test "parseArgs: -c, -l, -q select modes" {
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-c", "p", "d" };
        _ = try parseArgs(&a, &o);
        try std.testing.expectEqual(Mode.count, o.mode);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-l", "p", "d" };
        _ = try parseArgs(&a, &o);
        try std.testing.expectEqual(Mode.files, o.mode);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-q", "p", "d" };
        _ = try parseArgs(&a, &o);
        try std.testing.expectEqual(Mode.quiet, o.mode);
    }
}

test "parseArgs: -j takes the rest of the cluster or the next argument" {
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-cj4", "p", "d" };
        _ = try parseArgs(&a, &o);
        try std.testing.expectEqual(@as(usize, 4), o.threads);
        try std.testing.expectEqual(Mode.count, o.mode);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-j", "7", "p", "d" };
        _ = try parseArgs(&a, &o);
        try std.testing.expectEqual(@as(usize, 7), o.threads);
    }
}

test "parseArgs: long options" {
    var o: Options = .{};
    const a = [_][:0]const u8{ "zgrep", "--algo=bmh", "--threads=3", "--stats", "p", "d" };
    _ = try parseArgs(&a, &o);
    try std.testing.expectEqual(Algo.bmh, o.algo);
    try std.testing.expectEqual(@as(usize, 3), o.threads);
    try std.testing.expect(o.show_stats);
}

test "parseArgs: -- ends option parsing" {
    var o: Options = .{};
    const a = [_][:0]const u8{ "zgrep", "--", "-not-a-flag", "d" };
    const p = try parseArgs(&a, &o);
    try std.testing.expectEqualStrings("-not-a-flag", p.pattern);
    try std.testing.expectEqual(@as(usize, 1), p.operands.len);
}

test "parseArgs: unknown option is a usage error with a reason" {
    var o: Options = .{};
    const a = [_][:0]const u8{ "zgrep", "-z", "p", "d" };
    try std.testing.expectError(error.Usage, parseArgs(&a, &o));
    const f = o.fail orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("unrecognized option", f.what);
    try std.testing.expectEqualStrings("-z", f.arg);
}

test "parseArgs: missing pattern is a usage error" {
    var o: Options = .{};
    const a = [_][:0]const u8{ "zgrep" };
    try std.testing.expectError(error.Usage, parseArgs(&a, &o));
}

test "parseArgs: -k, --kamikaze, --dataflow, --exclude-dir, --no-hidden" {
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-k", "pat", "dir" };
        _ = try parseArgs(&a, &o);
        try std.testing.expect(o.kamikaze);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--dataflow", "--exclude-dir=.git", "--no-hidden", "pat", "dir" };
        _ = try parseArgs(&a, &o);
        try std.testing.expect(o.kamikaze);
        try std.testing.expect(o.skip_hidden);
        try std.testing.expectEqual(@as(usize, 1), o.exclude_dirs_count);
        try std.testing.expectEqualStrings(".git", o.exclude_dirs[0]);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--exclude-ext=log,tmp", "--include-ext=zig", "--no-ignore", "--no-default-ignore", "pat", "dir" };
        _ = try parseArgs(&a, &o);
        try std.testing.expect(o.no_ignore);
        try std.testing.expect(o.no_default_ignore);
        try std.testing.expectEqual(@as(usize, 1), o.exclude_exts_count);
        try std.testing.expectEqualStrings("log,tmp", o.exclude_exts[0]);
        try std.testing.expectEqual(@as(usize, 1), o.include_exts_count);
        try std.testing.expectEqualStrings("zig", o.include_exts[0]);
    }
}
