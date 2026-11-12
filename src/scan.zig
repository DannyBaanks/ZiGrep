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
const out_json = @import("out_json.zig");
const search = @import("search.zig");
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
    show_line_no: bool = false,
    /// `-Z`: terminate file names with NUL instead of ':' / newline.
    null_filename: bool = false,
    /// `-o`: one output line per (non-empty) match instead of per line.
    only_matching: bool = false,
    /// `--column`: print the 1-based byte column of the first match.
    column: bool = false,
    /// `--color=always`: highlight the match spans.
    color: bool = false,
    /// `--replace REPLACEMENT` (rg): substitute every match with the
    /// replacement text. Without `-o` the whole line is printed with the
    /// matches substituted; with `-o` the record is just the replacement.
    replace: ?[]const u8 = null,
    /// `--passthru` with `-r`: also print the lines that do not match.
    passthru: bool = false,
    /// M4 `--provenance` (only with `json`): a `provenance` event (sha256,
    /// size, mtime) before the events of every file that produced any.
    provenance: bool = false,
    /// `-b`: prefix each line with its byte offset in the file (grep).
    byte_offset: bool = false,
    /// `--crlf`: treat CRLF as the line terminator, dropping the CR (rg).
    crlf: bool = false,
    /// `--heading`: print the path as a header line before the first output
    /// of the file, instead of prefixing every line (rg).
    heading: bool = false,
    /// `--vimgrep`: one output line per match, each with the whole line (rg).
    vimgrep: bool = false,
    /// `--null-data` (grep -z): NUL is the record separator.
    null_data: bool = false,
    /// `-U`: the whole file is one record, so a match may span newlines.
    multiline: bool = false,
    /// `--json`: structured output (JSONL, schema zgrep/1) instead of text.
    json: bool = false,
    /// `--stop-on-nonmatch`: stop once a non-matching line follows a match.
    stop_on_nonmatch: bool = false,
    /// `--encoding`: how bytes become the haystack.
    encoding: Encoding = .auto,

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
/// `--encoding` decides how a file's bytes become the haystack:
///   * `none`  -> raw bytes, no BOM sniffing at all (rg's `none`)
///   * `auto`  -> BOM sniff only, the default and what this scanner already did
///   * `utf-16le` / `utf-16be` -> decode, ignoring any BOM
///   * `utf-16` -> BOM decides, else LE (rg does the same)
///   * `utf-8` / `latin1` -> bytes as-is
pub const Encoding = enum { auto, none, utf8, utf16, utf16le, utf16be, latin1 };

/// Byte-order mark flavour, named so both the sniffer and the forced value
/// return the SAME type.
pub const BomKind = enum { le, be };

pub fn parseEncoding(name: []const u8) ?Encoding {
    if (std.mem.eql(u8, name, "auto")) return .auto;
    if (std.mem.eql(u8, name, "none")) return .none;
    if (std.mem.eql(u8, name, "utf-8")) return .utf8;
    if (std.mem.eql(u8, name, "utf-16")) return .utf16;
    if (std.mem.eql(u8, name, "utf-16le")) return .utf16le;
    if (std.mem.eql(u8, name, "utf-16be")) return .utf16be;
    if (std.mem.eql(u8, name, "latin1")) return .latin1;
    return null;
}

/// The BOM this encoding forces, if any. `auto`/`none` return null.
pub fn forcedBom(enc: Encoding) ?BomKind {
    return switch (enc) {
        .utf16le => .le,
        .utf16be => .be,
        else => null,
    };
}

pub fn isUtf16Bom(bytes: []const u8) ?BomKind {
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
    json_kind: out_json.Kind,
    json_span: ?Match,
    line_start: usize,
    config: ScanConfig,
) Allocator.Error!void {
    if (config.json) {
        try out_json.emitLineEvent(out, gpa, .{
            .path = path,
            .line_no = line_no,
            .line_start = line_start,
            .line_bytes = text,
            .span = json_span,
            .kind = json_kind,
            .text = text,
            .inverted = config.invert and json_kind == .match,
        });
        return;
    }
    // With `--heading` the path went on its own header line, so the per-line
    // prefix is off.
    const with_path = show_path and !heading_mode;
    const path_extra: usize = if (with_path) path.len + 1 else 0;
    const line_extra: usize = if (show_line_no) 24 else 0;
    const off_extra: usize = if (byte_offset) |_| 24 else 0;
    const needed = path_extra + line_extra + off_extra + 1 + text.len + 1;
    try out.ensureUnusedCapacity(gpa, needed);

    if (with_path) {
        out.appendSliceAssumeCapacity(path);
        // The NUL after the path belongs to `-Z` (--null). `--null-data` (-z)
        // only changes the RECORD separator: the field separators stay ':'.
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
    out.appendAssumeCapacity(out_sep);
}

/// The visible end of the line that starts at `from`: the position of the
/// `\n`, or the end of the buffer, minus the `\r` when `--crlf` is on.
/// Callers must still advance with the RAW end (the byte after `\n`).
fn visibleLineEnd(data: []const u8, from: usize, crlf: bool) usize {
    const e = std.mem.findScalarPos(u8, data, from, '\n') orelse data.len;
    if (crlf and e > from and data[e - 1] == '\r') return e - 1;
    return e;
}

/// `--heading`: the header line that replaces the per-line path prefix.
fn emitHeading(out: *std.ArrayList(u8), gpa: Allocator, path: []const u8) Allocator.Error!void {
    try out.appendSlice(gpa, path);
    try out.append(gpa, '\n');
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
    if (show_path and !heading_mode) {
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
            if (cfg.json) {
                try out_json.emitLineEvent(out, gpa, .{
                    .path = path,
                    .line_no = line_no,
                    .line_start = line_start,
                    .line_bytes = line,
                    .span = m,
                    .kind = .occurrence,
                    .text = if (cfg.replace) |rep| rep else line[m.start..m.end],
                });
                from = m.end;
                continue;
            }
            // `-b -o`: grep prints the offset of the MATCH, absolute in the
            // file, so it is line_start + m.start.
            const off: ?usize = if (cfg.byte_offset) line_start + m.start else null;
            try emitPrefix(out, gpa, path, show_path, cfg.show_line_no, ':', line_no, cfg.null_filename, cfg.color, off);
            try out.appendSlice(gpa, if (cfg.replace) |rep| rep else line[m.start..m.end]);
            try out.append(gpa, out_sep);
        }
        from = if (m.end == m.start) m.start + 1 else m.end;
    }
}

