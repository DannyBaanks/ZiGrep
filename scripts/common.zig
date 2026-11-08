//! Shared helpers for the benchmark scripts. Standalone `zig run` scripts
//! import this with a relative path, so there is no build wiring involved.
const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

pub const Group = struct {
    label: []const u8,
    argv: []const []const u8,
};

// ---------------------------------------------------------------------------
// Files and directories (raw syscalls, same style as src/)
// ---------------------------------------------------------------------------

/// Creates every POSIX path prefix of `path`. Existing directories are fine.
pub fn makePath(arena: Allocator, path: []const u8) Allocator.Error!void {
    if (path.len == 0) return;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            const prefix = try std.fmt.allocPrintSentinel(arena, "{s}", .{path[0..i]}, 0);
            _ = linux.mkdirat(linux.AT.FDCWD, prefix, 0o755);
        }
    }
}

pub fn writeFile(path: [:0]const u8, data: []const u8) bool {
    const rc = linux.openat(
        linux.AT.FDCWD,
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
        0o644,
    );
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: i32 = @intCast(@as(isize, @bitCast(rc)));
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const w = linux.write(fd, data.ptr + off, data.len - off);
        const e = linux.errno(w);
        if (e == .INTR) continue;
        if (e != .SUCCESS or w == 0) return false;
        off += w;
    }
    return true;
}

/// Reads a whole small file, e.g. `/proc/loadavg`.
pub fn readFile(arena: Allocator, path: [:0]const u8) ?[]const u8 {
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(@as(isize, @bitCast(rc)));
    defer _ = linux.close(fd);
    var buf: [128]u8 = undefined;
    const r = linux.read(fd, &buf, buf.len);
    if (linux.errno(r) != .SUCCESS or r == 0) return null;
    const n = std.mem.trimEnd(u8, buf[0..r], "\n");
    return std.fmt.allocPrint(arena, "{s}", .{n}) catch null;
}

// ---------------------------------------------------------------------------
// Clock — std.time exposes only constants in Zig 0.16
// ---------------------------------------------------------------------------

pub fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    if (linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    if (ts.sec < 0 or ts.nsec < 0) return 0;
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec * 1_000_000_000 + nsec;
}

pub fn nowMs() u64 {
    return nowNs() / 1_000_000;
}

/// Formats into a stack buffer and writes to stdout. `std.debug.print` targets
/// stderr in Zig 0.16, which is right for diagnostics but not for reports.
pub fn printOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [64 * 1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    var off: usize = 0;
    while (off < s.len) {
        const w = linux.write(linux.STDOUT_FILENO, s.ptr + off, s.len - off);
        const e = linux.errno(w);
        if (e == .INTR) continue;
        if (e != .SUCCESS or w == 0) return;
        off += w;
    }
}

// ---------------------------------------------------------------------------
// Child process helpers
// ---------------------------------------------------------------------------

/// Shell-compatible exit code for a `std.process.Child.Term`.
pub fn termCode(t: std.process.Child.Term) u8 {
    return switch (t) {
        .exited => |c| c,
        .signal => |s| blk: {
            const raw: u32 = @intFromEnum(s);
            // Written as an if rather than `@min(raw, 127)`: Zig 0.16 narrows
            // `@min` to the smallest type holding the bound (u7 here), and then
            // `128 + u7` no longer fits. The explicit widening keeps u32.
            const capped: u32 = if (raw > 127) 127 else raw;
            break :blk @intCast(128 + capped);
        },
        .stopped, .unknown => 255,
    };
}

// ---------------------------------------------------------------------------
// Output comparison
// ---------------------------------------------------------------------------

pub fn lessThanBytes(_: void, a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return a[i] < b[i];
    }
    return a.len < b.len;
}

pub fn countNewlines(text: []const u8) usize {
    var n: usize = 0;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

/// Splits `text` into lines (one trailing newline optional) and sorts them
/// byte-wise, giving an order-independent view for comparison. Byte-identical
/// duplicates land adjacent, so the result is canonical regardless of the
/// underlying search order.
pub fn sortLines(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var body = text;
    if (body.len > 0 and body[body.len - 1] == '\n') body = body[0 .. body.len - 1];
    var list: std.ArrayList([]const u8) = .empty;
    if (body.len == 0) return list.items;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| try list.append(arena, line);
    std.sort.pdq([]const u8, list.items, {}, lessThanBytes);
    return list.items;
}

/// Turns a free-form label into a safe file-name component.
pub fn sanitizeLabel(arena: Allocator, label: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (label) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        try out.append(arena, if (ok) c else '_');
    }
    if (out.items.len == 0) try out.appendSlice(arena, "group");
    return out.items;
}

// ---------------------------------------------------------------------------
// `--name=LABEL CMD...` group collection
// ---------------------------------------------------------------------------

/// Parses a tail of argv that starts at (or after) the first `--name=`.
/// Global options must appear *before* the first `--name=`; each script parses
/// those itself and hands the remainder here.
pub fn collectGroups(arena: Allocator, args: []const [:0]const u8) ![]const Group {
    var groups: std.ArrayList(Group) = .empty;
    var label: ?[]const u8 = null;
    var argv: std.ArrayList([]const u8) = .empty;

    for (args) |a| {
        if (std.mem.startsWith(u8, a, "--name=")) {
            if (label) |l| {
                if (argv.items.len == 0) return error.BadArg;
                try groups.append(arena, .{ .label = l, .argv = argv.items });
                argv = .empty;
            }
            label = a["--name=".len..];
            if (label.?.len == 0) return error.BadArg;
            continue;
        }
        if (label == null) return error.BadArg;
        try argv.append(arena, a);
    }
    if (label) |l| {
        if (argv.items.len == 0) return error.BadArg;
        try groups.append(arena, .{ .label = l, .argv = argv.items });
    }
    if (groups.items.len < 2) return error.NeedAtLeastTwoGroups;
    return groups.items;
}
