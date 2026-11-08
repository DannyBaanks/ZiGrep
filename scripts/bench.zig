//! Repeated wall-clock benchmark of one or more commands.
//!
//! ```sh
//! zig run scripts/bench.zig -- --runs=10 --warmup=3 --bytes=402241343 \
//!     --name=zgrep ./zig-out/bin/zgrep -rnF PATTERN CORPUS \
//!     --name=grep  grep -rnIF PATTERN CORPUS
//! ```
//!
//! Each group is warmed up `--warmup` times (untimed, so the page cache is
//! hot), then timed `--runs` times around `spawn` → `wait`. Warm-up and timed
//! runs are **interleaved across groups** in rotating order, so a busy host
//! penalises every group equally instead of whichever runs last. The child's
//! stdout goes to `/dev/null`, which is what a real `grep | wc` pipeline costs
//! too.
//!
//! A Markdown table plus the raw samples go to stdout, so the evidence pack
//! keeps the numbers behind every claim. `--out=FILE` also writes JSON.
//!
//! Global options must precede the first `--name=`.
const std = @import("std");
const common = @import("common.zig");
const Allocator = std.mem.Allocator;

const usage =
    \\scripts/bench.zig — time N repetitions of each given command
    \\
    \\usage: zig run scripts/bench.zig -- [OPTIONS] --name=LABEL CMD...
    \\
    \\  --runs=N      timed repetitions per group (default 10)
    \\  --warmup=N    untimed repetitions before measuring (default 3)
    \\  --bytes=N     corpus bytes; enables the MB/s column
    \\  --out=FILE    also write the results as JSON
    \\  --help
    \\
    \\Global options must come before the first --name=.
    \\
;

const Summary = struct {
    min_ns: u64,
    median_ns: u64,
    mean_ns: f64,
    max_ns: u64,
    stddev_ns: f64,
};

const Result = struct {
    group: common.Group,
    samples: []u64,
    codes: []u8,
    summary: Summary,
};

fn summarize(arena: Allocator, samples: []const u64) !Summary {
    const sorted = try arena.dupe(u64, samples);
    std.sort.pdq(u64, sorted, {}, std.sort.asc(u64));
    const n = sorted.len;
    var median: u64 = 0;
    if (n % 2 == 1) {
        median = sorted[n / 2];
    } else {
        median = @divFloor(sorted[n / 2 - 1] + sorted[n / 2], 2);
    }
    var sum: u128 = 0;
    for (sorted) |s| sum += s;
    const mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(n));
    var acc: f64 = 0;
    for (sorted) |s| {
        const d = @as(f64, @floatFromInt(s)) - mean;
        acc += d * d;
    }
    const stddev = if (n > 1) @sqrt(acc / @as(f64, @floatFromInt(n - 1))) else 0;
    return .{
        .min_ns = sorted[0],
        .median_ns = median,
        .mean_ns = mean,
        .max_ns = sorted[n - 1],
        .stddev_ns = stddev,
    };
}

fn runOnce(io: std.Io, argv: []const []const u8) !struct { ns: u64, code: u8 } {
    const t0 = common.nowNs();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    return .{ .ns = common.nowNs() -| t0, .code = common.termCode(term) };
}

