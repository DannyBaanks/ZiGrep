//! File scanning: open → size → mmap (read fallback) → binary probe →
//! match → `path:line:text` emission.
//!
//! Line tracking is incremental and never rescans the buffer: `line_start` and
//! `line_no` only move forward, and each emitted line is skipped past in one
//! step (`pos = line_end + 1`), so the whole file is walked a constant number
//! of times regardless of how many lines match.
//!
//! After a match on a line the scan resumes at the *next* line. That is
//! exactly grep semantics: one output line per matching line, not one per
//! occurrence.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const Searcher = @import("search.zig").Searcher;
const Match = @import("search.zig").Match;
const io_engine = @import("io_engine.zig");

pub const Mode = enum {
    /// `path:line:text`
    lines,
    /// `path:count` for every scanned file (grep `-c` behaviour).
    count,
    /// `path:count` where count is the number of MATCHES (rg `--count-matches`).
    count_matches,
    /// `path` for files with at least one match.
    files,
    /// `path` for files with NO matches (-L behaviour).
    files_without_match,
    /// No output at all; exit status only.
    quiet,
};

pub const ScanConfig = struct {
    invert: bool = false,
    max_count: ?usize = null,
    /// Lines of context before/after a selected line (`-A` / `-B` / `-C`).
    before_context: usize = 0,
    after_context: usize = 0,
    /// Print the line-number prefix (default on, like GNU grep -n).
    show_line_no: bool = true,
    /// `-Z`: terminate file names with NUL instead of ':' / newline.
    null_filename: bool = false,
    /// `-o`: one output line per (non-empty) match instead of per line.
    only_matching: bool = false,
    /// `--column`: print the 1-based byte column of the first match.
    column: bool = false,
    /// `--color=always`: highlight the match spans.
    color: bool = false,
    /// `-r REPLACEMENT` (rg): emit the matches with the replacement text.
    replace: ?[]const u8 = null,
    /// `--passthru` with `-r`: also print the lines that do not match.
    passthru: bool = false,
    /// `-b`: prefix each line with its byte offset in the file (grep).
    byte_offset: bool = false,

    /// True when the emission needs the match spans, so the fast
    /// "jump to the next match" path cannot be used.
    pub fn needs_spans(self: ScanConfig) bool {
        return self.only_matching or self.column or self.color or self.replace != null or self.passthru;
    }
};

/// NUL probe window used to decide a file is binary, aligned with GNU grep's
/// first-block check and ripgrep's default heuristic.
pub const binary_probe_bytes = 8192;

/// Checks for UTF-16 Byte Order Marks (BOM):
/// 0xFF 0xFE = Little-Endian, 0xFE 0xFF = Big-Endian.
pub fn isUtf16Bom(bytes: []const u8) ?enum { le, be } {
    if (bytes.len < 2) return null;
    if (bytes[0] == 0xFF and bytes[1] == 0xFE) return .le;
    if (bytes[0] == 0xFE and bytes[1] == 0xFF) return .be;
    return null;
}

/// Decodes UTF-16 text to UTF-8 without treating it as binary.
pub fn decodeUtf16ToUtf8(gpa: Allocator, raw: []const u8, is_le: bool) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 2; // skip 2-byte BOM
    while (i + 1 < raw.len) : (i += 2) {
        const u = if (is_le)
            @as(u16, raw[i]) | (@as(u16, raw[i + 1]) << 8)
        else
            @as(u16, raw[i + 1]) | (@as(u16, raw[i]) << 8);
        if (u < 0x80) {
            try out.append(gpa, @intCast(u));
        } else {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(u), &buf) catch 0;
            if (len > 0) try out.appendSlice(gpa, buf[0..len]);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// mmap below this size is rarely a win over a plain read; the read path
/// exists mainly as a fallback for mappings the kernel refuses.
pub const mmap_threshold = 256 * 1024;

pub const FileScan = struct {
    matched: bool = false,
    lines: usize = 0,
    /// Matches, not lines (only filled when `--count-matches` is on).
    matches: usize = 0,
    /// Bytes actually searched (excludes binary skips and failures).
    bytes: usize = 0,
    err: ?linux.E = null,
};

pub const BufferResult = struct {
    matched: bool = false,
    lines: usize = 0,
    /// Matches, not lines: only filled when `--count-matches` is on.
    matches: usize = 0,
};

fn appendDecimal(out: *std.ArrayList(u8), gpa: Allocator, value: usize) Allocator.Error!void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    try out.appendSlice(gpa, s);
}

fn emitLine(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    path: []const u8,
    show_path: bool,
    show_line_no: bool,
    sep: u8,
    line_no: usize,
    text: []const u8,
    null_filename: bool,
    byte_offset: ?usize,
) Allocator.Error!void {
    const path_extra: usize = if (show_path) path.len + 1 else 0;
    const line_extra: usize = if (show_line_no) 24 else 0;
    const off_extra: usize = if (byte_offset) |_| 24 else 0;
    const needed = path_extra + line_extra + off_extra + 1 + text.len + 1;
    try out.ensureUnusedCapacity(gpa, needed);

    if (show_path) {
        out.appendSliceAssumeCapacity(path);
        out.appendAssumeCapacity(if (null_filename) 0 else sep);
    }
    if (show_line_no) {
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{line_no}) catch unreachable;
        out.appendSliceAssumeCapacity(s);
        out.appendAssumeCapacity(sep);
    }
    if (byte_offset) |bo| {
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{bo}) catch unreachable;
        out.appendSliceAssumeCapacity(s);
        out.appendAssumeCapacity(sep);
    }
    out.appendSliceAssumeCapacity(text);
    out.appendAssumeCapacity('\n');
}

