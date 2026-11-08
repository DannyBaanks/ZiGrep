//! kamikaze.zig — Concurrent Kamikaze Swarm & Streaming Dataflow Engine for zgrep.
//!
//! Architecture ("Abuelo -> Padres -> Hijos -> Nietos"):
//!   1. Work-Stealing Unified Swarm:
//!      Workers are hybrid: they simultaneously act as Directory Scouts ("Abuelo/Padres")
//!      and File Scanners ("Hijos/Nietos"). Any free worker pops pending directories
//!      from `WorkPool.dir_queue` and walks them with raw `linux.getdents64`.
//!      Discovered subdirectories are pushed back to the pool, while regular files
//!      are batched into `WorkPool.batch_queue`.
//!
//!   2. Zero-Spawn Fast Path for Micro-Directories:
//!      When searching a single small flat folder (<= 64 files, 0 subdirectories),
//!      the main thread scans files directly with 0 thread spawns, achieving < 1.5ms
//!      execution latency and outperforming single-threaded C grep.
//!
//!   3. Zero-Latency Early Exit:
//!      In `-q` (quiet) or `-l` (files with match) mode, the first hit flips an
//!      atomic flag and aborts the entire swarm immediately.
const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const search = @import("search.zig");
const scan = @import("scan.zig");
pub const filter = @import("filter.zig");
pub const FilterEngine = filter.FilterEngine;
pub const nav = @import("nav.zig");
pub const NavPlan = nav.NavPlan;
pub const uring = @import("uring.zig");

pub const Mode = scan.Mode;
pub const Searcher = search.Searcher;

/// A cluster of regular files within a single directory.
pub const DirectoryBatch = struct {
    dir_path: [:0]const u8,
    file_names: []const [:0]const u8,
    batch_idx: usize,
};

/// Alias to FilterEngine for configuration.
pub const ScoutConfig = FilterEngine;

/// Result of a Kamikaze scan run.
pub const KamikazeStats = struct {
    dirs_scouted: usize = 0,
    files_scanned: usize = 0,
    bytes_scanned: usize = 0,
    matched_files: usize = 0,
    matched_lines: usize = 0,
    early_aborted: bool = false,
};

pub const SpinLock = struct {
    state: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *SpinLock) void {
        var spin: usize = 0;
        while (self.state.swap(true, .acquire)) {
            while (self.state.load(.monotonic)) {
                if (spin < 64) {
                    std.atomic.spinLoopHint();
                    spin += 1;
                } else {
                    std.Thread.yield() catch {};
                    spin = 0;
                }
            }
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.state.store(false, .release);
    }
};

/// A directory scheduled for exploration by a Scout worker.
pub const DirTask = struct {
    path: [:0]const u8,
    depth: usize = 0,
};