fn appendJsonString(list: *std.ArrayList(u8), arena: Allocator, s: []const u8) Allocator.Error!void {
    try list.append(arena, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(arena, "\\\""),
            '\\' => try list.appendSlice(arena, "\\\\"),
            '\n' => try list.appendSlice(arena, "\\n"),
            '\r' => try list.appendSlice(arena, "\\r"),
            '\t' => try list.appendSlice(arena, "\\t"),
            else => if (c < 0x20) {
                const esc = std.fmt.allocPrint(arena, "\\u{x:0>4}", .{c}) catch {
                    try list.append(arena, ' ');
                    continue;
                };
                try list.appendSlice(arena, esc);
            } else try list.append(arena, c),
        }
    }
    try list.append(arena, '"');
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var runs: usize = 10;
    var warmup: usize = 3;
    var bytes: usize = 0;
    var out_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        }
        if (std.mem.startsWith(u8, a, "--runs=")) {
            runs = std.fmt.parseInt(usize, a["--runs=".len..], 10) catch 0;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--warmup=")) {
            warmup = std.fmt.parseInt(usize, a["--warmup=".len..], 10) catch 0;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--bytes=")) {
            bytes = std.fmt.parseInt(usize, a["--bytes=".len..], 10) catch 0;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--out=")) {
            out_path = a["--out=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, a, "--name=")) break;
        std.debug.print("bench: unexpected argument '{s}'\n{s}try --help for usage\n", .{ a, usage });
        std.process.exit(2);
    }
    if (i >= args.len) {
        std.debug.print("bench: no --name groups given\n{s}", .{usage});
        std.process.exit(2);
    }
    if (runs == 0 or runs > 10_000) {
        std.debug.print("bench: --runs must be 1..10000\n", .{});
        std.process.exit(2);
    }

    const groups = common.collectGroups(arena, args[i..]) catch |err| {
        std.debug.print("bench: bad group syntax ({s}); need at least two --name groups\n", .{@errorName(err)});
        std.process.exit(2);
    };

    const load = common.readFile(arena, "/proc/loadavg") orelse "n/a";
    const nproc = std.Thread.getCpuCount() catch 0;

    common.printOut("bench: runs={d} warmup={d} corpus_bytes={d} nproc={d} loadavg={s}\n\n", .{ runs, warmup, bytes, nproc, load });

    const results = try arena.alloc(Result, groups.len);
    for (groups, 0..) |g, gi| {
        results[gi] = .{
            .group = g,
            .samples = try arena.alloc(u64, runs),
            .codes = try arena.alloc(u8, runs),
            .summary = undefined,
        };
    }

    // Warm-up: one full round per iteration, rotating which group goes first,
    // so no group systematically gets the coldest page cache.
    var w: usize = 0;
    while (w < warmup) : (w += 1) {
        var gi: usize = 0;
        while (gi < groups.len) : (gi += 1) {
            const idx = (gi + w) % groups.len;
            const r = runOnce(init.io, groups[idx].argv) catch |err| {
                std.debug.print("bench: '{s}' failed to run: {s}\n", .{ groups[idx].label, @errorName(err) });
                std.process.exit(2);
            };
            if (w == 0 and r.code != 0) {
                std.debug.print("bench: WARNING '{s}' exited {d} on warmup (first argv: {s})\n", .{ groups[idx].label, r.code, groups[idx].argv[0] });
            }
        }
    }

    // Timed rounds: interleaved and rotated, so load drift or cache pressure
    // during the run is shared by every group instead of penalising whichever
    // happens to run last.
    var k: usize = 0;
    while (k < runs) : (k += 1) {
        var gi: usize = 0;
        while (gi < groups.len) : (gi += 1) {
            const idx = (gi + k) % groups.len;
            const r = try runOnce(init.io, groups[idx].argv);
            results[idx].samples[k] = r.ns;
            results[idx].codes[k] = r.code;
        }
    }
    for (results) |*r| {
        r.summary = try summarize(arena, r.samples);
    }

    // --- report ------------------------------------------------------------
    common.printOut("| {s:<14} | {s:>10} | {s:>10} | {s:>10} | {s:>10} | {s:>11} | {s:>10} | {s:>5} |\n", .{
        "label", "median ms", "min ms", "max ms", "mean ms", "stddev ms", "MB/s", "exit",
    });
    common.printOut("|{s}|{s}|{s}|{s}|{s}|{s}|{s}|{s}|\n", .{
        "---",
        "---:",
        "---:",
        "---:",
        "---:",
        "---:",
        "---:",
        "---:",
    });

    for (results) |r| {
        const med_s = @as(f64, @floatFromInt(r.summary.median_ns)) / 1e9;
        const mbps = if (bytes > 0 and med_s > 0) @as(f64, @floatFromInt(bytes)) / med_s / 1e6 else 0;
        const codes_same = blk: {
            var ok = true;
            for (r.codes) |c| {
                if (c != r.codes[0]) ok = false;
            }
            break :blk ok;
        };
        var code_buf: [8]u8 = undefined;
        const code_str: []const u8 = if (codes_same)
            (std.fmt.bufPrint(&code_buf, "{d}", .{r.codes[0]}) catch unreachable)
        else
            "varies";
        common.printOut("| {s:<14} | {d:>10.3} | {d:>10.3} | {d:>10.3} | {d:>10.3} | {d:>11.3} | {d:>10.1} | {s:>5} |\n", .{
            r.group.label,
            @as(f64, @floatFromInt(r.summary.median_ns)) / 1e6,
            @as(f64, @floatFromInt(r.summary.min_ns)) / 1e6,
            @as(f64, @floatFromInt(r.summary.max_ns)) / 1e6,
            r.summary.mean_ns / 1e6,
            r.summary.stddev_ns / 1e6,
            mbps,
            code_str,
        });
    }

    common.printOut("\n", .{});
    for (results) |r| {
        common.printOut("raw {s}:", .{r.group.label});
        for (r.samples) |s| common.printOut(" {d}", .{s});
        common.printOut("\n", .{});
    }

    common.printOut("cmd {s}", .{results[0].group.label});
    for (results[0].group.argv) |tok| common.printOut(" {s}", .{tok});
    common.printOut("\n", .{});
    for (results[1..]) |r| {
        common.printOut("cmd {s}", .{r.group.label});
        for (r.group.argv) |tok| common.printOut(" {s}", .{tok});
        common.printOut("\n", .{});
    }

    // --- JSON ---------------------------------------------------------------
    if (out_path) |path| {
        var j: std.ArrayList(u8) = .empty;
        const jput = struct {
            fn put(list: *std.ArrayList(u8), gpa: Allocator, comptime fmt: []const u8, fmt_args: anytype) void {
                const s = std.fmt.allocPrint(gpa, fmt, fmt_args) catch return;
                list.appendSlice(gpa, s) catch {};
            }
        }.put;

        jput(&j, arena, "{{\"tool\":\"scripts/bench.zig\",\"runs\":{d},\"warmup\":{d},\"corpus_bytes\":{d},\"nproc\":{d},\"loadavg\":", .{ runs, warmup, bytes, nproc });
        try appendJsonString(&j, arena, load);
        jput(&j, arena, ",\"groups\":[", .{});
        for (results, 0..) |r, gi| {
            if (gi > 0) jput(&j, arena, ",", .{});
            jput(&j, arena, "{{\"label\":", .{});
            try appendJsonString(&j, arena, r.group.label);
            jput(&j, arena, ",\"argv\":[", .{});
            for (r.group.argv, 0..) |tok, ti| {
                if (ti > 0) jput(&j, arena, ",", .{});
                try appendJsonString(&j, arena, tok);
            }
            jput(&j, arena, "],\"exit_codes\":[", .{});
            for (r.codes, 0..) |c, ci| {
                if (ci > 0) jput(&j, arena, ",", .{});
                jput(&j, arena, "{d}", .{c});
            }
            jput(&j, arena, "],\"samples_ns\":[", .{});
            for (r.samples, 0..) |s, si| {
                if (si > 0) jput(&j, arena, ",", .{});
                jput(&j, arena, "{d}", .{s});
            }
            jput(&j, arena, "],\"min_ns\":{d},\"median_ns\":{d},\"mean_ns\":{d:.1},\"max_ns\":{d},\"stddev_ns\":{d:.1}}}", .{
                r.summary.min_ns,
                r.summary.median_ns,
                r.summary.mean_ns,
                r.summary.max_ns,
                r.summary.stddev_ns,
            });
        }
        jput(&j, arena, "]}}\n", .{});

        const op = try std.fmt.allocPrintSentinel(arena, "{s}", .{path}, 0);
        if (!common.writeFile(op, j.items)) {
            std.debug.print("bench: failed to write {s}\n", .{path});
            std.process.exit(2);
        }
        common.printOut("json {s} ({d} bytes)\n", .{ path, j.items.len });
    }
}
