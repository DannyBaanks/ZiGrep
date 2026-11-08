//! Directory walk built directly on `getdents64`.
//!
//! When sorted mode is requested (--sort / --deterministic), entries are
//! sorted locally within each directory and emitted in deterministic
//! lexicographical order matching GNU grep traversal without memory bloat.
//!
//! Symlinks, sockets, fifos and device nodes are never followed or searched,
//! matching both `grep -r` (no `-R`) and ripgrep defaults.
const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const filter = @import("filter.zig");
const FilterEngine = filter.FilterEngine;

/// Hard guard against pathological trees. Deeper than this is reported as an
/// error rather than risking a stack overflow in the recursive descent.
pub const max_depth = 512;

/// Bytes read from a directory per `getdents64` syscall.
pub const dirent_buffer_bytes = 32 * 1024;

pub const Error = error{
    OutOfMemory,
    OpenFailed,
    ReadFailed,
    TooDeep,
};

pub const Item = struct {
    path: [:0]const u8,
    kind: u8,

    pub fn lessThan(_: void, a: Item, b: Item) bool {
        return std.mem.order(u8, a.path, b.path) == .lt;
    }
};

/// Appends every regular file reachable from `roots` to `out`.
/// If `filter_engine` is provided, noisy directories (.git, node_modules, etc.)
/// and ignored files are pruned immediately during getdents64 scanning.
pub fn walk(
    gpa: Allocator,
    roots: []const [:0]const u8,
    out: *std.ArrayList([:0]const u8),
    filter_engine: ?*const FilterEngine,
) Error!void {
    for (roots) |root| try walkOne(gpa, root, out, 0, filter_engine);
}

fn childPath(gpa: Allocator, dir: [:0]const u8, name: []const u8) Allocator.Error![:0]const u8 {
    if (dir.len > 0 and dir[dir.len - 1] == '/') {
        return std.fmt.allocPrintSentinel(gpa, "{s}{s}", .{ dir, name }, 0);
    }
    return std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, name }, 0);
}

fn walkOne(
    gpa: Allocator,
    dir: [:0]const u8,
    out: *std.ArrayList([:0]const u8),
    depth: usize,
    filter_engine: ?*const FilterEngine,
) Error!void {
    if (depth > max_depth) return error.TooDeep;

    const rc = linux.openat(linux.AT.FDCWD, dir, .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    const open_err = linux.errno(rc);
    if (open_err != .SUCCESS) {
        // A non-directory operand is simply a file to search.
        if (open_err == .NOTDIR) {
            try out.append(gpa, dir);
            return;
        }
        return error.OpenFailed;
    }
    const fd: i32 = @intCast(@as(isize, @bitCast(rc)));
    defer _ = linux.close(fd);

    var items: std.ArrayList(Item) = .empty;
    defer items.deinit(gpa);

    const buf = try gpa.alloc(u8, dirent_buffer_bytes);
    defer gpa.free(buf);

    while (true) {
        const n = linux.getdents64(fd, buf.ptr, buf.len);
        const rd_err = linux.errno(n);
        if (rd_err == .INTR) continue;
        if (rd_err != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;

        var off: usize = 0;
        while (off < n) {
            const ent: *align(1) const linux.dirent64 = @ptrCast(&buf[off]);
            const reclen: usize = ent.reclen;
            if (reclen == 0) break; // corrupt record: stop rather than spin
            const name: [:0]const u8 = std.mem.sliceTo(
                @as([*:0]const u8, @ptrCast(buf.ptr + off + @offsetOf(linux.dirent64, "name"))),
                0,
            );
            off += reclen;

            if (name.len == 0) continue;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

            var kind: u8 = ent.type;
            if (kind == linux.DT.DIR) {
                if (filter_engine) |fe| {
                    if (fe.isDirExcluded(name)) continue;
                }
                const child = try childPath(gpa, dir, name);
                try items.append(gpa, .{ .path = child, .kind = kind });
                continue;
            } else if (kind == linux.DT.REG) {
                if (filter_engine) |fe| {
                    if (fe.isFileExcluded(name)) continue;
                }
                const child = try childPath(gpa, dir, name);
                try items.append(gpa, .{ .path = child, .kind = kind });
                continue;
            }
            if (kind != linux.DT.UNKNOWN) continue; // symlink / socket / fifo / device

            // Filesystem did not provide d_type: ask the kernel once.
            const child = try childPath(gpa, dir, name);
            var stx: linux.Statx = undefined;
            const src = linux.statx(
                linux.AT.FDCWD,
                child,
                @intCast(linux.AT.SYMLINK_NOFOLLOW),
                .{ .TYPE = true },
                &stx,
            );
            if (linux.errno(src) != .SUCCESS) {
                gpa.free(child);
                continue;
            }
            const m = stx.mode & linux.S.IFMT;
            if (m == linux.S.IFDIR) {
                if (filter_engine) |fe| {
                    if (fe.isDirExcluded(name)) {
                        gpa.free(child);
                        continue;
                    }
                }
                kind = linux.DT.DIR;
                try items.append(gpa, .{ .path = child, .kind = kind });
            } else if (m == linux.S.IFREG) {
                if (filter_engine) |fe| {
                    if (fe.isFileExcluded(name)) {
                        gpa.free(child);
                        continue;
                    }
                }
                kind = linux.DT.REG;
                try items.append(gpa, .{ .path = child, .kind = kind });
            } else {
                gpa.free(child);
            }
        }
    }

    // Deterministic per-directory sort
    std.sort.pdq(Item, items.items, {}, Item.lessThan);

    for (items.items) |it| {
        if (it.kind == linux.DT.DIR) {
            try walkOne(gpa, it.path, out, depth + 1, filter_engine);
        } else {
            try out.append(gpa, it.path);
        }
    }
}

test "childPath: no doubled slash, root handled" {
    const gpa = std.testing.allocator;
    {
        const p = try childPath(gpa, "a/b", "c.txt");
        defer gpa.free(p);
        try std.testing.expectEqualStrings("a/b/c.txt", p);
    }
    {
        const p = try childPath(gpa, "a/b/", "c.txt");
        defer gpa.free(p);
        try std.testing.expectEqualStrings("a/b/c.txt", p);
    }
    {
        const p = try childPath(gpa, "/", "etc");
        defer gpa.free(p);
        try std.testing.expectEqualStrings("/etc", p);
    }
}
