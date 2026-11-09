const std = @import("std");
const linux = std.os.linux;
const RWF = linux.RWF;
const ADV = 4; // POSIX_FADV_DONTNEED

const Vec = std.posix.iovec;

fn zpath(buf: []u8, path: []const u8) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, "{s}", .{path}) catch unreachable;
}

fn openRO(buffer: []u8, path: []const u8) ?i32 {
    const rc = linux.openat(linux.AT.FDCWD, zpath(buffer, path), .{ .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(@as(isize, @bitCast(rc)));
}

fn probe(path: []const u8, label: []const u8) void {
    var pz: [256]u8 = undefined;
    const fd = openRO(&pz, path) orelse {
        std.debug.print("{s:<28} open fallo\n", .{label});
        return;
    };
    defer _ = linux.close(fd);

    var buf: [256 * 1024]u8 = undefined;
    var iov = [1]Vec{ .{ .base = &buf, .len = buf.len } };
    const n = linux.preadv2(fd, &iov, 1, 0, RWF.NOWAIT);
    const e = linux.errno(n);
    if (e != .SUCCESS) {
        std.debug.print("{s:<30} preadv2(NOWAIT) -> {s:<12} FRIO / no soportado\n", .{ label, @tagName(e) });
    } else {
        std.debug.print("{s:<30} preadv2(NOWAIT) -> {d:>8} bytes   CALIENTE\n", .{ label, n });
    }
}

fn evict(path: []const u8) void {
    var pz: [256]u8 = undefined;
    const fd = openRO(&pz, path) orelse return;
    defer _ = linux.close(fd);
    _ = linux.fadvise(fd, 0, 0, ADV);
}

pub fn main() !void {
    probe("/home/danny/Development/ISyCo Git/ZigGrep/src/main.zig", "main.zig (en cache)");
    evict("/home/danny/Development/ISyCo Git/ZigGrep/src/main.zig");
    probe("/home/danny/Development/ISyCo Git/ZigGrep/src/main.zig", "main.zig tras DONTNEED");

    var mk: [256]u8 = undefined;
    for ([_][]const u8{ "/tmp/opencode/probe-a.bin", "/tmp/opencode/probe-b.bin" }) |p| {
        const rc = linux.openat(linux.AT.FDCWD, zpath(&mk, p), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
        if (linux.errno(rc) == .SUCCESS) {
            const fd: i32 = @intCast(@as(isize, @bitCast(rc)));
            var chunk: [8 * 1024 * 1024]u8 = undefined;
            @memset(&chunk, 'x');
            var written: usize = 0;
            while (written < chunk.len) {
                const w = linux.write(fd, chunk[written..].ptr, chunk.len - written);
                if (linux.errno(w) != .SUCCESS) break;
                written += w;
            }
            _ = linux.close(fd);
        }
    }

    probe("/tmp/opencode/probe-a.bin", "8 MB recien escrito");
    evict("/tmp/opencode/probe-a.bin");
    probe("/tmp/opencode/probe-a.bin", "8 MB tras DONTNEED");
    evict("/tmp/opencode/probe-a.bin");
    probe("/tmp/opencode/probe-a.bin", "8 MB tras 2o DONTNEED");

    var pb: [256]u8 = undefined;
    const fdb = openRO(&pb, "/tmp/opencode/probe-b.bin") orelse return;
    defer _ = linux.close(fdb);
    var buf: [256 * 1024]u8 = undefined;
    var iov = [1]Vec{ .{ .base = &buf, .len = buf.len } };
    // lectura normal (sin NOWAIT): trae el fichero a cache
    _ = linux.preadv2(fdb, &iov, 1, 0, 0);
    probe("/tmp/opencode/probe-b.bin", "8 MB tras preadv2 normal");
}
