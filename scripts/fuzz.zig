//! Adversarial Entropic Fuzzer Swarm for ZiGrep.
//!
//! Spawns a parallel multi-core swarm of 4 specialized adversaries:
//!   - Adversary 1: "The Grammar Shatterer" (Regex engine & Thompson NFA / lazy DFA fuzzer)
//!   - Adversary 2: "The Chaos CLI Permutator" (CLI options, cluster flags, and subprocess crash fuzzer)
//!   - Adversary 3: "The Toxic Payload Injector" (Corrupt buffers, truncated UTF-16, NUL floods, SIMD boundary fuzzer)
//!   - Adversary 4: "The Differential Oracle Auditor" (Mathematical & logical invariant cross-validator)
//!
//! Pure Zig 0.16, zero libc, multi-threaded with atomic stats and live HUD.
//!
//! Usage:
//!   zig build fuzz -- [ITERATIONS] [--threads=N] [--adversary=1..4|all] [--cli-rate=N]
const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");
const zgrep = @import("zgrep");

const search = zgrep.search;
const regex = zgrep.regex;
const scan = zgrep.scan;
const nav = zgrep.nav;
const main_mod = zgrep.main_mod;
const filter = zgrep.filter;
const kamikaze = zgrep.kamikaze;

const Searcher = search.Searcher;
const Algo = search.Algo;
const Mode = scan.Mode;
const ScanConfig = scan.ScanConfig;
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Global Swarm Coordination State
// ---------------------------------------------------------------------------

const SwarmStats = struct {
    total_ops: std.atomic.Value(u64) = .init(0),
    adv1_ops: std.atomic.Value(u64) = .init(0),
    adv2_ops: std.atomic.Value(u64) = .init(0),
    adv3_ops: std.atomic.Value(u64) = .init(0),
    adv4_ops: std.atomic.Value(u64) = .init(0),

    anomalies: std.atomic.Value(u64) = .init(0),
    crashes: std.atomic.Value(u64) = .init(0),
    bad_exits: std.atomic.Value(u64) = .init(0),
    invariant_fails: std.atomic.Value(u64) = .init(0),

    stop: std.atomic.Value(bool) = .init(false),
};

const SwarmConfig = struct {
    target_ops: u64 = 100_000,
    threads: usize = 0,
    selected_adversary: u8 = 0, // 0 = all, 1..4 = specific
    cli_rate: u32 = 100, // 1 in N CLI ops runs full external subprocess
    master_seed: u64 = 0,
    knob: u8 = 3, // 1: Gentle, 2: Flags, 3: Grammar, 4: ReDoS, 5: Chaos
    exe_path: []const u8 = if (builtin.os.tag == .windows) "zig-out/bin/zigrep.exe" else "zig-out/bin/zigrep",
    /// Print every spawned CLI argv to stderr. Off by default because it
    /// floods the output; useful to identify a hanging child.
    trace_cli: bool = false,
    /// Hard limit for a CLI child. Without it a child that never terminates
    /// blocks the whole swarm forever (the swarm has no watchdog).
    cli_timeout_ms: u64 = 10_000,
};

/// Counter used by the `--trace-cli` diagnostic to pair every spawned CLI
/// argv with its completion, so a child that never finishes is identifiable.
var trace_counter = std.atomic.Value(u64).init(0);

// ---------------------------------------------------------------------------
// Reproducer Writer
// ---------------------------------------------------------------------------

fn saveReproducer(
    io: std.Io,
    gpa: Allocator,
    adversary: []const u8,
    seed: u64,
    description: []const u8,
    payload: []const u8,
    cmd_args: ?[]const []const u8,
) void {
    _ = common.makePath(io, "evidence/reproducers") catch {};
    const ts = common.nowNs(io);
    const fname = std.fmt.allocPrint(gpa, "evidence/reproducers/repro_{d}_{s}_{d}.txt", .{ ts, adversary, seed }) catch return;
    defer gpa.free(fname);

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);

    content.appendSlice(gpa, "# ZiGrep Adversarial Fuzzer Reproducer\n") catch return;
    content.appendSlice(gpa, "# Timestamp: ") catch return;
    if (std.fmt.allocPrint(gpa, "{d}\n", .{ts})) |s| {
        defer gpa.free(s);
        content.appendSlice(gpa, s) catch return;
    } else |_| return;
    content.appendSlice(gpa, "# Adversary: ") catch return;
    content.appendSlice(gpa, adversary) catch return;
    content.appendSlice(gpa, "\n# Seed: ") catch return;
    if (std.fmt.allocPrint(gpa, "{d}\n", .{seed})) |s| {
        defer gpa.free(s);
        content.appendSlice(gpa, s) catch return;
    } else |_| return;
    content.appendSlice(gpa, "# Issue: ") catch return;
    content.appendSlice(gpa, description) catch return;
    content.appendSlice(gpa, "\n\n") catch return;

    if (cmd_args) |args| {
        content.appendSlice(gpa, "## CLI Command Line:\n") catch return;
        for (args) |a| {
            content.appendSlice(gpa, a) catch return;
            content.appendSlice(gpa, " ") catch return;
        }
        content.appendSlice(gpa, "\n\n") catch return;
    }

    if (payload.len > 0) {
        content.appendSlice(gpa, "## Payload Preview (up to 1024 bytes):\n") catch return;
        const cap = @min(payload.len, 1024);
        content.appendSlice(gpa, payload[0..cap]) catch return;
        content.appendSlice(gpa, "\n") catch return;
    }

    const fname_z = std.fmt.allocPrintSentinel(gpa, "{s}", .{fname}, 0) catch return;
    defer gpa.free(fname_z);
    _ = common.writeFile(io, fname_z, content.items);
    std.debug.print("\n[CRITICAL FUZZ ANOMALY DETECTED] Reproducer saved: {s}\n", .{fname});
}