const color_off = "\x1b[0m";
const color_match = "\x1b[01;31m";
const color_lineno = "\x1b[32m";

/// Shared `path<sep>line<sep>` prefix. `colored` wraps the line number the way
/// GNU grep does (green); `sep` is ':' for a match and '-' for context.
fn emitPrefix(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    path: []const u8,
    show_path: bool,
    show_line_no: bool,
    sep: u8,
    line_no: usize,
    null_filename: bool,
    colored: bool,
    byte_offset: ?usize,
) Allocator.Error!void {
    if (show_path) {
        try out.appendSlice(gpa, path);
        try out.append(gpa, if (null_filename) 0 else sep);
    }
    if (show_line_no) {
        if (colored) try out.appendSlice(gpa, color_lineno);
        var buf: [24]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "{d}", .{line_no}) catch unreachable;
        try out.appendSlice(gpa, t);
        if (colored) try out.appendSlice(gpa, color_off);
        try out.append(gpa, sep);
    }
    // `-b`: the offset goes after the line number and before the text, which
    // is where grep puts it.
    if (byte_offset) |bo| {
        var buf: [24]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "{d}", .{bo}) catch unreachable;
        try out.appendSlice(gpa, t);
        try out.append(gpa, sep);
    }
}

/// One output line per non-empty match (`grep -o`, `rg -r REPLACEMENT`).
/// Zero-width matches are dropped, exactly like grep -o.
fn emitMatches(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    searcher: *const Searcher,
    cfg: ScanConfig,
    path: []const u8,
    show_path: bool,
    line_no: usize,
    line_start: usize,
    line: []const u8,
) Allocator.Error!void {
    var from: usize = 0;
    while (from <= line.len) {
        const m = searcher.matchSpan(line, from) orelse break;
        if (m.end > m.start) {
            // `-b -o`: grep prints the offset of the MATCH, absolute in the
            // file, so it is line_start + m.start.
            const off: ?usize = if (cfg.byte_offset) line_start + m.start else null;
            try emitPrefix(out, gpa, path, show_path, cfg.show_line_no, ':', line_no, cfg.null_filename, cfg.color, off);
            try out.appendSlice(gpa, if (cfg.replace) |rep| rep else line[m.start..m.end]);
            try out.append(gpa, '\n');
        }
        from = if (m.end == m.start) m.start + 1 else m.end;
    }
}

/// The whole line, optionally with `--column` after the line number and the
/// match spans highlighted (`--color`).
fn emitLineSpanned(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    searcher: *const Searcher,
    cfg: ScanConfig,
    path: []const u8,
    show_path: bool,
    line_no: usize,
    line: []const u8,
) Allocator.Error!void {
    var first: ?Match = null;
    if (cfg.column) first = searcher.matchSpan(line, 0);
    if (show_path) {
        try out.appendSlice(gpa, path);
        try out.append(gpa, if (cfg.null_filename) 0 else ':');
    }
    if (cfg.show_line_no) {
        if (cfg.color) try out.appendSlice(gpa, color_lineno);
        var buf: [24]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "{d}", .{line_no}) catch unreachable;
        try out.appendSlice(gpa, t);
        if (cfg.color) try out.appendSlice(gpa, color_off);
        try out.append(gpa, ':');
    }
    if (first) |m| {
        var cbuf: [24]u8 = undefined;
        const c = std.fmt.bufPrint(&cbuf, "{d}:", .{m.start + 1}) catch unreachable;
        try out.appendSlice(gpa, c);
    }
    if (!cfg.color) {
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
        return;
    }
    var from: usize = 0;
    while (from < line.len) {
        const m = searcher.matchSpan(line, from) orelse break;
        if (m.end == m.start) {
            from = m.start + 1;
            continue;
        }
        try out.appendSlice(gpa, line[from..m.start]);
        try out.appendSlice(gpa, color_match);
        try out.appendSlice(gpa, line[m.start..m.end]);
        try out.appendSlice(gpa, color_off);
        from = m.end;
    }
    try out.appendSlice(gpa, line[from..]);
    try out.append(gpa, '\n');
}

const LineRef = struct { start: usize, end: usize, no: usize };

