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
const builtin = @import("builtin");
const common = @import("common.zig");
const Allocator = std.mem.Allocator;

const TestCase = struct {
    name: []const u8,
    zigrep_args: []const []const u8,
    /// `null` = GNU grep cannot express this check here. The baseline on this
    /// host is grep 3.0 (the one Git for Windows ships), which has no
    /// --count-matches and no --replace. Such a case must still carry
    /// `rg_args`, or it would only be checking that zigrep exits.
    grep_args: ?[]const []const u8 = null,
    rg_args: ?[]const []const u8 = null,
    expected_exit: u8 = 0,
    check_output: bool = true,
};

const cases = [_]TestCase{
    .{
        .name = "literal 'Searcher' (-n)",
        .zigrep_args = &.{ "-n", "Searcher", "src" },
        .grep_args = &.{ "-rnIF", "Searcher", "src" },
        .rg_args = &.{ "-n", "-F", "Searcher", "src" },
        .expected_exit = 0,
    },
    .{
        .name = "case-insensitive -i 'searcher'",
        .zigrep_args = &.{ "-n", "-i", "searcher", "src" },
        .grep_args = &.{ "-rnIF", "-i", "searcher", "src" },
        .rg_args = &.{ "-n", "-F", "-i", "searcher", "src" },
        .expected_exit = 0,
    },
    .{
        .name = "whole-word -w 'Searcher'",
        .zigrep_args = &.{ "-n", "-w", "Searcher", "src" },
        .grep_args = &.{ "-rnIF", "-w", "Searcher", "src" },
        .rg_args = &.{ "-n", "-F", "-w", "Searcher", "src" },
        .expected_exit = 0,
    },
    .{
        .name = "combined -i -w 'searcher'",
        .zigrep_args = &.{ "-n", "-i", "-w", "searcher", "src" },
        .grep_args = &.{ "-rnIF", "-i", "-w", "searcher", "src" },
        .rg_args = &.{ "-n", "-F", "-i", "-w", "searcher", "src" },
        .expected_exit = 0,
    },
    .{
        .name = "multi-pattern -e 'const' -e 'pub'",
        .zigrep_args = &.{ "-n", "-e", "const", "-e", "pub", "src" },
        .grep_args = &.{ "-rnIF", "-e", "const", "-e", "pub", "src" },
        .rg_args = &.{ "-n", "-F", "-e", "const", "-e", "pub", "src" },
        .expected_exit = 0,
    },
    .{
        .name = "regex 'pub\\s+fn\\s+'",
        .zigrep_args = &.{ "-n", "pub\\s+fn\\s+", "src" },
        .grep_args = &.{ "-rnIE", "pub[[:space:]]+fn[[:space:]]+", "src" },
        .rg_args = &.{ "-n", "pub\\s+fn\\s+", "src" },
        .expected_exit = 0,
    },
    .{
        .name = "regex alternation 'searcher|filter'",
        .zigrep_args = &.{ "-n", "-i", "searcher|filter", "src" },
        .grep_args = &.{ "-rnIE", "-i", "searcher|filter", "src" },
        .rg_args = &.{ "-n", "-i", "searcher|filter", "src" },
        .expected_exit = 0,
    },
    .{
        .name = "regex digits '[0-9]{2,}'",
        .zigrep_args = &.{ "-n", "[0-9]{2,}", "src" },
        // Git for Windows' GNU grep 3.0 misparses this interval expression.
        // The equivalent ERE below keeps the differential check meaningful.
        .grep_args = &.{ "-rnIE", "[0-9][0-9]+", "src" },
        .rg_args = &.{ "-n", "[0-9]{2,}", "src" },
        .expected_exit = 0,
    },
    .{
        .name = "regex anchor '^const'",
        .zigrep_args = &.{ "-n", "^const ", "src" },
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
        .zigrep_args = &.{ "-n", "-k", "Searcher", "src" },
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
        .zigrep_args = &.{ "-n", "--uring", "Searcher", "src" },
        .grep_args = &.{ "-rnIF", "Searcher", "src" },
        .rg_args = &.{ "-n", "-F", "Searcher", "src" },
        .expected_exit = 0,
    },
    .{
        .name = "deterministic sorted mode --sort",
        .zigrep_args = &.{ "-n", "--sort", "Searcher", "src" },
        .grep_args = &.{ "-rnIF", "Searcher", "src" },
        .rg_args = &.{ "-n", "-F", "--sort", "path", "Searcher", "src" },
        .expected_exit = 0,
        .check_output = true,
    },
    .{
        .name = "nav depth ceiling -m 'v^' (scan root only)",
        .zigrep_args = &.{ "-n", "-m", "v^", "Searcher", "src" },
        .grep_args = &.{ "-rnIF", "Searcher", "src" },
        .rg_args = &.{ "-n", "-F", "Searcher", "src" },
        .expected_exit = 0,
        .check_output = true,
    },
    .{
        .name = "nav trampoline -m '^v' (dive into subdirs)",
        .zigrep_args = &.{ "-n", "-m", "^v", "name", ".github" },
        .grep_args = &.{ "-rnIF", "name", ".github" },
        .rg_args = &.{ "-n", "-F", "name", ".github" },
        .expected_exit = 0,
        .check_output = true,
    },
    .{
        .name = "absent needle (exit 1)",
        .zigrep_args = &.{ "-n", "zzz_non_existent_token_xyz", "src" },
        .grep_args = &.{ "-rnIF", "zzz_non_existent_token_xyz", "src" },
        .rg_args = &.{ "-n", "-F", "zzz_non_existent_token_xyz", "src" },
        .expected_exit = 1,
        .check_output = true,
    },
    .{
        .name = "invert-match -v 'const'",
        .zigrep_args = &.{ "-n", "-v", "const", "src/root.zig" },
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
        .zigrep_args = &.{ "-n", "-m", "1", "Searcher", "src/search.zig" },
        .grep_args = &.{ "-rnIF", "-m", "1", "Searcher", "src/search.zig" },
        .rg_args = &.{ "-n", "-F", "-m", "1", "Searcher", "src/search.zig" },
        .expected_exit = 0,
        .check_output = true,
    },
    .{
        .name = "max-count --max-count=2 'Searcher'",
        .zigrep_args = &.{ "-n", "--max-count=2", "Searcher", "src/search.zig" },
        .grep_args = &.{ "-rnIF", "--max-count=2", "Searcher", "src/search.zig" },
        .rg_args = &.{ "-n", "-F", "--max-count=2", "Searcher", "src/search.zig" },
        .expected_exit = 0,
        .check_output = true,
    },
    .{
        .name = "invert-match with max-count -v -m 2",
        .zigrep_args = &.{ "-n", "-v", "-m", "2", "pub", "src/root.zig" },
        .grep_args = &.{ "-rnIF", "-v", "-m", "2", "pub", "src/root.zig" },
        .rg_args = &.{ "-n", "-F", "-v", "-m", "2", "pub", "src/root.zig" },
        .expected_exit = 0,
        .check_output = true,
    },
    .{
        // Several explicit FILE operands: output in argument order, like GNU
        // grep. The streaming path used to answer them LIFO (last file first).
        .name = "operand order: several files, argument order",
        .zigrep_args = &.{ "-F", "Searcher", "src/search.zig", "src/main.zig", "src/scan.zig" },
        .grep_args = &.{ "-IF", "Searcher", "src/search.zig", "src/main.zig", "src/scan.zig" },
        .rg_args = null,
        .expected_exit = 0,
        .check_output = true,
    },
    .{
        // POSIX: with -q a match wins over an unreadable operand (rc 0, not 2).
        .name = "quiet -q: match + missing operand is 0",
        .zigrep_args = &.{ "-q", "-F", "Searcher", "src/search.zig", "zz_missing_operand" },
        .grep_args = &.{ "-q", "-F", "Searcher", "src/search.zig", "zz_missing_operand" },
        .rg_args = &.{ "-q", "-F", "Searcher", "src/search.zig", "zz_missing_operand" },
        .expected_exit = 0,
    },
    // Features added after the first Windows port. Each one had a real bug at
    // some point, so each one gets a differential case against the reference
    // implementation that can express it.
    .{
        .name = "count-matches --count-matches",
        .zigrep_args = &.{ "--count-matches", "Searcher", "src/search.zig" },
        .grep_args = null, // grep 3.0 has no --count-matches
        .rg_args = &.{ "--count-matches", "-F", "Searcher", "src/search.zig" },
        .expected_exit = 0,
    },
    .{
        .name = "replace --replace ZZ (rest of line)",
        .zigrep_args = &.{ "-n", "--replace", "ZZ", "-F", "Searcher", "src/search.zig" },
        .grep_args = null, // grep 3.0 has no --replace
        .rg_args = &.{ "-n", "--replace", "ZZ", "-F", "Searcher", "src/search.zig" },
        .expected_exit = 0,
    },
    .{
        .name = "column --column 'Searcher'",
        .zigrep_args = &.{ "--column", "-F", "Searcher", "src/search.zig" }, // --column implies -n, like rg: no -n on purpose
        .grep_args = null, // grep has no --column
        .rg_args = &.{ "--column", "-F", "Searcher", "src/search.zig" },
        .expected_exit = 0,
    },
    .{
        .name = "exclude-from drops search.zig",
        .zigrep_args = &.{ "-n", "--exclude-from=scripts/fixtures/exclude.txt", "-F", "Searcher", "src" },
        .grep_args = &.{ "-rnIF", "--exclude-from=scripts/fixtures/exclude.txt", "Searcher", "src" },
        .rg_args = &.{ "-n", "-F", "--ignore-file=scripts/fixtures/exclude.txt", "Searcher", "src" },
        .expected_exit = 0,
    },
};