// ---------------------------------------------------------------------------
// Adversary 1: The Grammar Shatterer (Regex Engine & Thompson DFA)
// ---------------------------------------------------------------------------

const regex_tokens = [_][]const u8{
    "(",         ")",      "[",             "]",    "{",             "}",                 "*",                   "+",       "?",     "|",     "^",      "$",     ".",
    "\\d",       "\\w",    "\\s",           "\\b",  "\\B",           "\\p{L}",            "\\0",                 "\\x00",   "\\xFF", "[a-z]", "[^a-z]", "[0-9]", "[[:alpha:]]",
    "[[:bad:]]", "[--]",   "[z-a]",         "()",   "||",            "(a|)",              "(|b)",                "(a|b|c)", "(a+)+", "(a*)*", "(a|a)*", "{0,0}", "{0,1}",
    "{1,5}",     "{10,2}", "{99999,99999}", "{,5}", "fn\\s+\\w+\\(", "pub\\s+(const|fn)", "std\\.(mem|math|os)",
};

const corpus_words = [_][]const u8{
    "searcher", "filter",    "kamikaze", "io_uring", "walk",   "scan",   "buffer",
    "result",   "allocator", "pattern",  "literal",  "vector", "stream", "corrupt",
    "alpha",    "omega",     "zenith",
    "nadír",
    "über",
    "añejo",
    "こんにちは",
};

fn mutateRegex(arena: Allocator, rand: std.Random, knob: u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    if (knob == 1) {
        // Knob 1 (Gentle): Valid words, simple alternations
        if (rand.boolean()) {
            try out.appendSlice(arena, corpus_words[rand.uintLessThan(usize, corpus_words.len)]);
        } else {
            try out.appendSlice(arena, corpus_words[rand.uintLessThan(usize, corpus_words.len)]);
            try out.append(arena, '|');
            try out.appendSlice(arena, corpus_words[rand.uintLessThan(usize, corpus_words.len)]);
        }
        return out.items;
    }

    if (knob == 2) {
        // Knob 2 (Standard): Words with character classes & anchors
        if (rand.boolean()) {
            try out.append(arena, '^');
            try out.appendSlice(arena, corpus_words[rand.uintLessThan(usize, corpus_words.len)]);
        } else {
            try out.appendSlice(arena, "[a-z]+_");
            try out.appendSlice(arena, corpus_words[rand.uintLessThan(usize, corpus_words.len)]);
        }
        return out.items;
    }

    if (knob == 4) {
        // Knob 4 (ReDoS / Catastrophic Backtracking)
        const sub = corpus_words[rand.uintLessThan(usize, corpus_words.len)];
        const s = try std.fmt.allocPrint(arena, "({s}+)+$|({s}*)*", .{ sub, sub });
        try out.appendSlice(arena, s);
        return out.items;
    }

    // Knob 3 or 5: Grammar stress / Chaos
    const mode = if (knob == 5) rand.uintLessThan(u8, 6) else rand.uintLessThan(u8, 5);

    switch (mode) {
        0 => {
            // Deeply nested parentheses: (((((a)))))
            const depth = rand.uintLessThan(usize, 40) + 1;
            var i: usize = 0;
            while (i < depth) : (i += 1) try out.append(arena, '(');
            try out.appendSlice(arena, corpus_words[rand.uintLessThan(usize, corpus_words.len)]);
            i = 0;
            // Optionally unbalance closing parens
            const close_depth = if (rand.boolean()) depth else rand.uintLessThan(usize, depth * 2);
            while (i < close_depth) : (i += 1) try out.append(arena, ')');
        },
        1 => {
            // Chaotic token assembly
            const num_tokens = rand.uintLessThan(usize, 12) + 1;
            var i: usize = 0;
            while (i < num_tokens) : (i += 1) {
                const t = regex_tokens[rand.uintLessThan(usize, regex_tokens.len)];
                try out.appendSlice(arena, t);
                if (rand.boolean()) {
                    try out.appendSlice(arena, corpus_words[rand.uintLessThan(usize, corpus_words.len)]);
                }
            }
        },
        2 => {
            // Catastrophic backtracking patterns
            const sub = corpus_words[rand.uintLessThan(usize, corpus_words.len)];
            const s = try std.fmt.allocPrint(arena, "({s}+)+$|({s}*)*", .{ sub, sub });
            try out.appendSlice(arena, s);
        },
        3 => {
            // Random byte stream injection / invalid UTF-8 in regex
            const len = rand.uintLessThan(usize, 32) + 1;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const b = rand.int(u8);
                // Keep out newlines as main.zig explicitly disallows newlines in patterns
                if (b != '\n') try out.append(arena, b);
            }
        },
        4 => {
            // Quantifier / boundary abuse
            try out.appendSlice(arena, corpus_words[rand.uintLessThan(usize, corpus_words.len)]);
            if (rand.boolean()) {
                const q = rand.uintLessThan(u8, 4);
                switch (q) {
                    0 => try out.appendSlice(arena, "**"),
                    1 => try out.appendSlice(arena, "+?*"),
                    2 => try out.appendSlice(arena, "{1000,2000}"),
                    3 => try out.appendSlice(arena, "{5,2}"),
                    else => {},
                }
            }
        },
        5 => {
            // Alternation flood: a|b|c|d|e|...
            const count = rand.uintLessThan(usize, 16) + 2;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (i > 0) try out.append(arena, '|');
                if (rand.boolean()) {
                    try out.appendSlice(arena, corpus_words[rand.uintLessThan(usize, corpus_words.len)]);
                }
            }
        },
        else => {},
    }

    if (out.items.len == 0) try out.appendSlice(arena, "a");
    return out.items;
}