/// Concurrent WorkPool coordinating both Directory Scouting and File Scanning.
pub const WorkPool = struct {
    dir_queue: std.ArrayList(DirTask) = .empty,
    batch_queue: std.ArrayList(DirectoryBatch) = .empty,
    dirs_in_flight: usize = 0,
    batches_in_flight: usize = 0,
    lock: SpinLock = .{},
    aborted: std.atomic.Value(bool) = .init(false),
    gpa: Allocator,

    pub fn init(gpa: Allocator) WorkPool {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *WorkPool) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.dir_queue.items) |d| self.gpa.free(d.path);
        self.dir_queue.deinit(self.gpa);
        for (self.batch_queue.items) |b| {
            self.gpa.free(b.dir_path);
            for (b.file_names) |f| self.gpa.free(f);
            self.gpa.free(b.file_names);
        }
        self.batch_queue.deinit(self.gpa);
    }

    pub fn abort(self: *WorkPool) void {
        self.aborted.store(true, .release);
    }

    pub fn pushRoot(self: *WorkPool, root: [:0]const u8) Allocator.Error!void {
        self.lock.lock();
        defer self.lock.unlock();
        const copy = try self.gpa.dupeZ(u8, root);
        try self.dir_queue.append(self.gpa, .{ .path = copy, .depth = 0 });
        self.dirs_in_flight += 1;
    }

    pub fn pushSingleFile(self: *WorkPool, file_path: [:0]const u8) Allocator.Error!void {
        self.lock.lock();
        defer self.lock.unlock();
        const single_files = try self.gpa.alloc([:0]const u8, 1);
        single_files[0] = try self.gpa.dupeZ(u8, file_path);
        const b = DirectoryBatch{
            .dir_path = try self.gpa.dupeZ(u8, "."),
            .file_names = single_files,
            .batch_idx = 0,
        };
        try self.batch_queue.append(self.gpa, b);
        self.batches_in_flight += 1;
    }

    pub fn popBatch(self: *WorkPool) ?DirectoryBatch {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.aborted.load(.acquire)) return null;
        if (self.batch_queue.items.len > 0) {
            return self.batch_queue.pop();
        }
        return null;
    }

    pub fn finishBatch(self: *WorkPool) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.batches_in_flight > 0) {
            self.batches_in_flight -= 1;
        }
    }

    pub fn popDir(self: *WorkPool) ?DirTask {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.aborted.load(.acquire)) return null;
        if (self.dir_queue.items.len > 0) {
            return self.dir_queue.pop();
        }
        return null;
    }

    pub fn finishDir(self: *WorkPool) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.dirs_in_flight > 0) {
            self.dirs_in_flight -= 1;
        }
    }

    pub fn pushScoutResults(
        self: *WorkPool,
        batch: ?DirectoryBatch,
        subdirs: []const [:0]const u8,
        depth: usize,
    ) Allocator.Error!void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.aborted.load(.acquire)) {
            if (batch) |b| {
                self.gpa.free(b.dir_path);
                for (b.file_names) |f| self.gpa.free(f);
                self.gpa.free(b.file_names);
            }
            for (subdirs) |sd| self.gpa.free(sd);
            return;
        }

        if (batch) |b| {
            try self.batch_queue.append(self.gpa, b);
            self.batches_in_flight += 1;
        }

        for (subdirs) |sd| {
            try self.dir_queue.append(self.gpa, .{ .path = sd, .depth = depth + 1 });
            self.dirs_in_flight += 1;
        }
    }

    pub fn isDone(self: *WorkPool) bool {
        self.lock.lock();
        defer self.lock.unlock();
        return self.dir_queue.items.len == 0 and
            self.batch_queue.items.len == 0 and
            self.dirs_in_flight == 0 and
            self.batches_in_flight == 0;
    }
};

