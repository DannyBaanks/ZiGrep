//! Literal (fixed-string) search kernels for zgrep.
//!
//! Three strategies are exposed so the experiment can compare them as an
//! independent variable:
//!
//!   * `bmh`    Boyer-Moore-Horspool. The 256-entry skip table is built
//!              **once per pattern** by `Searcher.init`, not per call, which
//!              is what `std.mem.findPos` does internally and why it is not
//!              usable hot here.
//!   * `memchr` vectorised first-byte anchor (`std.mem.findScalarPos`) plus a
//!              full compare of the candidate.
//!   * `auto`   `memchr` for needles of 1..=3 bytes, `bmh` otherwise.
//!
//! The engine is `Searcher`, a value that owns the precomputed table and is
//! passed by pointer into the hot loop.
const std = @import("std");

pub const Algo = enum { auto, bmh, memchr };

pub const Searcher = struct {
    needle: []const u8,
    algo: Algo,
    /// `skip[c]` = distance to advance the window when the byte at the last
    /// position of the window is `c`. Default is the pattern length.
    skip: [256]u32 = undefined,

    /// Builds the BMH skip table. Must be called exactly once per pattern.
    pub fn init(needle: []const u8, algo: Algo) Searcher {
        var self: Searcher = .{ .needle = needle, .algo = algo };
        if (needle.len > std.math.maxInt(u32)) unreachable; // absurd pattern size
        const n: u32 = @intCast(needle.len);
        @memset(&self.skip, n);
        // Positions 0..n-2 only: the last byte never participates in a shift
        // that would be 0 (which would loop forever).
        var i: usize = 0;
        while (i + 1 < needle.len) : (i += 1) {
            self.skip[needle[i]] = @intCast(needle.len - 1 - i);
        }
        return self;
    }

    /// Resolves `auto` against the actual needle length.
    pub fn effectiveAlgo(self: *const Searcher) Algo {
        return switch (self.algo) {
            .auto => if (self.needle.len <= 3) .memchr else .bmh,
            else => self.algo,
        };
    }

    /// First occurrence of the needle at or after `start`, or null.
    /// An empty needle matches at `start` (grep semantics: matches every line).
    pub fn find(self: *const Searcher, hay: []const u8, start: usize) ?usize {
        const n = self.needle.len;
        if (n == 0) return if (start <= hay.len) start else null;
        if (start >= hay.len or hay.len - start < n) return null;
        return switch (self.effectiveAlgo()) {
            .bmh => self.findBmh(hay, start),
            .memchr => self.findMemchr(hay, start),
            .auto => unreachable,
        };
    }

    fn findBmh(self: *const Searcher, hay: []const u8, start: usize) ?usize {
        const nd = self.needle;
        const n = nd.len;
        const last = n - 1;
        const last_byte = nd[last];
        var i = start;
        while (i + n <= hay.len) {
            const window_last = hay[i + last];
            if (window_last == last_byte and
                std.mem.eql(u8, hay[i .. i + last], nd[0..last]))
            {
                return i;
            }
            i += self.skip[window_last];
        }
        return null;
    }

    fn findMemchr(self: *const Searcher, hay: []const u8, start: usize) ?usize {
        const nd = self.needle;
        const n = nd.len;
        var i = start;
        while (i + n <= hay.len) {
            const p = std.mem.findScalarPos(u8, hay, i, nd[0]) orelse return null;
            if (p + n > hay.len) return null;
            if (std.mem.eql(u8, hay[p .. p + n], nd)) return p;
            i = p + 1;
        }
        return null;
    }
};

