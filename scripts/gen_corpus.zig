//! Deterministic synthetic benchmark corpus generator.
//!
//! ```sh
//! zig run scripts/gen_corpus.zig -- \
//!     --out=bench-corpus/synthetic --files=2000 --size=65536 --seed=20261107
//! ```
//!
//! Produces a tree of plain-text files with three planted markers:
//!
//!   * `ZGREP_PLANTED_TOKEN` — frequent, planted on ~1/13 of every file's lines
//!   * `ZGREP_RARE_TOKEN`    — planted in exactly `--rare-files` files, once each
//!   * `ZGREP_ABSENT_TOKEN`  — never planted (negative control)
//!
//! A `<out>.truth` file is written **next to** the corpus (never inside it, so
//! it cannot pollute the search) with the exact expected aggregate counts.
//! That gives the experiment an oracle that does not depend on GNU grep.
//!
//! Everything is driven by a single seeded PRNG, so the same arguments always
//! produce byte-identical files.
const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

pub const planted = "ZGREP_PLANTED_TOKEN";
pub const rare = "ZGREP_RARE_TOKEN";
pub const absent = "ZGREP_ABSENT_TOKEN";

/// Every word is <= 14 bytes, which bounds a generated line (12 words + one
/// planted marker) at ~210 bytes so the output buffer guard is exact.
const words = [_][]const u8{
    "const",      "fn",         "struct",     "pub",        "return",     "error",      "allocator",  "memory",
    "buffer",     "pointer",    "value",      "result",     "index",      "count",      "length",     "search",
    "pattern",    "engine",     "target",     "source",     "system",     "module",     "package",    "interface",
    "implementation", "process", "thread",    "signal",     "handle",     "context",    "state",      "status",
    "command",    "output",     "input",      "stream",     "socket",     "network",    "protocol",   "encoding",
    "format",     "parser",     "lexer",      "token",      "symbol",     "table",      "entry",      "record",
    "field",      "object",     "array",      "slice",      "vector",     "matrix",     "graph",      "node",
    "edge",       "tree",       "branch",     "commit",     "version",    "release",    "build",      "test",
    "debug",      "trace",      "log",        "level",      "query",      "cache",      "store",      "flush",
    "close",      "open",       "start",      "stop",       "pause",      "resume",     "queue",      "worker",
    "manager",    "service",    "client",     "server",     "request",    "response",   "header",     "body",
    "method",     "route",      "filter",     "policy",     "rule",       "check",      "valid",      "type",
    "size",       "path",       "file",       "dir",        "line",       "byte",       "word",       "text",
    "data",       "info",       "note",       "plan",       "step",       "goal",       "task",       "work",
    "code",       "lock",       "key",        "map",        "set",        "list",       "item",       "unit",
    "case",       "mode",       "kind",       "name",       "flag",       "opt",        "arg",        "param",
};

const usage =
    \\scripts/gen_corpus.zig — build a deterministic synthetic text corpus
    \\
    \\usage: zig run scripts/gen_corpus.zig -- [OPTIONS]
    \\
    \\  --out=DIR          corpus root (default bench-corpus/synthetic)
    \\  --files=N          number of files (default 2000)
    \\  --size=N           approximate bytes per file (default 65536)
    \\  --seed=N           PRNG seed (default 20261107)
    \\  --deep=N           leaf directories per top directory (default 16)
    \\  --top=N            top-level directories (default 4)
    \\  --rare-files=N     files receiving ZGREP_RARE_TOKEN (default 3)
    \\  --help
    \\
    \\A ground-truth file is written to <out>.truth, beside the corpus.
    \\
;

const Config = struct {
    out: []const u8 = "bench-corpus/synthetic",
    files: usize = 2000,
    size: usize = 65536,
    seed: u64 = 20261107,
    deep: usize = 16,
    top: usize = 4,
    rare_files: usize = 3,
};

fn parseInt(comptime T: type, v: []const u8) ?T {
    return std.fmt.parseInt(T, v, 10) catch null;
}

