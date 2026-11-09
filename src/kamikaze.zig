//! kamikaze.zig — Concurrent Kamikaze Swarm & Streaming Dataflow Engine for zgrep.
//!
//! Architecture ("Abuelo -> Padres -> Hijos -> Nietos"):
//!   1. Work-Stealing Unified Swarm:
//!      Workers are hybrid: they simultaneously act as Directory Scouts ("Abuelo/Padres")
//!      and File Scanners ("Hijos/Nietos"). Any free worker pops pending directories
//!      from `WorkPool.dir_queue` and walks them through the VFS adapter.
//!      Discovered subdirectories are pushed back to the pool, while regular files
//!      are batched into `WorkPool.batch_queue`.
//!
//!   2. Zero-Spawn Fast Path for Micro-Trees:
//!      When searching a single micro-tree (regular files adding up to less
//!      than 2 MB), the main thread scans every file directly with 0 thread
//!      spawns and without the upward `.dataignore`/`.gitignore` walk,
//!      beating single-threaded C grep. `--force-swarm` disables it and
//!      restores the swarm-only behaviour.
//!
//!   3. Zero-Latency Early Exit:
//!      In `-q` (quiet) or `-l` (files with match) mode, the first hit flips an
//!      atomic flag and aborts the entire swarm immediately.
const std = @import("std");
const platform = @import("platform.zig");
const vfs = @import("vfs.zig");
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

/// Upper bound for the worker pool.
///
/// Every worker is an OS thread with its own stack, so the count has to stay
/// bounded. An unbounded value (`-j 18446744073709551615`) used to turn the
/// spawn loop below into an endless create-and-exit cycle: the machine was
/// pinned at 100% CPU and the process could not even be killed promptly.
/// The CLI rejects such values up front; this clamp is the second line of
/// defence for every other caller.
pub const max_threads: usize = 1024;

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
    /// True when the run was served by the zero-thread micro-tree fast path.
    micro_path: bool = false,
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
    // Native separator, so the emitted paths match the ones built by the VFS
    // adapter (`\` on Windows, `/` on POSIX).
    const has_sep = dir[dir.len - 1] == '/' or dir[dir.len - 1] == '\\';
    const sep_len: usize = if (has_sep) 0 else 1;
    const total_len = dir.len + sep_len + name.len;
    if (total_len + 1 > buf.len) return null;

    @memcpy(buf[0..dir.len], dir);
    var cursor = dir.len;
    if (!has_sep) {
        buf[cursor] = std.fs.path.sep;
        cursor += 1;
    }
    @memcpy(buf[cursor .. cursor + name.len], name);
    cursor += name.len;
    buf[cursor] = 0;
    return buf[0..cursor :0];
}

pub fn joinPathSentinel(gpa: Allocator, dir: []const u8, name: []const u8) Allocator.Error![:0]const u8 {
    return vfs.joinPathSentinel(gpa, dir, name);
}