/// `--replace` WITHOUT `-o`: the WHOLE line, with every match substituted by
/// the replacement text. rg keeps the rest of the line (`needle here` becomes
/// `X here`), and `--passthru --replace` only makes sense with that behaviour:
/// the non-matching lines are printed whole, so the matching ones have to be
/// printed whole too.
///
/// With `-o` the record is just the replacement (see `emitMatches`).
fn emitReplacedLine(
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
    const rep = cfg.replace.?;
    if (cfg.json) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        var from: usize = 0;
        while (from <= line.len) {
            const m = searcher.matchSpan(line, from) orelse break;
            if (m.end == m.start) {
                from = m.start + 1;
                continue;
            }
            try buf.appendSlice(gpa, line[from..m.start]);
            try buf.appendSlice(gpa, rep);
            from = m.end;
        }
        if (from <= line.len) try buf.appendSlice(gpa, line[from..]);
        try out_json.emitLineEvent(out, gpa, .{
            .path = path,
            .line_no = line_no,
            .line_start = line_start,
            .line_bytes = line,
            .span = searcher.matchSpan(line, 0),
            .kind = .match,
            .text = buf.items,
        });
        return;
    }
    const off: ?usize = if (cfg.byte_offset) line_start else null;
    try emitPrefix(out, gpa, path, show_path, cfg.show_line_no, ':', line_no, cfg.null_filename, cfg.color, off);
    var from: usize = 0;
    while (from <= line.len) {
        const m = searcher.matchSpan(line, from) orelse break;
        if (m.end == m.start) {
            from = m.start + 1;
            continue;
        }
        try out.appendSlice(gpa, line[from..m.start]);
        try out.appendSlice(gpa, rep);
        from = m.end;
    }
    if (from <= line.len) try out.appendSlice(gpa, line[from..]);
    try out.append(gpa, out_sep);
}

/// `-U`: rg prints each LINE the match spans, separately.
fn emitSpannedLines(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    cfg: ScanConfig,
    path: []const u8,
    show_path: bool,
    data: []const u8,
    span: Match,
) Allocator.Error!void {
    var ls = span.start;
    while (ls > 0 and data[ls - 1] != '\n') ls -= 1;
    var no: usize = 1;
    var k: usize = 0;
    while (k < ls) : (k += 1) {
        if (data[k] == '\n') no += 1;
    }
    var i = ls;
    while (i < data.len) {
        const raw = std.mem.findScalarPos(u8, data, i, '\n') orelse data.len;
        const end = if (cfg.crlf and raw > i and data[raw - 1] == '\r') raw - 1 else raw;
        try emitLine(out, gpa, path, show_path, cfg.show_line_no, ':', no, data[i..end], cfg.null_filename, if (cfg.byte_offset) i else null, .match, null, i, cfg);
        if (raw >= span.end) break;
        i = raw + 1;
        no += 1;
    }
}

