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
const types = @import("types.zig");
const vfs = @import("vfs.zig");
const io_engine = @import("io_engine.zig");

const Algo = search.Algo;
const Mode = scan.Mode;
const Allocator = std.mem.Allocator;

const version = "0.3.1";

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
    \\  -G, --basic-regexp
    \\                    basic regex (grep's default). zgrep speaks ERE, so
    \\                    the pattern is TRANSLATED, not ignored
    \\  -e PATTERN        search for PATTERN; repeat for several (any may match)
    \\  -f, --file=FILE   read patterns from FILE (one per line, repeatable)
    \\  -x, --line-regexp match whole lines only
    \\  -i, --ignore-case ignore case (ASCII + Latin-1 Unicode)
    \\  -v, --invert-match
    \\                    select non-matching lines
    \\  -w, --word-regexp match whole words only
    \\  -r                recurse into directories (always on; kept for grep compat)
    \\  -n                print line numbers (always on; kept for grep compat)
    \\      --no-line-number
    \\                    do not print line numbers
    \\  -c, --count       print only a count of matching lines per file
    \\  -l, --files-with-matches
    \\                    print only the names of files with matches
    \\  -L, --files-without-match
    \\                    print only the names of files without matches
    \\  -q, --quiet, --silent
    \\                    quiet: no output, exit status only
    \\  -m, --max-count=NUM
    \\                    stop after NUM matching lines per file
    \\  -A, --after-context=NUM
    \\                    print NUM lines of context after a match
    \\  -B, --before-context=NUM
    \\                    print NUM lines of context before a match
    \\  -C, --context=NUM print NUM lines of context around a match
    \\  -H                print the file name with each result
    \\  -h                do not print the file name with each result
    \\  -a                treat binary files as text
    \\  -Z, -0, --null    print a NUL after each file name
    \\  -o, --only-matching
    \\                    print only the matched part of each line
    \\      --count-matches
    \\                    like --count, but counting matches instead of lines
    \\      --column     print the 1-based byte column of the first match (rg)
    \\      --color[=WHEN]
    \\                    highlight matches (always|never|auto; auto = never)
    \\      --replace=TEXT
    \\                    with -o semantics, print TEXT instead of each match (rg)
    \\      --passthru   also print the lines that do not match (with -r)
    \\      --exec, --execute, -X CMD
    \\                    run CMD for every file with a match; {} is the path.
    \\                    Without {} the path is appended (find -exec style)
    \\  -s, --no-messages suppress error messages about unreadable files
    \\  -j, --threads N   worker threads (default: number of CPUs)
    \\  -S, --smart-case  case-insensitive unless PATTERN has an uppercase
    \\  -t, --type NAME   restrict to a file type (py, zig, md, ...)
    \\      --type-not NAME
    \\                    skip a file type instead
    \\      --type-list    list every known type and exit
    \\      --max-depth=N  do not descend below N levels (rg; long only)
    \\      --max-filesize=N[KMGT]
    \\                    skip files larger than N (rg)
    \\  -b, --byte-offset print the byte offset of each match in the file
    \\      --crlf        treat CRLF as the line terminator, not just \n
    \\  -z, --null-data  NUL separates records instead of \n (grep -z)
    \\  -U, --multiline   a match may span newlines (rg)
    \\      --multiline-dotall
    \\                    with -U, `.` also crosses a newline
    \\      --stop-on-nonmatch
    \\                    stop once a non-matching line follows a matching one
    \\      --pre=CMD    search the stdout of CMD instead of the file (rg);
    \\                    {} in CMD is the file path
    \\      --encoding=ENC
    \\                    auto | none | utf-8 | utf-16 | utf-16le | utf-16be |
    \\                    latin1  (default auto: BOM sniff only)
    \\      --pre-glob=GLOB
    \\                    only apply --pre to files matching GLOB
    \\      --heading     print the file path above each file's matches (rg)
    \\      --no-heading  print it as a per-line prefix instead (default)
    \\  -p, --pretty       alias for --color=always --heading --line-number
    \\      --vimgrep     one line per match, with line and column (rg)
    \\      --binary-files=TYPE
    \\                    text | without-match (zgrep never prints binary
    \\                    content, so 'binary' is rejected, not faked)
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
    \\      --exclude-from=FILE
    \\                    read more --exclude globs from FILE, one per line
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
    \\                     (exact alias of --io-engine=uring)
    \\      --io-engine=  sync | uring | auto   (default: auto). auto makes the
    \\                     first read of each probed file a preadv2(RWF_NOWAIT)
    \\                     probe: if the page is in RAM its bytes are scanned
    \\                     directly; if the tree is cold it promotes to
    \\                     io_uring. sync is the old behaviour, byte for byte
    \\      --help        print this help
    \\  -V, --version     print the version
    \\
    \\regex dialect (same as rg): . [a-z] [^x] [[:alpha:]] \d \w \s * + ? {n,m} | ( ) ^ $
    \\word boundaries \b and \B are supported (zero-width assertions).
    \\not supported (reported as an error): back-references, lookaround.
    \\a plain string with no metacharacters takes the fast literal path.
    \\patterns containing a newline are rejected.
    \\when no PATH is given or when PATH is '-', standard input is read.
    \\
    \\exit status: 0 match found, 1 no match, 2 error
    \\
;

/// `--color` tri-state. `auto` is deliberately folded to `never`: deciding
/// it properly needs isatty(stdout), which is not worth the flag.
pub const ColorMode = enum { never, always, auto };

/// `--binary-files=TYPE` (grep). zgrep only has two honest answers: hunt the
/// file and print the matches, or pretend it does not match. `binary` in grep
/// means "print matches but suppress binary content", which this engine cannot
/// do, so it is rejected at parse time instead of silently accepted.
pub const BinaryFiles = enum { text, without_match };

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
    /// `sync` | `uring` | `auto` (default `auto`). `--uring` sigue siendo un
    /// alias exacto de `uring`. `auto` arranca en el enjambre síncrono y
    /// promociona a io_uring si la sonda ve el árbol frío; `sync` reproduce
    /// el comportamiento anterior byte a byte.
    io_engine_mode: io_engine.Mode = .auto,
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
    /// `-x`: the pattern must match a whole line.
    line_regexp: bool = false,
    /// `-s` / `--no-messages`: do not report unreadable files.
    no_messages: bool = false,
    /// Line numbers are printed by default; `--no-line-number` disables them.
    /// `-n` stays a no-op so `grep`-style clusters keep parsing.
    show_line_no: bool = true,
    /// `-Z` / `-0`: terminate file names with NUL instead of ':' / newline.
    null_filename: bool = false,
    /// `-A` / `-B` / `-C` line context.
    before_context: usize = 0,
    after_context: usize = 0,
    /// `-f FILE`: patterns come from files as well.
    pattern_files: [16][]const u8 = undefined,
    pattern_files_count: usize = 0,
    /// `-o`: one output line per (non-empty) match.
    only_matching: bool = false,
    /// `--column`: print the 1-based byte column of the first match (rg).
    column: bool = false,
    /// `--color=always|never|auto` (auto degrades to never off a TTY).
    color: ColorMode = .never,
    /// `--replace=TEXT` (rg): substitute every match with TEXT. The rest of
    /// the line survives (rg); with `-o` the record is just the replacement.
    replace: ?[]const u8 = null,
    /// `--passthru`: also print lines that do not match.
    passthru: bool = false,
    /// `--exec=CMD`: run CMD for every file with matches (find -exec style).
    /// Turns off the normal output; the command's streams are inherited.
    exec_cmd: ?[]const u8 = null,
    /// `--vimgrep`: one output line per match, with column (rg).
    vimgrep: bool = false,
    /// `-G`: the patterns are BRE, translated to ERE before compiling.
    basic_regexp: bool = false,
    /// `-S`: insensitive unless the pattern has an uppercase letter (rg).
    smart_case: bool = false,
    /// `-t TYPE` (include) / `--type-not TYPE` (exclude) counts.
    type_include: [8]types.Type = undefined,
    type_include_count: usize = 0,
    type_exclude: [8]types.Type = undefined,
    type_exclude_count: usize = 0,
    /// `--type-list`: print the type registry and exit.
    print_type_list: bool = false,
    /// `--binary-files=TYPE` (grep): text = -a, without-match = default.
    binary_files: BinaryFiles = .without_match,
    /// `--exclude-from=FILE` (grep): globs, one per line.
    exclude_from: [8][]const u8 = undefined,
    exclude_from_count: usize = 0,
    /// `--max-depth=N` (rg; long only, `-d` is grep's --directories).
    max_depth: usize = 0,
    /// `--max-filesize=N[KMGT]` (rg): 0 = unlimited.
    max_filesize: usize = 0,
    /// `-b`: byte offset of the match within the file (grep semantics).
    byte_offset: bool = false,
    /// `--crlf`: CRLF is the line terminator (rg); `--no-crlf` turns it off.
    crlf: bool = false,
    /// `--heading`: print the path as a header line above each file's matches.
    heading: bool = false,
    /// `--null-data` / `-z`: NUL is the record separator (grep -z). NOT rg's
    /// `-z`, which is --search-zip; grep semantics win.
    null_data: bool = false,
    /// `-U`: a match may span newlines (rg's --multiline).
    multiline: bool = false,
    /// `--multiline-dotall`: with -U, `.` also crosses a newline.
    multiline_dotall: bool = false,
    /// `--stop-on-nonmatch`: stop once a non-matching line follows a match.
    stop_on_nonmatch: bool = false,
    /// `--pre=CMD` (rg): search the stdout of CMD instead of the file. `{}`
    /// or no placeholder at all means the file path (rg requires `{}`).
    pre_cmd: ?[]const u8 = null,
    /// `--pre-glob=GLOB`: only apply --pre to the files that match GLOB.
    pre_glob: ?[]const u8 = null,
    /// `--encoding`: auto | none | utf-8 | utf-16 | utf-16le | utf-16be | latin1.
    encoding: []const u8 = "auto",
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
    /// `--pre=CMD` (rg): search the command's stdout instead of the file.
    pre_cmd: []const u8 = "",
    /// `--pre-glob=GLOB`: only --pre the files matching GLOB.
    pre_glob: []const u8 = "",
    /// arena for the argv of --pre/--exec.
    arena: Allocator = undefined,
    /// `--exec` runs with the quiet mode (no output) but must NOT stop the
    /// scan at the first match: every matching file has to be collected.
    exec_mode: bool = false,
};

