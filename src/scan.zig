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
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const Searcher = @import("search.zig").Searcher;

pub const Mode = enum {
    /// `path:line:text`
    lines,
    /// `path:count` for every scanned file (grep `-c` behaviour).
    count,
    /// `path` for files with at least one match.
    files,
    /// No output at all; exit status only.
    quiet,
};

/// NUL probe window used to decide a file is binary, aligned with GNU grep's
/// first-block check and ripgrep's default heuristic.
pub const binary_probe_bytes = 8192;

/// mmap below this size is rarely a win over a plain read; the read path
/// exists mainly as a fallback for mappings the kernel refuses.
pub const mmap_threshold = 64 * 1024;

pub const FileScan = struct {
    matched: bool = false,
    lines: usize = 0,
    /// Bytes actually searched (excludes binary skips and failures).
    bytes: usize = 0,
    err: ?linux.E = null,
};

pub const BufferResult = struct {
    matched: bool = false,
    lines: usize = 0,
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
    line_no: usize,
    text: []const u8,
) Allocator.Error!void {
    const path_extra: usize = if (show_path) path.len + 1 else 0;
    const needed = path_extra + 24 + 1 + text.len + 1;
    try out.ensureUnusedCapacity(gpa, needed);

    if (show_path) {
        out.appendSliceAssumeCapacity(path);
        out.appendAssumeCapacity(':');
    }
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{line_no}) catch unreachable;
    out.appendSliceAssumeCapacity(s);
    out.appendAssumeCapacity(':');
    out.appendSliceAssumeCapacity(text);
    out.appendAssumeCapacity('\n');
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
    out: *std.ArrayList(u8),
) Allocator.Error!BufferResult {
    var res: BufferResult = .{};

    // Early-exit optimization for files (-l) and quiet (-q) modes:
    // Once any match is found, we don't need to scan remaining lines.
    if (mode == .quiet or mode == .files) {
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
            try emitLine(out, gpa, path, show_path, line_no, data[line_start..line_end]);
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
pub fn scanFile(
    gpa: Allocator,
    searcher: *const Searcher,
    path: [:0]const u8,
    show_path: bool,
    mode: Mode,
    binary: bool,
    out: *std.ArrayList(u8),
    scratch: ?[]u8,
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
                if (emitOncePerFile(out, gpa, path, show_path, mode, res)) |e| res.err = e;
                return res;
            }
            const data = sbuf[0..got];
            const probe = @min(data.len, binary_probe_bytes);
            const is_binary = !binary and std.mem.findScalar(u8, data[0..probe], 0) != null;
            if (!is_binary) {
                const br = scanBuffer(gpa, data, searcher, path, show_path, mode, out) catch {
                    res.err = .NOMEM;
                    return res;
                };
                res.matched = br.matched;
                res.lines = br.lines;
                res.bytes = data.len;
            }
            if (emitOncePerFile(out, gpa, path, show_path, mode, res)) |e| res.err = e;
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
        if (emitOncePerFile(out, gpa, path, show_path, mode, res)) |e| res.err = e;
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
    const is_binary = !binary and std.mem.findScalar(u8, data[0..probe], 0) != null;
    if (!is_binary) {
        const br = scanBuffer(gpa, data, searcher, path, show_path, mode, out) catch {
            res.err = .NOMEM;
            return res;
        };
        res.matched = br.matched;
        res.lines = br.lines;
        res.bytes = data.len;
    }

    // --- modes that emit once per file ------------------------------------
    // `-c` reports every scanned file, including binary-skipped ones as 0,
    // which is what `grep -c` does.
    if (emitOncePerFile(out, gpa, path, show_path, mode, res)) |e| res.err = e;
    return res;
}

/// Emits the once-per-file part of `-c` and `-l`.
/// Returns null on success or the errno if the buffer could not grow.
fn emitOncePerFile(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    path: []const u8,
    show_path: bool,
    mode: Mode,
    res: FileScan,
) ?linux.E {
    if (mode == .count) {
        if (show_path) {
            out.appendSlice(gpa, path) catch return .NOMEM;
            out.append(gpa, ':') catch return .NOMEM;
        }
        appendDecimal(out, gpa, res.lines) catch return .NOMEM;
        out.append(gpa, '\n') catch return .NOMEM;
    } else if (mode == .files and res.matched) {
        out.appendSlice(gpa, path) catch return .NOMEM;
        out.append(gpa, '\n') catch return .NOMEM;
    }
    return null;
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

fn run(
    data: []const u8,
    needle: []const u8,
    mode: Mode,
    path: []const u8,
    show_path: bool,
) ![]u8 {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const searcher = Searcher.init(needle, .auto);
    _ = try scanBuffer(gpa, data, &searcher, path, show_path, mode, &out);
    return out.toOwnedSlice(gpa);
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