/// Ordered line scan used by `-v` and by `-A`/`-B`/`-C`. The jump-to-next-match
/// path in `scanBuffer` cannot see the lines between matches, so context needs
/// this loop; it also keeps one output line per selected line (grep semantics).
fn scanBufferLines(
    gpa: Allocator,
    data: []const u8,
    searcher: *const Searcher,
    path: []const u8,
    show_path: bool,
    mode: Mode,
    config: ScanConfig,
    out: *std.ArrayList(u8),
) Allocator.Error!BufferResult {
    var res: BufferResult = .{};

    var ring: []LineRef = &.{};
    if (config.before_context > 0) {
        ring = try gpa.alloc(LineRef, config.before_context);
    }
    defer if (ring.len > 0) gpa.free(ring);
    var ring_len: usize = 0;
    var ring_pos: usize = 0;

    // Group separators only exist with context enabled: without `-A/-B/-C`
    // the old ordered path printed nothing but matching lines.
    const context_enabled = config.before_context > 0 or config.after_context > 0;
    const spans = config.needs_spans();

    var line_start: usize = 0;
    var line_no: usize = 1;
    var last_printed: usize = 0;
    var printed_any = false;
    var after_left: usize = 0;
    var maxed = false;

    while (line_start < data.len) {
        const line_end = std.mem.findScalarPos(u8, data, line_start, '\n') orelse data.len;
        const line_slice = data[line_start..line_end];
        const has_match = searcher.find(line_slice, 0) != null;
        const selected = if (config.invert) !has_match else has_match;

        if (selected and !maxed) {
            res.matched = true;
            res.lines += 1;
            if (mode == .quiet or mode == .files or mode == .files_without_match) return res;

            if (mode == .count_matches) {
                var from: usize = 0;
                while (from <= line_slice.len) {
                    const m = searcher.matchSpan(line_slice, from) orelse break;
                    if (m.end > m.start) res.matches += 1;
                    from = if (m.end == m.start) m.start + 1 else m.end;
                }
            }

            if (mode == .lines) {
                if (spans and (config.only_matching or config.replace != null)) {
                    // `grep -o -v` prints nothing: -o describes the matches of
                    // a selected line, and with -v there are none.
                    if (!config.invert) {
                        try emitMatches(out, gpa, searcher, config, path, show_path, line_no, line_start, line_slice);
                    }
                } else if (spans) {
                    try emitLineSpanned(out, gpa, searcher, config, path, show_path, line_no, line_slice);
                } else {
                    if (ring.len > 0 and ring_len > 0) {
                        const first = if (line_no > config.before_context) line_no - config.before_context else 1;
                        var k: usize = 0;
                        while (k < ring_len) : (k += 1) {
                            const at = (ring_pos + ring.len - ring_len + k) % ring.len;
                            const ref = ring[at];
                            if (ref.no < first or ref.no <= last_printed) continue;
                            if (context_enabled and printed_any and ref.no > last_printed + 1) try out.appendSlice(gpa, "--\n");
                            try emitLine(out, gpa, path, show_path, config.show_line_no, '-', ref.no, data[ref.start..ref.end], config.null_filename, if (config.byte_offset) ref.start else null);
                            last_printed = ref.no;
                            printed_any = true;
                        }
                    }
                    if (context_enabled and printed_any and line_no > last_printed + 1) try out.appendSlice(gpa, "--\n");
                    try emitLine(out, gpa, path, show_path, config.show_line_no, ':', line_no, line_slice, config.null_filename, if (config.byte_offset) line_start else null);
                    last_printed = line_no;
                    printed_any = true;
                }
            }

            after_left = if (mode == .lines) config.after_context else 0;
            if (config.max_count) |mc| {
                if (res.lines >= mc) maxed = true;
            }
        } else if (config.passthru and mode == .lines and !selected) {
            // --passthru prints the non-matching lines untouched; with -r the
            // matches of the matching lines were already substituted above.
            if (!spans) {
                try emitLine(out, gpa, path, show_path, config.show_line_no, ':', line_no, line_slice, config.null_filename, if (config.byte_offset) line_start else null);
            } else {
                try emitLineSpanned(out, gpa, searcher, config, path, show_path, line_no, line_slice);
            }
        } else if (mode == .lines and after_left > 0 and line_no > last_printed) {
            if (context_enabled and printed_any and line_no > last_printed + 1) try out.appendSlice(gpa, "--\n");
            try emitLine(out, gpa, path, show_path, config.show_line_no, '-', line_no, line_slice, config.null_filename, if (config.byte_offset) line_start else null);
            last_printed = line_no;
            printed_any = true;
            after_left -= 1;
        } else if (maxed and after_left == 0) {
            break;
        }

        if (ring.len > 0) {
            ring[ring_pos] = .{ .start = line_start, .end = line_end, .no = line_no };
            ring_pos = (ring_pos + 1) % ring.len;
            if (ring_len < ring.len) ring_len += 1;
        }

        if (line_end >= data.len) break;
        line_start = line_end + 1;
        line_no += 1;
    }

    return res;
}

/// Searches one in-memory buffer and, in `lines` mode, appends the matching
/// lines to `out`. Separated from the syscall layer so it can be unit tested
/// against known ground truth without touching the filesystem.
pub fn scanBuffer(
    gpa: Allocator,
    data: []const u8,
    searcher: *const Searcher,
    path: []const u8,
    show_path: bool,
    mode: Mode,
    config: ScanConfig,
    out: *std.ArrayList(u8),
) Allocator.Error!BufferResult {
    var res: BufferResult = .{};

    if (data.len == 0) {
        return res;
    }

    if (config.max_count != null and config.max_count.? == 0) {
        return res;
    }

    // Inverted matching and/or line context both need every line in order;
    // the jump-to-next-match fast path below cannot provide context.
    if (config.invert or config.before_context > 0 or config.after_context > 0 or config.needs_spans()) {
        return scanBufferLines(gpa, data, searcher, path, show_path, mode, config, out);
    }

    // Early-exit optimization for files (-l, -L) and quiet (-q) modes:
    // Once any match is found, we don't need to scan remaining lines.
    if (config.max_count == null and (mode == .quiet or mode == .files or mode == .files_without_match)) {
        if (searcher.find(data, 0) != null) {
            res.matched = true;
            res.lines = 1;
        }
        return res;
    }

    var line_start: usize = 0;
    var line_no: usize = 1;
    var pos: usize = 0;

    // `pos < data.len` (rather than `true`) is what stops an empty pattern
    // from inventing a phantom line after a trailing newline.
    while (pos < data.len) {
        const m = searcher.find(data, pos) orelse break;
        // Advance the line cursor to the line that contains the match.
        while (true) {
            const nl = std.mem.findScalarPos(u8, data, line_start, '\n') orelse break;
            if (nl >= m) break;
            line_start = nl + 1;
            line_no += 1;
        }
        const line_end = std.mem.findScalarPos(u8, data, m, '\n') orelse data.len;

        res.matched = true;
        res.lines += 1;
        if (mode == .lines) {
            try emitLine(out, gpa, path, show_path, config.show_line_no, ':', line_no, data[line_start..line_end], config.null_filename, if (config.byte_offset) line_start else null);
        }
        if (config.max_count) |mc| {
            if (res.lines >= mc) break;
        }

        if (line_end >= data.len) break;
        // Skip the remainder of this line: grep reports a line once.
        pos = line_end + 1;
        line_start = line_end + 1;
        line_no += 1;
    }
    return res;
}