fn naiveFind(hay: []const u8, needle: []const u8, start: usize) ?usize {
    if (needle.len == 0) return if (start <= hay.len) start else null;
    if (start > hay.len or hay.len - start < needle.len) return null;
    var i = start;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.mem.eql(u8, hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

test "skip table: pattern length and per-byte shift" {
    // Horspool: every byte except the last gets n-1-i; the last byte keeps
    // the default n (a zero shift would spin forever).
    const s = Searcher.init("abcd", .bmh);
    try std.testing.expectEqual(@as(u32, 3), s.skip['a']);
    try std.testing.expectEqual(@as(u32, 2), s.skip['b']);
    try std.testing.expectEqual(@as(u32, 1), s.skip['c']);
    try std.testing.expectEqual(@as(u32, 4), s.skip['d']);
    try std.testing.expectEqual(@as(u32, 4), s.skip['z']);
}

test "find: known positions" {
    const hay = "the quick brown fox jumps over the lazy dog";
    {
        const s = Searcher.init("the", .bmh);
        try std.testing.expectEqual(@as(?usize, 0), s.find(hay, 0));
        try std.testing.expectEqual(@as(?usize, 31), s.find(hay, 1));
    }
    {
        const s = Searcher.init("the", .memchr);
        try std.testing.expectEqual(@as(?usize, 0), s.find(hay, 0));
        try std.testing.expectEqual(@as(?usize, 31), s.find(hay, 1));
        try std.testing.expectEqual(@as(?usize, null), s.find(hay, 32));
    }
    {
        const s = Searcher.init("zzz", .auto);
        try std.testing.expectEqual(@as(?usize, null), s.find(hay, 0));
    }
    {
        const s = Searcher.init("fox", .auto);
        try std.testing.expectEqual(@as(?usize, 16), s.find(hay, 0));
    }
}

test "find: needle longer than haystack" {
    const s = Searcher.init("abcdef", .bmh);
    try std.testing.expectEqual(@as(?usize, null), s.find("abc", 0));
    try std.testing.expectEqual(@as(?usize, null), s.find("", 0));
}

test "find: single byte needle degenerates to a scalar scan" {
    const s = Searcher.init("x", .bmh);
    try std.testing.expectEqual(@as(?usize, 2), s.find("abxcx", 0));
    try std.testing.expectEqual(@as(?usize, 4), s.find("abxcx", 3));
    try std.testing.expectEqual(@as(?usize, null), s.find("abxcx", 5));
}

test "find: repeated pattern does not loop forever" {
    // "aa" is the classic BMH zero-shift trap.
    const s = Searcher.init("aa", .bmh);
    try std.testing.expectEqual(@as(?usize, 0), s.find("aaa", 0));
    try std.testing.expectEqual(@as(?usize, 1), s.find("aaa", 1));
    try std.testing.expectEqual(@as(?usize, null), s.find("aaa", 3));
    try std.testing.expectEqual(@as(?usize, 1), s.find("baa", 0));
}

test "find: empty needle matches at every position" {
    const s = Searcher.init("", .auto);
    try std.testing.expectEqual(@as(?usize, 0), s.find("abc", 0));
    try std.testing.expectEqual(@as(?usize, 3), s.find("abc", 3));
    try std.testing.expectEqual(@as(?usize, null), s.find("abc", 4));
}

test "find: differential against naive for random haystacks" {
    var prng = std.Random.DefaultPrng.init(0x5eed_1234_5678_9abc);
    const rnd = prng.random();

    const alphabets = [_][]const u8{ "ab", "abc", "abcdefgh", "abcabcabc" };
    var iter: usize = 0;
    while (iter < 400) : (iter += 1) {
        const alphabet = alphabets[rnd.uintLessThan(usize, alphabets.len)];
        var hay_buf: [96]u8 = undefined;
        const hay_len = rnd.uintLessThan(usize, hay_buf.len + 1);
        for (hay_buf[0..hay_len]) |*c| c.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];

        var nd_buf: [8]u8 = undefined;
        const nd_len = rnd.uintLessThan(usize, nd_buf.len + 1);
        for (nd_buf[0..nd_len]) |*c| c.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];

        const hay = hay_buf[0..hay_len];
        const needle = nd_buf[0..nd_len];
        const searcher = Searcher.init(needle, .auto);

        var start: usize = 0;
        while (start <= hay_len) : (start += 1) {
            const want = naiveFind(hay, needle, start);
            const got_bm = Searcher.init(needle, .bmh).find(hay, start);
            const got_mc = Searcher.init(needle, .memchr).find(hay, start);
            const got_auto = searcher.find(hay, start);
            if (want != got_bm or want != got_mc or want != got_auto) {
                std.debug.print(
                    "\nMISMATCH hay={s} needle={s} start={d} want={?d} bmh={?d} memchr={?d} auto={?d}\n",
                    .{ hay, needle, start, want, got_bm, got_mc, got_auto },
                );
                return error.TestExpectedEqual;
            }
        }
    }
}