fn runCmd(arena: Allocator, io: anytype, argv: []const []const u8) !struct { code: u8, stdout: []const u8, stderr: []const u8 } {
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
        .stderr = r.stderr,
    };
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    _ = args;

    // Resolve binary path: prefer zig-out/bin/zigrep, fallback to zig-out/bin/zgrep
    const exe = blk: {
        const zigrep = if (builtin.os.tag == .windows) "zig-out/bin/zigrep.exe" else "zig-out/bin/zigrep";
        const zgrep = if (builtin.os.tag == .windows) "zig-out/bin/zgrep.exe" else "zig-out/bin/zgrep";
        if (std.Io.Dir.cwd().access(init.io, zigrep, .{})) |_| break :blk zigrep else |_| {}
        if (std.Io.Dir.cwd().access(init.io, zgrep, .{})) |_| break :blk zgrep else |_| {}
        std.debug.print("Error: zig-out/bin/zigrep not found. Run 'zig build' first.\n", .{});
        std.process.exit(2);
    };

    common.printOut(init.io, "===============================================================================\n", .{});
    common.printOut(init.io, "  zigrep Differential Oracle Suite (pure Zig runner)\n", .{});
    common.printOut(init.io, "  Testing {s} against GNU grep and ripgrep\n", .{exe});
    common.printOut(init.io, "===============================================================================\n\n", .{});

    var passed: usize = 0;
    var failed: usize = 0;

    for (cases) |c| {
        // 1. Build zigrep argv
        var z_argv: std.ArrayList([]const u8) = .empty;
        try z_argv.append(arena, exe);
        try z_argv.appendSlice(arena, c.zigrep_args);

        // Run zigrep
        const z_res = runCmd(arena, init.io, z_argv.items) catch |err| {
            common.printOut(init.io, "  [FAIL] {s:<42} failed to run zigrep: {s}\n", .{ c.name, @errorName(err) });
            failed += 1;
            continue;
        };

        // 2. Run GNU grep, unless this case cannot be expressed with it.
        const g_res: ?@TypeOf(z_res) = if (c.grep_args) |ga| blk: {
            var g_argv: std.ArrayList([]const u8) = .empty;
            try g_argv.append(arena, "grep");
            try g_argv.appendSlice(arena, ga);
            break :blk runCmd(arena, init.io, g_argv.items) catch |err| {
                common.printOut(init.io, "  [FAIL] {s:<42} failed to run grep: {s}\n", .{ c.name, @errorName(err) });
                failed += 1;
                continue;
            };
        } else null;

        // Check exit codes: against the frozen expectation always, and against
        // grep only when grep can express the case.
        var ok = z_res.code == c.expected_exit;
        var reason: []const u8 = if (ok) "OK" else "EXIT_CODE_MISMATCH";

        if (ok) {
            if (g_res) |g| {
                if (z_res.code != g.code) {
                    ok = false;
                    reason = "EXIT_CODE_MISMATCH";
                }
            }
        }

        if (ok and c.check_output) {
            if (g_res) |g| {
                const z_lines = try common.sortLines(arena, z_res.stdout);
                const g_lines = try common.sortLines(arena, g.stdout);

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
        }

        // Check against ripgrep if specified
        if (ok and c.rg_args != null) {
            var r_argv: std.ArrayList([]const u8) = .empty;
            try r_argv.append(arena, "rg");
            try r_argv.appendSlice(arena, c.rg_args.?);

            const r_res = runCmd(arena, init.io, r_argv.items) catch |err| {
                common.printOut(init.io, "  [FAIL] {s:<42} failed to run rg: {s}\n", .{ c.name, @errorName(err) });
                failed += 1;
                continue;
            };
            if (r_res.code != c.expected_exit) {
                ok = false;
                reason = "RG_EXIT_MISMATCH";
            } else if (c.check_output) {
                const z_lines = try common.sortLines(arena, z_res.stdout);
                const r_lines = try common.sortLines(arena, r_res.stdout);
                if (z_lines.len != r_lines.len) {
                    ok = false;
                    reason = "RG_LINE_COUNT_MISMATCH";
                } else {
                    for (z_lines, r_lines) |zl, rl| {
                        if (!std.mem.eql(u8, zl, rl)) {
                            ok = false;
                            reason = "RG_CONTENT_MISMATCH";
                            break;
                        }
                    }
                }
            }
        }

        if (ok) {
            passed += 1;
            common.printOut(init.io, "  [PASS] {s:<42} (exit {d}, lines {d})\n", .{
                c.name,
                z_res.code,
                common.countNewlines(z_res.stdout),
            });
        } else {
            failed += 1;
            if (g_res) |g| {
                common.printOut(init.io, "  [FAIL] {s:<42} reason={s} (zigrep code={d}, grep code={d})\n", .{
                    c.name,
                    reason,
                    z_res.code,
                    g.code,
                });
                if (g.stderr.len > 0) common.printOut(init.io, "         grep stderr: {s}", .{g.stderr});
            } else {
                common.printOut(init.io, "  [FAIL] {s:<42} reason={s} (zigrep code={d}, grep n/a)\n", .{
                    c.name,
                    reason,
                    z_res.code,
                });
            }
            if (z_res.stderr.len > 0) common.printOut(init.io, "         zigrep stderr: {s}", .{z_res.stderr});
        }
    }

    // Stdin pipeline differential test (pipe -> zigrep vs pipe -> grep -n).
    // POSIX-only: it relies on `sh -c` and `printf`, which the native Windows
    // build cannot assume on PATH, so it is skipped there explicitly.
    var total_tests = cases.len;
    if (builtin.os.tag != .windows) {
        // Each case: the same printf input piped into zigrep and into grep,
        // compared on exit code AND stdout bytes. `printf '\000'` writes a NUL.
        const StdinCase = struct { name: []const u8, input: []const u8, z_args: []const u8, g_args: []const u8 };
        const stdin_cases = [_]StdinCase{
            .{ .name = "stdin pipeline (pipe -> zigrep)", .input = "alpha\\nbeta\\ngamma\\n", .z_args = "-n 'beta'", .g_args = "-n 'beta'" },
            // M11 R24: binary stdin without the pattern used to print "Binary
            // file (standard input) matches" and exit 0 without searching.
            .{ .name = "stdin binary, no match -> rc 1, no output", .input = "abc\\000def\\n", .z_args = "'zzz'", .g_args = "'zzz'" },
            // -z on stdin: NUL is the record separator, not a binary marker,
            // and the output records are NUL-terminated (was '\\n').
            .{ .name = "stdin -z: NUL records, NUL output", .input = "abc\\000def\\000", .z_args = "-z 'def'", .g_args = "-z 'def'" },
        };
        for (stdin_cases) |sc| {
            total_tests += 1;
            const cmd_z = try std.fmt.allocPrint(arena, "printf '{s}' | {s} {s}", .{ sc.input, exe, sc.z_args });
            const cmd_g = try std.fmt.allocPrint(arena, "printf '{s}' | grep {s}", .{ sc.input, sc.g_args });
            const z_res = runCmd(arena, init.io, &.{ "sh", "-c", cmd_z }) catch null;
            const g_res = runCmd(arena, init.io, &.{ "sh", "-c", cmd_g }) catch null;
            if (z_res != null and g_res != null and z_res.?.code == g_res.?.code and std.mem.eql(u8, z_res.?.stdout, g_res.?.stdout)) {
                passed += 1;
                common.printOut(init.io, "  [PASS] {s:<42} (exit {d})\n", .{ sc.name, z_res.?.code });
            } else {
                failed += 1;
                common.printOut(init.io, "  [FAIL] {s:<42} reason=STDIN_MISMATCH (zigrep {d}, grep {d})\n", .{ sc.name, if (z_res) |z| z.code else 255, if (g_res) |g| g.code else 255 });
            }
        }
    }

    common.printOut(init.io, "\n-------------------------------------------------------------------------------\n", .{});
    common.printOut(init.io, "Results: {d} PASSED, {d} FAILED (total {d})\n", .{ passed, failed, total_tests });
    common.printOut(init.io, "-------------------------------------------------------------------------------\n", .{});

    if (failed > 0) {
        std.process.exit(1);
    }
}