const map_failed: usize = @bitCast(@as(isize, -1));

/// Scans a single file. Never returns `error`; failures are reported through
/// `FileScan.err` so one unreadable file cannot abort a whole run.
///
/// An optional `scratch` buffer (e.g. 128 KB) enables zero-allocation reads for
/// small/medium files, completely avoiding allocator mutex lock contention.
///
/// `probe_state` solo llega con `--io-engine=auto`: mientras la muestra siga
/// abierta, la primera lectura del fichero se intenta con
/// `preadv2(RWF_NOWAIT)` y, si devuelve bytes, se escanean (la sonda y la
/// lectura son la misma). Con `sync`/`uring` o fuera de Linux llega `null` y
/// el camino es exactamente el de siempre.
pub fn scanFile(
    io: std.Io,
    gpa: Allocator,
    searcher: *const Searcher,
    path: [:0]const u8,
    show_path: bool,
    mode: Mode,
    binary: bool,
    config: ScanConfig,
    out: *std.ArrayList(u8),
    scratch: ?[]u8,
    probe_state: ?*io_engine.State,
) FileScan {
    if (builtin.os.tag == .linux) {
        return scanFileLinux(gpa, searcher, path, show_path, mode, binary, config, out, scratch, probe_state);
    }
    return scanFilePortable(io, gpa, searcher, path, show_path, mode, binary, config, out, scratch, probe_state);
}

fn scanFilePortable(
    io: std.Io,
    gpa: Allocator,
    searcher: *const Searcher,
    path: [:0]const u8,
    show_path: bool,
    mode: Mode,
    binary: bool,
    config: ScanConfig,
    out: *std.ArrayList(u8),
    scratch: ?[]u8,
    probe_state: ?*io_engine.State,
) FileScan {
    // `preadv2(RWF_NOWAIT)` es de Linux; fuera de Linux no hay sonda que
    // fusionar y el modo `auto` degrada a síncrono sin más.
    _ = probe_state;
    var res: FileScan = .{};
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        res.err = mapIoError(err);
        return res;
    };
    defer file.close(io);

    const stat = file.stat(io) catch |err| {
        res.err = mapIoError(err);
        return res;
    };
    const size = std.math.cast(usize, stat.size) orelse {
        res.err = .FBIG;
        return res;
    };
    if (size == 0) {
        if (emitOncePerFile(out, gpa, path, show_path, mode, res, config.null_filename)) |err| res.err = err;
        return res;
    }

    if (scratch) |buffer| {
        if (size < buffer.len) {
            const read = file.readPositionalAll(io, buffer[0..size], 0) catch |err| {
                res.err = mapIoError(err);
                return res;
            };
            if (read != size) {
                res.err = .IO;
                return res;
            }
            processBuffer(gpa, searcher, buffer[0..read], path, show_path, mode, binary, config, out, &res);
            if (emitOncePerFile(out, gpa, path, show_path, mode, res, config.null_filename)) |err| res.err = err;
            return res;
        }
    }

    if (size >= mmap_threshold) {
        if (std.Io.File.MemoryMap.create(io, file, .{
            .len = size,
            .protection = .{ .read = true, .write = false },
        })) |map_value| {
            var map = map_value;
            defer map.destroy(io);
            processBuffer(gpa, searcher, map.memory, path, show_path, mode, binary, config, out, &res);
            if (emitOncePerFile(out, gpa, path, show_path, mode, res, config.null_filename)) |err| res.err = err;
            return res;
        } else |_| {}
    }

    const data = gpa.alloc(u8, size) catch {
        res.err = .NOMEM;
        return res;
    };
    defer gpa.free(data);
    const read = file.readPositionalAll(io, data, 0) catch |err| {
        res.err = mapIoError(err);
        return res;
    };
    if (read != size) {
        res.err = .IO;
        return res;
    }
    processBuffer(gpa, searcher, data, path, show_path, mode, binary, config, out, &res);
    if (emitOncePerFile(out, gpa, path, show_path, mode, res, config.null_filename)) |err| res.err = err;
    return res;
}

fn processBuffer(
    gpa: Allocator,
    searcher: *const Searcher,
    data: []const u8,
    path: []const u8,
    show_path: bool,
    mode: Mode,
    binary: bool,
    config: ScanConfig,
    out: *std.ArrayList(u8),
    res: *FileScan,
) void {
    const probe = @min(data.len, binary_probe_bytes);
    const utf16_bom = isUtf16Bom(data);
    const is_binary = !binary and utf16_bom == null and std.mem.findScalar(u8, data[0..probe], 0) != null;
    if (is_binary) return;

    if (utf16_bom) |bom| {
        const decoded = decodeUtf16ToUtf8(gpa, data, bom == .le) catch {
            res.err = .NOMEM;
            return;
        };
        defer gpa.free(decoded);
        const match = scanBuffer(gpa, decoded, searcher, path, show_path, mode, config, out) catch {
            res.err = .NOMEM;
            return;
        };
        res.matched = match.matched;
        res.lines = match.lines;
        res.matches = match.matches;
        res.bytes = data.len;
        return;
    }

    const match = scanBuffer(gpa, data, searcher, path, show_path, mode, config, out) catch {
        res.err = .NOMEM;
        return;
    };
    res.matched = match.matched;
    res.lines = match.lines;
    res.bytes = data.len;
}