/// `-U -o`: the match itself, newlines included, as one output record.
fn emitSpanOnce(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    cfg: ScanConfig,
    path: []const u8,
    show_path: bool,
    line_no: usize,
    line_start: usize,
    text: []const u8,
) Allocator.Error!void {
    if (cfg.json) {
        try out_json.emitLineEvent(out, gpa, .{
            .path = path,
            .line_no = line_no,
            .line_start = line_start,
            .line_bytes = text,
            .span = .{ .start = 0, .end = text.len },
            .kind = .occurrence,
            .text = text,
        });
        return;
    }
    const off: ?usize = if (cfg.byte_offset) line_start else null;
    try emitPrefix(out, gpa, path, show_path, cfg.show_line_no, ':', line_no, cfg.null_filename, cfg.color, off);
    try out.appendSlice(gpa, text);
    try out.append(gpa, out_sep);
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
    column_override: ?usize,
    line_start: usize,
) Allocator.Error!void {
    var first: ?Match = null;
    if (cfg.column) first = searcher.matchSpan(line, 0);
    if (cfg.json) {
        try out_json.emitLineEvent(out, gpa, .{
            .path = path,
            .line_no = line_no,
            .line_bytes = line,
            .line_start = line_start,
            .span = first orelse searcher.matchSpan(line, 0),
            .kind = .match,
            .text = line,
            .inverted = cfg.invert,
        });
        return;
    }
    // With `--heading` the path is on its own line, so no per-line prefix.
    if (show_path and !heading_mode) {
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
    if (column_override) |col| {
        var cbuf: [24]u8 = undefined;
        const c = std.fmt.bufPrint(&cbuf, "{d}:", .{col + 1}) catch unreachable;
        try out.appendSlice(gpa, c);
    } else if (first) |m| {
        var cbuf: [24]u8 = undefined;
        const c = std.fmt.bufPrint(&cbuf, "{d}:", .{m.start + 1}) catch unreachable;
        try out.appendSlice(gpa, c);
    }
    if (!cfg.color) {
        try out.appendSlice(gpa, line);
        try out.append(gpa, out_sep);
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
    try out.append(gpa, out_sep);
}

/// The record separator: `\n` normally, NUL with `--null-data`.
inline fn recordSep(config: ScanConfig) u8 {
    return if (config.null_data) 0 else '\n';
}

/// Output record separator: '\n', or NUL with `--null-data` (grep -z prints
/// NUL-separated records). Set once by main before the scan starts.
pub var out_sep: u8 = '\n';

/// `--heading` is on for this run (rg prints the file path as a header line
/// instead of a per-line prefix, but only with more than one input).
pub var heading_mode: bool = false;

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

    const context_enabled = config.before_context > 0 or config.after_context > 0;
    const spans = config.needs_spans();

    // `-U`: the whole file is ONE record, so a match may span newlines; the
    // printer then emits every line the span covers.
    var multi_span: ?Match = null;

    var line_start: usize = 0;
    var line_no: usize = 1;
    var last_printed: usize = 0;
    var printed_any = false;
    var after_left: usize = 0;
    var maxed = false;

    while (line_start < data.len) {
        const raw_end = if (config.multiline)
            data.len
        else
            std.mem.findScalarPos(u8, data, line_start, recordSep(config)) orelse data.len;
        const line_end = if (config.crlf and raw_end > line_start and data[raw_end - 1] == '\r')
            raw_end - 1
        else
            raw_end;
        const line_slice = data[line_start..line_end];
        // What gets PRINTED. With `--crlf` the CR is not part of the line for
        // matching purposes, but it is part of the bytes of the file, so it
        // goes back out (that is what rg and grep do).
        const print_slice = data[line_start..raw_end];
        const has_match = blk: {
            if (config.multiline) {
                multi_span = searcher.findSpan(data, 0);
                break :blk multi_span != null;
            }
            break :blk searcher.find(line_slice, 0) != null;
        };
        const selected = if (config.invert) !has_match else has_match;
        // `--stop-on-nonmatch` (rg): the first non-selected line AFTER a
        // selected one ends the file. That line is still handled below (it can
        // be after-context or a --passthru line, as in rg); the loop stops
        // right after it. Lines before the first selected line never stop it.
        // This flag used to be parsed and documented but never read (M11 R28).
        const stop_after_this = config.stop_on_nonmatch and !selected and res.lines > 0;

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
                if (heading_mode and !config.json and !printed_any) {
                    try emitHeading(out, gpa, path);
                    printed_any = true;
                }
                if (config.multiline) {
                    if (multi_span) |sp| {
                        if (config.only_matching) {
                            try emitSpanOnce(out, gpa, config, path, show_path, line_no, line_start, data[sp.start..sp.end]);
                        } else {
                            try emitSpannedLines(out, gpa, config, path, show_path, data, sp);
                        }
                    }
                } else if (config.vimgrep) {
                    // rg: every match on its own line, each one printing the
                    // WHOLE line with its column. That can repeat a line once
                    // per match; rg warns about exactly that.
                    var vfrom: usize = 0;
                    while (vfrom <= line_slice.len) {
                        const m = searcher.matchSpan(line_slice, vfrom) orelse break;
                        try emitLineSpanned(out, gpa, searcher, config, path, show_path, line_no, print_slice, m.start, line_start);
                        if (m.end == m.start) {
                            vfrom = m.start + 1;
                        } else {
                            vfrom = m.end;
                        }
                        if (m.end <= m.start) break;
                    }
                } else if (spans and (config.only_matching or config.replace != null)) {
                    // `grep -o -v` prints nothing: -o describes the matches of
                    // a selected line, and with -v there are none.
                    if (!config.invert) {
                        if (config.replace != null and !config.only_matching) {
                            // rg: --replace substitutes the match INSIDE the
                            // line and the rest of the line survives.
                            try emitReplacedLine(out, gpa, searcher, config, path, show_path, line_no, line_start, line_slice);
                        } else {
                            try emitMatches(out, gpa, searcher, config, path, show_path, line_no, line_start, line_slice);
                        }
                    }
                } else if (spans) {
                    try emitLineSpanned(out, gpa, searcher, config, path, show_path, line_no, print_slice, null, line_start);
                } else {
                    if (ring.len > 0 and ring_len > 0) {
                        const first = if (line_no > config.before_context) line_no - config.before_context else 1;
                        var k: usize = 0;
                        while (k < ring_len) : (k += 1) {
                            const at = (ring_pos + ring.len - ring_len + k) % ring.len;
                            const ref = ring[at];
                            if (ref.no < first or ref.no <= last_printed) continue;
                            if (context_enabled and printed_any and ref.no > last_printed + 1 and !config.json) try out.appendSlice(gpa, "--\n");
                            try emitLine(out, gpa, path, show_path, config.show_line_no, '-', ref.no, data[ref.start..ref.end], config.null_filename, if (config.byte_offset) ref.start else null, .context, null, ref.start, config);
                            last_printed = ref.no;
                            printed_any = true;
                        }
                    }
                    if (context_enabled and printed_any and line_no > last_printed + 1 and !config.json) try out.appendSlice(gpa, "--\n");
                    try emitLine(out, gpa, path, show_path, config.show_line_no, ':', line_no, print_slice, config.null_filename, if (config.byte_offset) line_start else null, .match, if (config.json) searcher.matchSpan(line_slice, 0) else null, line_start, config);
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
            // In --json a passthru line is its own event type (schema zgrep/1
            // declares `passthru`), never a `match`: an agent that filters on
            // type=="match" must count only the real matches.
            if (!spans or config.json) {
                try emitLine(out, gpa, path, show_path, config.show_line_no, ':', line_no, print_slice, config.null_filename, if (config.byte_offset) line_start else null, .passthru, null, line_start, config);
            } else {
                try emitLineSpanned(out, gpa, searcher, config, path, show_path, line_no, print_slice, null, line_start);
            }
        } else if (mode == .lines and after_left > 0 and line_no > last_printed) {
            if (context_enabled and printed_any and line_no > last_printed + 1 and !config.json) try out.appendSlice(gpa, "--\n");
            try emitLine(out, gpa, path, show_path, config.show_line_no, '-', line_no, print_slice, config.null_filename, if (config.byte_offset) line_start else null, .context, null, line_start, config);
            last_printed = line_no;
            printed_any = true;
            after_left -= 1;
        } else if (maxed and after_left == 0) {
            break;
        }
        if (stop_after_this) break;

        if (ring.len > 0) {
            ring[ring_pos] = .{ .start = line_start, .end = raw_end, .no = line_no };
            ring_pos = (ring_pos + 1) % ring.len;
            if (ring_len < ring.len) ring_len += 1;
        }

        if (raw_end >= data.len) break;
        line_start = raw_end + 1;
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
    // The fast path splits on '\n' internally (the DFA's own line handling),
    // so with `--null-data` a record that contains \n could never match.
    if (config.invert or config.before_context > 0 or config.after_context > 0 or config.needs_spans() or config.null_data or config.multiline or config.json or config.stop_on_nonmatch) {
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
    var heading_out = false;

    // `pos < data.len` (rather than `true`) is what stops an empty pattern
    // from inventing a phantom line after a trailing newline.
    while (pos < data.len) {
        const m = searcher.find(data, pos) orelse break;
        // Advance the line cursor to the line that contains the match. One
        // backward search finds where that line starts; the separators in
        // between are only COUNTED (vectorised countScalar) when the number
        // is printed. It used to call findScalarPos once per intermediate
        // line even with -n off, the default since 0.4.0.
        if (m > line_start) {
            const gap = data[line_start..m];
            if (std.mem.findScalarLast(u8, gap, recordSep(config))) |last| {
                if (config.show_line_no) line_no += std.mem.countScalar(u8, gap, recordSep(config));
                line_start += last + 1;
            }
        }
        // The RAW end is the byte of the '\n' itself; the VISIBLE end is one
        // byte earlier when `--crlf` is on (the CR is not part of the line).
        // The cursor must advance with the RAW end: advancing with the visible
        // one lands ON the '\n', so every CRLF line after the first was
        // counted twice (lines 1, 3, 5... instead of 1, 2, 3...).
        const raw_end = std.mem.findScalarPos(u8, data, m, recordSep(config)) orelse data.len;
        const line_end = if (config.crlf and raw_end > m and data[raw_end - 1] == '\r')
            raw_end - 1
        else
            raw_end;

        res.matched = true;
        res.lines += 1;
        if (mode == .count_matches) {
            // The fast path reports one line per match, but `--count-matches`
            // counts MATCHES: every match of the line has to be counted.
            const line_slice = data[line_start..line_end];
            var from: usize = 0;
            while (from <= line_slice.len) {
                const mm = searcher.matchSpan(line_slice, from) orelse break;
                if (mm.end > mm.start) res.matches += 1;
                from = if (mm.end == mm.start) mm.start + 1 else mm.end;
            }
        }
        if (mode == .lines) {
            if (heading_mode and !config.json and !config.null_filename and !heading_out) {
                try emitHeading(out, gpa, path);
                heading_out = true;
            }
            // The printed text keeps the CR: `--crlf` changes how a line is
            // MATCHED (the CR is not part of it), not which bytes come out.
            try emitLine(out, gpa, path, show_path, config.show_line_no, ':', line_no, data[line_start..raw_end], config.null_filename, if (config.byte_offset) line_start else null, .match, null, line_start, config);
        }
        if (config.max_count) |mc| {
            if (res.lines >= mc) break;
        }

        if (raw_end >= data.len) break;
        // Skip the remainder of this line: grep reports a line once.
        pos = raw_end + 1;
        line_start = raw_end + 1;
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
    const prov_start = out.items.len;
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
    const mtime_from: MtimeFrom = .{ .value = @intCast(stat.mtime.nanoseconds) };
    if (size == 0) {
        if (finishFile(out, gpa, path, show_path, mode, res, config, prov_start, "", .file, mtime_from)) |err| res.err = err;
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
            if (finishFile(out, gpa, path, show_path, mode, res, config, prov_start, buffer[0..read], provSourceOf(buffer[0..read], config), mtime_from)) |err| res.err = err;
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
            if (finishFile(out, gpa, path, show_path, mode, res, config, prov_start, map.memory, provSourceOf(map.memory, config), mtime_from)) |err| res.err = err;
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
    if (finishFile(out, gpa, path, show_path, mode, res, config, prov_start, data, provSourceOf(data, config), mtime_from)) |err| res.err = err;
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
    const utf16_bom = if (config.encoding == .none)
        null
    else if (forcedBom(config.encoding)) |f|
        f
    else if (config.encoding == .utf16)
        isUtf16Bom(data) orelse .le
    else
        isUtf16Bom(data);
    // `--null-data` makes NUL the separator, so it can no longer mean
    // "binary": that probe is off (rg does the same).
    const is_binary = !binary and !config.null_data and utf16_bom == null and std.mem.findScalar(u8, data[0..probe], 0) != null;
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
    // `--count-matches` counts MATCHES, not lines: without this the count
    // was always 0 on this path (the UTF-16 branch above already had it).
    res.matches = match.matches;
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
    const prov_start = out.items.len;

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
                if (finishFile(out, gpa, path, show_path, mode, res, config, prov_start, "", .file, .{ .fd = fd })) |e| res.err = e;
                return res;
            }
            const data = sbuf[0..got];
            const probe = @min(data.len, binary_probe_bytes);
            const utf16_bom = if (config.encoding == .none)
        null
    else if (forcedBom(config.encoding)) |f|
        f
    else if (config.encoding == .utf16)
        isUtf16Bom(data) orelse .le
    else
        isUtf16Bom(data);
            // `--null-data` makes NUL the separator, so it can no longer mean
    // "binary": that probe is off (rg does the same).
    const is_binary = !binary and !config.null_data and utf16_bom == null and std.mem.findScalar(u8, data[0..probe], 0) != null;
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
            if (finishFile(out, gpa, path, show_path, mode, res, config, prov_start, data, if (utf16_bom != null) .file_utf16 else .file, .{ .fd = fd })) |e| res.err = e;
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
        if (finishFile(out, gpa, path, show_path, mode, res, config, prov_start, "", .file, .{ .fd = fd })) |e| res.err = e;
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
    const utf16_bom = if (config.encoding == .none)
        null
    else if (forcedBom(config.encoding)) |f|
        f
    else if (config.encoding == .utf16)
        isUtf16Bom(data) orelse .le
    else
        isUtf16Bom(data);
    // `--null-data` makes NUL the separator, so it can no longer mean
    // "binary": that probe is off (rg does the same).
    const is_binary = !binary and !config.null_data and utf16_bom == null and std.mem.findScalar(u8, data[0..probe], 0) != null;
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
    if (finishFile(out, gpa, path, show_path, mode, res, config, prov_start, data, if (utf16_bom != null) .file_utf16 else .file, .{ .fd = fd })) |e| res.err = e;
    return res;
}

/// The portable path decides UTF-16 inside `processBuffer`; this repeats
/// that decision so the provenance event can say how the offsets relate.
fn provSourceOf(data: []const u8, config: ScanConfig) ProvSource {
    if (config.encoding == .none) return .file;
    if (forcedBom(config.encoding) != null or config.encoding == .utf16) return .file_utf16;
    return if (isUtf16Bom(data) != null) .file_utf16 else .file;
}

pub const ProvSource = enum {
    file,
    file_utf16,
    pre,
    stdin,
    fn name(self: ProvSource) []const u8 {
        return switch (self) {
            .file => "file",
            .file_utf16 => "file-utf16",
            .pre => "pre",
            .stdin => "stdin",
        };
    }
};

/// Where the mtime of a provenance event comes from.
pub const MtimeFrom = union(enum) {
    /// No file behind the bytes (stdin, preprocessor output).
    none,
    /// The open descriptor that was read (Linux sync path).
    fd: i32,
    /// `statx` by path (io_uring path, where the fd is already closed).
    path,
    /// Already known (portable path: the `stat` it did before reading).
    value: i128,
};

fn mtimeNs(from: MtimeFrom, path: [:0]const u8) ?i128 {
    switch (from) {
        .none => return null,
        .value => |v| return v,
        .fd, .path => {
            if (builtin.os.tag != .linux) return null;
            var sx: linux.Statx = undefined;
            const mask: linux.STATX = .{ .MTIME = true };
            const rc = switch (from) {
                .fd => |fd| linux.statx(fd, "", 0x1000, mask, &sx), // AT_EMPTY_PATH
                else => linux.statx(linux.AT.FDCWD, path, 0, mask, &sx),
            };
            if (linux.errno(rc) != .SUCCESS) return null;
            return @as(i128, sx.mtime.sec) * std.time.ns_per_s + sx.mtime.nsec;
        },
    }
}

/// End of one file: the once-per-file events (`-c`/`-l`/`-L`), then, with
/// `--json --provenance` and only if this file produced output, its
/// `provenance` event inserted at `start` — before all its events. The hash is
/// of `data`, the bytes that were actually searched; files with no output are
/// never hashed (that is what keeps `--provenance` cheap on sparse searches).
pub fn finishFile(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    path: [:0]const u8,
    show_path: bool,
    mode: Mode,
    res: FileScan,
    config: ScanConfig,
    start: usize,
    data: []const u8,
    source: ProvSource,
    mtime_from: MtimeFrom,
) ?linux.E {
    const rows_end = out.items.len;
    if (emitOncePerFile(out, gpa, path, show_path, mode, res, config.null_filename, config.json)) |e| return e;
    if (!config.json) return null;
    // compact: line rows carry no path, so they need the file header; the
    // -l/-c rows carry their own path and only get one for --provenance.
    const needs = if (out_json.compact)
        rows_end > start or (config.provenance and out.items.len > start)
    else
        config.provenance and out.items.len > start;
    if (needs) {
        insertFileHeader(out, gpa, path, start, data, source, if (config.provenance) mtimeNs(mtime_from, path) else null, config.provenance) catch return .NOMEM;
    }
    return null;
}

/// What goes in front of one file's output: in `zgrep/1` the `provenance`
/// event (only with `--provenance`); in `zgrep/1c` the `{"path":..}` header,
/// which carries the provenance fields when they were asked for. Only
/// `--provenance` hashes.
pub fn insertFileHeader(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    path: []const u8,
    start: usize,
    data: []const u8,
    source: ProvSource,
    mtime_ns: ?i128,
    provenance: bool,
) Allocator.Error!void {
    if (!out_json.compact) {
        if (provenance) try insertProvenance(out, gpa, path, start, data, source, mtime_ns);
        return;
    }
    var ev: std.ArrayList(u8) = .empty;
    defer ev.deinit(gpa);
    if (provenance) {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        try out_json.emitCompactFileHeader(&ev, gpa, path, .{ .sha256 = &digest, .size = data.len, .mtime_ns = mtime_ns, .source = source.name() });
    } else {
        try out_json.emitCompactFileHeader(&ev, gpa, path, null);
    }
    try out.insertSlice(gpa, start, ev.items);
}

pub fn insertProvenance(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    path: []const u8,
    start: usize,
    data: []const u8,
    source: ProvSource,
    mtime_ns: ?i128,
) Allocator.Error!void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    var ev: std.ArrayList(u8) = .empty;
    defer ev.deinit(gpa);
    try out_json.emitProvenanceEvent(&ev, gpa, path, &digest, data.len, mtime_ns, source.name());
    try out.insertSlice(gpa, start, ev.items);
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
    json: bool,
) ?linux.E {
    if (json) {
        if (mode == .count or mode == .count_matches) {
            out_json.emitCountEvent(out, gpa, path, if (mode == .count) res.lines else null, if (mode == .count_matches) res.matches else null) catch return .NOMEM;
        } else if (mode == .files and res.matched) {
            out_json.emitFileEvent(out, gpa, path, true) catch return .NOMEM;
        } else if (mode == .files_without_match and !res.matched) {
            out_json.emitFileEvent(out, gpa, path, false) catch return .NOMEM;
        }
        return null;
    }
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
    // Los tests de abajo fijan el comportamiento CON `-n`, que es el que
    // tenian cuando se escribieron. El default nuevo (sin numeros) tiene su
    // propio test, para que los dos comportamientos queden clavados.
    return runWithConfig(data, needle, mode, .{ .show_line_no = true }, path, show_path);
}

test "scanBuffer: sin -n no hay numero de linea (default 0.4.0)" {
    const got = try runWithConfig("alpha\nbeta gamma\ngamma\n", "gamma", .lines, .{}, "f.txt", false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        \\beta gamma
        \\gamma
        \\
    , got);
}

test "scanBuffer: -n enciende la numeracion explicitamente" {
    const got = try runWithConfig("alpha\nbeta gamma\ngamma\n", "gamma", .lines, .{ .show_line_no = true }, "f.txt", false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        \\2:beta gamma
        \\3:gamma
        \\
    , got);
}

test "scanBuffer --json: un evento por coincidencia, con bytes absolutos" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const searcher = Searcher.init("HIT", .auto);
    _ = try scanBuffer(std.testing.allocator, "one\ntwo\nHIT\n", &searcher, "a.txt", true, .lines, .{ .json = true }, &out);
    try std.testing.expectEqualStrings(
        \\{"schema":"zgrep/1","type":"match","path":"a.txt","line":3,"column":1,"byte_start":8,"byte_end":11,"match":"HIT","text":"HIT","inverted":false}
        \\
    , out.items);
}

test "scanBuffer --json: --passthru emite passthru, nunca match" {
    // Bug de la auditoria de M2: las lineas no coincidentes salian como
    // type:"match" con inverted:true, y un agente que filtra por match
    // contaba 5 en vez de 2.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const searcher = Searcher.init("HIT", .auto);
    _ = try scanBuffer(std.testing.allocator, "a\nHIT\nb\n", &searcher, "f", false, .lines, .{ .json = true, .passthru = true }, &out);
    try std.testing.expectEqualStrings(
        \\{"schema":"zgrep/1","type":"passthru","path":"f","line":1,"column":null,"byte_start":null,"byte_end":null,"match":null,"text":"a","inverted":false}
        \\{"schema":"zgrep/1","type":"match","path":"f","line":2,"column":1,"byte_start":2,"byte_end":5,"match":"HIT","text":"HIT","inverted":false}
        \\{"schema":"zgrep/1","type":"passthru","path":"f","line":3,"column":null,"byte_start":null,"byte_end":null,"match":null,"text":"b","inverted":false}
        \\
    , out.items);
}

test "scanBuffer --json: inverted sale del flag -v" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const searcher = Searcher.init("HIT", .auto);
    _ = try scanBuffer(std.testing.allocator, "a\nHIT\n", &searcher, "f", false, .lines, .{ .json = true, .invert = true }, &out);
    try std.testing.expectEqualStrings(
        \\{"schema":"zgrep/1","type":"match","path":"f","line":1,"column":null,"byte_start":null,"byte_end":null,"match":null,"text":"a","inverted":true}
        \\
    , out.items);
}

test "scanBuffer --json: sin --json la salida de texto no cambia" {
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(std.testing.allocator);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(std.testing.allocator);
    const searcher = Searcher.init("HIT", .auto);
    _ = try scanBuffer(std.testing.allocator, "one\nHIT\n", &searcher, "a.txt", true, .lines, .{}, &a);
    _ = try scanBuffer(std.testing.allocator, "one\nHIT\n", &searcher, "a.txt", true, .lines, .{ .json = false }, &b);
    try std.testing.expectEqualStrings(a.items, b.items);
    // y ninguno de los dos es JSON
    try std.testing.expect(std.mem.indexOf(u8, a.items, "\"schema\"") == null);
}

test "scanBufferLines --json: contexto con span null y tipo context" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const searcher = Searcher.init("HIT", .auto);
    _ = try scanBufferLines(std.testing.allocator, "one\ntwo\nHIT\nfour\n", &searcher, "a.txt", true, .lines, .{ .json = true, .before_context = 1, .after_context = 1 }, &out);
    // tres eventos, y NINGUNO es la linea "--" del separador de grupos
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, out.items, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\n--\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"type\":\"context\"") != null);
}