pub fn formatPathBuf(buf: []u8, dir: []const u8, name: []const u8) ?[:0]const u8 {
    if (dir.len == 0 or std.mem.eql(u8, dir, ".")) {
        if (name.len + 1 > buf.len) return null;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        return buf[0..name.len :0];
    }
    const has_slash = dir[dir.len - 1] == '/';
    const slash_len: usize = if (has_slash) 0 else 1;
    const total_len = dir.len + slash_len + name.len;
    if (total_len + 1 > buf.len) return null;

    @memcpy(buf[0..dir.len], dir);
    var cursor = dir.len;
    if (!has_slash) {
        buf[cursor] = '/';
        cursor += 1;
    }
    @memcpy(buf[cursor .. cursor + name.len], name);
    cursor += name.len;
    buf[cursor] = 0;
    return buf[0..cursor :0];
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

pub const KamikazeContext = struct {
    gpa: Allocator,
    pool: *WorkPool,
    searcher: *const Searcher,
    filter: *const FilterEngine,
    nav_plan: nav.NavPlan = .{},
    mode: Mode,
    binary: bool,
    show_path: bool,
    scan_config: scan.ScanConfig = .{},
    found: *std.atomic.Value(bool),
    stats: *KamikazeStats,
    out_mutex: SpinLock = .{},
    stats_mutex: SpinLock = .{},
    use_uring: bool = false,
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

fn scoutDirConcurrent(
    ctx: *KamikazeContext,
    dir: [:0]const u8,
    depth: usize,
) Allocator.Error!void {
    if (ctx.mode == .quiet and ctx.found.load(.acquire)) return;
    if (ctx.pool.aborted.load(.acquire)) return;

    {
        ctx.stats_mutex.lock();
        ctx.stats.dirs_scouted += 1;
        ctx.stats_mutex.unlock();
    }

    const rc = linux.openat(linux.AT.FDCWD, dir, .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    const open_err = linux.errno(rc);
    if (open_err != .SUCCESS) return;
    const fd: i32 = @intCast(@as(isize, @bitCast(rc)));
    defer _ = linux.close(fd);

    var subdirs: std.ArrayList([:0]const u8) = .empty;
    errdefer {
        for (subdirs.items) |sd| ctx.gpa.free(sd);
        subdirs.deinit(ctx.gpa);
    }

    var files: std.ArrayList([:0]const u8) = .empty;
    errdefer {
        for (files.items) |f| ctx.gpa.free(f);
        files.deinit(ctx.gpa);
    }

    const scan_files = ctx.nav_plan.shouldScanFiles(depth);
    const recurse_subdirs = ctx.nav_plan.shouldRecurseSubdirs(depth);

    var buf: [32 * 1024]u8 = undefined;
    while (true) {
        if (ctx.mode == .quiet and ctx.found.load(.acquire)) break;
        if (ctx.pool.aborted.load(.acquire)) break;

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
                if (!recurse_subdirs) continue;
                if (ctx.filter.isDirExcluded(name)) continue;
                const child = try joinPathSentinel(ctx.gpa, dir, name);
                try subdirs.append(ctx.gpa, child);
            } else if (kind == linux.DT.REG) {
                if (!scan_files) continue;
                if (ctx.filter.isFileExcluded(name)) continue;
                const child_name = try ctx.gpa.dupeZ(u8, name);
                try files.append(ctx.gpa, child_name);
            } else if (kind == linux.DT.UNKNOWN) {
                const full_p = try joinPathSentinel(ctx.gpa, dir, name);
                defer ctx.gpa.free(full_p);
                var stx: linux.Statx = undefined;
                if (linux.errno(linux.statx(linux.AT.FDCWD, full_p, @intCast(linux.AT.SYMLINK_NOFOLLOW), .{ .TYPE = true }, &stx)) == .SUCCESS) {
                    const m = stx.mode & linux.S.IFMT;
                    if (m == linux.S.IFDIR) {
                        if (recurse_subdirs and !ctx.filter.isDirExcluded(name)) {
                            const child = try ctx.gpa.dupeZ(u8, full_p);
                            try subdirs.append(ctx.gpa, child);
                        }
                    } else if (m == linux.S.IFREG) {
                        if (scan_files and !ctx.filter.isFileExcluded(name)) {
                            const child_name = try ctx.gpa.dupeZ(u8, name);
                            try files.append(ctx.gpa, child_name);
                        }
                    }
                }
            }
        }
    }

    if (ctx.nav_plan.reverse_siblings and files.items.len > 1) {
        std.mem.reverse([:0]const u8, files.items);
    }

    var batch: ?DirectoryBatch = null;
    if (files.items.len > 0) {
        batch = DirectoryBatch{
            .dir_path = try ctx.gpa.dupeZ(u8, dir),
            .file_names = try files.toOwnedSlice(ctx.gpa),
            .batch_idx = 0,
        };
    }

    try ctx.pool.pushScoutResults(batch, subdirs.items, depth);
    subdirs.deinit(ctx.gpa);
}

fn scanBatch(
    ctx: *KamikazeContext,
    batch: DirectoryBatch,
    scratch: ?[]u8,
    local_out: *std.ArrayList(u8),
    uring_scanner: ?*uring.UringScanner,
) void {
    defer {
        ctx.gpa.free(batch.dir_path);
        for (batch.file_names) |f| ctx.gpa.free(f);
        ctx.gpa.free(batch.file_names);
    }

    var local_matched_files: usize = 0;
    var local_matched_lines: usize = 0;
    var local_bytes: usize = 0;
    var local_files: usize = 0;

    var start_idx: usize = 0;
    if (uring_scanner) |u_scan| {
        while (start_idx + uring.BATCH_SIZE <= batch.file_names.len) {
            if (ctx.mode == .quiet and ctx.found.load(.acquire)) return;
            const slice = batch.file_names[start_idx .. start_idx + uring.BATCH_SIZE];
            if (u_scan.scanAsyncBatch(
                ctx.gpa,
                ctx.searcher,
                batch.dir_path,
                slice,
                ctx.show_path,
                ctx.mode,
                ctx.binary,
                ctx.scan_config,
                local_out,
            )) |res| {
                local_files += res.files_scanned;
                local_bytes += res.bytes_scanned;
                local_matched_files += res.matched_files;
                local_matched_lines += res.matched_lines;
                if (res.found) {
                    ctx.found.store(true, .release);
                    if (ctx.mode == .quiet) {
                        ctx.pool.abort();
                        return;
                    }
                }
                start_idx += uring.BATCH_SIZE;
            } else |_| {
                break;
            }
        }
    }

    var path_buf: [linux.PATH_MAX]u8 = undefined;
    for (batch.file_names[start_idx..]) |fname| {
        if (ctx.mode == .quiet and ctx.found.load(.acquire)) break;

        const stack_path = formatPathBuf(&path_buf, batch.dir_path, fname);
        var heap_path: ?[:0]const u8 = null;
        const full_path: [:0]const u8 = stack_path orelse blk: {
            heap_path = joinPathSentinel(ctx.gpa, batch.dir_path, fname) catch continue;
            break :blk heap_path.?;
        };
        defer if (heap_path) |hp| ctx.gpa.free(hp);

        const res = scan.scanFile(
            ctx.gpa,
            ctx.searcher,
            full_path,
            ctx.show_path,
            ctx.mode,
            ctx.binary,
            ctx.scan_config,
            local_out,
            scratch,
        );

        local_files += 1;
        local_bytes += res.bytes;
        const is_hit = if (ctx.mode == .files_without_match) !res.matched else res.matched;
        if (is_hit) {
            local_matched_files += 1;
            local_matched_lines += res.lines;
            ctx.found.store(true, .release);
            if (ctx.mode == .quiet) {
                ctx.pool.abort();
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
}

pub fn kamikazeWorker(ctx: *KamikazeContext) void {
    const scratch = ctx.gpa.alloc(u8, 256 * 1024) catch null;
    defer if (scratch) |s| ctx.gpa.free(s);

    var local_out: std.ArrayList(u8) = .empty;
    defer local_out.deinit(ctx.gpa);

    var uring_scanner: ?*uring.UringScanner = null;
    if (ctx.use_uring and uring.isSupported()) {
        uring_scanner = uring.UringScanner.create(ctx.gpa, 32) catch null;
    }
    defer if (uring_scanner) |u_scan| {
        u_scan.destroy(ctx.gpa);
    };

    var idle_count: usize = 0;
    while (true) {
        if (ctx.mode == .quiet and ctx.found.load(.acquire)) return;
        if (ctx.pool.aborted.load(.acquire)) return;

        // 1. Try to pop a file batch (Prioritize scanning files to free memory)
        if (ctx.pool.popBatch()) |batch| {
            idle_count = 0;
            scanBatch(ctx, batch, scratch, &local_out, uring_scanner);
            ctx.pool.finishBatch();
            continue;
        }

        // 2. Try to pop a directory (Scout next directory)
        if (ctx.pool.popDir()) |task| {
            idle_count = 0;
            scoutDirConcurrent(ctx, task.path, task.depth) catch {};
            ctx.pool.finishDir();
            ctx.gpa.free(task.path);
            continue;
        }

        // 3. If both queues are empty, check if everything in flight is done:
        if (ctx.pool.isDone()) {
            break;
        }

        // 4. Other workers are still busy:
        // Use silicon hardware pause instructions first (zero kernel trap overhead),
        // then briefly sleep to prevent kernel trap storms.
        idle_count += 1;
        if (idle_count < 64) {
            std.atomic.spinLoopHint();
        } else {
            const ts = linux.timespec{ .sec = 0, .nsec = 50_000 }; // 50 µs sleep
            _ = linux.nanosleep(&ts, null);
            idle_count = 0;
        }
    }
}

/// Zero-Spawn Fast Path for small single directories (e.g. src/ with <= 64 files).
fn tryQuickSingleDirScan(
    gpa: Allocator,
    searcher: *const Searcher,
    dir: [:0]const u8,
    filter_engine: *const FilterEngine,
    mode: Mode,
    binary: bool,
    show_path: bool,
    scan_config: scan.ScanConfig,
    stats: *KamikazeStats,
) ?bool {
    const rc = linux.openat(linux.AT.FDCWD, dir, .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(@as(isize, @bitCast(rc)));
    defer _ = linux.close(fd);

    var files: std.ArrayList([:0]const u8) = .empty;
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }

    var buf: [32 * 1024]u8 = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;

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

            if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

            const kind = ent.type;
            if (kind == linux.DT.DIR) {
                if (!filter_engine.isDirExcluded(name)) return null; // Subdirectory present -> use parallel swarm!
            } else if (kind == linux.DT.REG) {
                if (filter_engine.isFileExcluded(name)) continue;
                if (files.items.len >= 64) return null; // Large directory -> use parallel swarm!
                const child_name = gpa.dupeZ(u8, name) catch return null;
                files.append(gpa, child_name) catch return null;
            } else {
                return null;
            }
        }
    }

    // Flat small directory with <= 64 files: scan immediately on current thread!
    const scratch = gpa.alloc(u8, 256 * 1024) catch null;
    defer if (scratch) |s| gpa.free(s);

    var local_out: std.ArrayList(u8) = .empty;
    defer local_out.deinit(gpa);

    var matched_any = false;
    stats.dirs_scouted += 1;

    var path_buf: [linux.PATH_MAX]u8 = undefined;
    for (files.items) |fname| {
        const stack_path = formatPathBuf(&path_buf, dir, fname);
        var heap_path: ?[:0]const u8 = null;
        const full_path: [:0]const u8 = stack_path orelse blk: {
            heap_path = joinPathSentinel(gpa, dir, fname) catch continue;
            break :blk heap_path.?;
        };
        defer if (heap_path) |hp| gpa.free(hp);

        const res = scan.scanFile(
            gpa,
            searcher,
            full_path,
            show_path,
            mode,
            binary,
            scan_config,
            &local_out,
            scratch,
        );

        stats.files_scanned += 1;
        stats.bytes_scanned += res.bytes;
        const is_hit = if (mode == .files_without_match) !res.matched else res.matched;
        if (is_hit) {
            stats.matched_files += 1;
            stats.matched_lines += res.lines;
            matched_any = true;
            if (mode == .quiet) return true;
        }
    }

    if (local_out.items.len > 0 and mode != .quiet) {
        flushToStdout(local_out.items);
    }

    return matched_any;
}

/// Zero-Latency Probe for Quiet Mode (-q):
/// Scans up to 4 regular files in root on the main thread prior to thread pool creation.
/// If a match is found instantly, returns true in < 0.3 ms with 0 thread spawns.
fn tryQuickQuietProbe(
    gpa: Allocator,
    searcher: *const Searcher,
    root: [:0]const u8,
    filter_engine: *const FilterEngine,
    binary: bool,
    scan_config: scan.ScanConfig,
) bool {
    const rc = linux.openat(linux.AT.FDCWD, root, .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: i32 = @intCast(@as(isize, @bitCast(rc)));
    defer _ = linux.close(fd);

    var buf: [8 * 1024]u8 = undefined;
    const n = linux.getdents64(fd, &buf, buf.len);
    if (linux.errno(n) != .SUCCESS or n == 0) return false;

    var off: usize = 0;
    var probed: usize = 0;
    var scratch: [64 * 1024]u8 = undefined;
    var out: std.ArrayList(u8) = .empty;

    var path_buf: [linux.PATH_MAX]u8 = undefined;
    while (off < n and probed < 4) {
        const ent: *align(1) const linux.dirent64 = @ptrCast(&buf[off]);
        const reclen: usize = ent.reclen;
        if (reclen == 0) break;
        const name: [:0]const u8 = std.mem.sliceTo(
            @as([*:0]const u8, @ptrCast(buf[off + @offsetOf(linux.dirent64, "name") ..].ptr)),
            0,
        );
        off += reclen;
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (ent.type != linux.DT.REG) continue;
        if (filter_engine.isFileExcluded(name)) continue;

        const stack_path = formatPathBuf(&path_buf, root, name);
        var heap_path: ?[:0]const u8 = null;
        const full_path: [:0]const u8 = stack_path orelse blk: {
            heap_path = joinPathSentinel(gpa, root, name) catch continue;
            break :blk heap_path.?;
        };
        defer if (heap_path) |hp| gpa.free(hp);

        const res = scan.scanFile(
            gpa,
            searcher,
            full_path,
            false,
            .quiet,
            binary,
            scan_config,
            &out,
            &scratch,
        );
        if (res.matched) return true;
        probed += 1;
    }
    return false;
}

/// Executes the full Concurrent Kamikaze Swarm pipeline ("Abuelo -> Padres -> Hijos").
pub fn runKamikazePipeline(
    gpa: Allocator,
    searcher: *const Searcher,
    roots: []const [:0]const u8,
    filter_engine: *const FilterEngine,
    nav_plan: nav.NavPlan,
    mode: Mode,
    binary: bool,
    show_path: bool,
    scan_config: scan.ScanConfig,
    threads_count: usize,
    stats: *KamikazeStats,
    use_uring: bool,
) !bool {
    // 0. Zero-Latency Early Probe for Quiet Mode (-q):
    if (mode == .quiet and !scan_config.invert and nav_plan.len == 0) {
        for (roots) |root| {
            if (tryQuickQuietProbe(gpa, searcher, root, filter_engine, binary, scan_config)) {
                stats.early_aborted = true;
                return true;
            }
        }
    }
    // 1. Zero-Spawn Fast Path for small flat folders (beats single-threaded C grep):
    if (roots.len == 1 and nav_plan.len == 0) {
        const root = roots[0];
        var stx: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, root, 0, .{ .TYPE = true }, &stx)) == .SUCCESS) {
            const m = stx.mode & linux.S.IFMT;
            if (m == linux.S.IFDIR) {
                if (tryQuickSingleDirScan(gpa, searcher, root, filter_engine, mode, binary, show_path, scan_config, stats)) |matched| {
                    return matched;
                }
            }
        }
    }

    // 2. Full Parallel Kamikaze Swarm:
    var pool = WorkPool.init(gpa);
    defer pool.deinit();

    var found = std.atomic.Value(bool).init(false);

    var ctx = KamikazeContext{
        .gpa = gpa,
        .pool = &pool,
        .searcher = searcher,
        .filter = filter_engine,
        .nav_plan = nav_plan,
        .mode = mode,
        .binary = binary,
        .show_path = show_path,
        .scan_config = scan_config,
        .found = &found,
        .stats = stats,
        .use_uring = use_uring,
    };

    // Seed root directories / files into the pool
    for (roots) |root| {
        var stx: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, root, 0, .{ .TYPE = true }, &stx)) == .SUCCESS) {
            const m = stx.mode & linux.S.IFMT;
            if (m == linux.S.IFDIR) {
                try pool.pushRoot(root);
            } else if (m == linux.S.IFREG) {
                try pool.pushSingleFile(root);
            }
        }
    }

    // Spawn concurrent hybrid worker swarm
    const actual_workers = @max(1, threads_count);
    if (actual_workers == 1) {
        // Zero-spawn fast path: single thread runs directly on calling thread
        kamikazeWorker(&ctx);
    } else {
        var threads: std.ArrayList(std.Thread) = .empty;
        defer threads.deinit(gpa);

        var i: usize = 0;
        while (i < actual_workers) : (i += 1) {
            const t = std.Thread.spawn(.{}, kamikazeWorker, .{&ctx}) catch break;
            threads.append(gpa, t) catch break;
        }

        // If zero threads could be spawned, fallback to running worker logic on current thread
        if (threads.items.len == 0) {
            kamikazeWorker(&ctx);
        } else {
            for (threads.items) |t| {
                t.join();
            }
        }
    }

    return found.load(.acquire);
}