fn mapIoError(err: anyerror) linux.E {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => .ACCES,
        error.FileNotFound => .NOENT,
        error.IsDir => .ISDIR,
        error.SystemResources => .NOMEM,
        else => .IO,
    };
}

fn scanFileLinux(
    gpa: Allocator,
    searcher: *const Searcher,
    path: [:0]const u8,
    show_path: bool,
    mode: Mode,
    binary: bool,
    config: ScanConfig,
    out: *std.ArrayList(u8),
    scratch: ?[]u8,
    probe_state: ?*io_engine.State,
) FileScan {
    var res: FileScan = .{};

    const rc = linux.openat(linux.AT.FDCWD, path, .{ .CLOEXEC = true }, 0);
    const open_err = linux.errno(rc);
    if (open_err != .SUCCESS) {
        res.err = open_err;
        return res;
    }
    const fd: i32 = @intCast(@as(isize, @bitCast(rc)));
    defer _ = linux.close(fd);

    // Fast-path: read directly into scratch buffer if provided (no lseek, no heap alloc, no mutex).
    if (scratch) |sbuf| {
        var got: usize = 0;
        var read_err: ?linux.E = null;

        // Motor híbrido, rebanada 2: mientras el modo `auto` no haya decidido,
        // la primera lectura ES la sonda. En caliente `preadv2` devuelve los
        // bytes del fichero y se escanean tal cual (antes se tiraban y el
        // fichero se volvía a leer: dos copias del mismo trozo). En frío el
        // EAGAIN cuesta 2,3 µs y la lectura de abajo hace el trabajo normal.
        if (probe_state) |st| {
            if (st.armed()) {
                const p = io_engine.probe(fd, sbuf);
                switch (p) {
                    .cached => |n| {
                        got = n;
                        // `preadv2` no mueve el offset del fd: hay que dejarlo
                        // donde terminó la sonda o la lectura de abajo
                        // repetiría los primeros bytes.
                        if (n > 0) _ = linux.lseek(fd, @intCast(n), linux.SEEK.SET);
                    },
                    .cold, .unsupported => {},
                }
                _ = st.record(p);
            }
        }

        while (got < sbuf.len) {
            const rr = linux.read(fd, sbuf.ptr + got, sbuf.len - got);
            const e = linux.errno(rr);
            if (e == .INTR) continue;
            if (e != .SUCCESS) {
                read_err = e;
                break;
            }
            if (rr == 0) break; // EOF reached!
            got += rr;
        }

        if (read_err) |e| {
            res.err = e;
            return res;
        }

        // Did the entire file fit in the scratch buffer?
        if (got < sbuf.len) {
            if (got == 0) {
                if (emitOncePerFile(out, gpa, path, show_path, mode, res, config.null_filename)) |e| res.err = e;
                return res;
            }
            const data = sbuf[0..got];
            const probe = @min(data.len, binary_probe_bytes);
            const utf16_bom = isUtf16Bom(data);
            const is_binary = !binary and utf16_bom == null and std.mem.findScalar(u8, data[0..probe], 0) != null;
            if (!is_binary) {
                if (utf16_bom) |bom| {
                    if (decodeUtf16ToUtf8(gpa, data, bom == .le)) |decoded| {
                        defer gpa.free(decoded);
                        const br = scanBuffer(gpa, decoded, searcher, path, show_path, mode, config, out) catch {
                            res.err = .NOMEM;
                            return res;
                        };
                        res.matched = br.matched;
                        res.lines = br.lines;
                    res.matches = br.matches;
                        res.matches = br.matches;
                        res.bytes = data.len;
                    } else |_| {}
                } else {
                    const br = scanBuffer(gpa, data, searcher, path, show_path, mode, config, out) catch {
                        res.err = .NOMEM;
                        return res;
                    };
                    res.matched = br.matched;
                    res.lines = br.lines;
                    res.matches = br.matches;
                    res.bytes = data.len;
                }
            }
            if (emitOncePerFile(out, gpa, path, show_path, mode, res, config.null_filename)) |e| res.err = e;
            return res;
        }
        // File >= sbuf.len: rewind to 0 for mmap/read fallback.
        _ = linux.lseek(fd, 0, linux.SEEK.SET);
    }

    const szr = linux.lseek(fd, 0, linux.SEEK.END);
    const sz_err = linux.errno(szr);
    if (sz_err != .SUCCESS) {
        res.err = sz_err;
        return res;
    }
    const size: usize = @intCast(@as(isize, @bitCast(szr)));
    _ = linux.lseek(fd, 0, linux.SEEK.SET);
    if (size == 0) {
        if (emitOncePerFile(out, gpa, path, show_path, mode, res, config.null_filename)) |e| res.err = e;
        return res;
    }

    // --- obtain a readable view of the whole file -------------------------
    var data: []const u8 = &.{};
    var mapped = false;
    var owned: ?[]u8 = null;

    if (size < mmap_threshold) {
        // Small file: one bounded read beats mmap's page-fault setup.
        const buf = gpa.alloc(u8, size) catch {
            res.err = .NOMEM;
            return res;
        };
        owned = buf;
        if (readFully(fd, buf)) |e| {
            gpa.free(buf);
            res.err = e;
            return res;
        }
        data = buf;
    } else {
        const mrc = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
        if (mrc != map_failed) {
            data = @as([*]align(1) const u8, @ptrFromInt(mrc))[0..size];
            mapped = true;
        } else {
            const buf = gpa.alloc(u8, size) catch {
                res.err = .NOMEM;
                return res;
            };
            owned = buf;
            if (readFully(fd, buf)) |e| {
                gpa.free(buf);
                res.err = e;
                return res;
            }
            data = buf;
        }
    }
    defer {
        if (mapped) {
            _ = linux.munmap(@ptrCast(data.ptr), data.len);
        } else if (owned) |b| {
            gpa.free(b);
        }
    }

    // --- binary probe ------------------------------------------------------
    // `-a` disables it; otherwise a NUL in the first block means the file is
    // skipped entirely (grep `-I`, ripgrep default).
    const probe = @min(data.len, binary_probe_bytes);
    const utf16_bom = isUtf16Bom(data);
    const is_binary = !binary and utf16_bom == null and std.mem.findScalar(u8, data[0..probe], 0) != null;
    if (!is_binary) {
        if (utf16_bom) |bom| {
            if (decodeUtf16ToUtf8(gpa, data, bom == .le)) |decoded| {
                defer gpa.free(decoded);
                const br = scanBuffer(gpa, decoded, searcher, path, show_path, mode, config, out) catch {
                    res.err = .NOMEM;
                    return res;
                };
                res.matched = br.matched;
                res.lines = br.lines;
                res.bytes = data.len;
            } else |_| {}
        } else {
            const br = scanBuffer(gpa, data, searcher, path, show_path, mode, config, out) catch {
                res.err = .NOMEM;
                return res;
            };
            res.matched = br.matched;
            res.lines = br.lines;
            res.bytes = data.len;
        }
    }

    // --- modes that emit once per file ------------------------------------
    // `-c` reports every scanned file, including binary-skipped ones as 0,
    // which is what `grep -c` does.
    if (emitOncePerFile(out, gpa, path, show_path, mode, res, config.null_filename)) |e| res.err = e;
    return res;
}