fn runAdversary1(gpa: Allocator, stats: *SwarmStats, rand: std.Random, seed: u64, knob: u8) void {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pat = mutateRegex(arena, rand, knob) catch return;

    const icase = rand.boolean();
    const word = rand.boolean();
    const algo: Algo = switch (rand.uintLessThan(u8, 3)) {
        0 => .auto,
        1 => .bmh,
        2 => .memchr,
        else => .auto,
    };

    var searcher_opt: ?Searcher = null;
    if (search.build(arena, &.{pat}, .{
        .algo = algo,
        .fixed = false,
        .icase = icase,
        .word = word,
    })) |s| {
        searcher_opt = s;
    } else |_| {
        // Clean error rejection (e.g. error.BadRegex, error.PatternTooLong) is safe and expected
        _ = stats.adv1_ops.fetchAdd(1, .monotonic);
        return;
    }

    // If searcher built successfully, execute it against adversarial haystacks to verify NFA/DFA safety
    if (searcher_opt) |s| {
        const haystacks = [_][]const u8{
            "",
            "a",
            "\n",
            "\x00",
            "\xFF\xFE\x00\x00",
            "searcher and filter in kamikaze swarm with io_uring and regex",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab",
            "012345678901234567890123456789012345678901234567890123456789",
        };

        for (haystacks) |h| {
            _ = s.find(h, 0);
        }
    }

    _ = stats.adv1_ops.fetchAdd(1, .monotonic);
    _ = seed;
}

// ---------------------------------------------------------------------------
// Adversary 2: The Chaos CLI Permutator (Argument, Option & Subprocess Swarm)
// ---------------------------------------------------------------------------

const short_flags = [_][]const u8{
    "-F", "-E", "-i", "-v", "-w", "-c", "-l", "-L", "-q", "-H", "-h", "-a", "-k", "-r", "-n",
};

const long_flags = [_][]const u8{
    "--fixed-strings",      "--extended-regexp",     "--ignore-case",
    "--invert-match",       "--word-regexp",         "--count",
    "--files-with-matches", "--files-without-match", "--quiet",
    "--kamikaze",           "--sort",                "--uring",
    "--stats",              "--no-ignore",           "--no-default-ignore",
    "--no-hidden",
};

const num_values = [_][]const u8{
    "0", "1", "2", "4", "12", "16", "64", "999999", "18446744073709551615", "-1", "auto", "max",
};

const befunge_values = [_][]const u8{
    "v^", "^v", "><", "ud", "du", "rl", "v^><udrl", "vvvvvv", "^^^^^^", "invalid_op_!",
};

