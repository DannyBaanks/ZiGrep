//! Oracle test suite in pure Zig: differential testing of zigrep vs GNU grep and ripgrep.
//!
//! Verifies:
//!   - Fixed-string literals (-F and auto-detection)
//!   - ASCII case-folding (-i)
//!   - Whole-word matching (-w)
//!   - Combined flags (-i -w)
//!   - Multi-pattern search (-e)
//!   - Linear regex engine (\d, \w, +, *, ?, |, ^, $)
//!   - Per-file line count (-c)
//!   - File listing (-l)
//!   - Quiet early-exit (-q) with exit 0 and exit 1
//!   - Kamikaze concurrent swarm (-k) order-independent line equivalence
//!
//! Usage:
//!   zig run scripts/oracle.zig [--target=DIR]
const std = @import("std");
const common = @import("common.zig");
const Allocator = std.mem.Allocator;

const TestCase = struct {
    name: []const u8,
    zigrep_args: []const []const u8,
    grep_args: []const []const u8,
    rg_args: ?[]const []const u8 = null,
    expected_exit: u8 = 0,
    check_output: bool = true,
};

const cases = [_]TestCase{
    .{
        .name = "literal 'Searcher' (-n)",
        .zigrep_args = &.{ "Searcher", "src" },
        .grep_args = &.{ "-rnIF", "Searcher", "src" },
        .rg_args = &.{ "-n", "-F", "Searcher", "src" },
        .expected_exit = 0,
    },
    .{
        .name = "case-insensitive -i 'searcher'",
        .zigrep_args = &.{ "-i", "searcher", "src" },
        .grep_args = &.{ "-rnIF", "-i", "searcher", "src" },
        .rg_args = &.{ "-n", "-F", "-i", "searcher", "src" },
        .expected_exit = 0,
    },
    .{
        .name = "whole-word -w 'Searcher'",
        .zigrep_args = &.{ "-w", "Searcher", "src" },
        .grep_args = &.{ "-rnIF", "-w", "Searcher", "src" },
        .rg_args = &.{ "-n", "-F", "-w", "Searcher", "src" },
        .expected_exit = 0,
    },
    .{
        .name = "combined -i -w 'searcher'",
        .zigrep_args = &.{ "-i", "-w", "searcher", "src" },
        .grep_args = &.{ "-rnIF", "-i", "-w", "searcher", "src" },
        .rg_args = &.{ "-n", "-F", "-i", "-w", "searcher", "src" },
        .expected_exit = 0,
    },
    .{
        .name = "multi-pattern -e 'const' -e 'pub'",
        .zigrep_args = &.{ "-e", "const", "-e", "pub", "src" },
        .grep_args = &.{ "-rnIF", "-e", "const", "-e", "pub", "src" },
        .rg_args = &.{ "-n", "-F", "-e", "const", "-e", "pub", "src" },
        .expected_exit = 0,
    },
    .{
        .name = "regex 'pub\\s+fn\\s+'",
        .zigrep_args = &.{ "pub\\s+fn\\s+", "src" },
        .grep_args = &.{ "-rnIE", "pub[[:space:]]+fn[[:space:]]+", "src" },
        .rg_args = &.{ "-n", "pub\\s+fn\\s+", "src" },
        .expected_exit = 0,
    },
    .{
        .name = "regex alternation 'searcher|filter'",
        .zigrep_args = &.{ "-i", "searcher|filter", "src" },
        .grep_args = &.{ "-rnIE", "-i", "searcher|filter", "src" },
        .rg_args = &.{ "-n", "-i", "searcher|filter", "src" },
        .expected_exit = 0,
    },
    .{
        .name = "regex digits '[0-9]{2,}'",
        .zigrep_args = &.{ "[0-9]{2,}", "src" },
        .grep_args = &.{ "-rnIE", "[0-9]{2,}", "src" },
        .rg_args = &.{ "-n", "[0-9]{2,}", "src" },
        .expected_exit = 0,
    },
    .{
        .name = "regex anchor '^const'",
        .zigrep_args = &.{ "^const ", "src" },
        .grep_args = &.{ "-rnIE", "^const ", "src" },
        .rg_args = &.{ "-n", "^const ", "src" },
        .expected_exit = 0,
    },
    .{
        .name = "count mode -c",
        .zigrep_args = &.{ "-c", "Searcher", "src" },
        .grep_args = &.{ "-rIFc", "Searcher", "src" },
        .rg_args = null, // ripgrep omits 0-count files in -c mode
        .expected_exit = 0,
    },
    .{
        .name = "files mode -l",
        .zigrep_args = &.{ "-l", "Searcher", "src" },
        .grep_args = &.{ "-rIFl", "Searcher", "src" },
        .rg_args = &.{ "-F", "-l", "Searcher", "src" },
        .expected_exit = 0,
    },
    .{
        .name = "quiet mode -q present (exit 0)",
        .zigrep_args = &.{ "-q", "Searcher", "src" },
        .grep_args = &.{ "-rIFq", "Searcher", "src" },
        .rg_args = &.{ "-F", "-q", "Searcher", "src" },
        .expected_exit = 0,
        .check_output = false,
    },
    .{
        .name = "quiet mode -q absent (exit 1)",
        .zigrep_args = &.{ "-q", "zzz_non_existent_token_xyz", "src" },
        .grep_args = &.{ "-rIFq", "zzz_non_existent_token_xyz", "src" },
        .rg_args = &.{ "-F", "-q", "zzz_non_existent_token_xyz", "src" },
        .expected_exit = 1,
        .check_output = false,
    },
    .{
        .name = "kamikaze swarm -k 'Searcher'",
        .zigrep_args = &.{ "-k", "Searcher", "src" },
        .grep_args = &.{ "-rnIF", "Searcher", "src" },
        .rg_args = &.{ "-n", "-F", "Searcher", "src" },
        .expected_exit = 0,
    },
    .{
        .name = "kamikaze swarm -k -q present (exit 0)",
        .zigrep_args = &.{ "-k", "-q", "Searcher", "src" },
        .grep_args = &.{ "-rIFq", "Searcher", "src" },
        .rg_args = &.{ "-F", "-q", "Searcher", "src" },
        .expected_exit = 0,
        .check_output = false,
    },
    .{
        .name = "io_uring async batch --uring 'Searcher'",
        .zigrep_args = &.{ "--uring", "Searcher", "src" },
        .grep_args = &.{ "-rnIF", "Searcher", "src" },
        .rg_args = &.{ "-n", "-F", "Searcher", "src" },
        .expected_exit = 0,
    },
    .{
        .name = "deterministic sorted mode --sort",
        .zigrep_args = &.{ "--sort", "Searcher", "src" },
        .grep_args = &.{ "-rnIF", "Searcher", "src" },
        .rg_args = &.{ "-n", "-F", "--sort", "path", "Searcher", "src" },
        .expected_exit = 0,
        .check_output = true,
    },
    .{
        .name = "nav depth ceiling -m 'v^' (scan root only)",
        .zigrep_args = &.{ "-m", "v^", "Searcher", "src" },
        .grep_args = &.{ "-rnIF", "Searcher", "src" },
        .rg_args = &.{ "-n", "-F", "Searcher", "src" },
        .expected_exit = 0,
        .check_output = true,
    },
    .{
        .name = "nav trampoline -m '^v' (dive into subdirs)",
        .zigrep_args = &.{ "-m", "^v", "name", ".github" },
        .grep_args = &.{ "-rnIF", "name", ".github" },
        .rg_args = &.{ "-n", "-F", "name", ".github" },
        .expected_exit = 0,
        .check_output = true,
    },
    .{
        .name = "absent needle (exit 1)",
        .zigrep_args = &.{ "zzz_non_existent_token_xyz", "src" },
        .grep_args = &.{ "-rnIF", "zzz_non_existent_token_xyz", "src" },
        .rg_args = &.{ "-n", "-F", "zzz_non_existent_token_xyz", "src" },
        .expected_exit = 1,
        .check_output = true,
    },
    .{
        .name = "invert-match -v 'const'",
        .zigrep_args = &.{ "-v", "const", "src/root.zig" },
        .grep_args = &.{ "-rnIF", "-v", "const", "src/root.zig" },
        .rg_args = &.{ "-n", "-F", "-v", "const", "src/root.zig" },
        .expected_exit = 0,
        .check_output = true,
    },
    .{
        .name = "files-without-match -L 'Searcher'",
        .zigrep_args = &.{ "-L", "Searcher", "src" },
        .grep_args = &.{ "-rIFL", "Searcher", "src" },
        .rg_args = &.{ "--files-without-match", "-F", "Searcher", "src" },
        .expected_exit = 0,
        .check_output = true,
    },
    .{
        .name = "max-count -m 1 'Searcher'",
        .zigrep_args = &.{ "-m", "1", "Searcher", "src/search.zig" },
        .grep_args = &.{ "-rnIF", "-m", "1", "Searcher", "src/search.zig" },
        .rg_args = &.{ "-n", "-F", "-m", "1", "Searcher", "src/search.zig" },
        .expected_exit = 0,
        .check_output = true,
    },
    .{
        .name = "max-count --max-count=2 'Searcher'",
        .zigrep_args = &.{ "--max-count=2", "Searcher", "src/search.zig" },
        .grep_args = &.{ "-rnIF", "--max-count=2", "Searcher", "src/search.zig" },
        .rg_args = &.{ "-n", "-F", "--max-count=2", "Searcher", "src/search.zig" },
        .expected_exit = 0,
        .check_output = true,
    },
    .{
        .name = "invert-match with max-count -v -m 2",
        .zigrep_args = &.{ "-v", "-m", "2", "pub", "src/root.zig" },
        .grep_args = &.{ "-rnIF", "-v", "-m", "2", "pub", "src/root.zig" },
        .rg_args = &.{ "-n", "-F", "-v", "-m", "2", "pub", "src/root.zig" },
        .expected_exit = 0,
        .check_output = true,
    },
};