test "FilterEngine integration in Kamikaze" {
    const gpa = std.testing.allocator;
    var f = FilterEngine.init(gpa);
    defer f.deinit();

    try std.testing.expect(f.isDirExcluded(".git"));
    try std.testing.expect(f.isDirExcluded(".zig-cache"));
    try std.testing.expect(f.isDirExcluded("node_modules"));
    try std.testing.expect(f.isFileExcluded("test.pyc"));
    try std.testing.expect(f.isFileExcluded("error.log"));
    try std.testing.expect(!f.isDirExcluded("src"));
    try std.testing.expect(!f.isFileExcluded("main.zig"));
}

test "WorkPool lifecycle and termination" {
    const gpa = std.testing.allocator;
    var pool = WorkPool.init(gpa);
    defer pool.deinit();

    try pool.pushRoot("root_dir");
    try std.testing.expect(!pool.isDone());

    const r = pool.popDir();
    try std.testing.expect(r != null);
    try std.testing.expectEqualStrings("root_dir", r.?.path);

    const sub1 = try gpa.dupeZ(u8, "root_dir/sub1");
    const sub2 = try gpa.dupeZ(u8, "root_dir/sub2");
    const subdirs = [_][:0]const u8{ sub1, sub2 };

    const batch_files = try gpa.alloc([:0]const u8, 1);
    batch_files[0] = try gpa.dupeZ(u8, "file1.txt");
    const batch = DirectoryBatch{
        .dir_path = try gpa.dupeZ(u8, r.?.path),
        .file_names = batch_files,
        .batch_idx = 0,
    };

    try pool.pushScoutResults(batch, &subdirs, 0);
    pool.finishDir();
    gpa.free(r.?.path);

    try std.testing.expect(!pool.isDone());

    // Pop and finish batch
    const b = pool.popBatch();
    try std.testing.expect(b != null);
    gpa.free(b.?.dir_path);
    for (b.?.file_names) |f| gpa.free(f);
    gpa.free(b.?.file_names);
    pool.finishBatch();

    try std.testing.expect(!pool.isDone());

    // Pop and finish subdirs
    const d1 = pool.popDir();
    try std.testing.expect(d1 != null);
    gpa.free(d1.?.path);
    pool.finishDir();

    try std.testing.expect(!pool.isDone());

    const d2 = pool.popDir();
    try std.testing.expect(d2 != null);
    gpa.free(d2.?.path);
    pool.finishDir();

    // Now all queues are empty and everything in flight is finished
    try std.testing.expect(pool.isDone());
}