test "scanBufferLines --json: -o emite un evento por ocurrencia" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const searcher = Searcher.init("TOKEN", .auto);
    _ = try scanBufferLines(std.testing.allocator, "aa TOKEN bb TOKEN\nplain\n", &searcher, "o.txt", true, .lines, .{ .json = true, .only_matching = true }, &out);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.items, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"type\":\"occurrence\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"byte_start\":3") != null);
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
    const got = try runWithConfig(data, "ap", .lines, .{ .invert = true, .show_line_no = true }, "f", false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("2:banana\n3:cherry\n", got);
}

test "--stop-on-nonmatch: stops at the first non-matching line after a match (rg semantics)" {
    const data = "x0\na1\na2\nb\na3\nb2\n";
    const cases = [_]struct { cfg: ScanConfig, want: []const u8 }{
        // x0 comes before any match, so it does not stop the scan; b does.
        .{ .cfg = .{ .stop_on_nonmatch = true, .show_line_no = true }, .want = "2:a1\n3:a2\n" },
        // The stopping line is still after-context, as in rg -A1.
        .{ .cfg = .{ .stop_on_nonmatch = true, .show_line_no = true, .after_context = 1 }, .want = "2:a1\n3:a2\n4-b\n" },
        // -v: x0 is selected, a1 is not, so only x0.
        .{ .cfg = .{ .stop_on_nonmatch = true, .show_line_no = true, .invert = true }, .want = "1:x0\n" },
        // Without the flag nothing changes (a3 is found).
        .{ .cfg = .{ .show_line_no = true }, .want = "2:a1\n3:a2\n5:a3\n" },
    };
    for (cases) |c| {
        const got = try runWithConfig(data, "a", .lines, c.cfg, "f", false);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

test "scanBuffer: max-count (-m)" {
    const data = "hit 1\nhit 2\nhit 3\nhit 4\n";
    const got = try runWithConfig(data, "hit", .lines, .{ .max_count = 2, .show_line_no = true }, "f", false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("1:hit 1\n2:hit 2\n", got);
}

test "scanBuffer: invert-match with max-count (-v -m)" {
    const data = "apple\nbanana\ncherry\ndate\n";
    const got = try runWithConfig(data, "apple", .lines, .{ .invert = true, .max_count = 2, .show_line_no = true }, "f", false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("2:banana\n3:cherry\n", got);
}

test "scanFile: files-without-match (-L)" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const searcher = Searcher.init("non_existent_token_xyz", .auto);
    const res = scanFile(std.testing.io, gpa, &searcher, "src/root.zig", false, .files_without_match, false, .{ .show_line_no = true,}, &out, null, null);
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

    const res = scanFile(std.testing.io, gpa, &searcher, path, false, .lines, false, .{ .show_line_no = true,}, &out, &scratch, &st);
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
    const got = try runWithConfig(ctx_data, "HIT", .lines, .{ .before_context = 1, .after_context = 1, .show_line_no = true }, "a.txt", false);
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
    const got = try runWithConfig(ctx_data, "HIT", .lines, .{ .before_context = 2, .after_context = 2, .show_line_no = true }, "a.txt", true);
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
        const got = try runWithConfig(ctx_data, "HIT", .lines, .{ .show_line_no = true, .after_context = 1 }, "a.txt", false);
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
        const got = try runWithConfig(ctx_data, "HIT", .lines, .{ .show_line_no = true, .before_context = 1 }, "a.txt", false);
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
    const got = try runWithConfig(ctx_data, "HIT", .lines, .{ .show_line_no = true, .before_context = 1 }, "a.txt", false);
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
    const got = try runWithConfig(ctx_data, "HIT", .lines, .{ .show_line_no = true, .before_context = 10, .after_context = 10 }, "a.txt", true);
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
    const got = try runWithConfig(ctx_data, "HIT", .lines, .{ .show_line_no = true, .after_context = 2, .max_count = 1 }, "a.txt", false);
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
    const got = try runWithConfig(data, "zzz", .lines, .{ .invert = true, .show_line_no = true }, "f", false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("1:one\n2:two\n3:three\n4:four\n5:five\n6:six\n", got);
    const inc = try runWithConfig(data, "e", .lines, .{ .invert = true, .show_line_no = true }, "f", false);
    defer std.testing.allocator.free(inc);
    try std.testing.expectEqualStrings("2:two\n4:four\n6:six\n", inc);
    // same, with after-context: matches become context of an inverted match
    const with_ctx = try runWithConfig(data, "e", .lines, .{ .show_line_no = true, .invert = true, .after_context = 1 }, "f", false);
    defer std.testing.allocator.free(with_ctx);
    try std.testing.expectEqualStrings("2:two\n3-three\n4:four\n5-five\n6:six\n", with_ctx);
}

test "scanBuffer: -A1 -B1 still honours invert (-v)" {
    const got = try runWithConfig(ctx_data, "HIT", .lines, .{ .show_line_no = true, .invert = true, .after_context = 1 }, "a.txt", false);
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
        const got = try runWithConfig(ctx_data, "HIT", .lines, .{ .show_line_no = true, .null_filename = true }, "a.txt", true);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("a.txt\x003:HIT a\na.txt\x008:HIT b\na.txt\x0010:HIT c\n", got);
    }
    {
        const got = try runWithConfig(ctx_data, "HIT", .lines, .{ .show_line_no = true, .null_filename = true, .after_context = 1 }, "a.txt", true);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("a.txt\x003:HIT a\na.txt\x004-l4\n--\na.txt\x008:HIT b\na.txt\x009-l9\na.txt\x0010:HIT c\na.txt\x0011-l11\n", got);
    }
    {
        const got = try runWithConfig(ctx_data, "HIT", .count, .{ .show_line_no = true, .null_filename = true }, "a.txt", true);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("", got);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        const searcher = Searcher.init("HIT", .auto);
        const br = try scanBuffer(std.testing.allocator, ctx_data, &searcher, "a.txt", true, .count, .{ .null_filename = true }, &out);
        _ = emitOncePerFile(&out, std.testing.allocator, "a.txt", true, .count, .{ .matched = br.matched, .lines = br.lines }, true, false);
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
        _ = emitOncePerFile(&out, std.testing.allocator, "a.txt", true, .files, .{ .matched = br.matched, .lines = br.lines }, true, false);
        try std.testing.expectEqualStrings("a.txt\x00", out.items);
    }
}

test "scanBuffer: --count-matches counts MATCHES, not lines" {
    // The fast path (no context, no spans) reports one line per match, so
    // the count of matches has to be counted inside the line: it used to
    // print 0 for every file.
    const data = "aa aa\naa\n";
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        const searcher = Searcher.init("aa", .auto);
        const br = try scanBuffer(std.testing.allocator, data, &searcher, "f.txt", true, .count_matches, .{}, &out);
        try std.testing.expectEqual(@as(usize, 3), br.matches);
        try std.testing.expectEqual(@as(usize, 2), br.lines);
        _ = emitOncePerFile(&out, std.testing.allocator, "f.txt", true, .count_matches, .{ .matched = br.matched, .lines = br.lines, .matches = br.matches }, false, false);
        try std.testing.expectEqualStrings("f.txt:3\n", out.items);
    }
    // With `-o` the path is the line-by-line one; the count must agree.
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        const searcher = Searcher.init("aa", .auto);
        const br = try scanBuffer(std.testing.allocator, data, &searcher, "f.txt", true, .count_matches, .{ .only_matching = true }, &out);
        try std.testing.expectEqual(@as(usize, 3), br.matches);
    }
}

test "scanBuffer: -z makes NUL the RECORD separator, not the field separator" {
    // GNU grep -z prints `1:record<NUL>`, the ':' stays a colon.
    out_sep = 0;
    defer out_sep = '\n';
    const got = try runWithConfig("needle\x00other needle\x00", "needle", .lines, .{ .null_data = true, .show_line_no = true }, "f.txt", false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("1:needle\x002:other needle\x00", got);
}

test "scanBuffer: --crlf counts CRLF lines once and keeps the CR in the output" {
    // The CR is not part of the line for MATCHING, but it is part of the
    // bytes of the file, so it goes back out (rg and grep do the same).
    // The line numbers used to be 1, 3, 5... because every CRLF was counted
    // twice.
    const data = "needle one\r\nneedle two\r\nplain\r\n";
    {
        const got = try runWithConfig(data, "needle", .lines, .{ .crlf = true, .show_line_no = true }, "f.txt", false);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("1:needle one\r\n2:needle two\r\n", got);
    }
    // Without --crlf the CR is part of the line, so `$` does not match
    // before it. With --crlf it does: the CR is the terminator, not content.
    // The `crlf` flag of the searcher is what makes `$` accept before the CR
    // (the CLI wires it in `search.build`).
    // `search.build` hands the compiled `Program` to the caller that passed the
    // allocator and no owner frees it (the CLI keeps it alive for the whole
    // run). An arena per case keeps `std.testing.allocator` leak-free without
    // pretending the engine has a deinit it does not have.
    {
        var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_inst.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        const searcher = try search.build(arena_inst.allocator(), &.{"needle one$"}, .{ .crlf = false });
        _ = try scanBuffer(std.testing.allocator, data, &searcher, "f.txt", false, .lines, .{}, &out);
        try std.testing.expectEqualStrings("", out.items);
    }
    {
        var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_inst.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        const searcher = try search.build(arena_inst.allocator(), &.{"needle one$"}, .{ .crlf = true });
        _ = try scanBuffer(std.testing.allocator, data, &searcher, "f.txt", false, .lines, .{ .crlf = true, .show_line_no = true }, &out);
        try std.testing.expectEqualStrings("1:needle one\r\n", out.items);
    }
}

test "scanBuffer: --replace substitutes inside the line, the rest of it survives" {
    // rg: `needle here` becomes `X here`. It used to print only `X`, which
    // also made `--passthru --replace` incoherent.
    {
        const got = try runWithConfig("needle here\nsecond needle\n", "needle", .lines, .{ .replace = "X", .show_line_no = true }, "f.txt", false);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("1:X here\n2:second X\n", got);
    }
    // With `-o` the record is just the replacement.
    {
        const got = try runWithConfig("needle here\nsecond needle\n", "needle", .lines, .{ .replace = "X", .only_matching = true, .show_line_no = true }, "f.txt", false);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("1:X\n2:X\n", got);
    }
    // Every match of the line is substituted, not only the first.
    {
        const got = try runWithConfig("aa aa\n", "aa", .lines, .{ .replace = "X", .show_line_no = true }, "f.txt", false);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("1:X X\n", got);
    }
}

test "insertProvenance: un evento antes de los del fichero, sha256 de los bytes buscados" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "PREVIO\n");
    const start = out.items.len;
    try out.appendSlice(gpa, "{\"schema\":\"zgrep/1\",\"type\":\"match\"}\n");
    try insertProvenance(&out, gpa, "f.txt", start, "abc", .file, 42);
    // sha256("abc"), el vector de prueba de FIPS 180-2.
    try std.testing.expectEqualStrings(
        \\PREVIO
        \\{"schema":"zgrep/1","type":"provenance","path":"f.txt","sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","size":3,"mtime_ns":42,"source":"file"}
        \\{"schema":"zgrep/1","type":"match"}
        \\
    , out.items);
}

test "finishFile: sin salida del fichero no hay provenance (no se hashea)" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const cfg: ScanConfig = .{ .json = true, .provenance = true };
    try std.testing.expect(finishFile(&out, gpa, "f.txt", false, .lines, .{}, cfg, 0, "abc", .file, .none) == null);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    // -c emite siempre su evento de recuento, asi que si lleva provenance
    try std.testing.expect(finishFile(&out, gpa, "f.txt", false, .count, .{}, cfg, 0, "abc", .file, .none) == null);
    try std.testing.expect(std.mem.startsWith(u8, out.items, "{\"schema\":\"zgrep/1\",\"type\":\"provenance\""));
}
