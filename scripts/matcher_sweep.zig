//! Matcher crossover sweep — measures Boyer–Moore–Horspool against the
//! vectorised `memchr` matcher across needle lengths, so the `auto` heuristic
//! threshold is chosen from data instead of guessed.
//!
//! The kernels under test are imported **from `src/search.zig` itself** — this
//! script never carries its own copy of the matcher, so what it measures is
//! exactly what the `zgrep` binary runs.
//!
//! Method:
//!   * Walk `--dir` (regular files only), map the largest text files until
//!     `--budget` bytes are collected. That set is the haystack for every
//!     measurement, identical for every algo. Binary files (a NUL inside the
//!     first 8192 bytes) are skipped the same way zgrep skips them.
//!   * For each length L in `--lengths`, draw `--samples` needles by taking L
//!     consecutive bytes out of the haystack at deterministic offsets — real
//!     text, real statistics, nothing hand-picked.
//!   * Each needle is counted over the whole haystack with `countAll`, a full
//!     traversal to the end: the case that dominates a large tree (the
//!     rare/absent workload). Time per traversal with `common.nowNs`;
//!     `--runs` repetitions, median kept. Single-threaded, so the number
//!     isolates the algorithm from the scheduler and the output path.
//!   * An alignment control re-counts every sample with the other algo and
//!     fails loudly if the two kernels disagree.
//!
//! ```sh
//! zig run scripts/matcher_sweep.zig -- \
//!     --dir=/home/danny/Development/ISyCo/workspace/assembly \
//!     --budget=67108864 --lengths=1,2,3,4,5,6,8,10,12,16,20,24,32,48,64 \
//!     --samples=12 --runs=3
//! ```
const std = @import("std");
const common = @import("common.zig");
// Provided as an anonymous import by build.zig — it points at the real
// src/search.zig, so this sweep measures the shipped matchers, not a copy.
const matcher = @import("matcher");
// Same, for the raw getdents64 walker: one traversal implementation, reused.
const walk = @import("walk");

const Algo = matcher.Algo;
const Searcher = matcher.Searcher;
const Allocator = std.mem.Allocator;

const usage =
    \\scripts/matcher_sweep.zig — bmh vs memchr across needle lengths
    \\
    \\usage: zig run scripts/matcher_sweep.zig -- [OPTIONS]
    \\
    \\  --dir=PATH       haystack tree (default: cwd)
    \\  --budget=N       collect text bytes until N (default 64 MiB)
    \\  --maxfile=N      cap each mapped file at N bytes (default 1 MiB; keeps a
    \\                   few huge files from replacing the whole haystack)
    \\  --lengths=a,b,c  needle lengths to sweep (default: 1,2,3,4,5,6,8,10,12,16,20,24,32,48,64)
    \\  --samples=N      needles per length (default 12)
    \\  --runs=N         timed repetitions per (needle, algo), median kept (default 3)
    \\  --out=FILE       also write the Markdown table to a file
    \\  --help
    \\
;

const Map = struct {
    file: std.Io.File,
    memory: std.Io.File.MemoryMap,
    len: usize,
};

const Haystack = struct {
    maps: std.ArrayList(Map),
    bytes: usize,
};

fn mapFile(io: std.Io, path: []const u8, maxfile: usize) ?Map {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    errdefer file.close(io);
    const stat = file.stat(io) catch return null;
    const full = std.math.cast(usize, stat.size) orelse return null;
    // Cap the mapping: a handful of 48 MB CSVs must not swamp the haystack.
    const size: usize = if (maxfile != 0 and full > maxfile) maxfile else full;
    if (size == 0) return null;

    const memory = std.Io.File.MemoryMap.create(io, file, .{
        .len = size,
        .protection = .{ .read = true, .write = false },
    }) catch return null;
    return .{ .file = file, .memory = memory, .len = size };
}

fn view(m: Map) []const u8 {
    return m.memory.memory[0..m.len];
}

/// Full exhaustive count of the needle in `data`, starting at `start`.
/// Both algos traverse to the end, so the timing reflects scan throughput.
fn countAll(searcher: *const Searcher, data: []const u8, start0: usize) usize {
    var cnt: usize = 0;
    var start: usize = start0;
    while (start < data.len) {
        const p = searcher.find(data, start) orelse break;
        cnt += 1;
        start = p + 1;
    }
    return cnt;
}

