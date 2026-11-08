//! Output-equivalence control for zgrep against GNU grep and ripgrep.
//!
//! ```sh
//! zig run scripts/check.zig -- [--save=OUTDIR] \
//!     --name=zgrep ./zig-out/bin/zgrep -rnF PATTERN CORPUS \
//!     --name=grep  grep -rnIF PATTERN CORPUS \
//!     --name=rg    rg -n -F --no-ignore --hidden PATTERN CORPUS
//! ```
//!
//! Each command's stdout is captured, then every pair is compared twice:
//!
//!   * **raw**    — byte-for-byte, including traversal order
//!   * **sorted** — order-independent, so parallel walkers still count
//!
//! Exit status is 0 only when every pair agrees after sorting, which makes the
//! script usable as a gate rather than a report.
//!
//! Global options (`--save=`, `--help`) must precede the first `--name=`.
const std = @import("std");
const common = @import("common.zig");
const Allocator = std.mem.Allocator;

const usage =
    \\scripts/check.zig — compare the output of two or more search commands
    \\
    \\usage: zig run scripts/check.zig -- [OPTIONS] --name=LABEL CMD...
    \\
    \\  --save=DIR   write each command's stdout/stderr to DIR/<label>.out
    \\  --help
    \\
    \\At least two --name groups are required. Exit 0 when all pairs agree
    \\after sorting their output, 1 when any pair differs, 2 on a bad call.
    \\
;

const Outcome = enum { identical, sorted_only, different };

fn compareSorted(arena: std.mem.Allocator, a: []const u8, b: []const u8) !Outcome {
    const la = try common.sortLines(arena, a);
    const lb = try common.sortLines(arena, b);
    if (la.len != lb.len) return .different;
    for (la, lb) |x, y| {
        if (!std.mem.eql(u8, x, y)) return .different;
    }
    return .sorted_only;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var save: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        }
        if (std.mem.startsWith(u8, a, "--save=")) {
            save = a["--save=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, a, "--name=")) break;
        std.debug.print("check: unexpected argument '{s}'\n{s}try --help for usage\n", .{ a, usage });
        std.process.exit(2);
    }
    if (i >= args.len) {
        std.debug.print("check: no --name groups given\n{s}", .{usage});
        std.process.exit(2);
    }

    const groups = common.collectGroups(arena, args[i..]) catch |err| {
        std.debug.print("check: bad group syntax ({s})\n", .{@errorName(err)});
        std.process.exit(2);
    };

    const stdout_limit = std.Io.Limit.limited(1 << 30);

    const results = try arena.alloc(struct {
        label: []const u8,
        code: u8,
        lines: usize,
        stdout: []const u8,
        stderr: []const u8,
    }, groups.len);

    for (groups, 0..) |g, gi| {
        const r = std.process.run(arena, init.io, .{
            .argv = g.argv,
            .stdout_limit = stdout_limit,
            .stderr_limit = std.Io.Limit.limited(8 << 20),
        }) catch |err| {
            std.debug.print("check: failed to run '{s}': {s}\n", .{ g.label, @errorName(err) });
            std.process.exit(2);
        };
        results[gi] = .{
            .label = g.label,
            .code = common.termCode(r.term),
            .lines = common.countNewlines(r.stdout),
            .stdout = r.stdout,
            .stderr = r.stderr,
        };
        if (r.stderr.len > 0) {
            std.debug.print("check: [{s}] stderr ({d} bytes):\n{s}", .{ g.label, r.stderr.len, r.stderr });
        }
    }

    var report: std.ArrayList(u8) = .empty;
    const emit = struct {
        fn line(list: *std.ArrayList(u8), gpa: Allocator, comptime fmt: []const u8, fmt_args: anytype) void {
            const s = std.fmt.allocPrint(gpa, fmt, fmt_args) catch return;
            list.appendSlice(gpa, s) catch {};
        }
    }.line;

    emit(&report, arena, "check: groups={d}\n", .{groups.len});
    for (results) |r| {
        emit(&report, arena, "  {s:<16} exit={d} lines={d} bytes={d}\n", .{ r.label, r.code, r.lines, r.stdout.len });
    }

    var all_ok = true;
    var pair: usize = 0;
    while (pair < results.len) : (pair += 1) {
        var other: usize = pair + 1;
        while (other < results.len) : (other += 1) {
            const a = results[pair];
            const b = results[other];
            const raw = if (std.mem.eql(u8, a.stdout, b.stdout)) Outcome.identical else compareSorted(arena, a.stdout, b.stdout) catch .different;
            const verdict: []const u8 = switch (raw) {
                .identical => "raw=identical",
                .sorted_only => "raw=different sorted=identical",
                .different => "raw=different sorted=DIFFERENT",
            };
            if (raw == .different) all_ok = false;
            emit(&report, arena, "pair {s} vs {s}: {s}{s}\n", .{ a.label, b.label, verdict, if (raw == .different) "  <== MISMATCH" else "" });
        }
    }

    emit(&report, arena, "result: {s}\n", .{if (all_ok) "PASS (all pairs agree after sorting)" else "FAIL (outputs differ)"});

    std.debug.print("{s}", .{report.items});
    if (save) |dir| {
        common.makePath(arena, dir) catch {};
        for (results) |r| {
            const stem = try common.sanitizeLabel(arena, r.label);
            const op = try std.fmt.allocPrintSentinel(arena, "{s}/{s}.out", .{ dir, stem }, 0);
            const ep = try std.fmt.allocPrintSentinel(arena, "{s}/{s}.err", .{ dir, stem }, 0);
            if (!common.writeFile(op, r.stdout) or !common.writeFile(ep, r.stderr)) {
                std.debug.print("check: failed to save under {s}\n", .{dir});
                std.process.exit(2);
            }
        }
        const rp = try std.fmt.allocPrintSentinel(arena, "{s}/report.txt", .{dir}, 0);
        if (!common.writeFile(rp, report.items)) {
            std.debug.print("check: failed to write {s}\n", .{rp});
            std.process.exit(2);
        }
        std.debug.print("check: outputs saved to {s}\n", .{dir});
    }

    std.process.exit(if (all_ok) 0 else 1);
}
