const std = @import("std");
const linux = std.os.linux;
const Vec = std.posix.iovec;

const RWF_NOWAIT: u32 = 0x00000008;
const RWF_DONTCACHE: u32 = 0x00000080;

var buf: [256 * 1024]u8 = undefined;

fn zpath(b: []u8, p: []const u8) [:0]const u8 {
    return std.fmt.bufPrintZ(b, "{s}", .{p}) catch unreachable;
}

fn openRO(b: []u8, p: []const u8) ?i32 {
    const rc = linux.openat(linux.AT.FDCWD, zpath(b, p), .{ .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(@as(isize, @bitCast(rc)));
}

fn rd(fd: i32, flags: u32) union(enum) { n: usize, again: void, err: linux.E } {
    var iov = [1]Vec{ .{ .base = &buf, .len = buf.len } };
    const n = linux.preadv2(fd, &iov, 1, 0, flags);
    const e = linux.errno(n);
    if (e == .AGAIN) return .{ .again = {} };
    if (e != .SUCCESS) return .{ .err = e };
    return .{ .n = n };
}


pub fn main() !void {
    var b: [256]u8 = undefined;
    const fd = openRO(&b, "/tmp/opencode/probe-b.bin") orelse return;
    defer _ = linux.close(fd);

    switch (rd(fd, 0)) {
        .n => std.debug.print("  lectura normal                     : CALIENTE\n", .{}),
        else => std.debug.print("  lectura normal                     : ?\n", .{}),
    }
    switch (rd(fd, RWF_NOWAIT)) {
        .n => |n| std.debug.print("  NOWAIT                             : CALIENTE ({d} B)\n", .{n}),
        else => std.debug.print("  NOWAIT                             : FRIO\n", .{}),
    }

    // DONTCACHE + NOWAIT sobre un fichero caliente
    switch (rd(fd, RWF_NOWAIT | RWF_DONTCACHE)) {
        .n => |n| std.debug.print("  NOWAIT|DONTCACHE                   : CALIENTE ({d} B)\n", .{n}),
        .again => std.debug.print("  NOWAIT|DONTCACHE                   : EAGAIN\n", .{}),
        .err => |e| std.debug.print("  NOWAIT|DONTCACHE                   : err {s} (¿no soportado?)\n", .{@tagName(e)}),
    }
    // y ahora, ¿se quedaron las paginas fuera?
    switch (rd(fd, RWF_NOWAIT)) {
        .n => |n| std.debug.print("  NOWAIT tras DONTCACHE              : CALIENTE ({d} B) -> DONTCACHE no expulsó\n", .{n}),
        .again => std.debug.print("  NOWAIT tras DONTCACHE              : EAGAIN -> DONTCACHE SI expulsó las paginas\n", .{}),
        .err => |e| std.debug.print("  NOWAIT tras DONTCACHE              : err {s}\n", .{@tagName(e)}),
    }
    // DONTCACHE sin NOWAIT
    switch (rd(fd, RWF_DONTCACHE)) {
        .n => |n| std.debug.print("  DONTCACHE solo                     : {d} B\n", .{n}),
        .err => |e| std.debug.print("  DONTCACHE solo                     : err {s}\n", .{@tagName(e)}),
        .again => std.debug.print("  DONTCACHE solo                     : EAGAIN\n", .{}),
    }
    switch (rd(fd, RWF_NOWAIT)) {
        .n => |n| std.debug.print("  NOWAIT tras DONTCACHE solo         : CALIENTE ({d} B)\n", .{n}),
        .again => std.debug.print("  NOWAIT tras DONTCACHE solo         : EAGAIN\n", .{}),
        .err => |e| std.debug.print("  NOWAIT tras DONTCACHE solo         : err {s}\n", .{@tagName(e)}),
    }
}
