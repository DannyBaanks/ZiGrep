//! Small platform adapters for clocks, waits, and stdout. Linux retains direct
//! syscalls; other targets use Zig's native Io implementation.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

/// Maximum path length used by the zero-allocation stack path buffers.
/// Windows accepts longer paths; the callers fall back to the heap when
/// the stack buffer does not fit.
pub const path_max: usize = 4096;

pub fn nowNs(io: std.Io) u64 {
    if (builtin.os.tag == .linux) {
        var ts: linux.timespec = undefined;
        if (linux.clock_gettime(.MONOTONIC, &ts) != 0 or ts.sec < 0 or ts.nsec < 0) return 0;
        return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    }

    const ns = std.Io.Clock.now(.awake, io).nanoseconds;
    return if (ns <= 0) 0 else @intCast(ns);
}

pub fn sleepBrief(io: std.Io) void {
    if (builtin.os.tag == .linux) {
        const ts = linux.timespec{ .sec = 0, .nsec = 50_000 };
        _ = linux.nanosleep(&ts, null);
    } else {
        std.Io.sleep(io, .fromNanoseconds(50_000), .awake) catch return;
    }
}

/// Optional interposer for everything zgrep writes to stdout. `null` (the
/// default) is the plain write below. The batch / budget layer (M3,
/// `batch.zig`) installs one to tag, count and truncate JSONL events; it
/// writes through `writeStdoutRaw`.
pub const StdoutSink = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, bytes: []const u8) bool,
};
pub var stdout_sink: ?StdoutSink = null;

pub fn writeStdout(io: std.Io, bytes: []const u8) bool {
    if (stdout_sink) |sk| return sk.write(sk.ctx, bytes);
    return writeStdoutRaw(io, bytes);
}

pub fn writeStdoutRaw(io: std.Io, bytes: []const u8) bool {
    if (builtin.os.tag == .linux) {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const result = linux.write(linux.STDOUT_FILENO, bytes.ptr + offset, bytes.len - offset);
            const err = linux.errno(result);
            if (err == .INTR) continue;
            if (err != .SUCCESS or result == 0) return false;
            offset += result;
        }
        return true;
    }

    std.Io.File.stdout().writeStreamingAll(io, bytes) catch return false;
    return true;
}
