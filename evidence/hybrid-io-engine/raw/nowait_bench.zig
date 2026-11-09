const std = @import("std");
const linux = std.os.linux;
const RWF = linux.RWF;
const Vec = std.posix.iovec;

var sink: usize = 0;

fn zpath(buf: []u8, path: []const u8) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, "{s}", .{path}) catch unreachable;
}

fn openRO(buffer: []u8, path: []const u8) ?i32 {
    const rc = linux.openat(linux.AT.FDCWD, zpath(buffer, path), .{ .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(@as(isize, @bitCast(rc)));
}

fn nowaitRead(fd: i32, buf: []u8) union(enum) { bytes: usize, again: void, err: linux.E } {
    var iov = [1]Vec{ .{ .base = buf.ptr, .len = buf.len } };
    const n = linux.preadv2(fd, &iov, 1, 0, RWF.NOWAIT);
    const e = linux.errno(n);
    if (e == .AGAIN) return .{ .again = {} };
    if (e != .SUCCESS) return .{ .err = e };
    return .{ .bytes = n };
}

fn plainRead(fd: i32, buf: []u8) usize {
    var iov = [1]Vec{ .{ .base = buf.ptr, .len = buf.len } };
    const n = linux.preadv2(fd, &iov, 1, 0, 0);
    return if (linux.errno(n) == .SUCCESS) n else 0;
}

fn ns() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn t_open_ns(iters: usize, target: []const u8) usize {
    var pz: [256]u8 = undefined;
    const t0 = ns();
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const f = openRO(&pz, target) orelse break;
        _ = linux.close(f);
    }
    return (ns() - t0) / iters;
}

pub fn main() !void {
    var pz: [256]u8 = undefined;
    var buf: [256 * 1024]u8 = undefined;
    const target = "/home/danny/Development/ISyCo Git/ZigGrep/src/main.zig";
    const iters: usize = 20000;

    std.debug.print("=== 1. la sonda discrimina ===\n", .{});
    const fd = openRO(&pz, target) orelse return;
    defer _ = linux.close(fd);
    std.debug.print("  archivo frio?            ", .{});
    switch (nowaitRead(fd, &buf)) {
        .again => std.debug.print("EAGAIN\n", .{}),
        .bytes => |n| std.debug.print("CALIENTE ({d} B)\n", .{n}),
        .err => |e| std.debug.print("err {s}\n", .{@tagName(e)}),
    }
    _ = plainRead(fd, &buf);
    std.debug.print("  tras lectura normal:      ", .{});
    switch (nowaitRead(fd, &buf)) {
        .again => std.debug.print("EAGAIN\n", .{}),
        .bytes => |n| std.debug.print("CALIENTE ({d} B) <- la sonda funciona\n", .{n}),
        .err => |e| std.debug.print("err {s}\n", .{@tagName(e)}),
    }

    std.debug.print("\n=== 2. coste en caliente (iovec 256 KB sobre fichero de 62 KB) ===\n", .{});
    var t0 = ns();
    var acc: usize = 0;
    var i: usize = 0;
    while (i < iters) : (i += 1) switch (nowaitRead(fd, &buf)) {
        .bytes => |n| acc += n,
        else => {},
    };
    const t_probe = ns() - t0;
    sink += acc;
    t0 = ns();
    acc = 0;
    i = 0;
    while (i < iters) : (i += 1) acc += plainRead(fd, &buf);
    const t_plain = ns() - t0;
    sink += acc;
    std.debug.print("  preadv2(NOWAIT) caliente : {d:>7} ns/llamada\n", .{t_probe / iters});
    std.debug.print("  preadv2 normal caliente  : {d:>7} ns/llamada\n", .{t_plain / iters});
    std.debug.print("  abrir+cerrar sin leer    : {d:>7} ns/llamada\n", .{t_open_ns(iters, target)});

    std.debug.print("\n=== 3. coste puro del miss (expulsando en cada vuelta) ===\n", .{});
    var pz2: [256]u8 = undefined;
    const fdc = openRO(&pz2, "/tmp/opencode/probe-a.bin") orelse return;
    defer _ = linux.close(fdc);
    _ = linux.fadvise(fdc, 0, 0, 4);
    var misses: usize = 0;
    t0 = ns();
    i = 0;
    while (i < 2000) : (i += 1) {
        _ = linux.fadvise(fdc, 0, 0, 4);
        switch (nowaitRead(fdc, &buf)) {
            .again => misses += 1,
            .bytes => |n| acc += n,
            else => {},
        }
    }
    const t_evict_probe = ns() - t0;
    t0 = ns();
    i = 0;
    while (i < 2000) : (i += 1) _ = linux.fadvise(fdc, 0, 0, 4);
    const t_evict_only = ns() - t0;
    std.debug.print("  expulsar + sonda miss   : {d:>7} ns/vuelta ({d}/2000 dieron EAGAIN)\n", .{ t_evict_probe / 2000, misses });
    std.debug.print("  solo expulsar           : {d:>7} ns/vuelta\n", .{t_evict_only / 2000});
    std.debug.print("  => sonda miss (restando): {d:>7} ns/vuelta\n", .{@max(t_evict_probe - t_evict_only, 0) / 2000});
    std.debug.print("\n  conclusion: en caliente la sonda cuesta el {d}% de una lectura normal\n", .{(t_probe * 100) / @max(t_plain, 1)});
    std.debug.print("  (sink={d})\n", .{acc});
}
