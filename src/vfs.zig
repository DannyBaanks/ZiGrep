//! Platform filesystem adapter. Linux keeps the raw getdents64 fast path;
//! other hosts use Zig's native Io directory and metadata APIs.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const EntryKind = enum {
    file,
    directory,
    symlink,
    unknown,
    other,
};

pub const Entry = struct {
    name: []const u8,
    kind: EntryKind,
};

pub const Metadata = struct {
    kind: EntryKind,
    size: u64,
};

pub const Error = error{
    OpenFailed,
    ReadFailed,
};

fn normalizedDriveRoot(path: []const u8, buffer: *[5:0]u8) ?[:0]const u8 {
    if (builtin.os.tag != .windows or path.len != 3 or path[1] != ':' or (path[2] != '\\' and path[2] != '/')) {
        return null;
    }
    @memcpy(buffer[0..3], path[0..3]);
    buffer[3] = '.';
    buffer[4] = 0;
    return buffer[0..4 :0];
}

pub fn statFile(
    io: std.Io,
    path: []const u8,
    options: std.Io.Dir.StatFileOptions,
) std.Io.Dir.StatFileError!std.Io.File.Stat {
    var root_buffer: [5:0]u8 = undefined;
    if (normalizedDriveRoot(path, &root_buffer)) |normalized| {
        return std.Io.Dir.cwd().statFile(io, normalized, options);
    }
    return std.Io.Dir.cwd().statFile(io, path, options);
}

const LinuxState = struct {
    fd: i32,
    buffer: [32 * 1024]u8 = undefined,
    bytes_read: usize = 0,
    offset: usize = 0,
};

const PortableState = struct {
    dir: std.Io.Dir,
    iterator: std.Io.Dir.Iterator,
};

pub const DirStream = struct {
    io: std.Io,
    state: union(enum) {
        linux: LinuxState,
        portable: PortableState,
    },

    pub fn open(io: std.Io, path: [:0]const u8) Error!DirStream {
        if (builtin.os.tag == .linux) {
            const linux = std.os.linux;
            const rc = linux.openat(linux.AT.FDCWD, path, .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
            if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
            const fd: i32 = @intCast(@as(isize, @bitCast(rc)));
            return .{ .io = io, .state = .{ .linux = .{ .fd = fd } } };
        }

        var root_buffer: [5:0]u8 = undefined;
        const open_path = normalizedDriveRoot(path, &root_buffer) orelse path;
        const dir = std.Io.Dir.cwd().openDir(io, open_path, .{ .iterate = true }) catch return error.OpenFailed;
        return .{
            .io = io,
            .state = .{ .portable = .{
                .dir = dir,
                .iterator = std.Io.Dir.iterateAssumeFirstIteration(dir),
            } },
        };
    }

    pub fn close(self: *DirStream) void {
        switch (self.state) {
            .linux => |state| _ = std.os.linux.close(state.fd),
            .portable => |state| state.dir.close(self.io),
        }
    }

    pub fn next(self: *DirStream) Error!?Entry {
        switch (self.state) {
            .linux => |*state| {
                const linux = std.os.linux;
                while (true) {
                    if (state.offset >= state.bytes_read) {
                        const n = linux.getdents64(state.fd, &state.buffer, state.buffer.len);
                        const err = linux.errno(n);
                        if (err == .INTR) continue;
                        if (err != .SUCCESS) return error.ReadFailed;
                        if (n == 0) return null;
                        state.bytes_read = @intCast(n);
                        state.offset = 0;
                    }

                    const ent: *align(1) const linux.dirent64 = @ptrCast(&state.buffer[state.offset]);
                    const reclen: usize = ent.reclen;
                    if (reclen == 0 or state.offset + reclen > state.bytes_read) return error.ReadFailed;
                    const name: [*:0]const u8 = @ptrCast(&state.buffer[state.offset + @offsetOf(linux.dirent64, "name")]);
                    state.offset += reclen;
                    const slice = std.mem.sliceTo(name, 0);
                    if (slice.len == 0 or std.mem.eql(u8, slice, ".") or std.mem.eql(u8, slice, "..")) continue;
                    return .{ .name = slice, .kind = switch (ent.type) {
                        linux.DT.REG => .file,
                        linux.DT.DIR => .directory,
                        linux.DT.LNK => .symlink,
                        linux.DT.UNKNOWN => .unknown,
                        else => .other,
                    } };
                }
            },
            .portable => |*state| {
                const maybe_entry = state.iterator.next(self.io) catch return error.ReadFailed;
                const entry = maybe_entry orelse return null;
                return .{ .name = entry.name, .kind = switch (entry.kind) {
                    .file => .file,
                    .directory => .directory,
                    .sym_link => .symlink,
                    else => .other,
                } };
            },
        }
    }
};

pub fn stat(io: std.Io, path: []const u8, follow_symlinks: bool) ?Metadata {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const path_z = std.heap.page_allocator.dupeZ(u8, path) catch return null;
        defer std.heap.page_allocator.free(path_z);
        var stx: linux.Statx = undefined;
        const flags: u32 = if (follow_symlinks) 0 else @intCast(linux.AT.SYMLINK_NOFOLLOW);
        if (linux.errno(linux.statx(linux.AT.FDCWD, path_z, flags, .{ .TYPE = true }, &stx)) != .SUCCESS) return null;
        const mode = stx.mode & linux.S.IFMT;
        return .{
            .kind = if (mode == linux.S.IFDIR) .directory else if (mode == linux.S.IFREG) .file else if (mode == linux.S.IFLNK) .symlink else .other,
            .size = stx.size,
        };
    }

    const info = statFile(io, path, .{ .follow_symlinks = follow_symlinks }) catch return null;
    return .{
        .kind = switch (info.kind) {
            .file => .file,
            .directory => .directory,
            .sym_link => .symlink,
            else => .other,
        },
        .size = info.size,
    };
}