fn parse(args: []const [:0]const u8, cfg: *Config) !void {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        }
        if (!std.mem.startsWith(u8, a, "--")) return error.BadArg;
        const eq = std.mem.indexOfScalar(u8, a, '=') orelse return error.BadArg;
        const key = a[2..eq];
        const val = a[eq + 1 ..];
        if (std.mem.eql(u8, key, "out")) cfg.out = val else if (std.mem.eql(u8, key, "files")) cfg.files = parseInt(usize, val) orelse return error.BadArg else if (std.mem.eql(u8, key, "size")) cfg.size = parseInt(usize, val) orelse return error.BadArg else if (std.mem.eql(u8, key, "seed")) cfg.seed = parseInt(u64, val) orelse return error.BadArg else if (std.mem.eql(u8, key, "deep")) cfg.deep = parseInt(usize, val) orelse return error.BadArg else if (std.mem.eql(u8, key, "top")) cfg.top = parseInt(usize, val) orelse return error.BadArg else if (std.mem.eql(u8, key, "rare-files")) cfg.rare_files = parseInt(usize, val) orelse return error.BadArg else return error.BadArg;
    }
    if (cfg.files == 0 or cfg.size < 256 or cfg.deep == 0 or cfg.top == 0) return error.BadArg;
}

/// Creates every path prefix of `path`, POSIX-style. Existing dirs are fine.
fn makePath(arena: Allocator, path: []const u8) Allocator.Error!void {
    if (path.len == 0) return;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            const prefix = try std.fmt.allocPrintSentinel(arena, "{s}", .{path[0..i]}, 0);
            _ = linux.mkdirat(linux.AT.FDCWD, prefix, 0o755);
        }
    }
}

fn writeFile(path: [:0]const u8, data: []const u8) bool {
    const rc = linux.openat(
        linux.AT.FDCWD,
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
        0o644,
    );
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: i32 = @intCast(@as(isize, @bitCast(rc)));
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const w = linux.write(fd, data.ptr + off, data.len - off);
        const e = linux.errno(w);
        if (e == .INTR) continue;
        if (e != .SUCCESS or w == 0) return false;
        off += w;
    }
    return true;
}

fn appendWord(buf: []u8, pos: *usize, word: []const u8) void {
    buf[pos.*] = ' ';
    pos.* += 1;
    @memcpy(buf[pos.*..][0..word.len], word);
    pos.* += word.len;
}

