//! uring.zig — portable facade for the Linux io_uring batch dispatch engine.
//!
//! The real engine lives in `uring_linux.zig` and is only compiled on Linux:
//! `std.os.linux.IoUring` cannot be built for other targets because its errno
//! enum does not match `std.c` there. On every other host this facade reports
//! `isSupported() == false` and exposes a stub scanner that is never created,
//! so `--uring` simply falls back to the regular synchronous workers.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const search = @import("search.zig");
const scan = @import("scan.zig");

/// Maximum number of files dispatched in a single batched round.
pub const BATCH_SIZE = 16;
/// Per-slot async buffer size (256 KB).
pub const BUFFER_SIZE = 256 * 1024;

pub const UringBatchResult = struct {
    files_scanned: usize = 0,
    bytes_scanned: usize = 0,
    matched_files: usize = 0,
    matched_lines: usize = 0,
    found: bool = false,
};

/// True only on a Linux host that actually exposes io_uring.
pub fn isSupported() bool {
    if (builtin.os.tag != .linux) return false;
    return @import("uring_linux.zig").isSupported();
}

/// Stub used on every non-Linux host. `isSupported()` is false there, so
/// `create` is never reached at runtime; it exists so that the shared
/// call sites keep compiling unchanged.
const UnsupportedScanner = struct {
    pub fn create(gpa: Allocator, entries: u16) !*UnsupportedScanner {
        _ = gpa;
        _ = entries;
        return error.Unsupported;
    }

    pub fn destroy(self: *UnsupportedScanner, gpa: Allocator) void {
        _ = self;
        _ = gpa;
    }

    pub fn deinit(self: *UnsupportedScanner) void {
        _ = self;
    }

    pub fn scanAsyncBatch(
        self: *UnsupportedScanner,
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
    ) !UringBatchResult {
        _ = self;
        _ = io;
        _ = gpa;
        _ = searcher;
        _ = dir_path;
        _ = file_names;
        _ = show_path;
        _ = mode;
        _ = binary;
        _ = config;
        _ = out;
        return error.Unsupported;
    }
};

pub const UringScanner = if (builtin.os.tag == .linux)
    @import("uring_linux.zig").UringScanner
else
    UnsupportedScanner;