/// Emits the once-per-file part of `-c`, `-l`, and `-L`.
/// Returns null on success or the errno if the buffer could not grow.
pub fn emitOncePerFile(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    path: []const u8,
    show_path: bool,
    mode: Mode,
    res: FileScan,
    null_filename: bool,
) ?linux.E {
    if (mode == .count or mode == .count_matches) {
        if (show_path) {
            out.appendSlice(gpa, path) catch return .NOMEM;
            out.append(gpa, if (null_filename) 0 else ':') catch return .NOMEM;
        }
        appendDecimal(out, gpa, if (mode == .count_matches) res.matches else res.lines) catch return .NOMEM;
        out.append(gpa, '\n') catch return .NOMEM;
    } else if (mode == .files and res.matched) {
        out.appendSlice(gpa, path) catch return .NOMEM;
        out.append(gpa, if (null_filename) 0 else '\n') catch return .NOMEM;
    } else if (mode == .files_without_match and !res.matched) {
        out.appendSlice(gpa, path) catch return .NOMEM;
        out.append(gpa, if (null_filename) 0 else '\n') catch return .NOMEM;
    }
    return null;
}

/// `-A/-B/-C` with more than one file: GNU grep prints a `--` line between the
/// context groups of different files. Callers snapshot `out.items.len` before
/// appending a file and call this afterwards.
pub fn insertGroupSeparator(out: *std.ArrayList(u8), gpa: Allocator, before_len: usize) void {
    if (before_len > 0 and out.items.len > before_len) {
        out.insertSlice(gpa, before_len, "--\n") catch {};
    }
}