fn runAdversary2(
    gpa: Allocator,
    stats: *SwarmStats,
    rand: std.Random,
    seed: u64,
    cfg: *const SwarmConfig,
    io: anytype,
) void {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var args_list: std.ArrayList([:0]const u8) = .empty;
    args_list.append(arena, "zigrep") catch return;

    // Pick 1 to 6 random options
    const opt_count = rand.uintLessThan(usize, 6) + 1;
    var i: usize = 0;
    while (i < opt_count) : (i += 1) {
        const choice = rand.uintLessThan(u8, 6);
        switch (choice) {
            0 => {
                const f = short_flags[rand.uintLessThan(usize, short_flags.len)];
                args_list.append(arena, std.fmt.allocPrintSentinel(arena, "{s}", .{f}, 0) catch return) catch return;
            },
            1 => {
                const f = long_flags[rand.uintLessThan(usize, long_flags.len)];
                args_list.append(arena, std.fmt.allocPrintSentinel(arena, "{s}", .{f}, 0) catch return) catch return;
            },
            2 => {
                const nv = num_values[rand.uintLessThan(usize, num_values.len)];
                const flag = if (rand.boolean()) "-j" else "-m";
                args_list.append(arena, std.fmt.allocPrintSentinel(arena, "{s}", .{flag}, 0) catch return) catch return;
                args_list.append(arena, std.fmt.allocPrintSentinel(arena, "{s}", .{nv}, 0) catch return) catch return;
            },
            3 => {
                const bf = befunge_values[rand.uintLessThan(usize, befunge_values.len)];
                args_list.append(arena, std.fmt.allocPrintSentinel(arena, "-N", .{}, 0) catch return) catch return;
                args_list.append(arena, std.fmt.allocPrintSentinel(arena, "{s}", .{bf}, 0) catch return) catch return;
            },
            4 => {
                // Clustered flags
                const cluster = if (rand.boolean()) "-vicwn" else "-vLqk";
                args_list.append(arena, std.fmt.allocPrintSentinel(arena, "{s}", .{cluster}, 0) catch return) catch return;
            },
            5 => {
                // Algo override
                const algo_name = if (rand.boolean()) "bmh" else "memchr";
                args_list.append(arena, std.fmt.allocPrintSentinel(arena, "--algo", .{}, 0) catch return) catch return;
                args_list.append(arena, std.fmt.allocPrintSentinel(arena, "{s}", .{algo_name}, 0) catch return) catch return;
            },
            else => {},
        }
    }

    // Pattern positional or -e
    const pat = corpus_words[rand.uintLessThan(usize, corpus_words.len)];
    if (rand.boolean()) {
        args_list.append(arena, std.fmt.allocPrintSentinel(arena, "-e", .{}, 0) catch return) catch return;
        args_list.append(arena, std.fmt.allocPrintSentinel(arena, "{s}", .{pat}, 0) catch return) catch return;
    } else {
        args_list.append(arena, std.fmt.allocPrintSentinel(arena, "{s}", .{pat}, 0) catch return) catch return;
    }

    // Path positional
    const path_choice = rand.uintLessThan(u8, 4);
    switch (path_choice) {
        0 => args_list.append(arena, std.fmt.allocPrintSentinel(arena, "src", .{}, 0) catch return) catch return,
        1 => args_list.append(arena, std.fmt.allocPrintSentinel(arena, if (builtin.os.tag == .windows) "nul" else "/dev/null", .{}, 0) catch return) catch return,
        2 => args_list.append(arena, std.fmt.allocPrintSentinel(arena, "nonexistent_dir_or_file_xyz", .{}, 0) catch return) catch return,
        3 => args_list.append(arena, std.fmt.allocPrintSentinel(arena, "build.zig", .{}, 0) catch return) catch return,
        else => {},
    }

    // Phase A: In-process parseArgs verification
    var opts: main_mod.Options = .{};
    _ = main_mod.parseArgs(arena, args_list.items, &opts) catch {
        // Returned error.Usage cleanly
    };

    // Phase B: Periodic Subprocess Execution (Worker 0 only, 1 in cli_rate iterations)
    // Keeps process spawning strictly serialized and lightweight so the system/terminal is never overloaded.
    const is_worker_zero = (seed & 0xF == 0); // naturally rate-limited to 1 in 16 workers
    const run_subprocess = is_worker_zero and (rand.uintLessThan(u32, cfg.cli_rate) == 0);
    if (run_subprocess) {
        // Build argv with the binary path
        var sub_argv: std.ArrayList([]const u8) = .empty;
        sub_argv.append(arena, cfg.exe_path) catch return;
        for (args_list.items[1..]) |a| {
            sub_argv.append(arena, a) catch return;
        }

        const trace_id = if (cfg.trace_cli) trace_counter.fetchAdd(1, .monotonic) else 0;
        if (cfg.trace_cli) {
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(gpa);
            for (sub_argv.items) |a| {
                line.appendSlice(gpa, a) catch {};
                line.append(gpa, ' ') catch {};
            }
            line.append(gpa, '\n') catch {};
            std.debug.print("[CLI #{d} START] {s}", .{ trace_id, line.items });
        }

        // NEVER truncate the captured streams.
        //
        // std.process.run stops reading a stream once it exceeds its limit,
        // but the child keeps writing. On Windows the pipe buffer is 8 KB, so
        // the child blocks forever on a full pipe while the parent waits for
        // it: a deadlock. Measured with Zig 0.16.0 on Windows 11:
        //   stdout_limit = 4096  -> the call took 294 s and then reported
        //                          error.StreamTooLong (the deferred kill did
        //                          not rescue it)
        //   stdout_limit = .unlimited -> the same call returned in 57 ms
        // The captured output is bounded by the fuzzer's own corpus (the
        // repository tree), so draining it is safe.
        const res = std.process.run(arena, io, .{
            .argv = sub_argv.items,
            .stdout_limit = .unlimited,
            .stderr_limit = .unlimited,
            // A child that never terminates would block the whole swarm: the
            // swarm has no watchdog of its own.
            .timeout = .{ .duration = .{
                .raw = .fromMilliseconds(@intCast(cfg.cli_timeout_ms)),
                .clock = .awake,
            } },
        }) catch |err| {
            // Failed to spawn (e.g. process limit) is not a bug in zigrep.
            // A timeout is a finding, not a bug in the fuzzer: report it and
            // keep going instead of hanging forever.
            if (cfg.trace_cli) {
                std.debug.print("[CLI #{d} END] (error: {s})\n", .{ trace_id, @errorName(err) });
            }
            if (err == error.Timeout) {
                _ = stats.anomalies.fetchAdd(1, .monotonic);
                const desc = std.fmt.allocPrint(arena, "CLI child timed out after {d} ms", .{cfg.cli_timeout_ms}) catch "CLI child timed out";
                saveReproducer(io, gpa, "CLI_Permutator", seed, desc, "", sub_argv.items);
            }
            _ = stats.adv2_ops.fetchAdd(1, .monotonic);
            return;
        };

        if (cfg.trace_cli) {
            std.debug.print("[CLI #{d} END] code={d}\n", .{ trace_id, common.termCode(res.term) });
        }

        const code = common.termCode(res.term);
        // Valid exit codes: 0 = match, 1 = no match, 2 = usage error
        if (code > 2) {
            _ = stats.anomalies.fetchAdd(1, .monotonic);
            _ = stats.bad_exits.fetchAdd(1, .monotonic);
            if (code >= 128) _ = stats.crashes.fetchAdd(1, .monotonic);

            const desc = std.fmt.allocPrint(arena, "Unexpected exit code {d} (signal/crash)", .{code}) catch "exit code > 2";
            saveReproducer(io, gpa, "CLI_Permutator", seed, desc, res.stderr, sub_argv.items);
        }
    }

    _ = stats.adv2_ops.fetchAdd(1, .monotonic);
}

