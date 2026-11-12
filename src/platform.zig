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

/// A prefix written once, right before the FIRST bytes that reach stdout, and
/// never if nothing does (zgrep/1c's stream header: an empty search must stay
/// an empty stdout, like every grep). Writers are already serialized (the
/// swarm under its out mutex, the ordered path on one thread), so the swap
/// is enough to keep the prefix first.
pub var stdout_prefix: []const u8 = "";
pub var stdout_prefix_pending: std.atomic.Value(bool) = .init(false);

pub fn writeStdout(io: std.Io, bytes: []const u8) bool {
    if (bytes.len > 0 and stdout_prefix_pending.swap(false, .acq_rel)) {
        if (!writeStdoutInner(io, stdout_prefix)) return false;
    }
    return writeStdoutInner(io, bytes);
}

fn writeStdoutInner(io: std.Io, bytes: []const u8) bool {
    if (stdout_sink) |sk| return sk.write(sk.ctx, bytes);
    return writeStdoutRaw(io, bytes);
}

/// One whole diagnostic line to stderr in ONE write: up to PIPE_BUF bytes a
/// write is atomic, so lines from several scan threads never interleave, and
/// there is no global lock (`std.debug.print` takes one and writes each
/// format piece separately; measured 2026-11-12 with 299 `--binary-files=note`
/// lines: 16.5 ms with it, 15.2 ms with this, 15.3 ms without notices).
pub fn writeStderrLine(bytes: []const u8) void {
    if (builtin.os.tag == .linux) {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const result = linux.write(linux.STDERR_FILENO, bytes.ptr + offset, bytes.len - offset);
            const err = linux.errno(result);
            if (err == .INTR) continue;
            if (err != .SUCCESS or result == 0) return;
            offset += result;
        }
        return;
    }
    std.debug.print("{s}", .{bytes});
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