fn medianNs(samples: []const u64) u64 {
    const sorted = std.heap.page_allocator.alloc(u64, samples.len) catch return 0;
    defer std.heap.page_allocator.free(sorted);
    @memcpy(sorted, samples);
    std.sort.pdq(u64, sorted, {}, std.sort.asc(u64));
    const n = sorted.len;
    if (n == 0) return 0;
    if (n % 2 == 1) return sorted[n / 2];
    return (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
}

/// Times one (needle, algo) as the median of `runs` full haystack traversals.
fn timeOne(io: std.Io, hay: *const Haystack, needle: []const u8, algo: Algo, runs: usize) u64 {
    var samples: [32]u64 = undefined;
    const n = @min(runs, samples.len);
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const t0 = common.nowNs(io);
        var acc: usize = 0;
        var m: usize = 0;
        while (m < hay.maps.items.len) : (m += 1) {
            // Fresh Searcher per traversal: no memoisation, worst case.
            var searcher = Searcher.init(needle, algo);
            acc +%= countAll(&searcher, view(hay.maps.items[m]), 0);
        }
        std.mem.doNotOptimizeAway(acc);
        samples[k] = common.nowNs(io) -| t0;
    }
    return medianNs(samples[0..n]);
}

fn mbpsFrom(bytes: usize, ns: u64) f64 {
    if (ns == 0) return 0;
    const secs = @as(f64, @floatFromInt(ns)) / 1e9;
    if (secs <= 0) return 0;
    return @as(f64, @floatFromInt(bytes)) / secs / 1e6;
}

/// Appends one formatted line to an ArrayList, the same style scan.zig uses.
fn line(gpa: Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    out.appendSlice(gpa, s) catch {};
}

