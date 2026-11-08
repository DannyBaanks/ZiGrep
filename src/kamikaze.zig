//! kamikaze.zig — Kamikaze Scout & Streaming Dataflow Engine for zgrep.
//!
//! Architecture:
//!   1. Scout Kamikaze (Directory Topology Radar):
//!      Fast discovery of directory structure using raw `linux.getdents64`.
//!      Separates directories from files with zero full-stat overhead.
//!      Prunes excluded directories (e.g. `--exclude-dir=.git`, `.zig-cache`).
//!      Supports instant abort on early match (`ctx.found == true`).
//!
//!   2. Streaming Dataflow Pipeline:
//!      The Scout emits `DirectoryBatch`es into a bounded concurrent ring buffer.
//!      Worker threads (Kamikaze Scanners) grab batches concurrently and
//!      execute SIMD rarest-byte scans using thread-local scratch buffers.
//!
//!   3. Zero-Latency Early Exit:
//!      In `-q` (quiet) or `-l` (files with match) mode, the first hit flips an
//!      atomic flag that halts both the Scout and all workers immediately,
//!      eliminating the full-walk penalty on large repositories.
const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const search = @import("search.zig");
const scan = @import("scan.zig");

pub const Mode = scan.Mode;
pub const Searcher = search.Searcher;

/// A cluster of regular files within a single directory.
pub const DirectoryBatch = struct {
    dir_path: [:0]const u8,
    file_names: []const [:0]const u8,
    batch_idx: usize,
};

/// Configuration options for the Kamikaze Scout.
pub const ScoutConfig = struct {
    exclude_dirs: []const []const u8 = &.{},
    skip_hidden: bool = false,
    max_depth: usize = 512,
};

/// Result of a Kamikaze scan run.
pub const KamikazeStats = struct {
    dirs_scouted: usize = 0,
    files_scanned: usize = 0,
    bytes_scanned: usize = 0,
    matched_files: usize = 0,
    matched_lines: usize = 0,
    early_aborted: bool = false,
};

/// Thread-safe bounded channel for streaming directory batches from the Scout to Workers.
pub const BatchChannel = struct {
    const QueueCapacity = 512;

    batches: [QueueCapacity]DirectoryBatch = undefined,
    head: std.atomic.Value(usize) = .init(0),
    tail: std.atomic.Value(usize) = .init(0),
    closed: std.atomic.Value(bool) = .init(false),
    aborted: std.atomic.Value(bool) = .init(false),

    pub fn init() BatchChannel {
        return .{};
    }

    pub fn push(self: *BatchChannel, batch: DirectoryBatch) bool {
        while (!self.aborted.load(.acquire)) {
            const h = self.head.load(.monotonic);
            const t = self.tail.load(.acquire);
            if (h - t < QueueCapacity) {
                if (self.head.cmpxchgWeak(h, h + 1, .release, .monotonic) == null) {
                    self.batches[h % QueueCapacity] = batch;
                    return true;
                }
            } else {
                std.Thread.yield() catch {};
            }
        }
        return false;
    }

    pub fn pop(self: *BatchChannel) ?DirectoryBatch {
        while (true) {
            if (self.aborted.load(.acquire)) return null;
            const t = self.tail.load(.monotonic);
            const h = self.head.load(.acquire);
            if (t < h) {
                if (self.tail.cmpxchgWeak(t, t + 1, .release, .monotonic) == null) {
                    return self.batches[t % QueueCapacity];
                }
            } else {
                if (self.closed.load(.acquire)) return null;
                std.Thread.yield() catch {};
            }
        }
    }

    pub fn close(self: *BatchChannel) void {
        self.closed.store(true, .release);
    }

    pub fn abort(self: *BatchChannel) void {
        self.aborted.store(true, .release);
    }
};

/// Helper: checks if a directory name should be excluded.
pub fn isExcluded(dir_name: []const u8, config: ScoutConfig) bool {
    if (config.skip_hidden and dir_name.len > 0 and dir_name[0] == '.') {
        return true;
    }
    for (config.exclude_dirs) |ex| {
        if (std.mem.eql(u8, dir_name, ex)) return true;
    }
    return false;
}

pub fn joinPathSentinel(gpa: Allocator, dir: []const u8, name: []const u8) Allocator.Error![:0]const u8 {
    if (dir.len == 0 or std.mem.eql(u8, dir, ".")) {
        return std.fmt.allocPrintSentinel(gpa, "{s}", .{name}, 0);
    }
    if (dir[dir.len - 1] == '/') {
        return std.fmt.allocPrintSentinel(gpa, "{s}{s}", .{ dir, name }, 0);
    }
    return std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, name }, 0);
}

/// Kamikaze Scout: walks a directory tree, streaming file batches into `channel`.
pub fn scoutTree(
    gpa: Allocator,
    channel: *BatchChannel,
    root: [:0]const u8,
    config: ScoutConfig,
    found: *const std.atomic.Value(bool),
    stats: *KamikazeStats,
) Allocator.Error!void {
    try scoutDir(gpa, channel, root, 0, config, found, stats);
}