pub const KamikazeContext = struct {
    io: std.Io,
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

fn flushToStdout(io: std.Io, bytes: []const u8) void {
    _ = platform.writeStdout(io, bytes);
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

    var stream = vfs.DirStream.open(ctx.io, dir) catch return;
    defer stream.close();

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
    while (true) {
        if (ctx.mode == .quiet and ctx.found.load(.acquire)) break;
        if (ctx.pool.aborted.load(.acquire)) break;

        const maybe_entry = stream.next() catch break;
        const entry = maybe_entry orelse break;
        var kind = entry.kind;
        if (kind == .unknown) {
            const full_path = try joinPathSentinel(ctx.gpa, dir, entry.name);
            defer ctx.gpa.free(full_path);
            kind = if (vfs.stat(ctx.io, full_path, false)) |info| info.kind else .other;
        }

        if (kind == .directory) {
            if (!recurse_subdirs) continue;
            if (ctx.filter.isDirExcluded(entry.name)) continue;
            try subdirs.append(ctx.gpa, try joinPathSentinel(ctx.gpa, dir, entry.name));
        } else if (kind == .file) {
            if (!scan_files) continue;
            if (ctx.filter.isFileExcluded(entry.name)) continue;
            try files.append(ctx.gpa, try ctx.gpa.dupeZ(u8, entry.name));
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
                ctx.io,
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

    var path_buf: [platform.path_max]u8 = undefined;
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
            ctx.io,
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
        flushToStdout(ctx.io, local_out.items);
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
            platform.sleepBrief(ctx.io); // 50 us sleep, native on every OS
            idle_count = 0;
        }
    }
}

/// Portable stat that never follows symlinks and always reports the size.
///
/// `vfs.stat` cannot be used for the byte budget: on Linux it asks statx for
/// the TYPE mask only, so `stx.size` is left unset.
fn statNoFollow(io: std.Io, path: []const u8) ?vfs.Metadata {
    const info = vfs.statFile(io, path, .{ .follow_symlinks = false }) catch return null;
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

/// Zero-Spawn Fast Path for micro-trees.
///
/// A micro-tree is a directory whose regular files add up to `max_bytes`
/// (2 MB by default) and that stays inside the file/dir/depth budgets. It is
/// scanned on the calling thread: no worker pool, no mutexes, no io_uring —
/// and, because ignore-file upkeep is pointless in a tree that small, no
/// `.dataignore` / `.gitignore` inspection either.
///
/// The traversal goes through the portable `vfs` layer, so the same fast path
/// runs natively on Linux and on Windows.
///
/// Returns `null` when the tree is not a micro-tree; the caller then hands
/// the run over to the full concurrent swarm.
fn tryQuickTreeScan(
    io: std.Io,
    gpa: Allocator,
    searcher: *const Searcher,
    root: [:0]const u8,
    filter_engine: *const FilterEngine,
    mode: Mode,
    binary: bool,
    show_path: bool,
    scan_config: scan.ScanConfig,
    max_bytes: usize,
    stats: *KamikazeStats,
) ?bool {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Budgets: a micro-tree is small by construction. Anything bigger belongs
    // to the swarm, which parallelises the I/O. The size budget is the real
    // gate; the file/dir/depth caps only bound the work spent discovering
    // that the tree is too big.
    const max_files: usize = 2048;
    const max_dirs: usize = 512;
    const max_depth: usize = 32;

    var dir_queue: std.ArrayList(DirTask) = .empty;
    dir_queue.append(arena, .{ .path = root, .depth = 0 }) catch return null;

    var dirs_visited: usize = 0;
    var total_bytes: u64 = 0;
    var files: std.ArrayList([:0]const u8) = .empty;

    // --- Phase 1: collect the candidate files ------------------------------
    // Every candidate is measured *before* a single byte is read: the budget
    // is measured in bytes, so a tree that is too big goes to the swarm
    // without any wasted I/O.
    while (dir_queue.items.len > 0) {
        const task = dir_queue.pop().?;
        var stream = vfs.DirStream.open(io, task.path) catch continue;
        defer stream.close();

        dirs_visited += 1;
        if (dirs_visited > max_dirs) return null;

        while (true) {
            const maybe_entry = stream.next() catch return null;
            const entry = maybe_entry orelse break;

            var kind = entry.kind;
            var size: u64 = 0;

            if (kind == .unknown or kind == .file) {
                // The size is needed for the budget, and the kind has to be
                // confirmed: an entry can be a symlink, and symlinks are
                // never followed (same rule as the concurrent scout).
                const full_p = joinPathSentinel(arena, task.path, entry.name) catch return null;
                const info = statNoFollow(io, full_p) orelse continue;
                kind = info.kind;
                size = info.size;
            }

            switch (kind) {
                .directory => {
                    if (filter_engine.isDirExcluded(entry.name)) continue;
                    if (task.depth >= max_depth) return null;
                    const child_dir = joinPathSentinel(arena, task.path, entry.name) catch return null;
                    dir_queue.append(arena, .{ .path = child_dir, .depth = task.depth + 1 }) catch return null;
                },
                .file => {
                    if (filter_engine.isFileExcluded(entry.name)) continue;
                    if (files.items.len >= max_files) return null;
                    total_bytes += size;
                    if (total_bytes > @as(u64, max_bytes)) return null;
                    const full_path = joinPathSentinel(arena, task.path, entry.name) catch return null;
                    files.append(arena, full_path) catch return null;
                },
                else => {
                    // Symlinks, sockets, fifos and device nodes are skipped,
                    // exactly like the concurrent scout does.
                },
            }
        }
    }

    // --- Phase 2: scan on the calling thread -------------------------------
    // Micro-tree verified: scan sequentially on the calling thread!
    const scratch = gpa.alloc(u8, 256 * 1024) catch null;
    defer if (scratch) |s| gpa.free(s);

    var local_out: std.ArrayList(u8) = .empty;
    defer local_out.deinit(gpa);

    var matched_any = false;
    stats.dirs_scouted += dirs_visited;

    for (files.items) |full_path| {
        const res = scan.scanFile(
            io,
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
        flushToStdout(io, local_out.items);
    }

    return matched_any;
}

/// Zero-Latency Probe for Quiet Mode (-q):
/// Scans up to 4 regular files in root on the main thread prior to thread pool creation.
/// If a match is found instantly, returns true in < 0.3 ms with 0 thread spawns.
fn tryQuickQuietProbe(
    io: std.Io,
    gpa: Allocator,
    searcher: *const Searcher,
    root: [:0]const u8,
    filter_engine: *const FilterEngine,
    binary: bool,
    scan_config: scan.ScanConfig,
) bool {
    var stream = vfs.DirStream.open(io, root) catch return false;
    defer stream.close();

    var probed: usize = 0;
    var scratch: [64 * 1024]u8 = undefined;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    var path_buf: [platform.path_max]u8 = undefined;
    while (probed < 4) {
        const maybe_entry = stream.next() catch return false;
        const entry = maybe_entry orelse break;
        var kind = entry.kind;
        if (kind == .unknown) {
            const probe_path = joinPathSentinel(gpa, root, entry.name) catch continue;
            defer gpa.free(probe_path);
            kind = if (vfs.stat(io, probe_path, false)) |info| info.kind else .other;
        }
        if (kind != .file) continue;
        if (filter_engine.isFileExcluded(entry.name)) continue;

        const stack_path = formatPathBuf(&path_buf, root, entry.name);
        var heap_path: ?[:0]const u8 = null;
        const full_path: [:0]const u8 = stack_path orelse blk: {
            heap_path = joinPathSentinel(gpa, root, entry.name) catch continue;
            break :blk heap_path.?;
        };
        defer if (heap_path) |hp| gpa.free(hp);

        const res = scan.scanFile(
            io,
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

/// Zero-Latency Probe for Quiet Mode (-q), run over every root.
fn quietProbeHit(
    io: std.Io,
    gpa: Allocator,
    searcher: *const Searcher,
    roots: []const [:0]const u8,
    filter_engine: *const FilterEngine,
    binary: bool,
    scan_config: scan.ScanConfig,
    stats: *KamikazeStats,
) bool {
    for (roots) |root| {
        if (tryQuickQuietProbe(io, gpa, searcher, root, filter_engine, binary, scan_config)) {
            stats.early_aborted = true;
            return true;
        }
    }
    return false;
}

/// Executes the full Concurrent Kamikaze Swarm pipeline ("Abuelo -> Padres -> Hijos").
///
/// `force_swarm` disables the zero-thread micro-tree fast path and restores
/// the old swarm-only behaviour (including the upward ignore-file walk and
/// the quiet probe running before any traversal).
/// `micro_max_bytes` is the size budget under which a tree qualifies as a
/// micro-tree and is scanned on the calling thread.
pub fn runKamikazePipeline(
    io: std.Io,
    gpa: Allocator,
    searcher: *const Searcher,
    roots: []const [:0]const u8,
    filter_engine: *FilterEngine,
    nav_plan: nav.NavPlan,
    mode: Mode,
    binary: bool,
    show_path: bool,
    scan_config: scan.ScanConfig,
    threads_count: usize,
    stats: *KamikazeStats,
    use_uring: bool,
    force_swarm: bool,
    micro_max_bytes: usize,
) !bool {
    const probe_early = mode == .quiet and !scan_config.invert and nav_plan.len == 0;

    if (force_swarm) {
        // 0. Old flow, exactly: the ignore files are loaded up front and the
        //    quiet probe answers before any traversal happens.
        filter_engine.loadIgnoreFiles(io, roots);
        if (probe_early and quietProbeHit(io, gpa, searcher, roots, filter_engine, binary, scan_config, stats)) {
            return true;
        }
    } else {
        // 1. Zero-Spawn Fast Path for micro-trees (no threads, no ignore files).
        //    The tree size decides the path, so this runs before the quiet
        //    probe: a micro-tree and the swarm do not see the same file set.
        if (roots.len == 1 and nav_plan.len == 0) {
            const root = roots[0];
            if (vfs.stat(io, root, true)) |info| {
                if (info.kind == .directory) {
                    if (tryQuickTreeScan(io, gpa, searcher, root, filter_engine, mode, binary, show_path, scan_config, micro_max_bytes, stats)) |matched| {
                        stats.micro_path = true;
                        return matched;
                    }
                }
            }
        }
        // 2. The tree is too big for the fast path: the upward
        //    `.dataignore` / `.gitignore` walk happens here, and the quiet
        //    probe now sees the same file set as the swarm.
        filter_engine.loadIgnoreFiles(io, roots);
        if (probe_early and quietProbeHit(io, gpa, searcher, roots, filter_engine, binary, scan_config, stats)) {
            return true;
        }
    }

    // 3. Full Parallel Kamikaze Swarm.

    var pool = WorkPool.init(gpa);
    defer pool.deinit();

    var found = std.atomic.Value(bool).init(false);

    var ctx = KamikazeContext{
        .io = io,
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
        if (vfs.stat(io, root, true)) |info| {
            if (info.kind == .directory) {
                try pool.pushRoot(root);
            } else if (info.kind == .file) {
                try pool.pushSingleFile(root);
            }
        }
    }

    // Spawn concurrent hybrid worker swarm
    const actual_workers = @min(@max(1, threads_count), max_threads);
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