/// Monotonic milliseconds. `std.time` exposes only constants in Zig 0.16, so
/// the vdso-accelerated clock is read directly, as in `src/main.zig`.
fn nowMs() u64 {
    var ts: linux.timespec = undefined;
    if (linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    if (ts.sec < 0 or ts.nsec < 0) return 0;
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec * std.time.ms_per_s + nsec / 1_000_000;
}

const FileStats = struct {
    bytes: usize = 0,
    lines: usize = 0,
    needle: usize = 0,
    rare: usize = 0,
};

/// Fills `buf` up to (at least) `target` bytes with plausible-looking text.
/// `plant_rare` puts `ZGREP_RARE_TOKEN` on the file's first line.
fn generate(rnd: std.Random, buf: []u8, target: usize, file_index: usize, plant_rare: bool) FileStats {
    var st: FileStats = .{};
    var pos: usize = 0;
    while (pos < target) {
        const line_start = pos;
        const nw = 4 + rnd.uintLessThan(usize, 9);
        var w: usize = 0;
        while (w < nw) : (w += 1) {
            if (pos > line_start) {
                buf[pos] = ' ';
                pos += 1;
            }
            const word = words[rnd.uintLessThan(usize, words.len)];
            @memcpy(buf[pos..][0..word.len], word);
            pos += word.len;
        }
        st.lines += 1;
        if ((st.lines + file_index) % 13 == 0) {
            appendWord(buf, &pos, planted);
            st.needle += 1;
        }
        if (plant_rare and st.lines == 1) {
            appendWord(buf, &pos, rare);
            st.rare += 1;
        }
        buf[pos] = '\n';
        pos += 1;
    }
    st.bytes = pos;
    return st;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var cfg: Config = .{};
    parse(args, &cfg) catch {
        std.debug.print("zgrep: bad arguments\n{s}try --help for usage\n", .{usage});
        std.process.exit(2);
    };

    const t0 = nowMs();

    try makePath(arena, cfg.out);
    var t: usize = 0;
    while (t < cfg.top) : (t += 1) {
        const top_dir = try std.fmt.allocPrintSentinel(arena, "{s}/sub{d:0>2}", .{ cfg.out, t }, 0);
        _ = linux.mkdirat(linux.AT.FDCWD, top_dir, 0o755);
        var d: usize = 0;
        while (d < cfg.deep) : (d += 1) {
            const leaf = try std.fmt.allocPrintSentinel(
                arena,
                "{s}/sub{d:0>2}/deep{d:0>2}",
                .{ cfg.out, t, d },
                0,
            );
            _ = linux.mkdirat(linux.AT.FDCWD, leaf, 0o755);
        }
    }

    var prng = std.Random.DefaultPrng.init(cfg.seed);
    const rnd = prng.random();

    // 512 bytes of headroom: the longest possible line is ~210 bytes.
    const buf = try arena.alloc(u8, cfg.size + 512);

    var written: usize = 0;
    var total_bytes: usize = 0;
    var total_lines: usize = 0;
    var needle_lines: usize = 0;
    var needle_files: usize = 0;
    var rare_lines: usize = 0;
    var rare_files: usize = 0;

    var i: usize = 0;
    while (i < cfg.files) : (i += 1) {
        const path: [:0]const u8 = if (i % 8 == 7)
            try std.fmt.allocPrintSentinel(arena, "{s}/f{d:0>5}.txt", .{ cfg.out, i }, 0)
        else blk: {
            const tt = i % cfg.top;
            const dd = (i / cfg.top) % cfg.deep;
            break :blk try std.fmt.allocPrintSentinel(
                arena,
                "{s}/sub{d:0>2}/deep{d:0>2}/f{d:0>5}.txt",
                .{ cfg.out, tt, dd, i },
                0,
            );
        };

        const st = generate(rnd, buf, cfg.size, i, i < cfg.rare_files);
        if (!writeFile(path, buf[0..st.bytes])) {
            std.debug.print("zgrep: failed to write {s}\n", .{path});
            std.process.exit(2);
        }
        written += 1;
        total_bytes += st.bytes;
        total_lines += st.lines;
        needle_lines += st.needle;
        if (st.needle > 0) needle_files += 1;
        rare_lines += st.rare;
        if (st.rare > 0) rare_files += 1;
    }

    const truth_path = try std.fmt.allocPrintSentinel(arena, "{s}.truth", .{cfg.out}, 0);
    const truth = try std.fmt.allocPrint(
        arena,
        \\# zgrep synthetic corpus ground truth
        \\# generated by scripts/gen_corpus.zig; do not edit by hand
        \\out={s}
        \\seed={d}
        \\files={d}
        \\top={d}
        \\deep={d}
        \\size_target={d}
        \\total_bytes={d}
        \\total_lines={d}
        \\needle={s}
        \\needle_matching_lines={d}
        \\needle_matching_files={d}
        \\rare={s}
        \\rare_matching_lines={d}
        \\rare_matching_files={d}
        \\absent={s}
        \\absent_matching_lines=0
        \\absent_matching_files=0
        \\
    , .{
        cfg.out,
        cfg.seed,
        written,
        cfg.top,
        cfg.deep,
        cfg.size,
        total_bytes,
        total_lines,
        planted,
        needle_lines,
        needle_files,
        rare,
        rare_lines,
        rare_files,
        absent,
    });
    if (!writeFile(truth_path, truth)) {
        std.debug.print("zgrep: failed to write {s}\n", .{truth_path});
        std.process.exit(2);
    }

    const elapsed = nowMs() -| t0;
    std.debug.print(
        "gen_corpus: files={d} bytes={d} lines={d} needle_lines={d} rare_lines={d} in {d} ms\n",
        .{ written, total_bytes, total_lines, needle_lines, rare_lines, elapsed },
    );
    std.debug.print("gen_corpus: truth written to {s}\n", .{truth_path});
}