fn scoutDir(
    gpa: Allocator,
    channel: *BatchChannel,
    dir: [:0]const u8,
    depth: usize,
    config: ScoutConfig,
    found: *const std.atomic.Value(bool),
    stats: *KamikazeStats,
) Allocator.Error!void {
    if (depth > config.max_depth) return;
    if (found.load(.acquire) or channel.aborted.load(.acquire)) {
        stats.early_aborted = true;
        return;
    }

    stats.dirs_scouted += 1;

    const rc = linux.openat(linux.AT.FDCWD, dir, .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    const open_err = linux.errno(rc);
    if (open_err != .SUCCESS) return;
    const fd: i32 = @intCast(@as(isize, @bitCast(rc)));
    defer _ = linux.close(fd);

    var subdirs: std.ArrayList([:0]const u8) = .empty;
    defer {
        for (subdirs.items) |sd| gpa.free(sd);
        subdirs.deinit(gpa);
    }

    var files: std.ArrayList([:0]const u8) = .empty;
    defer files.deinit(gpa);

    var buf: [32 * 1024]u8 = undefined;
    while (true) {
        if (found.load(.acquire) or channel.aborted.load(.acquire)) {
            stats.early_aborted = true;
            return;
        }

        const n = linux.getdents64(fd, &buf, buf.len);
        const rd_err = linux.errno(n);
        if (rd_err == .INTR) continue;
        if (rd_err != .SUCCESS or n == 0) break;

        var off: usize = 0;
        while (off < n) {
            const ent: *align(1) const linux.dirent64 = @ptrCast(&buf[off]);
            const reclen: usize = ent.reclen;
            if (reclen == 0) break;
            const name: [:0]const u8 = std.mem.sliceTo(
                @as([*:0]const u8, @ptrCast(buf[off + @offsetOf(linux.dirent64, "name") ..].ptr)),
                0,
            );
            off += reclen;

            if (name.len == 0) continue;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

            const kind = ent.type;
            if (kind == linux.DT.DIR) {
                if (isExcluded(name, config)) continue;
                const child = try joinPathSentinel(gpa, dir, name);
                try subdirs.append(gpa, child);
            } else if (kind == linux.DT.REG) {
                const child_name = try gpa.dupeZ(u8, name);
                try files.append(gpa, child_name);
            } else if (kind == linux.DT.UNKNOWN) {
                const full_p = try joinPathSentinel(gpa, dir, name);
                defer gpa.free(full_p);
                var stx: linux.Statx = undefined;
                if (linux.errno(linux.statx(linux.AT.FDCWD, full_p, @intCast(linux.AT.SYMLINK_NOFOLLOW), .{ .TYPE = true }, &stx)) == .SUCCESS) {
                    const m = stx.mode & linux.S.IFMT;
                    if (m == linux.S.IFDIR) {
                        if (!isExcluded(name, config)) {
                            const child = try gpa.dupeZ(u8, full_p);
                            try subdirs.append(gpa, child);
                        }
                    } else if (m == linux.S.IFREG) {
                        const child_name = try gpa.dupeZ(u8, name);
                        try files.append(gpa, child_name);
                    }
                }
            }
        }
    }

    if (files.items.len > 0) {
        const batch_files = try gpa.dupe([:0]const u8, files.items);
        const batch_dir = try gpa.dupeZ(u8, dir);
        const pushed = channel.push(.{
            .dir_path = batch_dir,
            .file_names = batch_files,
            .batch_idx = stats.dirs_scouted,
        });
        if (!pushed) {
            gpa.free(batch_dir);
            for (batch_files) |f| gpa.free(f);
            gpa.free(batch_files);
            return;
        }
    }

    for (subdirs.items) |sd| {
        try scoutDir(gpa, channel, sd, depth + 1, config, found, stats);
    }
}

pub const SpinLock = struct {
    state: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *SpinLock) void {
        while (self.state.swap(true, .acquire)) {
            while (self.state.load(.monotonic)) {
                std.Thread.yield() catch {};
            }
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.state.store(false, .release);
    }
};

pub const KamikazeContext = struct {
    gpa: Allocator,
    channel: *BatchChannel,
    searcher: *const Searcher,
    mode: Mode,
    binary: bool,
    show_path: bool,
    found: *std.atomic.Value(bool),
    stats: *KamikazeStats,
    out_mutex: SpinLock = .{},
    stats_mutex: SpinLock = .{},
};

fn flushToStdout(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const r = linux.write(linux.STDOUT_FILENO, bytes.ptr + off, bytes.len - off);
        const e = linux.errno(r);
        if (e == .INTR) continue;
        if (e != .SUCCESS or r == 0) break;
        off += r;
    }
}