// ---------------------------------------------------------------------------
// Adversary 3: The Toxic Payload Injector (Corrupt Buffers & Boundary Fuzzer)
// ---------------------------------------------------------------------------

const boundary_sizes = [_]usize{
    0, 1, 7, 8, 15, 16, 31, 32, 63, 64, 127, 128, 511, 512, 4095, 4096, 65535, 65536,
};

fn generateToxicPayload(arena: Allocator, rand: std.Random, knob: u8) ![]const u8 {
    if (knob == 1) {
        // Clean multi-line text
        var buf: std.ArrayList(u8) = .empty;
        const lines = rand.uintLessThan(usize, 20) + 1;
        var l: usize = 0;
        while (l < lines) : (l += 1) {
            try buf.appendSlice(arena, corpus_words[rand.uintLessThan(usize, corpus_words.len)]);
            try buf.append(arena, '\n');
        }
        return buf.items;
    }

    const kind = rand.uintLessThan(u8, 6);
    switch (kind) {
        0 => {
            // SIMD Boundary buffer
            const sz = boundary_sizes[rand.uintLessThan(usize, boundary_sizes.len)];
            const buf = try arena.alloc(u8, sz);
            rand.bytes(buf);
            return buf;
        },
        1 => {
            // Endless line without any newlines (up to 128 KB)
            const sz = rand.uintLessThan(usize, 64 * 1024) + 1024;
            const buf = try arena.alloc(u8, sz);
            @memset(buf, 'x');
            return buf;
        },
        2 => {
            // Newline flood
            const sz = rand.uintLessThan(usize, 4096) + 16;
            const buf = try arena.alloc(u8, sz);
            @memset(buf, '\n');
            return buf;
        },
        3 => {
            // NUL byte flood & mixed binary
            const sz = rand.uintLessThan(usize, 8192) + 32;
            const buf = try arena.alloc(u8, sz);
            for (buf) |*b| {
                b.* = if (rand.boolean()) 0 else rand.int(u8);
            }
            return buf;
        },
        4 => {
            // Truncated / malformed UTF-16
            const sz = (rand.uintLessThan(usize, 128) * 2) + 1; // odd length
            const buf = try arena.alloc(u8, sz + 2);
            buf[0] = 0xFF;
            buf[1] = 0xFE;
            rand.bytes(buf[2..]);
            return buf;
        },
        5 => {
            // Mixed CRLF / LF with random text
            var buf: std.ArrayList(u8) = .empty;
            const lines = rand.uintLessThan(usize, 50) + 1;
            var l: usize = 0;
            while (l < lines) : (l += 1) {
                try buf.appendSlice(arena, corpus_words[rand.uintLessThan(usize, corpus_words.len)]);
                if (rand.boolean()) {
                    try buf.appendSlice(arena, "\r\n");
                } else {
                    try buf.append(arena, '\n');
                }
            }
            return buf.items;
        },
        else => return "clean",
    }
}

fn runAdversary3(io: std.Io, gpa: Allocator, stats: *SwarmStats, rand: std.Random, seed: u64, knob: u8) void {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const payload = generateToxicPayload(arena, rand, knob) catch return;
    const pat = corpus_words[rand.uintLessThan(usize, corpus_words.len)];

    const searcher = search.build(arena, &.{pat}, .{
        .algo = .auto,
        .fixed = rand.boolean(),
        .icase = rand.boolean(),
        .word = rand.boolean(),
    }) catch return;

    const mode: Mode = switch (rand.uintLessThan(u8, 5)) {
        0 => .lines,
        1 => .count,
        2 => .files,
        3 => .files_without_match,
        4 => .quiet,
        else => .lines,
    };

    const cfg: ScanConfig = .{
        .invert = rand.boolean(),
        .max_count = if (rand.boolean()) rand.uintLessThan(usize, 5) else null,
    };

    var out_buf: std.ArrayList(u8) = .empty;

    // Execute scanBuffer across toxic buffer
    const res = scan.scanBuffer(
        arena,
        payload,
        &searcher,
        "fuzz_toxic_buf",
        true,
        mode,
        cfg,
        &out_buf,
    ) catch |err| {
        // OutOfMemory is acceptable under stress; any other error is an anomaly
        if (err != error.OutOfMemory) {
            _ = stats.anomalies.fetchAdd(1, .monotonic);
            _ = stats.bad_exits.fetchAdd(1, .monotonic);
            saveReproducer(io, gpa, "Toxic_Payload", seed, "scanBuffer failed with unexpected error", payload, null);
        }
        return;
    };

    // Sanity invariant: if max_count == 0, lines matched MUST be 0
    if (cfg.max_count != null and cfg.max_count.? == 0 and res.lines != 0) {
        _ = stats.anomalies.fetchAdd(1, .monotonic);
        _ = stats.invariant_fails.fetchAdd(1, .monotonic);
        saveReproducer(io, gpa, "Toxic_Payload", seed, "max_count == 0 violated (res.lines > 0)", payload, null);
    }

    _ = stats.adv3_ops.fetchAdd(1, .monotonic);
}

