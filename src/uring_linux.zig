//! uring_linux.zig — Linux io_uring Batch Dispatch Engine (Linux only).
//!
//! This file is the real implementation and is only ever imported on Linux.
//! `std.os.linux.IoUring` cannot be compiled for non-Linux targets (its
//! errno enum differs from `std.c`), so the portable facade in `uring.zig`
//! gates the import and falls back to a stub everywhere else.
//!
//! Submits batched asynchronous I/O requests directly to the Linux NVMe/filesystem kernel
//! driver via the io_uring submission/completion queue ABI with zero libc dependencies.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const IoUring = linux.IoUring;
const search = @import("search.zig");
const scan = @import("scan.zig");

const kamikaze = @import("kamikaze.zig");
const uring = @import("uring.zig");

pub const BATCH_SIZE = uring.BATCH_SIZE;
pub const BUFFER_SIZE = uring.BUFFER_SIZE;

pub fn isSupported() bool {
    var p: linux.io_uring_params = std.mem.zeroes(linux.io_uring_params);
    const rc = linux.io_uring_setup(2, &p);
    if (linux.errno(rc) == .SUCCESS) {
        const ring_fd: i32 = @intCast(@as(isize, @bitCast(rc)));
        _ = linux.close(ring_fd);
        return true;
    }
    return false;
}

/// Flags de `io_uring_setup` para el anillo de cada trabajador.
///
/// El anillo es de un solo emisor (lo crea quien lo usa y nadie mas lo toca),
/// que es la precondicion de `SINGLE_ISSUER`. `COOP_TASKRUN` evita que el
/// kernel despierte al hilo solo para publicar CQEs: en el modo sincrono eso
/// se traducia en IPIs entre nucleos que ensuciaban la L1/L2 del worker que
/// estaba corriendo SIMD.
///
/// Si el kernel los rechaza (anteriores a 6.0 / 5.19), se reintenta con 0:
/// funcionar sin las flags es mejor que no funcionar.
const ring_flags: u32 = linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_COOP_TASKRUN;