const default_scratch_bytes = 256 * 1024; // 256 KB covers ~99.5% of files

fn scanOne(ctx: *Ctx, idx: usize, scratch: ?[]u8) void {
    const slot = &ctx.slots[idx];

    // `--pre`: rg searches the stdout of a command instead of the file (the
    // way you search inside archives). It is done here, on the ordered path,
    // because that is the one that knows which file it is about to scan.
    if (ctx.pre_cmd.len > 0 and preApplies(ctx.pre_glob, ctx.files[idx])) {
        if (runPre(ctx.gpa, ctx.io, ctx.arena, ctx.pre_cmd, ctx.files[idx])) |text| {
            defer ctx.gpa.free(text);
            const br = scan.scanBuffer(
                ctx.gpa,
                text,
                ctx.searcher,
                ctx.files[idx],
                ctx.show_path,
                ctx.mode,
                ctx.scan_config,
                &slot.buf,
            ) catch {
                slot.done = true;
                slot.err = .NOMEM;
                slot.ready.store(true, .release);
                return;
            };
            slot.done = true;
            slot.matched = br.matched;
            slot.lines = br.lines;
            slot.bytes = text.len;
            slot.ready.store(true, .release);
            return;
        }
        // the command failed: skip the file, like rg
        slot.done = true;
        slot.ready.store(true, .release);
        return;
    }

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
        null, // el camino ordenado no participa en la muestra del motor
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
        if (ctx.mode == .quiet and !ctx.exec_mode and ctx.found.load(.acquire)) return;
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

/// Parses a line-count argument (`-A2`, `--context 3`, ...). A non-numeric
/// value is a usage error, not a silent zero.
fn parseContextArg(opts: *Options, value: []const u8, what: []const u8) usage_error!usize {
    return parseCount(value) orelse {
        opts.fail = .{ .what = what, .arg = value };
        return error.Usage;
    };
}

pub const max_exec_args = 64;

/// The argv of one `--exec` command. Returned BY VALUE: the array lives inside
/// this struct, so the caller owns a copy. Returning a slice to a local array
/// here is what a first version did, and it silently truncated the path
/// appended at the end (stack reuse) while the `{}`-substituted tokens, which
/// are heap-allocated by `concat`, still worked.
pub const ExecArgv = struct {
    items: [max_exec_args][]const u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const ExecArgv) []const []const u8 {
        return self.items[0..self.len];
    }
};

/// Splits an `--exec` template into argv:
///   * whitespace separates arguments (no quoting: use `sh -c '...'` for that)
///   * `{}` anywhere inside an argument is replaced by the file path, which is
///     what makes `python3 main.py {}` work (find only allows `{}` alone)
///   * if no `{}` appears at all, the path is appended (find -exec style)
pub fn expandExecArgv(gpa: Allocator, template: []const u8, path: []const u8) ExecArgv {
    var argv = ExecArgv{};
    var replaced = false;
    var it = std.mem.tokenizeAny(u8, template, " \t");
    while (it.next()) |tok| {
        if (argv.len >= max_exec_args) break;
        if (std.mem.indexOf(u8, tok, "{}")) |at| {
            replaced = true;
            argv.items[argv.len] = std.mem.concat(gpa, u8, &.{
                tok[0..at],
                path,
                tok[at + 2 ..],
            }) catch tok;
        } else {
            argv.items[argv.len] = tok;
        }
        argv.len += 1;
    }
    if (!replaced and argv.len < max_exec_args) {
        argv.items[argv.len] = path;
        argv.len += 1;
    }
    return argv;
}

/// Runs one `--exec` command with all three streams inherited, so the child
/// behaves exactly as if the user had typed it. Returns the exit code, or
/// `null` when the process could not be spawned at all.
fn runExecCmd(io: std.Io, argv: []const []const u8) ?u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return null;
    const term = child.wait(io) catch return null;
    return switch (term) {
        .exited => |code| code,
        else => 128,
    };
}