/// Reads exactly `buf.len` bytes. Returns null on success or the errno.
fn readFully(fd: i32, buf: []u8) ?linux.E {
    var got: usize = 0;
    while (got < buf.len) {
        const rr = linux.read(fd, buf.ptr + got, buf.len - got);
        const e = linux.errno(rr);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return e;
        if (rr == 0) return .IO; // truncated: size changed under us
        got += rr;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests: known ground truth for line tracking and emission format.
// ---------------------------------------------------------------------------

fn runWithConfig(
    data: []const u8,
    needle: []const u8,
    mode: Mode,
    config: ScanConfig,
    path: []const u8,
    show_path: bool,
) ![]u8 {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const searcher = Searcher.init(needle, .auto);
    _ = try scanBuffer(gpa, data, &searcher, path, show_path, mode, config, &out);
    return out.toOwnedSlice(gpa);
}

fn run(
    data: []const u8,
    needle: []const u8,
    mode: Mode,
    path: []const u8,
    show_path: bool,
) ![]u8 {
    return runWithConfig(data, needle, mode, .{}, path, show_path);
}

test "scanBuffer: line numbers and content" {
    const got = try run("alpha\nbeta gamma\ngamma\n", "gamma", .lines, "f.txt", true);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        \\f.txt:2:beta gamma
        \\f.txt:3:gamma
        \\
    , got);
}

test "scanBuffer: one output line per matching line, not per occurrence" {
    const got = try run("aa aa\naa\n", "aa", .lines, "f", false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("1:aa aa\n2:aa\n", got);
}

test "scanBuffer: match after a line with no newline at EOF" {
    const got = try run("one\ntwo\nthree", "three", .lines, "f", false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("3:three\n", got);
}

test "scanBuffer: match at start, empty lines preserved" {
    const got = try run("\n\nhit\n", "hit", .lines, "f", false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("3:hit\n", got);
}

test "scanBuffer: no match produces no output" {
    const got = try run("one\ntwo\n", "zzz", .lines, "f", true);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("", got);
}

test "scanBuffer: empty needle matches every line" {
    const got = try run("a\nbb\n", "", .lines, "f", false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("1:a\n2:bb\n", got);
}

test "scanBuffer: a needle containing a newline never matches a line" {
    // `main.zig` rejects such patterns up front; this pins the lower layer so
    // a future change cannot silently reintroduce cross-line matching.
    const got = try run("a\nb\n", "a\nb", .lines, "f", false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("1:a\n", got);
}

test "scanBuffer: line cursor survives long gaps between matches" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    var i: usize = 1;
    while (i <= 500) : (i += 1) {
        try data.appendSlice(
            std.testing.allocator,
            if (i == 42 or i == 500) "MARKER\n" else "filler line\n",
        );
    }
    const got = try run(data.items, "MARKER", .lines, "f", false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("42:MARKER\n500:MARKER\n", got);
}

test "scanBuffer: invert-match (-v)" {
    const data = "apple\nbanana\ncherry\napricot\n";
    const got = try runWithConfig(data, "ap", .lines, .{ .invert = true }, "f", false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("2:banana\n3:cherry\n", got);
}

test "scanBuffer: max-count (-m)" {
    const data = "hit 1\nhit 2\nhit 3\nhit 4\n";
    const got = try runWithConfig(data, "hit", .lines, .{ .max_count = 2 }, "f", false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("1:hit 1\n2:hit 2\n", got);
}

test "scanBuffer: invert-match with max-count (-v -m)" {
    const data = "apple\nbanana\ncherry\ndate\n";
    const got = try runWithConfig(data, "apple", .lines, .{ .invert = true, .max_count = 2 }, "f", false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("2:banana\n3:cherry\n", got);
}

test "scanFile: files-without-match (-L)" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const searcher = Searcher.init("non_existent_token_xyz", .auto);
    const res = scanFile(std.testing.io, gpa, &searcher, "src/root.zig", false, .files_without_match, false, .{}, &out, null, null);
    try std.testing.expect(!res.matched);
    try std.testing.expectEqualStrings("src/root.zig\n", out.items);
}

test "scanFile: en auto la sonda es la primera lectura y sus bytes se escanean" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const body = "alpha\nbeta needle\ngamma\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = body });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/f.txt", .{tmp.sub_path[0..]});

    var scratch: [4096]u8 = undefined;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const searcher = Searcher.init("needle", .auto);
    var st = io_engine.State{};

    const res = scanFile(std.testing.io, gpa, &searcher, path, false, .lines, false, .{}, &out, &scratch, &st);
    try std.testing.expect(res.err == null);
    try std.testing.expect(res.matched);
    try std.testing.expectEqual(@as(usize, 1), res.lines);
    try std.testing.expectEqual(body.len, res.bytes);
    try std.testing.expectEqualStrings("2:beta needle\n", out.items);
    // La sonda corrió sobre el mismo fd: un hit y ningún miss. Si el offset
    // del fd no se hubiera colocado tras la sonda, la lectura habría repetido
    // los primeros bytes y `bytes`/`lines` no darían esto.
    try std.testing.expectEqual(@as(u32, 1), st.probes.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), st.hits.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), st.misses.load(.monotonic));
}

test "utf16: BOM detection and LE decoding" {
    // UTF-16 LE: BOM (0xFF, 0xFE) followed by "Hello\n"
    const utf16_sample = [_]u8{
        0xFF, 0xFE, // BOM LE
        'H',  0x00,
        'e',  0x00,
        'l',  0x00,
        'l',  0x00,
        'o',  0x00,
        '\n', 0x00,
    };
    try std.testing.expectEqual(isUtf16Bom(&utf16_sample), .le);
    const decoded = try decodeUtf16ToUtf8(std.testing.allocator, &utf16_sample, true);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("Hello\n", decoded);
}

// ---------------------------------------------------------------------------
// Tests: -A / -B / -C context, --no-line-number, -Z, and their interaction
// with -v and -m. Every expected output here was captured from GNU grep 3.11
// and then repeated against ripgrep 14.1.0.
// ---------------------------------------------------------------------------

const ctx_data = "l1\nl2\nHIT a\nl4\nl5\nl6\nl7\nHIT b\nl9\nHIT c\nl11\n";

test "scanBuffer: -A1 -B1 without file names" {
    const got = try runWithConfig(ctx_data, "HIT", .lines, .{ .before_context = 1, .after_context = 1 }, "a.txt", false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        \\2-l2
        \\3:HIT a
        \\4-l4
        \\--
        \\7-l7
        \\8:HIT b
        \\9-l9
        \\10:HIT c
        \\11-l11
        \\
    , got);
}

test "scanBuffer: -A2 -B2 with file names" {
    const got = try runWithConfig(ctx_data, "HIT", .lines, .{ .before_context = 2, .after_context = 2 }, "a.txt", true);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        \\a.txt-1-l1
        \\a.txt-2-l2
        \\a.txt:3:HIT a
        \\a.txt-4-l4
        \\a.txt-5-l5
        \\a.txt-6-l6
        \\a.txt-7-l7
        \\a.txt:8:HIT b
        \\a.txt-9-l9
        \\a.txt:10:HIT c
        \\a.txt-11-l11
        \\
    , got);
}

test "scanBuffer: after-context only and before-context only" {
    {
        const got = try runWithConfig(ctx_data, "HIT", .lines, .{ .after_context = 1 }, "a.txt", false);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(
            \\3:HIT a
            \\4-l4
            \\--
            \\8:HIT b
            \\9-l9
            \\10:HIT c
            \\11-l11
            \\
        , got);
    }
    {
        const got = try runWithConfig(ctx_data, "HIT", .lines, .{ .before_context = 1 }, "a.txt", false);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(
            \\2-l2
            \\3:HIT a
            \\--
            \\7-l7
            \\8:HIT b
            \\9-l9
            \\10:HIT c
            \\
        , got);
    }
}

test "scanBuffer: a match inside a previous after-context is printed once, as a match" {
    // Lines 8, 9, 10 are consecutive matches; only the group separator makes
    // groups at all here, and grep does not print one between adjacent matches.
    const got = try runWithConfig(ctx_data, "HIT", .lines, .{ .before_context = 1 }, "a.txt", false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        \\2-l2
        \\3:HIT a
        \\--
        \\7-l7
        \\8:HIT b
        \\9-l9
        \\10:HIT c
        \\
    , got);
}

test "scanBuffer: context wider than the file stays a single group" {
    const got = try runWithConfig(ctx_data, "HIT", .lines, .{ .before_context = 10, .after_context = 10 }, "a.txt", true);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        \\a.txt-1-l1
        \\a.txt-2-l2
        \\a.txt:3:HIT a
        \\a.txt-4-l4
        \\a.txt-5-l5
        \\a.txt-6-l6
        \\a.txt-7-l7
        \\a.txt:8:HIT b
        \\a.txt-9-l9
        \\a.txt:10:HIT c
        \\a.txt-11-l11
        \\
    , got);
}

test "scanBuffer: max-count stops matching but still drains after-context" {
    const got = try runWithConfig(ctx_data, "HIT", .lines, .{ .after_context = 2, .max_count = 1 }, "a.txt", false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        \\3:HIT a
        \\4-l4
        \\5-l5
        \\
    , got);
}

test "scanBuffer: --no-line-number keeps the context separator" {
    const got = try runWithConfig(ctx_data, "HIT", .lines, .{ .before_context = 1, .after_context = 1, .show_line_no = false }, "a.txt", false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        \\l2
        \\HIT a
        \\l4
        \\--
        \\l7
        \\HIT b
        \\l9
        \\HIT c
        \\l11
        \\
    , got);
    // With file names the path separator still marks match vs context.
    const named = try runWithConfig(ctx_data, "HIT", .lines, .{ .before_context = 1, .show_line_no = false }, "a.txt", true);
    defer std.testing.allocator.free(named);
    try std.testing.expectEqualStrings(
        \\a.txt-l2
        \\a.txt:HIT a
        \\--
        \\a.txt-l7
        \\a.txt:HIT b
        \\a.txt-l9
        \\a.txt:HIT c
        \\
    , named);
}

test "scanBuffer: context is still counted, not emitted, in -c mode" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const searcher = Searcher.init("HIT", .auto);
    const br = try scanBuffer(std.testing.allocator, ctx_data, &searcher, "a.txt", true, .count, .{ .before_context = 2, .after_context = 2 }, &out);
    try std.testing.expectEqualStrings("", out.items);
    try std.testing.expectEqual(@as(usize, 3), br.lines);
}

test "scanBuffer: invert without context prints no group separators" {
    // Regression: the ordered path used by -v once leaked the `--` group
    // separator even with -A/-B/-C disabled (oracle case "invert-match -v").
    const data = "one\ntwo\nthree\nfour\nfive\nsix\n";
    const got = try runWithConfig(data, "zzz", .lines, .{ .invert = true }, "f", false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("1:one\n2:two\n3:three\n4:four\n5:five\n6:six\n", got);
    const inc = try runWithConfig(data, "e", .lines, .{ .invert = true }, "f", false);
    defer std.testing.allocator.free(inc);
    try std.testing.expectEqualStrings("2:two\n4:four\n6:six\n", inc);
    // same, with after-context: matches become context of an inverted match
    const with_ctx = try runWithConfig(data, "e", .lines, .{ .invert = true, .after_context = 1 }, "f", false);
    defer std.testing.allocator.free(with_ctx);
    try std.testing.expectEqualStrings("2:two\n3-three\n4:four\n5-five\n6:six\n", with_ctx);
}

test "scanBuffer: -A1 -B1 still honours invert (-v)" {
    const got = try runWithConfig(ctx_data, "HIT", .lines, .{ .invert = true, .after_context = 1 }, "a.txt", false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        \\1:l1
        \\2:l2
        \\3-HIT a
        \\4:l4
        \\5:l5
        \\6:l6
        \\7:l7
        \\8-HIT b
        \\9:l9
        \\10-HIT c
        \\11:l11
        \\
    , got);
}

test "scanBuffer: -Z prints a NUL after the file name" {
    {
        const got = try runWithConfig(ctx_data, "HIT", .lines, .{ .null_filename = true }, "a.txt", true);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("a.txt\x003:HIT a\na.txt\x008:HIT b\na.txt\x0010:HIT c\n", got);
    }
    {
        const got = try runWithConfig(ctx_data, "HIT", .lines, .{ .null_filename = true, .after_context = 1 }, "a.txt", true);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("a.txt\x003:HIT a\na.txt\x004-l4\n--\na.txt\x008:HIT b\na.txt\x009-l9\na.txt\x0010:HIT c\na.txt\x0011-l11\n", got);
    }
    {
        const got = try runWithConfig(ctx_data, "HIT", .count, .{ .null_filename = true }, "a.txt", true);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("", got);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        const searcher = Searcher.init("HIT", .auto);
        const br = try scanBuffer(std.testing.allocator, ctx_data, &searcher, "a.txt", true, .count, .{ .null_filename = true }, &out);
        _ = emitOncePerFile(&out, std.testing.allocator, "a.txt", true, .count, .{ .matched = br.matched, .lines = br.lines }, true);
        try std.testing.expectEqualStrings("a.txt\x003\n", out.items);
    }
    {
        const got = try runWithConfig(ctx_data, "HIT", .files, .{ .null_filename = true }, "a.txt", true);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("", got);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        const searcher = Searcher.init("HIT", .auto);
        const br = try scanBuffer(std.testing.allocator, ctx_data, &searcher, "a.txt", true, .files, .{ .null_filename = true }, &out);
        _ = emitOncePerFile(&out, std.testing.allocator, "a.txt", true, .files, .{ .matched = br.matched, .lines = br.lines }, true);
        try std.testing.expectEqualStrings("a.txt\x00", out.items);
    }
}