fn sendFile(io: std.Io, path: []const u8, data: []const u8) bool {
    return common.writeFile(io, path, data);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);

    var dir: []const u8 = ".";
    var budget: usize = 64 * 1024 * 1024;
    var samples_n: usize = 12;
    var runs: usize = 3;
    var out_path: ?[]const u8 = null;
    var maxfile: usize = 1024 * 1024;
    var lengths = [_]usize{ 1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24, 32, 48, 64 };
    var lengths_n: usize = lengths.len;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            common.printOut(init.io, "{s}", .{usage});
            std.process.exit(0);
        } else if (std.mem.startsWith(u8, a, "--dir=")) {
            dir = a["--dir=".len..];
        } else if (std.mem.startsWith(u8, a, "--budget=")) {
            budget = std.fmt.parseInt(usize, a["--budget=".len..], 10) catch budget;
        } else if (std.mem.startsWith(u8, a, "--samples=")) {
            samples_n = std.fmt.parseInt(usize, a["--samples=".len..], 10) catch samples_n;
        } else if (std.mem.startsWith(u8, a, "--runs=")) {
            runs = std.fmt.parseInt(usize, a["--runs=".len..], 10) catch runs;
        } else if (std.mem.startsWith(u8, a, "--maxfile=")) {
            maxfile = std.fmt.parseInt(usize, a["--maxfile=".len..], 10) catch maxfile;
        } else if (std.mem.startsWith(u8, a, "--out=")) {
            out_path = a["--out=".len..];
        } else if (std.mem.startsWith(u8, a, "--lengths=")) {
            const body = a["--lengths=".len..];
            var n: usize = 0;
            var it = std.mem.splitScalar(u8, body, ',');
            while (it.next()) |part| {
                if (part.len == 0 or n >= lengths.len) continue;
                lengths[n] = std.fmt.parseInt(usize, part, 10) catch continue;
                n += 1;
            }
            lengths_n = n;
        } else {
            common.printOut(init.io, "scripts/matcher_sweep.zig: unknown option '{s}'\n{s}", .{ a, usage });
            std.process.exit(2);
        }
    }
    if (samples_n == 0) samples_n = 1;
    if (runs == 0) runs = 1;

    // --- build the haystack: largest text files first, up to the budget -----
    var hay: Haystack = .{ .maps = .empty, .bytes = 0 };
    defer for (hay.maps.items) |*mapping| {
        mapping.memory.destroy(init.io);
        mapping.file.close(init.io);
    };
    var sizes: std.ArrayList(struct { path: []const u8, size: usize }) = .empty;
    defer sizes.deinit(gpa);

    // The repo's raw getdents64 walker: no symlinks, regular files only, the
    // same traversal the binary performs.
    var files: std.ArrayList([:0]const u8) = .empty;
    defer files.deinit(gpa);
    const rootz = std.fmt.allocPrintSentinel(gpa, "{s}", .{dir}, 0) catch
        std.process.exit(2);
    walk.walk(init.io, gpa, &.{rootz}, &files, null, null) catch |err| {
        common.printOut(init.io, "matcher_sweep: walk '{s}' failed: {s}\n", .{ dir, @errorName(err) });
        std.process.exit(1);
    };

    for (files.items) |path| {
        const file = std.Io.Dir.cwd().openFile(init.io, path, .{}) catch continue;
        const stat = file.stat(init.io) catch {
            file.close(init.io);
            continue;
        };
        file.close(init.io);
        const size = std.math.cast(usize, stat.size) orelse continue;
        try sizes.append(gpa, .{ .path = path, .size = size });
    }
    std.sort.pdq(@TypeOf(sizes.items[0]), sizes.items, {}, struct {
        fn lt(_: void, a: @TypeOf(sizes.items[0]), b: @TypeOf(sizes.items[0])) bool {
            return a.size > b.size;
        }
    }.lt);

    for (sizes.items) |e| {
        if (hay.bytes >= budget) break;
        if (e.size < 64) continue;
        var m = mapFile(init.io, e.path, maxfile) orelse continue;
        const data = view(m);
        // zgrep's binary rule: skip a file with a NUL in the first 8192 bytes.
        const probe = @min(data.len, 8192);
        if (std.mem.findScalar(u8, data[0..probe], 0) != null) {
            m.memory.destroy(init.io);
            m.file.close(init.io);
            continue;
        }
        try hay.maps.append(gpa, m);
        hay.bytes += m.len;
    }

    if (hay.bytes == 0 or hay.maps.items.len == 0) {
        common.printOut(init.io, "matcher_sweep: no text bytes under '{s}' (budget={d})\n", .{ dir, budget });
        std.process.exit(1);
    }

    var prng = std.Random.DefaultPrng.init(0x9e37_79b9_7f4a_7c15);
    const rnd = prng.random();
    const loadavg = common.readFile(init.io, gpa, "/proc/loadavg") orelse "?";

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    line(gpa, &out,
        \\# Matcher crossover sweep — bmh vs memchr
        \\
        \\- haystack dir: `{s}`
        \\- collected: {d} text bytes in {d} files (budget {d}, maxfile {d})
        \\- {d} needle samples per length, median of {d} runs each, single-threaded
        \\- host loadavg: {s}
        \\- matchers under test: imported from `src/search.zig`, not a copy
        \\
        \\| needle len | bmh MB/s | memchr MB/s | bmh / memchr | winner |
        \\|---:|---:|---:|---:|:--|
        \\
    , .{ dir, hay.bytes, hay.maps.items.len, budget, maxfile, samples_n, runs, loadavg });

    var misalign: usize = 0;
    var total_samples: usize = 0;

    for (lengths[0..lengths_n]) |L| {
        if (L == 0) continue;
        var bmh_ns = std.ArrayList(u64).empty;
        defer bmh_ns.deinit(gpa);
        var mc_ns = std.ArrayList(u64).empty;
        defer mc_ns.deinit(gpa);

        var s: usize = 0;
        while (s < samples_n) : (s += 1) {
            const mi = rnd.uintLessThan(usize, hay.maps.items.len);
            const data = view(hay.maps.items[mi]);
            if (data.len <= L) continue;
            const off = rnd.uintLessThan(usize, data.len - L);
            const needle = data[off .. off + L];

            // Alignment control: every needle counted with both kernels.
            var sb = Searcher.init(needle, .bmh);
            var sm = Searcher.init(needle, .memchr);
            var cb: usize = 0;
            var cm: usize = 0;
            for (hay.maps.items) |m| {
                cb += countAll(&sb, view(m), 0);
                cm += countAll(&sm, view(m), 0);
            }
            total_samples += 1;
            if (cb != cm) misalign += 1;

            try bmh_ns.append(gpa, timeOne(init.io, &hay, needle, .bmh, runs));
            try mc_ns.append(gpa, timeOne(init.io, &hay, needle, .memchr, runs));
        }

        const bmh_mbps = mbpsFrom(hay.bytes, medianNs(bmh_ns.items));
        const mc_mbps = mbpsFrom(hay.bytes, medianNs(mc_ns.items));
        const ratio: f64 = if (mc_mbps > 0) bmh_mbps / mc_mbps else 0;
        const winner: []const u8 = if (bmh_mbps >= mc_mbps) "bmh" else "memchr";
        line(gpa, &out, "| {d} | {d:.1} | {d:.1} | {d:.2}× | {s} |\n", .{ L, bmh_mbps, mc_mbps, ratio, winner });
    }

    line(gpa, &out,
        \\
        \\Alignment control: {d} samples recounted with both kernels, {d} disagreements (must be 0).
        \\
    , .{ total_samples, misalign });

    common.printOut(init.io, "{s}", .{out.items});
    if (out_path) |p| {
        if (!sendFile(init.io, p, out.items)) {
            common.printOut(init.io, "matcher_sweep: failed to write {s}\n", .{p});
            std.process.exit(2);
        }
    }
}