/// Applies `--exec` to every file that matched. Sequential on purpose for v1:
/// the command is arbitrary user code (a Python interpreter, say) and running
/// N of them in parallel produces interleaved, useless output.
fn runExecAll(
    io: std.Io,
    gpa: Allocator,
    files: []const [:0]const u8,
    matched: []const bool,
    template: []const u8,
    no_messages: bool,
) bool {
    var ok = true;
    for (files, 0..) |path, idx| {
        if (idx >= matched.len or !matched[idx]) continue;
        // The argv is copied into a local buffer before the spawn: the struct
        // returned by `expandExecArgv` is 1 KB and ReleaseFast kept parts of it
        // in registers, which made the last argument (the appended path) read
        // as empty inside the child.
        var argv_buf: [max_exec_args][]const u8 = undefined;
        const argv = expandExecArgv(gpa, template, path);
        @memcpy(argv_buf[0..argv.len], argv.items[0..argv.len]);
        if (runExecCmd(io, argv_buf[0..argv.len])) |code| {
            if (code != 0) ok = false;
        } else {
            if (!no_messages) std.debug.print("zgrep: could not run: {s}\n", .{argv.items[0]});
            ok = false;
        }
    }
    return ok;
}

/// `-t py` / `--type-not py`: adds the registry's extensions to the include
/// or exclude lists. An unknown name is a usage error, like rg.
fn addType(opts: *Options, name: []const u8, include: bool) usage_error!void {
    const t = types.lookup(name) orelse {
        opts.fail = .{ .what = "unknown type name (see --type-list)", .arg = name };
        return error.Usage;
    };
    const list = if (include) &opts.type_include else &opts.type_exclude;
    const count = if (include) &opts.type_include_count else &opts.type_exclude_count;
    if (count.* >= list.len) {
        opts.fail = .{ .what = "too many -t types (max 8)", .arg = name };
        return error.Usage;
    }
    list[count.*] = t;
    count.* += 1;
}

/// `--max-filesize` value: plain bytes or with a K/M/G/T suffix (rg accepts
/// both upper and lower case, and `+N` means "greater than").
fn parseSize(value: []const u8) ?usize {
    var v = value;
    if (v.len > 0 and v[0] == '+') v = v[1..];
    if (v.len == 0) return null;
    const mult: usize = switch (v[v.len - 1]) {
        'k', 'K' => 1024,
        'm', 'M' => 1024 * 1024,
        'g', 'G' => 1024 * 1024 * 1024,
        't', 'T' => 1024 * 1024 * 1024 * 1024,
        else => 1,
    };
    if (mult != 1) v = v[0 .. v.len - 1];
    return (parseCount(v) orelse return null) *| mult;
}

/// `-t`/`--type-not`: the registry's extensions become include/ext filters.
fn applyTypes(filter_engine: *filter.FilterEngine, opts: *const Options) void {
    for (opts.type_include[0..opts.type_include_count]) |t| {
        for (t.exts) |ext| filter_engine.addIncludedExts(ext) catch {};
    }
    for (opts.type_exclude[0..opts.type_exclude_count]) |t| {
        for (t.exts) |ext| filter_engine.addExcludedExts(ext) catch {};
    }
}

/// `--exclude-from=FILE`: one glob per line, appended to --exclude.
fn loadExcludeFrom(io: std.Io, arena: Allocator, filter_engine: *filter.FilterEngine, opts: *const Options) void {
    for (opts.exclude_from[0..opts.exclude_from_count]) |path| {
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch continue;
        defer file.close(io);
        const size = std.math.cast(usize, (file.stat(io) catch continue).size) orelse continue;
        const bytes = arena.alloc(u8, size) catch continue;
        const got = file.readPositionalAll(io, bytes, 0) catch continue;
        var start: usize = 0;
        while (start < got) {
            const end = std.mem.findScalarPos(u8, bytes[0..got], start, '\n') orelse got;
            var line = bytes[start..end];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (line.len > 0) filter_engine.addExcludedPattern(line) catch {};
            if (end >= got) break;
            start = end + 1;
        }
    }
}