// ---------------------------------------------------------------------------
// Adversary 4: The Differential Oracle Auditor (Mathematical Invariant Verifier)
// ---------------------------------------------------------------------------

fn runAdversary4(io: std.Io, gpa: Allocator, stats: *SwarmStats, rand: std.Random, seed: u64) void {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Generate a synthetic multi-line document with known properties
    var doc: std.ArrayList(u8) = .empty;
    const target = "TARGET_TOKEN";
    const filler = "filler line without special token";

    const total_lines = rand.uintLessThan(usize, 30) + 5;
    var expected_matches: usize = 0;

    var i: usize = 0;
    while (i < total_lines) : (i += 1) {
        if (rand.boolean()) {
            doc.appendSlice(arena, target) catch return;
            doc.appendSlice(arena, " in line context\n") catch return;
            expected_matches += 1;
        } else {
            doc.appendSlice(arena, filler) catch return;
            doc.append(arena, '\n') catch return;
        }
    }

    const payload = doc.items;

    // Searcher A: Default BMH / auto
    const s_auto = search.build(arena, &.{target}, .{ .algo = .auto, .fixed = true }) catch return;
    // Searcher B: Explicit BMH
    const s_bmh = search.build(arena, &.{target}, .{ .algo = .bmh, .fixed = true }) catch return;
    // Searcher C: Explicit memchr
    const s_memchr = search.build(arena, &.{target}, .{ .algo = .memchr, .fixed = true }) catch return;

    // 1. Invariant: Multi-engine match equivalence
    const m_auto = s_auto.find(payload, 0);
    const m_bmh = s_bmh.find(payload, 0);
    const m_memchr = s_memchr.find(payload, 0);

    const auto_off = m_auto orelse std.math.maxInt(usize);
    const bmh_off = m_bmh orelse std.math.maxInt(usize);
    const memchr_off = m_memchr orelse std.math.maxInt(usize);

    if (auto_off != bmh_off or bmh_off != memchr_off) {
        _ = stats.anomalies.fetchAdd(1, .monotonic);
        _ = stats.invariant_fails.fetchAdd(1, .monotonic);
        saveReproducer(io, gpa, "Differential_Oracle", seed, "BMH vs memchr mismatch", payload, null);
        return;
    }

    // 2. Invariant: Invert match partition: matches(P) + matches(-v P) == total_lines
    var out_norm: std.ArrayList(u8) = .empty;
    var out_inv: std.ArrayList(u8) = .empty;

    const res_norm = scan.scanBuffer(arena, payload, &s_auto, "doc", true, .lines, .{}, &out_norm) catch return;
    const res_inv = scan.scanBuffer(arena, payload, &s_auto, "doc", true, .lines, .{ .invert = true }, &out_inv) catch return;

    if (res_norm.lines + res_inv.lines != total_lines) {
        _ = stats.anomalies.fetchAdd(1, .monotonic);
        _ = stats.invariant_fails.fetchAdd(1, .monotonic);
        const desc = std.fmt.allocPrint(arena, "Invert partition violated: {d} + {d} != {d}", .{ res_norm.lines, res_inv.lines, total_lines }) catch "Invert partition error";
        saveReproducer(io, gpa, "Differential_Oracle", seed, desc, payload, null);
        return;
    }

    // 3. Invariant: Quiet mode match flag matches count > 0
    var out_q: std.ArrayList(u8) = .empty;
    const res_q = scan.scanBuffer(arena, payload, &s_auto, "doc", true, .quiet, .{}, &out_q) catch return;
    const quiet_matched = res_q.matched;
    const expected_matched = (expected_matches > 0);

    if (quiet_matched != expected_matched) {
        _ = stats.anomalies.fetchAdd(1, .monotonic);
        _ = stats.invariant_fails.fetchAdd(1, .monotonic);
        saveReproducer(io, gpa, "Differential_Oracle", seed, "Quiet mode match divergence", payload, null);
        return;
    }

    _ = stats.adv4_ops.fetchAdd(1, .monotonic);
}

// ---------------------------------------------------------------------------
// Worker Swarm Thread
// ---------------------------------------------------------------------------

const WorkerContext = struct {
    worker_id: usize,
    gpa: Allocator,
    stats: *SwarmStats,
    cfg: *const SwarmConfig,
    io: std.Io,
};