pub fn kamikazeWorker(ctx: *KamikazeContext) void {
    const scratch = ctx.gpa.alloc(u8, 128 * 1024) catch null;
    defer if (scratch) |s| ctx.gpa.free(s);

    var local_out: std.ArrayList(u8) = .empty;
    defer local_out.deinit(ctx.gpa);

    while (true) {
        if (ctx.mode == .quiet and ctx.found.load(.acquire)) return;
        const batch = ctx.channel.pop() orelse return;

        var local_matched_files: usize = 0;
        var local_matched_lines: usize = 0;
        var local_bytes: usize = 0;
        var local_files: usize = 0;

        for (batch.file_names) |fname| {
            if (ctx.mode == .quiet and ctx.found.load(.acquire)) break;

            const full_path = joinPathSentinel(ctx.gpa, batch.dir_path, fname) catch continue;
            defer ctx.gpa.free(full_path);

            const res = scan.scanFile(
                ctx.gpa,
                ctx.searcher,
                full_path,
                ctx.show_path,
                ctx.mode,
                ctx.binary,
                &local_out,
                scratch,
            );

            local_files += 1;
            local_bytes += res.bytes;
            if (res.matched) {
                local_matched_files += 1;
                local_matched_lines += res.lines;
                ctx.found.store(true, .release);
                if (ctx.mode == .quiet) {
                    ctx.channel.abort();
                    break;
                }
            }
        }

        if (local_out.items.len > 0 and ctx.mode != .quiet) {
            ctx.out_mutex.lock();
            defer ctx.out_mutex.unlock();
            flushToStdout(local_out.items);
            local_out.clearRetainingCapacity();
        }

        {
            ctx.stats_mutex.lock();
            defer ctx.stats_mutex.unlock();
            ctx.stats.files_scanned += local_files;
            ctx.stats.bytes_scanned += local_bytes;
            ctx.stats.matched_files += local_matched_files;
            ctx.stats.matched_lines += local_matched_lines;
        }

        ctx.gpa.free(batch.dir_path);
        for (batch.file_names) |f| ctx.gpa.free(f);
        ctx.gpa.free(batch.file_names);
    }
}

/// Executes the full Kamikaze Scout + Streaming Dataflow pipeline.
pub fn runKamikazePipeline(
    gpa: Allocator,
    searcher: *const Searcher,
    roots: []const [:0]const u8,
    config: ScoutConfig,
    mode: Mode,
    binary: bool,
    show_path: bool,
    threads_count: usize,
    stats: *KamikazeStats,
) !bool {
    var channel = BatchChannel.init();
    var found = std.atomic.Value(bool).init(false);

    var ctx = KamikazeContext{
        .gpa = gpa,
        .channel = &channel,
        .searcher = searcher,
        .mode = mode,
        .binary = binary,
        .show_path = show_path,
        .found = &found,
        .stats = stats,
    };

    var threads: std.ArrayList(std.Thread) = .empty;
    defer threads.deinit(gpa);

    const actual_workers = @max(1, threads_count);
    var i: usize = 0;
    while (i < actual_workers) : (i += 1) {
        const t = std.Thread.spawn(.{}, kamikazeWorker, .{&ctx}) catch break;
        threads.append(gpa, t) catch break;
    }

    for (roots) |root| {
        if (found.load(.acquire) and mode == .quiet) break;

        var stx: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, root, 0, .{ .TYPE = true }, &stx)) == .SUCCESS) {
            const m = stx.mode & linux.S.IFMT;
            if (m == linux.S.IFDIR) {
                try scoutTree(gpa, &channel, root, config, &found, stats);
            } else if (m == linux.S.IFREG) {
                const single_files = try gpa.alloc([:0]const u8, 1);
                single_files[0] = try gpa.dupeZ(u8, root);
                _ = channel.push(.{
                    .dir_path = try gpa.dupeZ(u8, "."),
                    .file_names = single_files,
                    .batch_idx = 0,
                });
            }
        }
    }

    channel.close();

    for (threads.items) |t| {
        t.join();
    }

    return found.load(.acquire);
}

test "isExcluded prunes correctly" {
    const conf = ScoutConfig{
        .exclude_dirs = &.{ ".git", ".zig-cache", "node_modules" },
        .skip_hidden = true,
    };
    try std.testing.expect(isExcluded(".git", conf));
    try std.testing.expect(isExcluded(".zig-cache", conf));
    try std.testing.expect(isExcluded("node_modules", conf));
    try std.testing.expect(isExcluded(".hidden_folder", conf));
    try std.testing.expect(!isExcluded("src", conf));
    try std.testing.expect(!isExcluded("workspace", conf));
}

test "BatchChannel push and pop" {
    var chan = BatchChannel.init();
    const files = [_][:0]const u8{ "a.txt", "b.txt" };
    const b = DirectoryBatch{
        .dir_path = "test_dir",
        .file_names = &files,
        .batch_idx = 1,
    };
    try std.testing.expect(chan.push(b));
    const popped = chan.pop();
    try std.testing.expect(popped != null);
    try std.testing.expectEqualStrings("test_dir", popped.?.dir_path);
    try std.testing.expectEqual(@as(usize, 2), popped.?.file_names.len);
}