fn runCmd(arena: Allocator, io: anytype, argv: []const []const u8) !struct { code: u8, stdout: []const u8 } {
    const limit = std.Io.Limit.limited(16 << 20);
    const r = std.process.run(arena, io, .{
        .argv = argv,
        .stdout_limit = limit,
        .stderr_limit = limit,
    }) catch |err| {
        std.debug.print("Failed to run cmd {s}: {s}\n", .{ argv[0], @errorName(err) });
        return err;
    };
    return .{
        .code = common.termCode(r.term),
        .stdout = r.stdout,
    };
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    _ = args;

    // Resolve binary path: prefer zig-out/bin/zigrep, fallback to zig-out/bin/zgrep
    const exe = blk: {
        const rc1 = std.os.linux.faccessat(std.os.linux.AT.FDCWD, "zig-out/bin/zigrep", 0, 0);
        if (std.os.linux.errno(rc1) == .SUCCESS) break :blk "zig-out/bin/zigrep";
        const rc2 = std.os.linux.faccessat(std.os.linux.AT.FDCWD, "zig-out/bin/zgrep", 0, 0);
        if (std.os.linux.errno(rc2) == .SUCCESS) break :blk "zig-out/bin/zgrep";
        std.debug.print("Error: zig-out/bin/zigrep not found. Run 'zig build' first.\n", .{});
        std.process.exit(2);
    };

    common.printOut("===============================================================================\n", .{});
    common.printOut("  zigrep Differential Oracle Suite (pure Zig runner)\n", .{});
    common.printOut("  Testing {s} against GNU grep and ripgrep\n", .{exe});
    common.printOut("===============================================================================\n\n", .{});

    var passed: usize = 0;
    var failed: usize = 0;

    for (cases) |c| {
        // 1. Build zigrep argv
        var z_argv: std.ArrayList([]const u8) = .empty;
        try z_argv.append(arena, exe);
        try z_argv.appendSlice(arena, c.zigrep_args);

        // 2. Build grep argv
        var g_argv: std.ArrayList([]const u8) = .empty;
        try g_argv.append(arena, "grep");
        try g_argv.appendSlice(arena, c.grep_args);

        // Run zigrep
        const z_res = runCmd(arena, init.io, z_argv.items) catch {
            failed += 1;
            continue;
        };

        // Run grep
        const g_res = runCmd(arena, init.io, g_argv.items) catch {
            failed += 1;
            continue;
        };

        // Check exit codes
        var ok = (z_res.code == c.expected_exit) and (z_res.code == g_res.code);
        var reason: []const u8 = "OK";

        if (!ok) {
            reason = "EXIT_CODE_MISMATCH";
        } else if (c.check_output) {
            const z_lines = try common.sortLines(arena, z_res.stdout);
            const g_lines = try common.sortLines(arena, g_res.stdout);

            if (z_lines.len != g_lines.len) {
                ok = false;
                reason = "LINE_COUNT_MISMATCH";
            } else {
                for (z_lines, g_lines) |zl, gl| {
                    if (!std.mem.eql(u8, zl, gl)) {
                        ok = false;
                        reason = "CONTENT_MISMATCH";
                        break;
                    }
                }
            }
        }

        // Check against ripgrep if specified
        if (ok and c.rg_args != null) {
            var r_argv: std.ArrayList([]const u8) = .empty;
            try r_argv.append(arena, "rg");
            try r_argv.appendSlice(arena, c.rg_args.?);

            if (runCmd(arena, init.io, r_argv.items)) |r_res| {
                if (r_res.code != c.expected_exit) {
                    ok = false;
                    reason = "RG_EXIT_MISMATCH";
                } else if (c.check_output) {
                    const z_lines = try common.sortLines(arena, z_res.stdout);
                    const r_lines = try common.sortLines(arena, r_res.stdout);
                    if (z_lines.len != r_lines.len) {
                        ok = false;
                        reason = "RG_LINE_COUNT_MISMATCH";
                    }
                }
            } else |_| {}
        }

        if (ok) {
            passed += 1;
            common.printOut("  [PASS] {s:<42} (exit {d}, lines {d})\n", .{
                c.name,
                z_res.code,
                common.countNewlines(z_res.stdout),
            });
        } else {
            failed += 1;
            common.printOut("  [FAIL] {s:<42} reason={s} (zigrep code={d}, grep code={d})\n", .{
                c.name,
                reason,
                z_res.code,
                g_res.code,
            });
        }
    }

    // Stdin pipeline differential test (pipe -> zigrep vs pipe -> grep -n)
    {
        const test_name = "stdin pipeline (pipe -> zigrep)";
        const cmd_z = try std.fmt.allocPrint(arena, "printf 'alpha\\nbeta\\ngamma\\n' | {s} 'beta'", .{exe});
        const cmd_g = "printf 'alpha\\nbeta\\ngamma\\n' | grep -n 'beta'";
        const z_res = runCmd(arena, init.io, &.{ "sh", "-c", cmd_z }) catch null;
        const g_res = runCmd(arena, init.io, &.{ "sh", "-c", cmd_g }) catch null;
        if (z_res != null and g_res != null and z_res.?.code == 0 and g_res.?.code == 0 and std.mem.eql(u8, z_res.?.stdout, g_res.?.stdout)) {
            passed += 1;
            common.printOut("  [PASS] {s:<42} (exit 0, lines 1)\n", .{test_name});
        } else {
            failed += 1;
            common.printOut("  [FAIL] {s:<42} reason=STDIN_MISMATCH\n", .{test_name});
        }
    }

    const total_tests = cases.len + 1;
    common.printOut("\n-------------------------------------------------------------------------------\n", .{});
    common.printOut("Results: {d} PASSED, {d} FAILED (total {d})\n", .{ passed, failed, total_tests });
    common.printOut("-------------------------------------------------------------------------------\n", .{});

    if (failed > 0) {
        std.process.exit(1);
    }
}