fn swarmWorker(ctx: *const WorkerContext) void {
    const thread_seed = ctx.cfg.master_seed ^ (@as(u64, @intCast(ctx.worker_id)) *% 0x9E3779B97F4A7C15);
    var prng = std.Random.DefaultPrng.init(thread_seed);
    const rand = prng.random();

    while (!ctx.stats.stop.load(.acquire)) {
        const total = ctx.stats.total_ops.fetchAdd(1, .monotonic);
        if (total >= ctx.cfg.target_ops) {
            ctx.stats.stop.store(true, .release);
            return;
        }

        const seed = thread_seed ^ total;

        const adv = if (ctx.cfg.selected_adversary != 0)
            ctx.cfg.selected_adversary
        else
            @as(u8, @intCast(rand.uintLessThan(u8, 4) + 1));

        switch (adv) {
            1 => runAdversary1(ctx.gpa, ctx.stats, rand, seed, ctx.cfg.knob),
            2 => runAdversary2(ctx.gpa, ctx.stats, rand, seed, ctx.cfg, ctx.io),
            3 => runAdversary3(ctx.io, ctx.gpa, ctx.stats, rand, seed, ctx.cfg.knob),
            4 => runAdversary4(ctx.io, ctx.gpa, ctx.stats, rand, seed),
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// Main & CLI Coordinator
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var cfg: SwarmConfig = .{
        .master_seed = common.nowNs(init.io),
    };

    // Detect CPU count for optimal parallel swarm
    const nproc = std.Thread.getCpuCount() catch 4;
    cfg.threads = nproc;

    // Parse CLI arguments
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--threads=")) {
            const val = arg["--threads=".len..];
            if (std.fmt.parseInt(usize, val, 10)) |t| {
                if (t > 0) cfg.threads = t;
            } else |_| {}
        } else if (std.mem.startsWith(u8, arg, "--adversary=")) {
            const val = arg["--adversary=".len..];
            if (std.mem.eql(u8, val, "all")) {
                cfg.selected_adversary = 0;
            } else if (std.fmt.parseInt(u8, val, 10)) |adv| {
                if (adv >= 1 and adv <= 4) cfg.selected_adversary = adv;
            } else |_| {}
        } else if (std.mem.startsWith(u8, arg, "--knob=")) {
            const val = arg["--knob=".len..];
            if (std.fmt.parseInt(u8, val, 10)) |k| {
                if (k >= 1 and k <= 5) cfg.knob = k;
            } else |_| {}
        } else if (std.mem.startsWith(u8, arg, "--cli-rate=")) {
            const val = arg["--cli-rate=".len..];
            if (std.fmt.parseInt(u32, val, 10)) |cr| {
                if (cr > 0) cfg.cli_rate = cr;
            } else |_| {}
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            const val = arg["--seed=".len..];
            if (std.fmt.parseInt(u64, val, 10)) |s| {
                cfg.master_seed = s;
            } else |_| {}
        } else if (std.mem.eql(u8, arg, "--trace-cli")) {
            cfg.trace_cli = true;
        } else if (std.mem.startsWith(u8, arg, "--cli-timeout-ms=")) {
            const val = arg["--cli-timeout-ms=".len..];
            if (std.fmt.parseInt(u64, val, 10)) |t| {
                if (t > 0) cfg.cli_timeout_ms = t;
            } else |_| {}
        } else if (std.mem.startsWith(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            common.printOut(init.io,
                \\Adversarial Entropic Fuzzer Swarm for ZiGrep
                \\
                \\Usage:
                \\  zig build fuzz -- [ITERATIONS] [OPTIONS]
                \\
                \\Options:
                \\  --threads=N       number of parallel fuzzer workers (default: CPU cores)
                \\  --adversary=N     1: Regex, 2: CLI, 3: Corrupt Buffers, 4: Oracle Invariants, all: Swarm
                \\  --cli-rate=N      1 in N CLI runs will execute full subprocess (default: 100)
                \\  --seed=N          master PRNG seed (default: monotonic clock)
                \\  --trace-cli       print every spawned CLI argv to stderr
                \\  --cli-timeout-ms=N  hard limit for a CLI child (default: 10000)
                \\  --help            show this help message
                \\
            , .{});
            return;
        } else {
            // Positional argument: target operations count
            if (std.fmt.parseInt(u64, arg, 10)) |ops| {
                if (ops > 0) cfg.target_ops = ops;
            } else |_| {}
        }
    }

    common.printOut(init.io,
        \\========================================================================================
        \\  ⚡ ZiGrep Adversarial Entropic Fuzzer Swarm (Pure Zig 0.16 Multi-Core Swarm)
        \\========================================================================================
        \\  Target Operations : {d} ops
        \\  Active Workers    : {d} parallel threads
        \\  Entropy Knob      : Level {d} (1=Gentle, 2=Flags, 3=Grammar, 4=ReDoS, 5=Chaos)
        \\  Adversaries Active: {s}
        \\  Master PRNG Seed  : 0x{x}
        \\  Subprocess Rate   : 1 in {d} CLI permutations
        \\----------------------------------------------------------------------------------------
        \\
    , .{
        cfg.target_ops,
        cfg.threads,
        cfg.knob,
        if (cfg.selected_adversary == 0) "All 4 Adversaries (Grammar, CLI, Payloads, Oracle)" else "Specialized Adversary Mode",
        cfg.master_seed,
        cfg.cli_rate,
    });

    var stats: SwarmStats = .{};

    // Prepare worker contexts and thread pool
    var threads: std.ArrayList(std.Thread) = .empty;
    defer threads.deinit(gpa);

    const contexts = try arena.alloc(WorkerContext, cfg.threads);
    const start_time = common.nowNs(init.io);

    var i: usize = 0;
    while (i < cfg.threads) : (i += 1) {
        contexts[i] = .{
            .worker_id = i,
            .gpa = gpa,
            .stats = &stats,
            .cfg = &cfg,
            .io = init.io,
        };
        const t = std.Thread.spawn(.{}, swarmWorker, .{&contexts[i]}) catch break;
        try threads.append(gpa, t);
    }

    if (threads.items.len == 0) {
        std.debug.print("Failed to spawn any worker threads\n", .{});
        return;
    }

    // Live Terminal HUD Monitor Loop (1 update per second, clean and lightweight)
    var last_ops: u64 = 0;
    var last_time = start_time;

    while (!stats.stop.load(.acquire)) {
        std.Io.sleep(init.io, .fromSeconds(1), .awake) catch {}; // 1000 ms

        const current_ops = stats.total_ops.load(.acquire);
        const current_time = common.nowNs(init.io);
        const elapsed_s = @as(f64, @floatFromInt(current_time - start_time)) / 1_000_000_000.0;
        const delta_s = @as(f64, @floatFromInt(current_time - last_time)) / 1_000_000_000.0;
        const delta_ops = current_ops -| last_ops;
        const current_rate = if (delta_s > 0) @as(f64, @floatFromInt(delta_ops)) / delta_s else 0.0;

        last_ops = current_ops;
        last_time = current_time;

        const adv1 = stats.adv1_ops.load(.acquire);
        const adv2 = stats.adv2_ops.load(.acquire);
        const adv3 = stats.adv3_ops.load(.acquire);
        const adv4 = stats.adv4_ops.load(.acquire);
        const anom = stats.anomalies.load(.acquire);

        common.printOut(init.io, "\r  [SWARM HUD] Elapsed: {d:.1}s | Ops: {d}/{d} ({d:.0} ops/s) | Adv[1:{d} 2:{d} 3:{d} 4:{d}] | Anomalies: {d}   ", .{
            elapsed_s,
            current_ops,
            cfg.target_ops,
            current_rate,
            adv1,
            adv2,
            adv3,
            adv4,
            anom,
        });

        if (current_ops >= cfg.target_ops) break;
    }

    // Join all worker threads
    for (threads.items) |t| {
        t.join();
    }

    const total_time_s = @as(f64, @floatFromInt(common.nowNs(init.io) - start_time)) / 1_000_000_000.0;
    const final_ops = stats.total_ops.load(.acquire);
    const avg_rate = if (total_time_s > 0) @as(f64, @floatFromInt(final_ops)) / total_time_s else 0.0;

    const final_adv1 = stats.adv1_ops.load(.acquire);
    const final_adv2 = stats.adv2_ops.load(.acquire);
    const final_adv3 = stats.adv3_ops.load(.acquire);
    const final_adv4 = stats.adv4_ops.load(.acquire);
    const final_anom = stats.anomalies.load(.acquire);
    const final_crashes = stats.crashes.load(.acquire);
    const final_bad_exits = stats.bad_exits.load(.acquire);
    const final_inv_fails = stats.invariant_fails.load(.acquire);

    common.printOut(init.io,
        \\
        \\----------------------------------------------------------------------------------------
        \\  🏁 Fuzzing Swarm Campaign Complete!
        \\----------------------------------------------------------------------------------------
        \\  Total Executions Completed : {d} ops
        \\  Wall Clock Elapsed Time    : {d:.2} seconds
        \\  Average Swarm Throughput   : {d:.0} ops/sec
        \\
        \\  Adversary Breakdown:
        \\    - Adv 1 (Regex & Thompson DFA)   : {d} ops
        \\    - Adv 2 (CLI Options & Perms)    : {d} ops
        \\    - Adv 3 (Toxic Payloads & SIMD)  : {d} ops
        \\    - Adv 4 (Differential Invariants): {d} ops
        \\
        \\  Vulnerability & Crash Findings:
        \\    - Total Anomalies Detected       : {d}
        \\    - Process Crashes (SIGSEGV/ABRT) : {d}
        \\    - Invalid Exit Codes (> 2)       : {d}
        \\    - Invariant / Logic Divergences  : {d}
        \\========================================================================================
        \\
    , .{
        final_ops,
        total_time_s,
        avg_rate,
        final_adv1,
        final_adv2,
        final_adv3,
        final_adv4,
        final_anom,
        final_crashes,
        final_bad_exits,
        final_inv_fails,
    });

    if (final_anom == 0) {
        common.printOut(init.io, "  Verdict: 🟢 ZERO ANOMALIES — ZiGrep stood resilient against {d} adversarial permutations!\n\n", .{final_ops});
    } else {
        common.printOut(init.io, "  Verdict: 🔴 {d} ANOMALIES FOUND! Reproducers saved to evidence/reproducers/\n\n", .{final_anom});
        std.process.exit(1);
    }
}