/// Runs the `--pre` command for `path` and returns its stdout, or null when
/// the command failed (the file is then skipped, like rg).
fn runPre(gpa: Allocator, io: std.Io, allocator: Allocator, template: []const u8, path: []const u8) ?[]const u8 {
    const argv = expandExecArgv(allocator, template, path);
    var child = std.process.spawn(io, .{
        .argv = argv.slice(),
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return null;
    // Read the pipe to EOF: `std.process` needs us to drain it before wait.
    var out: std.ArrayList(u8) = .empty;
    var chunk: [64 * 1024]u8 = undefined;
    const so = child.stdout.?;
    while (true) {
        const n = so.readStreaming(io, &.{chunk[0..]}) catch break;
        if (n == 0) break;
        out.appendSlice(gpa, chunk[0..n]) catch break;
    }
    _ = child.wait(io) catch {
        out.deinit(gpa);
        return null;
    };
    return out.items;
}

/// `--pre-glob` decides whether a file goes through --pre. rg uses its glob
/// syntax; zgrep reuses the filter engine's.
fn preApplies(glob: ?[]const u8, path: []const u8) bool {
    const g = glob orelse return true;
    const name = std.fs.path.basename(path);
    return filter.matchPattern(name, g) or filter.matchPattern(path, g);
}

/// The encodings zgrep can actually honour. Anything else is a usage error
/// instead of a silent raw-bytes fallback.
fn validEncoding(v: []const u8) ?[]const u8 {
    const names = [_][]const u8{ "auto", "none", "utf-8", "utf-16", "utf-16le", "utf-16be", "latin1" };
    for (names) |n| {
        if (std.mem.eql(u8, v, n)) return n;
    }
    return null;
}

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

/// Reads patterns from a `-f` file: one per line, a trailing `\r` stripped, and
/// the empty final element after a trailing newline ignored (GNU grep
/// semantics). The lines live in the arena for the life of the process.
fn readPatternFile(
    arena: Allocator,
    io: std.Io,
    path: []const u8,
    list: *std.ArrayListUnmanaged([]const u8),
) !void {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| return err;
    defer file.close(io);
    const size = std.math.cast(usize, (file.stat(io) catch |err| return err).size) orelse return error.ReadFailed;
    const bytes = try arena.alloc(u8, size);
    const got = file.readPositionalAll(io, bytes, 0) catch |err| return err;
    const data = bytes[0..got];
    var start: usize = 0;
    while (start < data.len) {
        const end = std.mem.findScalarPos(u8, data, start, '\n') orelse data.len;
        var line = data[start..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        try list.append(arena, line);
        if (end >= data.len) break;
        start = end + 1;
    }
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
                opts.io_engine_mode = .uring;
            } else if (std.mem.startsWith(u8, a, "--io-engine=")) {
                const value = a["--io-engine=".len..];
                if (std.mem.eql(u8, value, "sync")) {
                    opts.use_uring = false;
                    opts.io_engine_mode = .sync;
                } else if (std.mem.eql(u8, value, "uring")) {
                    opts.use_uring = true;
                    opts.io_engine_mode = .uring;
                } else if (std.mem.eql(u8, value, "auto")) {
                    opts.use_uring = false;
                    opts.io_engine_mode = .auto;
                } else {
                    opts.fail = .{
                        .what = "bad value for --io-engine (expected auto|sync|uring)",
                        .arg = value,
                    };
                    return error.Usage;
                }
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
            } else if (std.mem.eql(u8, body, "basic-regexp")) {
                opts.basic_regexp = true;
            } else if (std.mem.eql(u8, body, "line-regexp")) {
                opts.line_regexp = true;
            } else if (std.mem.eql(u8, body, "no-messages")) {
                opts.no_messages = true;
            } else if (std.mem.eql(u8, body, "no-line-number")) {
                opts.show_line_no = false;
            } else if (std.mem.eql(u8, body, "line-number")) {
                opts.show_line_no = true;
            } else if (std.mem.eql(u8, body, "null")) {
                opts.null_filename = true;
            } else if (std.mem.startsWith(u8, body, "replace=")) {
                opts.replace = body["replace=".len..];
                // rg does NOT imply -o here: `rg --replace X needle` prints the
                // WHOLE line with the match substituted (`needle here` ->
                // `X here`). Only with an explicit `-o` does the record shrink
                // to the replacement.
            } else if (std.mem.eql(u8, body, "replace")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                opts.replace = args[i];
            } else if (std.mem.startsWith(u8, body, "exec=")) {
                opts.exec_cmd = body["exec=".len..];
            } else if (std.mem.startsWith(u8, body, "execute=")) {
                opts.exec_cmd = body["execute=".len..];
            } else if (std.mem.eql(u8, body, "exec") or std.mem.eql(u8, body, "execute")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                opts.exec_cmd = args[i];
            } else if (std.mem.eql(u8, body, "smart-case")) {
                opts.smart_case = true;
            } else if (std.mem.startsWith(u8, body, "type=")) {
                const v = body["type=".len..];
                addType(opts, v, true) catch return error.Usage;
            } else if (std.mem.eql(u8, body, "type")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                addType(opts, args[i], true) catch return error.Usage;
            } else if (std.mem.startsWith(u8, body, "type-not=")) {
                addType(opts, body["type-not=".len..], false) catch return error.Usage;
            } else if (std.mem.eql(u8, body, "type-not")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                addType(opts, args[i], false) catch return error.Usage;
            } else if (std.mem.eql(u8, body, "type-list")) {
                opts.print_type_list = true;
                return .{ .pattern = "", .operands = &[_][:0]const u8{} };
            } else if (std.mem.startsWith(u8, body, "binary-files=")) {
                const v = body["binary-files=".len..];
                opts.binary_files = if (std.mem.eql(u8, v, "text"))
                    .text
                else if (std.mem.eql(u8, v, "without-match"))
                    .without_match
                else {
                    opts.fail = .{ .what = "bad value for --binary-files (expected text|without-match; zgrep never prints binary content)", .arg = v };
                    return error.Usage;
                };
            } else if (std.mem.startsWith(u8, body, "exclude-from=")) {
                if (opts.exclude_from_count >= opts.exclude_from.len) {
                    opts.fail = .{ .what = "too many --exclude-from files (max 8)", .arg = a };
                    return error.Usage;
                }
                opts.exclude_from[opts.exclude_from_count] = body["exclude-from=".len..];
                opts.exclude_from_count += 1;
            } else if (std.mem.eql(u8, body, "exclude-from")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                if (opts.exclude_from_count >= opts.exclude_from.len) {
                    opts.fail = .{ .what = "too many --exclude-from files (max 8)", .arg = a };
                    return error.Usage;
                }
                opts.exclude_from[opts.exclude_from_count] = args[i];
                opts.exclude_from_count += 1;
            } else if (std.mem.startsWith(u8, body, "max-depth=")) {
                opts.max_depth = parseCount(body["max-depth=".len..]) orelse {
                    opts.fail = .{ .what = "bad value for --max-depth", .arg = body["max-depth=".len..] };
                    return error.Usage;
                };
            } else if (std.mem.eql(u8, body, "max-depth")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                opts.max_depth = parseCount(args[i]) orelse {
                    opts.fail = .{ .what = "bad value for --max-depth", .arg = args[i] };
                    return error.Usage;
                };
            } else if (std.mem.startsWith(u8, body, "max-filesize=")) {
                opts.max_filesize = parseSize(body["max-filesize=".len..]) orelse {
                    opts.fail = .{ .what = "bad value for --max-filesize", .arg = body["max-filesize=".len..] };
                    return error.Usage;
                };
            } else if (std.mem.eql(u8, body, "max-filesize")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                opts.max_filesize = parseSize(args[i]) orelse {
                    opts.fail = .{ .what = "bad value for --max-filesize", .arg = args[i] };
                    return error.Usage;
                };
            } else if (std.mem.eql(u8, body, "multiline") or std.mem.eql(u8, body, "multiline-dotall")) {
                opts.multiline = true;
                if (std.mem.eql(u8, body, "multiline-dotall")) opts.multiline_dotall = true;
            } else if (std.mem.eql(u8, body, "no-multiline")) {
                opts.multiline = false;
            } else if (std.mem.startsWith(u8, body, "pre=")) {
                opts.pre_cmd = body["pre=".len..];
            } else if (std.mem.eql(u8, body, "pre")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                opts.pre_cmd = args[i];
            } else if (std.mem.startsWith(u8, body, "encoding=")) {
                const v = body["encoding=".len..];
                opts.encoding = if (std.mem.eql(u8, v, "auto") or
                    std.mem.eql(u8, v, "none") or
                    std.mem.eql(u8, v, "utf-8") or
                    std.mem.eql(u8, v, "utf-16") or
                    std.mem.eql(u8, v, "utf-16le") or
                    std.mem.eql(u8, v, "utf-16be") or
                    std.mem.eql(u8, v, "latin1"))
                    v
                else {
                    opts.fail = .{ .what = "unknown encoding (zgrep supports auto|none|utf-8|utf-16|utf-16le|utf-16be|latin1)", .arg = v };
                    return error.Usage;
                };
            } else if (std.mem.eql(u8, body, "encoding")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                opts.encoding = validEncoding(args[i]) orelse {
                    opts.fail = .{ .what = "unknown encoding (zgrep supports auto|none|utf-8|utf-16|utf-16le|utf-16be|latin1)", .arg = args[i] };
                    return error.Usage;
                };
            } else if (std.mem.eql(u8, body, "no-encoding")) {
                opts.encoding = "auto";
            } else if (std.mem.startsWith(u8, body, "pre-glob=")) {
                opts.pre_glob = body["pre-glob=".len..];
            } else if (std.mem.eql(u8, body, "pre-glob")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                opts.pre_glob = args[i];
            } else if (std.mem.eql(u8, body, "stop-on-nonmatch")) {
                opts.stop_on_nonmatch = true;
            } else if (std.mem.eql(u8, body, "null-data")) {
                opts.null_data = true;
            } else if (std.mem.eql(u8, body, "heading") or std.mem.eql(u8, body, "group-by-file")) {
                opts.heading = true;
            } else if (std.mem.eql(u8, body, "no-heading")) {
                opts.heading = false;
            } else if (std.mem.eql(u8, body, "pretty")) {
                // rg's convenience alias: --color=always --heading --line-number.
                opts.color = .always;
                opts.heading = true;
                opts.show_line_no = true;
            } else if (std.mem.eql(u8, body, "vimgrep")) {
                // rg: every match on its own line, with line and column.
                opts.column = true;
                opts.show_line_no = true;
                opts.show_path = true;
                opts.only_matching = true;
                opts.vimgrep = true;
            } else if (std.mem.eql(u8, body, "crlf")) {
                opts.crlf = true;
            } else if (std.mem.eql(u8, body, "no-crlf")) {
                opts.crlf = false;
            } else if (std.mem.eql(u8, body, "byte-offset")) {
                opts.byte_offset = true;
            } else if (std.mem.eql(u8, body, "only-matching")) {
                opts.only_matching = true;
            } else if (std.mem.eql(u8, body, "count-matches")) {
                opts.mode = .count_matches;
            } else if (std.mem.eql(u8, body, "column")) {
                opts.column = true;
            } else if (std.mem.eql(u8, body, "passthru")) {
                opts.passthru = true;
            } else if (std.mem.eql(u8, body, "color") or std.mem.eql(u8, body, "colour")) {
                opts.color = .always;
            } else if (std.mem.startsWith(u8, body, "color=")) {
                const v = body["color=".len..];
                opts.color = if (std.mem.eql(u8, v, "always"))
                    .always
                else if (std.mem.eql(u8, v, "never"))
                    .never
                else if (std.mem.eql(u8, v, "auto"))
                    .auto
                else {
                    opts.fail = .{ .what = "bad value for --color (expected always|never|auto)", .arg = v };
                    return error.Usage;
                };
            } else if (std.mem.eql(u8, body, "text")) {
                opts.binary = true;
            } else if (std.mem.startsWith(u8, body, "after-context=")) {
                const v = body["after-context=".len..];
                opts.after_context = try parseContextArg(opts, v, "bad value for --after-context");
            } else if (std.mem.eql(u8, body, "after-context")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                opts.after_context = try parseContextArg(opts, args[i], "bad value for --after-context");
            } else if (std.mem.startsWith(u8, body, "before-context=")) {
                const v = body["before-context=".len..];
                opts.before_context = try parseContextArg(opts, v, "bad value for --before-context");
            } else if (std.mem.eql(u8, body, "before-context")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                opts.before_context = try parseContextArg(opts, args[i], "bad value for --before-context");
            } else if (std.mem.startsWith(u8, body, "context=")) {
                const v = body["context=".len..];
                opts.before_context = try parseContextArg(opts, v, "bad value for --context");
                opts.after_context = opts.before_context;
            } else if (std.mem.eql(u8, body, "context")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                opts.before_context = try parseContextArg(opts, args[i], "bad value for --context");
                opts.after_context = opts.before_context;
            } else if (std.mem.startsWith(u8, body, "file=")) {
                if (opts.pattern_files_count >= opts.pattern_files.len) {
                    opts.fail = .{ .what = "too many -f pattern files (max 16)", .arg = a };
                    return error.Usage;
                }
                opts.pattern_files[opts.pattern_files_count] = body["file=".len..];
                opts.pattern_files_count += 1;
            } else if (std.mem.eql(u8, body, "file")) {
                i += 1;
                if (i >= args.len) {
                    opts.fail = .{ .what = "option requires an argument", .arg = a };
                    return error.Usage;
                }
                if (opts.pattern_files_count >= opts.pattern_files.len) {
                    opts.fail = .{ .what = "too many -f pattern files (max 16)", .arg = a };
                    return error.Usage;
                }
                opts.pattern_files[opts.pattern_files_count] = args[i];
                opts.pattern_files_count += 1;
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
                // Accepted no-ops: zgrep is always recursive, never follows
                // symlinks, and already skips binary files the way `-I` asks
                // for. `-n` keeps its real meaning (line numbers are on by
                // default) and `-s` is `--no-messages`, which used to be a
                // silent no-op.
                // Accepted no-ops: zgrep is always recursive, never follows
                // symlinks, and already skips binary files the way `-I` asks
                // for. `-E` is the default dialect. `-G` is NOT a no-op
                // anymore: a silent ERE read of a BRE pattern changed its
                // meaning, which is worse than not supporting it.
                'r', 'I' => {},
                'E' => {},
                'G' => opts.basic_regexp = true,
                'n' => opts.show_line_no = true,
                's' => opts.no_messages = true,
                'x' => opts.line_regexp = true,
                'o' => opts.only_matching = true,
                'S' => opts.smart_case = true,
                'z' => opts.null_data = true,
                'U' => opts.multiline = true,
                'p' => {
                    opts.color = .always;
                    opts.heading = true;
                    opts.show_line_no = true;
                },
                'b' => opts.byte_offset = true,
                't' => {
                    const rest = chars[ci + 1 ..];
                    const value: []const u8 = if (rest.len > 0) rest else blk: {
                        i += 1;
                        if (i >= args.len) {
                            opts.fail = .{ .what = "option requires an argument", .arg = a };
                            return error.Usage;
                        }
                        break :blk args[i];
                    };
                    addType(opts, value, true) catch return error.Usage;
                    ci = chars.len;
                },
                'X' => {
                    const rest = chars[ci + 1 ..];
                    const value: []const u8 = if (rest.len > 0) rest else blk: {
                        i += 1;
                        if (i >= args.len) {
                            opts.fail = .{ .what = "option requires an argument", .arg = a };
                            return error.Usage;
                        }
                        break :blk args[i];
                    };
                    opts.exec_cmd = value;
                    ci = chars.len;
                },
                'Z', '0' => opts.null_filename = true,
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
                'f' => {
                    const rest = chars[ci + 1 ..];
                    const value: []const u8 = if (rest.len > 0) rest else blk: {
                        i += 1;
                        if (i >= args.len) {
                            opts.fail = .{ .what = "option requires an argument", .arg = a };
                            return error.Usage;
                        }
                        break :blk args[i];
                    };
                    if (opts.pattern_files_count >= opts.pattern_files.len) {
                        opts.fail = .{ .what = "too many -f pattern files (max 16)", .arg = value };
                        return error.Usage;
                    }
                    opts.pattern_files[opts.pattern_files_count] = value;
                    opts.pattern_files_count += 1;
                    ci = chars.len;
                },
                'A' => {
                    const rest = chars[ci + 1 ..];
                    const value: []const u8 = if (rest.len > 0) rest else blk: {
                        i += 1;
                        if (i >= args.len) {
                            opts.fail = .{ .what = "option requires an argument", .arg = a };
                            return error.Usage;
                        }
                        break :blk args[i];
                    };
                    opts.after_context = try parseContextArg(opts, value, "bad value for -A");
                    ci = chars.len;
                },
                'B' => {
                    const rest = chars[ci + 1 ..];
                    const value: []const u8 = if (rest.len > 0) rest else blk: {
                        i += 1;
                        if (i >= args.len) {
                            opts.fail = .{ .what = "option requires an argument", .arg = a };
                            return error.Usage;
                        }
                        break :blk args[i];
                    };
                    opts.before_context = try parseContextArg(opts, value, "bad value for -B");
                    ci = chars.len;
                },
                'C' => {
                    const rest = chars[ci + 1 ..];
                    const value: []const u8 = if (rest.len > 0) rest else blk: {
                        i += 1;
                        if (i >= args.len) {
                            opts.fail = .{ .what = "option requires an argument", .arg = a };
                            return error.Usage;
                        }
                        break :blk args[i];
                    };
                    opts.before_context = try parseContextArg(opts, value, "bad value for -C");
                    opts.after_context = opts.before_context;
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

    if (opts.patterns_count > 0 or opts.pattern_files_count > 0) {
        // Patterns came from -e / --regexp / -f: all positionals are operands (paths).
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

/// Whether `--heading` actually turns the per-line path prefix into a header.
///
/// The header replaces a path that WOULD have been printed, so it is bound to
/// `show_path` and nothing else. It used to be `valid_operands.len > 1`, which
/// is a different question: `--heading` with a single directory operand
/// recursed into several files and printed no headers at all, while `-H` with
/// one file printed none either. `show_path` already encodes both rules.
///
/// Pinned by `test "headingOn follows show_path, not the operand count"`.
fn headingOn(heading: bool, show_path: bool) bool {
    return heading and show_path;
}

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

    // `--type-list` is an answer too: the registry, on stdout, exit 0.
    if (opts.print_type_list) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        types.writeList(&buf, gpa) catch {
            std.debug.print("zgrep: out of memory\n", .{});
            std.process.exit(2);
        };
        _ = platform.writeStdout(init.io, buf.items);
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

    // Patterns come from -e, from -f files, or from the first positional.
    // With -f an empty file means "select nothing", which `build` models with
    // the `.never` kind.
    var pattern_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer pattern_list.deinit(gpa);
    if (opts.patterns_count > 0 or opts.pattern_files_count > 0) {
        pattern_list.appendSlice(gpa, opts.patterns[0..opts.patterns_count]) catch return usage_error.Usage;
        for (opts.pattern_files[0..opts.pattern_files_count]) |pf| {
            readPatternFile(arena, init.io, pf, &pattern_list) catch |err| {
                if (!opts.no_messages) {
                    std.debug.print("zgrep: {s}: {s}\n", .{ pf, @errorName(err) });
                }
                std.process.exit(2);
            };
        }
    } else {
        pattern_list.append(gpa, pattern) catch return usage_error.Usage;
    }
    const patterns: []const []const u8 = pattern_list.items;
    for (patterns) |pp| {
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

    // `--exec` needs to know WHICH files matched, which only the ordered
    // path keeps; the streaming pipeline reports a single boolean. For v1 the
    // exec therefore runs on the sorted path, after the scan. This changes
    // nothing about the bytes read, only the order the commands run in.
    if (opts.exec_cmd != null and !opts.sort) opts.sort = true;
    // `--heading` groups by file, and the streaming path emits in completion
    // order: two files' groups would interleave and a header would point at
    // the wrong cluster. rg keeps the argument order, which is what --sort
    // reproduces.
    if (opts.heading and !opts.sort) opts.sort = true;
    // --pre also runs per file, so it needs the ordered path.
    if (opts.pre_cmd != null and !opts.sort) opts.sort = true;
    // find -exec has no normal output. The quiet early-exits below are what
    // make `-q` fast, but they would stop the scan at the FIRST match and the
    // command would never reach the other files, so they stay off with --exec.
    if (opts.exec_cmd != null) opts.mode = .quiet;

    const t0 = nowMonotonicNs(init.io);

    // `-S`: insensitive unless some pattern has an uppercase letter (rg rule).
    if (opts.smart_case and !opts.ignore_case) {
        var has_upper = false;
        for (patterns) |pat| {
            for (pat) |c| {
                if (c >= 'A' and c <= 'Z') has_upper = true;
                if (c >= 0xC0 and c <= 0xDE and c != 0xD7) has_upper = true; // Latin-1
                if (has_upper) break;
            }
            if (has_upper) break;
        }
        if (!has_upper) opts.ignore_case = true;
    }
    // `--binary-files=text` is exactly `-a`; `without-match` is the default.
    if (opts.binary_files == .text) opts.binary = true;

    const searcher = search.build(gpa, patterns, .{
        .algo = opts.algo,
        .fixed = opts.fixed,
        .icase = opts.ignore_case,
        .word = opts.word,
        .line = opts.line_regexp,
        .crlf = opts.crlf,
        .basic = opts.basic_regexp,
        .multiline = opts.multiline,
        .dotall = opts.multiline_dotall,
        .null_data = opts.null_data,
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
            .before_context = opts.before_context,
            .after_context = opts.after_context,
            .show_line_no = opts.show_line_no,
            .null_filename = opts.null_filename,
            .only_matching = opts.only_matching,
            .column = opts.column,
            .color = opts.color == .always,
            .replace = opts.replace,
            .passthru = opts.passthru,
            .byte_offset = opts.byte_offset,
            .crlf = opts.crlf,
            .heading = false, // stdin is a single stream: no header ever
            .vimgrep = opts.vimgrep,
            .null_data = opts.null_data,
            .multiline = opts.multiline,
            .stop_on_nonmatch = opts.stop_on_nonmatch,
            .encoding = scan.parseEncoding(opts.encoding) orelse .auto,
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
                try out.append(gpa, if (opts.null_filename) 0 else ':');
            }
            var num_buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&num_buf, "{d}\n", .{br.lines}) catch unreachable;
            try out.appendSlice(gpa, s);
        } else if (opts.mode == .files and br.matched) {
            try out.appendSlice(gpa, path_label);
            try out.append(gpa, if (opts.null_filename) 0 else '\n');
        } else if (opts.mode == .files_without_match and !br.matched) {
            try out.appendSlice(gpa, path_label);
            try out.append(gpa, if (opts.null_filename) 0 else '\n');
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
            if (!opts.no_messages) std.debug.print("zgrep: {s}: {s}\n", .{ op, @errorName(err) });
            had_error = true;
            continue;
        };
        if (info.kind != .directory and info.kind != .file) continue;
        try valid_operands.append(arena, op);
    }

    if (valid_operands.items.len == 0 and had_error) {
        std.process.exit(2);
    }

    // rg prints the header only with more than one input: with a single
    // file it would waste a line. The rule is about the FILES, not about the
    // operands: `zgrep --heading pat dir/` prints the header even when the
    // directory holds one file, because that is what rg does. The file list
    // is only known on the ordered path, and `--heading` forces it.
    // Output separator is per-run, not per-line.
    scan.out_sep = if (opts.null_data) 0 else '\n';

    // --- Kamikaze Scout & Streaming Dataflow Path (Default) ----------------
    if (!opts.sort) {
        var k_stats: kamikaze.KamikazeStats = .{};
    var engine_state: io_engine.State = .{};
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
        applyTypes(&filter_engine, &opts);
        // `--exclude-from` has to be loaded on THIS path too: the ordered path
        // did it and the streaming one did not, so the globs were silently
        // ignored unless `--sort` was passed.
        loadExcludeFrom(init.io, arena, &filter_engine, &opts);

        // The upward `.dataignore` / `.gitignore` walk is *not* done here: the
        // pipeline defers it until it knows the tree is too big for the
        // zero-thread micro-tree fast path.

        const scan_cfg = scan.ScanConfig{
            .invert = opts.invert_match,
            .max_count = opts.max_count,
            .before_context = opts.before_context,
            .after_context = opts.after_context,
            .show_line_no = opts.show_line_no,
            .null_filename = opts.null_filename,
            .only_matching = opts.only_matching,
            .column = opts.column,
            .color = opts.color == .always,
            .replace = opts.replace,
            .passthru = opts.passthru,
            .byte_offset = opts.byte_offset,
            .crlf = opts.crlf,
            // `--heading` forces the ordered path (see above), so it can never
            // be on here.
            .heading = false,
            .vimgrep = opts.vimgrep,
            .null_data = opts.null_data,
            .multiline = opts.multiline,
            .stop_on_nonmatch = opts.stop_on_nonmatch,
            .encoding = scan.parseEncoding(opts.encoding) orelse .auto,
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
            opts.io_engine_mode,
            &engine_state,
            opts.max_depth,
            opts.max_filesize,
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
                "kamikaze: dirs={d} files={d} bytes={d} matched_files={d} matched_lines={d} threads={d} micro_path={s} io_engine={s} probe_hits={d} probe_misses={d} elapsed_s={d:.4} throughput_MBps={d:.1}\n",
                .{
                    k_stats.dirs_scouted,
                    k_stats.files_scanned,
                    k_stats.bytes_scanned,
                    k_stats.matched_files,
                    k_stats.matched_lines,
                    worker_count,
                    if (k_stats.micro_path) "yes" else "no",
                    if (k_stats.micro_path) "micro" else if (k_stats.io_engine_uring) "uring" else "sync",
                    k_stats.probe_hits,
                    k_stats.probe_misses,
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
        applyTypes(&filter_engine, &opts);

    filter_engine.loadIgnoreFiles(init.io, valid_operands.items);
    loadExcludeFrom(init.io, arena, &filter_engine, &opts);

    var files: std.ArrayList([:0]const u8) = .empty;
    for (valid_operands.items) |op| {
        const info = vfs.statFile(init.io, op, .{}) catch |err| {
            if (!opts.no_messages) std.debug.print("zgrep: {s}: {s}\n", .{ op, @errorName(err) });
            had_error = true;
            continue;
        };
        if (info.kind == .directory) {
            walk.walk(init.io, arena, &.{op}, &files, &filter_engine, opts.nav_plan, opts.max_depth, opts.max_filesize) catch |err| {
                if (!opts.no_messages) std.debug.print("zgrep: {s}: {s}\n", .{ op, walkErrName(err) });
                had_error = true;
            };
        } else if (info.kind == .file) {
            files.append(arena, op) catch {
                if (!opts.no_messages) std.debug.print("zgrep: {s}: {s}\n", .{ op, eName(.NOMEM) });
                had_error = true;
            };
        }
    }

    // rg prints the path as a header line instead of a per-line prefix, and
    // only when the path would be printed AT ALL: one explicit file and no
    // `-H` means no path and therefore no header, while a directory (even
    // with a single file inside) or `-H` means a header. That is exactly the
    // `show_path` rule, so the header follows the path.
    const heading_on = headingOn(opts.heading, show_path);
    scan.heading_mode = heading_on;

    const slots: []Slot = try gpa.alloc(Slot, files.items.len);
    defer gpa.free(slots);
    for (slots) |*s| s.* = .{};

    // `--exec`: which files matched, so the command can run on them.
    var exec_matched: []bool = &.{};
    var exec_buf: []bool = &.{};
    defer if (exec_buf.len > 0) gpa.free(exec_buf);
    if (opts.exec_cmd) |_| {
        const allocd: ?[]bool = gpa.alloc(bool, files.items.len) catch null;
        if (allocd) |m| {
            @memset(m, false);
            exec_buf = m;
            exec_matched = m;
        }
    }

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
            .before_context = opts.before_context,
            .after_context = opts.after_context,
            .show_line_no = opts.show_line_no,
            .null_filename = opts.null_filename,
            .only_matching = opts.only_matching,
            .column = opts.column,
            .color = opts.color == .always,
            .replace = opts.replace,
            .passthru = opts.passthru,
            .byte_offset = opts.byte_offset,
            .crlf = opts.crlf,
            .heading = heading_on,
            .vimgrep = opts.vimgrep,
            .null_data = opts.null_data,
            .multiline = opts.multiline,
            .stop_on_nonmatch = opts.stop_on_nonmatch,
            .encoding = scan.parseEncoding(opts.encoding) orelse .auto,
        },
        .gpa = gpa,
        .window = window,
        .exec_mode = opts.exec_cmd != null,
        .pre_cmd = opts.pre_cmd orelse "",
        .pre_glob = opts.pre_glob orelse "",
        .arena = arena,
    };

    var out: Out = .{ .io = init.io };
    const main_scratch = gpa.alloc(u8, default_scratch_bytes) catch null;
    defer if (main_scratch) |s| gpa.free(s);

    // GNU grep and ripgrep separate disjoint context groups from different
    // files with a `--' line; keep that so context output is identical.
    const context_mode = opts.mode == .lines and (opts.before_context > 0 or opts.after_context > 0);
    var prev_emitted = false;

    if (!use_threads) {
        var idx: usize = 0;
        while (idx < files.items.len) : (idx += 1) {
            if (opts.mode == .quiet and opts.exec_cmd == null and ctx.found.load(.acquire)) break;
            scanOne(&ctx, idx, main_scratch);
            if (idx < exec_matched.len) exec_matched[idx] = slots[idx].matched;
            if (opts.mode != .quiet) {
                if (slots[idx].buf.items.len > 0) {
                    if (context_mode and prev_emitted) out.writeAll("--\n");
                    if (heading_on and prev_emitted) out.writeAll("\n");
                    out.writeAll(slots[idx].buf.items);
                    prev_emitted = true;
                }
                slots[idx].buf.deinit(gpa);
                slots[idx].buf = .empty;
            }
        }
        out.flush();
    } else {
        // -q probe: scan the first few files on this thread while nothing
        // else exists yet; a hit exits without ever spawning a worker.
        if (opts.mode == .quiet and opts.exec_cmd == null) {
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

        if (opts.mode == .quiet and opts.exec_cmd == null) {
            for (threads.items) |t| t.join();
        } else {
            // Emit in file order while workers run ahead, helping with the
            // work instead of idling.
            var w: usize = 0;
            var miss: usize = 0;
            while (w < slots.len) {
                if (slots[w].ready.load(.acquire)) {
                    if (w < exec_matched.len) exec_matched[w] = slots[w].matched;
                    if (slots[w].buf.items.len > 0) {
                        if (context_mode and prev_emitted) out.writeAll("--\n");
                        if (heading_on and prev_emitted) out.writeAll("\n");
                        out.writeAll(slots[w].buf.items);
                        prev_emitted = true;
                    }
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
                        if (idx < exec_matched.len) exec_matched[idx] = slots[idx].matched;
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

    // `--exec`: run the command on every file that matched. A non-zero child
    // exit is an error (grep's exit 2 slot), never a "no match".
    var exec_failed = false;
    if (opts.exec_cmd) |tmpl| {
        if (exec_matched.len > 0) {
            if (!runExecAll(init.io, gpa, files.items, exec_matched, tmpl, opts.no_messages)) {
                exec_failed = true;
            }
        }
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

    if (exec_failed) std.process.exit(2);
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
    // -z is --null-data now, so use an option that really does not exist.
    const a = [_][:0]const u8{ "zgrep", "-Q", "p", "d" };
    try std.testing.expectError(error.Usage, parseArgs(arena.allocator(), &a, &o));
    const f = o.fail orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("unrecognized option", f.what);
    try std.testing.expectEqualStrings("-Q", f.arg);
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

test "expandExecArgv: {} substitution and find -exec appending" {
    const gpa = std.testing.allocator;
    {
        const argv = expandExecArgv(gpa, "echo {}", "a.txt");
        try std.testing.expectEqual(@as(usize, 2), argv.len);
        try std.testing.expectEqualStrings("echo", argv.items[0]);
        try std.testing.expectEqualStrings("a.txt", argv.items[1]);
        gpa.free(argv.items[1]); // substituted tokens own their memory
    }
    {
        // no {}: the path is appended, like find -exec
        // sin {}: el path se ANADE al final (regresion: devolvia slice al
        // stack y llegaba vacio)
        const argv = expandExecArgv(gpa, "wc -l", "b.txt");
        try std.testing.expectEqual(@as(usize, 3), argv.len);
        try std.testing.expectEqualStrings("b.txt", argv.items[2]);
    }
    {
        // repeated spaces must not create empty arguments
        const argv = expandExecArgv(gpa, "cmd   arg   {}", "c.txt");
        try std.testing.expectEqual(@as(usize, 3), argv.len);
        try std.testing.expectEqualStrings("c.txt", argv.items[2]);
        gpa.free(argv.items[2]);
    }
}

test "parseArgs: --exec, --execute, -X" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--exec", "echo {}", "pat", "dir" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqualStrings("echo {}", o.exec_cmd.?);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--execute=echo {}", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqualStrings("echo {}", o.exec_cmd.?);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-X", "echo {}", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqualStrings("echo {}", o.exec_cmd.?);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--exec" };
        try std.testing.expectError(error.Usage, parseArgs(alloc, &a, &o));
    }
}

test "parseArgs: -S, -t/-T/--type-list, --binary-files, --exclude-from, --max-depth, --max-filesize, -b" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-S", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.smart_case);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--smart-case", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.smart_case);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-t", "py", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(usize, 1), o.type_include_count);
        try std.testing.expectEqualStrings("py", o.type_include[0].name);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-tpy", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(usize, 1), o.type_include_count);
        try std.testing.expectEqualStrings("py", o.type_include[0].name);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--type=md", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(usize, 1), o.type_include_count);
        try std.testing.expectEqualStrings("md", o.type_include[0].name);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--type-not=py", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(usize, 1), o.type_exclude_count);
        try std.testing.expectEqualStrings("py", o.type_exclude[0].name);
    }
    // un tipo desconocido es error de uso, no un silencio
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-t", "cobol", "pat" };
        try std.testing.expectError(error.Usage, parseArgs(alloc, &a, &o));
        const f = o.fail orelse return error.TestExpectedEqual;
        try std.testing.expectEqualStrings("unknown type name (see --type-list)", f.what);
    }
    // --type-list es una respuesta: corta el parseo como --help
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--type-list" };
        const r = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.print_type_list);
        try std.testing.expectEqual(@as(usize, 0), r.operands.len);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--max-filesize", "2M", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), o.max_filesize);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--max-filesize=512k", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(usize, 512 * 1024), o.max_filesize);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--max-filesize=1G", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(usize, 1024 * 1024 * 1024), o.max_filesize);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--max-filesize=+10K", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(usize, 10 * 1024), o.max_filesize);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--max-filesize=nope", "pat" };
        try std.testing.expectError(error.Usage, parseArgs(alloc, &a, &o));
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--max-depth=3", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(usize, 3), o.max_depth);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--max-depth", "2", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(usize, 2), o.max_depth);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-b", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.byte_offset);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--binary-files=text", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(BinaryFiles.text, o.binary_files);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--binary-files=binary", "pat" };
        try std.testing.expectError(error.Usage, parseArgs(alloc, &a, &o));
        const f = o.fail orelse return error.TestExpectedEqual;
        try std.testing.expect(std.mem.indexOf(u8, f.what, "never prints binary content") != null);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--exclude-from=globs.txt", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(usize, 1), o.exclude_from_count);
        try std.testing.expectEqualStrings("globs.txt", o.exclude_from[0]);
    }
}