pub const UringScanner = struct {
    ring: IoUring,
    buffers: [BATCH_SIZE][BUFFER_SIZE]u8 = undefined,
    open_fds: [BATCH_SIZE]i32 = [_]i32{-1} ** BATCH_SIZE,
    path_storage: [BATCH_SIZE][linux.PATH_MAX]u8 = undefined,
    path_slices: [BATCH_SIZE][:0]const u8 = undefined,

    pub fn create(gpa: Allocator, entries: u16) !*UringScanner {
        const self = try gpa.create(UringScanner);
        errdefer gpa.destroy(self);
        self.* = .{
            .ring = IoUring.init(entries, ring_flags) catch try IoUring.init(entries, 0),
            .open_fds = [_]i32{-1} ** BATCH_SIZE,
        };
        return self;
    }

    pub fn destroy(self: *UringScanner, gpa: Allocator) void {
        self.deinit();
        gpa.destroy(self);
    }

    pub fn deinit(self: *UringScanner) void {
        for (&self.open_fds) |*fd| {
            if (fd.* >= 0) {
                _ = linux.close(fd.*);
                fd.* = -1;
            }
        }
        self.ring.deinit();
    }

    /// Asynchronously scans a batch of up to BATCH_SIZE files within a directory.
    pub fn scanAsyncBatch(
        self: *UringScanner,
        io: std.Io,
        gpa: Allocator,
        searcher: *const search.Searcher,
        dir_path: []const u8,
        file_names: []const [:0]const u8,
        show_path: bool,
        mode: scan.Mode,
        binary: bool,
        config: scan.ScanConfig,
        out: *std.ArrayList(u8),
    ) !uring.UringBatchResult {
        var result = uring.UringBatchResult{};
        const count = @min(file_names.len, BATCH_SIZE);
        if (count == 0) return result;

        // Ensure no lingering open fds on error or exit:
        defer {
            for (&self.open_fds) |*fd| {
                if (fd.* >= 0) {
                    _ = linux.close(fd.*);
                    fd.* = -1;
                }
            }
        }

        var submitted: u32 = 0;

        // 1. Open files and enqueue asynchronous reads into io_uring:
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const fname = file_names[i];
            const p_buf = &self.path_storage[i];
            const full_p: [:0]const u8 = kamikaze.formatPathBuf(p_buf, dir_path, fname) orelse continue;
            self.path_slices[i] = full_p;

            const rc = linux.openat(linux.AT.FDCWD, full_p, .{ .CLOEXEC = true }, 0);
            const fd: i32 = @intCast(@as(isize, @bitCast(rc)));
            if (fd < 0) {
                self.open_fds[i] = -1;
                continue;
            }
            self.open_fds[i] = fd;

            _ = self.ring.read(@intCast(i), fd, .{ .buffer = self.buffers[i][0..] }, 0) catch {
                _ = linux.close(fd);
                self.open_fds[i] = -1;
                continue;
            };
            submitted += 1;
        }

        if (submitted == 0) return result;

        // 2. Submit all batched reads to the kernel in ONE single syscall:
        _ = try self.ring.submit_and_wait(submitted);

        // 3. Process completions as they arrive:
        var completed_total: u32 = 0;
        while (completed_total < submitted) {
            var cqes: [BATCH_SIZE]linux.io_uring_cqe = undefined;
            const remaining = submitted - completed_total;
            const n_copied = try self.ring.copy_cqes(&cqes, remaining);
            if (n_copied == 0) break;
            completed_total += n_copied;

            var cqe_idx: usize = 0;
            while (cqe_idx < n_copied) : (cqe_idx += 1) {
                const slot_idx: usize = @intCast(cqes[cqe_idx].user_data);
                const fd = self.open_fds[slot_idx];
                if (fd >= 0) {
                    _ = linux.close(fd);
                    self.open_fds[slot_idx] = -1;
                }

                const path = self.path_slices[slot_idx];
                const bytes_read = cqes[cqe_idx].res;
                if (bytes_read < 0) continue; // read error
                const n: usize = @intCast(bytes_read);

                result.files_scanned += 1;

                // If file was larger than BUFFER_SIZE, fallback to scanFile for remaining content:
                if (n == BUFFER_SIZE) {
                    // `scanFile` re-lee el fichero entero: sus `bytes` son el
                    // tamaño completo (0 si es binario o ilegible), así que se
                    // cuenta UNA vez. Antes se sumaba el primer trozo del
                    // anillo y se descartaba el resto: --stats mentía a la baja
                    // justo en frío, que es donde se usa el uring.
                    const fs = scan.scanFile(io, gpa, searcher, path, show_path, mode, binary, config, out, null, null);
                    result.bytes_scanned += fs.bytes;
                    const is_hit = if (mode == .files_without_match) !fs.matched else fs.matched;
                    if (is_hit) {
                        result.matched_files += 1;
                        result.matched_lines += fs.lines;
                        result.found = true;
                        if (mode == .quiet) return result;
                    }
                    continue;
                }

                // Normal file <= BUFFER_SIZE: scanned completely in the io_uring buffer!
                var fs = scan.FileScan{};
                if (n > 0) {
                    const data = self.buffers[slot_idx][0..n];
                    const probe = @min(data.len, scan.binary_probe_bytes);
                    const utf16_bom = scan.isUtf16Bom(data);
                    const is_bin = !binary and utf16_bom == null and std.mem.findScalar(u8, data[0..probe], 0) != null;
                    if (!is_bin) {
                        // Solo los bytes que de verdad se escanean (mismo
                        // criterio que el camino síncrono: un binario no suma).
                        result.bytes_scanned += n;
                        if (utf16_bom) |bom| {
                            if (scan.decodeUtf16ToUtf8(gpa, data, bom == .le)) |decoded| {
                                defer gpa.free(decoded);
                                const br = scan.scanBuffer(gpa, decoded, searcher, path, show_path, mode, config, out) catch continue;
                                fs.matched = br.matched;
                                fs.lines = br.lines;
                            } else |_| {}
                        } else {
                            const br = scan.scanBuffer(gpa, data, searcher, path, show_path, mode, config, out) catch continue;
                            fs.matched = br.matched;
                            fs.lines = br.lines;
                        }
                    }
                }
                if (scan.emitOncePerFile(out, gpa, path, show_path, mode, fs)) |e| fs.err = e;

                const is_hit = if (mode == .files_without_match) !fs.matched else fs.matched;
                if (is_hit) {
                    result.matched_files += 1;
                    result.matched_lines += fs.lines;
                    result.found = true;
                    if (mode == .quiet) return result;
                }
            }
        }

        return result;
    }
};

test "io_uring isSupported check" {
    const sup = isSupported();
    try std.testing.expect(sup);
}

test "io_uring UringScanner lifecycle and batch read" {
    const gpa = std.testing.allocator;
    var scanner = try UringScanner.create(gpa, 32);
    defer scanner.destroy(gpa);

    const searcher = search.Searcher.init("test", .auto);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const names = [_][:0]const u8{ "root.zig", "main.zig" };
    const res = try scanner.scanAsyncBatch(
        std.testing.io,
        gpa,
        &searcher,
        "src",
        &names,
        true,
        .lines,
        false,
        .{},
        &out,
    );
    try std.testing.expect(res.files_scanned >= 1);
    try std.testing.expect(res.bytes_scanned > 0);
}