pub fn joinPathSentinel(gpa: Allocator, dir: []const u8, name: []const u8) Allocator.Error![:0]const u8 {
    if (dir.len == 0 or std.mem.eql(u8, dir, ".")) return gpa.dupeZ(u8, name);

    const drive_relative = builtin.os.tag == .windows and dir.len == 2 and dir[1] == ':';
    const separator: []const u8 = if (drive_relative or dir[dir.len - 1] == '/' or dir[dir.len - 1] == '\\')
        ""
    else
        std.fs.path.sep_str;
    return std.fmt.allocPrintSentinel(gpa, "{s}{s}{s}", .{ dir, separator, name }, 0);
}

test "vfs: open and read current directory" {
    var stream = try DirStream.open(std.testing.io, ".");
    defer stream.close();

    var found_src = false;
    var count: usize = 0;
    while (try stream.next()) |entry| {
        count += 1;
        if (std.mem.eql(u8, entry.name, "src")) {
            found_src = true;
            try std.testing.expectEqual(EntryKind.directory, entry.kind);
        }
    }
    try std.testing.expect(found_src);
    try std.testing.expect(count > 0);
}

test "vfs: native path joining" {
    const joined = try joinPathSentinel(std.testing.allocator, "a", "file.txt");
    defer std.testing.allocator.free(joined);
    try std.testing.expectEqualStrings(if (builtin.os.tag == .windows) "a\\file.txt" else "a/file.txt", joined);
    if (builtin.os.tag == .windows) {
        const drive_relative = try joinPathSentinel(std.testing.allocator, "C:", "file.txt");
        defer std.testing.allocator.free(drive_relative);
        try std.testing.expectEqualStrings("C:file.txt", drive_relative);
    }
}

test "vfs: Windows drive root is stattable and iterable" {
    if (builtin.os.tag != .windows) return;
    const metadata = stat(std.testing.io, "C:\\", true);
    try std.testing.expect(metadata != null);
    try std.testing.expectEqual(EntryKind.directory, metadata.?.kind);

    var stream = try DirStream.open(std.testing.io, "C:\\");
    defer stream.close();
}
