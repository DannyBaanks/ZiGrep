//! Shared helpers for the benchmark scripts. Standalone `zig run` scripts
//! import this with a relative path, so there is no build wiring involved.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Group = struct {
    label: []const u8,
    argv: []const []const u8,
};

// ---------------------------------------------------------------------------
// Files, directories, clocks, and output
// ---------------------------------------------------------------------------

pub fn makePath(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
}

pub fn writeFile(io: std.Io, path: []const u8, data: []const u8) bool {
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return false;
    defer file.close(io);
    file.writeStreamingAll(io, data) catch return false;
    return true;
}

pub fn readFile(io: std.Io, arena: Allocator, path: []const u8) ?[]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var buf: [128]u8 = undefined;
    const r = file.readPositional(io, &.{&buf}, 0) catch return null;
    if (r == 0) return null;
    const n = std.mem.trimEnd(u8, buf[0..r], "\n");
    return std.fmt.allocPrint(arena, "{s}", .{n}) catch null;
}

pub fn nowNs(io: std.Io) u64 {
    const ns = std.Io.Clock.now(.awake, io).nanoseconds;
    return if (ns <= 0) 0 else @intCast(ns);
}

/// Formats into a stack buffer and writes to stdout. `std.debug.print` targets
/// stderr in Zig 0.16, which is right for diagnostics but not for reports.
pub fn printOut(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [64 * 1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch |err| {
        std.debug.print("script output formatting failed: {s}\n", .{@errorName(err)});
        return;
    };
    std.Io.File.stdout().writeStreamingAll(io, s) catch |err| {
        std.debug.print("script stdout write failed: {s}\n", .{@errorName(err)});
    };
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
/// duplicates land adjacent. Windows line endings and path separators are
/// normalized so native tools can be compared independent of their rendering.
pub fn sortLines(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var body = text;
    if (body.len > 0 and body[body.len - 1] == '\n') body = body[0 .. body.len - 1];
    var list: std.ArrayList([]const u8) = .empty;
    if (body.len == 0) return list.items;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        var end = line.len;
        if (end > 0 and line[end - 1] == '\r') end -= 1;
        const normalized = try arena.dupe(u8, line[0..end]);
        var path_end = normalized.len;
        var i: usize = 0;
        while (i < normalized.len) : (i += 1) {
            if (normalized[i] != ':') continue;
            var digit_end = i + 1;
            while (digit_end < normalized.len and std.ascii.isDigit(normalized[digit_end])) : (digit_end += 1) {}
            if (digit_end > i + 1 and (digit_end == normalized.len or normalized[digit_end] == ':')) {
                path_end = i;
                break;
            }
        }
        for (normalized[0..path_end]) |*byte| {
            if (byte.* == '\\') byte.* = '/';
        }
        try list.append(arena, normalized);
    }
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