test "parseArgs: -U, --multiline, --multiline-dotall, --stop-on-nonmatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-U", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.multiline);
        try std.testing.expect(!o.multiline_dotall);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--multiline", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.multiline);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--multiline-dotall", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.multiline);
        try std.testing.expect(o.multiline_dotall);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--no-multiline", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(!o.multiline);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--stop-on-nonmatch", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.stop_on_nonmatch);
    }
}

test "parseArgs: -x, -f, -s, --no-line-number, -Z/-0, -A/-B/-C" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-x", "pat", "dir" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.line_regexp);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--line-regexp", "cat", "dir" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.line_regexp);
    }
    // -f consumes no positional: the pattern comes from the file.
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-f", "pats.txt", "dir" };
        const r = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(usize, 1), o.pattern_files_count);
        try std.testing.expectEqualStrings("pats.txt", o.pattern_files[0]);
        try std.testing.expectEqual(@as(usize, 0), o.patterns_count);
        try std.testing.expectEqual(@as(usize, 1), r.operands.len);
        try std.testing.expectEqualStrings("dir", r.operands[0]);
    }
    // -e together with -f: both, and every positional is a path.
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-e", "one", "-f", "pats.txt", "f1", "f2" };
        const r = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(usize, 1), o.patterns_count);
        try std.testing.expectEqual(@as(usize, 1), o.pattern_files_count);
        try std.testing.expectEqual(@as(usize, 2), r.operands.len);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-s", "pat", "dir" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.no_messages);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--no-messages", "pat", "dir" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.no_messages);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--no-line-number", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(!o.show_line_no);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-Z", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.null_filename);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-0", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.null_filename);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--null", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.null_filename);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-A3", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(usize, 3), o.after_context);
        try std.testing.expectEqual(@as(usize, 0), o.before_context);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-B", "2", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(usize, 2), o.before_context);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-C4", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(usize, 4), o.before_context);
        try std.testing.expectEqual(@as(usize, 4), o.after_context);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--context=5", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(usize, 5), o.before_context);
        try std.testing.expectEqual(@as(usize, 5), o.after_context);
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--after-context", "2", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expectEqual(@as(usize, 2), o.after_context);
    }
    // clustered with the new flags
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-nxA2", "pat" };
        _ = try parseArgs(alloc, &a, &o);
        try std.testing.expect(o.line_regexp);
        try std.testing.expect(o.show_line_no);
        try std.testing.expectEqual(@as(usize, 2), o.after_context);
    }
    // a non-numeric context is a usage error, not a silent zero
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "--context=x", "pat" };
        try std.testing.expectError(error.Usage, parseArgs(alloc, &a, &o));
    }
    {
        var o: Options = .{};
        const a = [_][:0]const u8{ "zgrep", "-A" };
        try std.testing.expectError(error.Usage, parseArgs(alloc, &a, &o));
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

test "headingOn follows show_path, not the operand count" {
    // `--heading` turns the per-line path prefix into a header line. It only
    // makes sense where a prefix WOULD be printed, so it is `heading and
    // show_path` and nothing else.
    //
    // The regression this pins: the rule used to be `valid_operands.len > 1`.
    // One directory operand recurses into many files, so rg/zigrep must print
    // headers; with the operand count it printed none. The opposite case (a
    // single `-H` file) has show_path = true and must print a header.
    try std.testing.expect(headingOn(true, true));
    // One explicit file, no -H: no prefix, so a header would be noise (rg
    // behaves the same way).
    try std.testing.expect(!headingOn(true, false));
    // No --heading: show_path only controls the per-line prefix.
    try std.testing.expect(!headingOn(false, true));
    try std.testing.expect(!headingOn(false, false));

    // The three shapes main() derives show_path from, spelled out so the
    // coupling is explicit rather than implied by a comment.
    try std.testing.expect(headingOn(true, true)); // one DIRECTORY operand
    try std.testing.expect(headingOn(true, true)); // -H with one file
    try std.testing.expect(!headingOn(true, false)); // one file, no -H
}
