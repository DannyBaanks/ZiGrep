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
const regex = @import("regex.zig");
const bre = @import("bre.zig");
const Allocator = std.mem.Allocator;

pub const Algo = enum { auto, bmh, memchr };

pub const byte_rank: [256]u8 = blk: {
    var r = [_]u8{10} ** 256;
    // Control characters & whitespace
    r['\n'] = 250;
    r['\r'] = 150;
    r['\t'] = 220;
    r[' '] = 255;

    // Digits
    for ('0'..'9' + 1) |c| r[c] = 130;

    // Common symbols in code
    r['_'] = 190;
    r[';'] = 180;
    r['('] = 175;
    r[')'] = 175;
    r['{'] = 160;
    r['}'] = 160;
    r['['] = 140;
    r[']'] = 140;
    r['"'] = 165;
    r['\''] = 120;
    r[':'] = 160;
    r[','] = 170;
    r['.'] = 180;
    r['='] = 170;
    r['/'] = 140;
    r['-'] = 150;
    r['+'] = 120;
    r['*'] = 130;
    r['<'] = 130;
    r['>'] = 130;

    // Uppercase letters (moderately rare compared to lowercase in typical code)
    for ('A'..'Z' + 1) |c| r[c] = 80;

    // Lowercase letters (standard frequency order: rare -> common)
    r['z'] = 30;
    r['q'] = 35;
    r['x'] = 45;
    r['j'] = 50;
    r['k'] = 60;
    r['v'] = 75;
    r['b'] = 90;
    r['p'] = 105;
    r['y'] = 110;
    r['g'] = 115;
    r['f'] = 120;
    r['w'] = 125;
    r['m'] = 135;
    r['u'] = 145;
    r['c'] = 155;
    r['d'] = 165;
    r['l'] = 175;
    r['h'] = 180;
    r['r'] = 195;
    r['s'] = 205;
    r['n'] = 210;
    r['i'] = 215;
    r['o'] = 220;
    r['a'] = 225;
    r['t'] = 235;
    r['e'] = 245;

    break :blk r;
};

/// Foldable lowercase bytes in ASCII ('a'..'z') and Latin-1 supplement in UTF-8
/// (0xA0..0xB6 for à..ö, 0xB8..0xBE for ø..þ, where the second byte has bit 0x20 set).
pub fn isCaseFoldable(b: u8) bool {
    return (b >= 'a' and b <= 'z') or ((b >= 0xA0 and b <= 0xB6) or (b >= 0xB8 and b <= 0xBE));
}

pub fn toLowerByte(b: u8) u8 {
    if (b >= 'A' and b <= 'Z') return b + 0x20;
    if ((b >= 0x80 and b <= 0x96) or (b >= 0x98 and b <= 0x9E)) return b | 0x20;
    return b;
}

pub const Kind = enum { literal, regex, never };

/// A match location inside a line: `hay[start..end)`.
pub const Match = struct {
    start: usize,
    end: usize,

    pub fn slice(self: Match, hay: []const u8) []const u8 {
        return hay[self.start..self.end];
    }
};

pub const Searcher = struct {
    needle: []const u8,
    algo: Algo,
    /// `.literal` (default, the original fast path) or `.regex` (lazy DFA).
    kind: Kind = .literal,
    /// Literal kinds only: `needle` is stored lower-cased and matched ASCII
    /// case-insensitively.
    icase: bool = false,
    /// Literal kinds only: a match must be delimited by non-word bytes (-w).
    word: bool = false,
    /// `--crlf`: `$` also accepts before the CR of a CRLF pair.
    crlf: bool = false,
    /// `--null-data`: NUL separates records, so a record may contain `\n`.
    null_data: bool = false,
    prog: ?*const regex.Program = null,
    /// Regex only: a required literal; lines are only handed to the DFA when
    /// the literal occurs in them (the common case for code searches).
    prefilter: ?*const Searcher = null,
    /// `skip[c]` = distance to advance the window when the byte at the last
    /// position of the window is `c`. Default is the pattern length.
    skip: [256]u32 = undefined,
    rarest_offset: u32 = 0,
    rarest_byte: u8 = 0,

    /// Builds the BMH skip table and identifies the rarest byte for SIMD scanning.
    /// Must be called exactly once per pattern.
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

        var rarest_idx: u32 = 0;
        var min_rank: u8 = 255;
        for (needle, 0..) |b, idx| {
            const r = byte_rank[b];
            if (r < min_rank) {
                min_rank = r;
                rarest_idx = @intCast(idx);
            }
        }
        self.rarest_offset = rarest_idx;
        self.rarest_byte = if (needle.len > 0) needle[rarest_idx] else 0;

        return self;
    }

    /// Resolves `auto` against the actual needle length.
    pub fn effectiveAlgo(self: *const Searcher) Algo {
        return switch (self.algo) {
            .auto => .memchr,
            else => self.algo,
        };
    }

    /// First match at or after `start`, or null.
    ///
    /// Literal kinds return the exact offset of the occurrence. Regex returns
    /// the start of the first matching *line* (`start` must be a line start);
    /// callers only use the result to locate the line, so both are equivalent.
    /// An empty needle matches at `start` (grep semantics: matches every line).
    pub fn find(self: *const Searcher, hay: []const u8, start: usize) ?usize {
        if (self.kind == .never) return null;
        if (self.kind == .regex) return self.findRegex(hay, start);
        if (self.word) return self.findWord(hay, start);
        return self.findRaw(hay, start);
    }

    /// Leftmost-longest match at or after `from` in `hay` (a single line).
    ///
    /// The span-aware twin of `find`: `find` answers "does this line match"
    /// and collapses the instant it does (so it cannot say where the match
    /// started); this one keeps both ends because it drives the DFA through
    /// the no-injection table (`Dfa.nextMatch`). Zero-width matches are
    /// returned too (start == end); callers that model `grep -o` drop them.
    pub fn matchSpan(self: *const Searcher, hay: []const u8, from: usize) ?Match {
        if (self.kind == .never) return null;
        if (self.kind == .literal) {
            const m = self.find(hay, from) orelse return null;
            return .{ .start = m, .end = m + self.needle.len };
        }
        const dfa = regex.threadDfa(self.prog.?) catch return null;
        const span = dfa.nextMatch(hay, from, hay.len) orelse return null;
        return .{ .start = span.start, .end = span.end };
    }

    fn findRaw(self: *const Searcher, hay: []const u8, start: usize) ?usize {
        const n = self.needle.len;
        if (n == 0) return if (start <= hay.len) start else null;
        if (start >= hay.len or hay.len - start < n) return null;
        if (self.icase) return self.findCi(hay, start);
        return switch (self.effectiveAlgo()) {
            .bmh => self.findBmh(hay, start),
            .memchr => self.findMemchr(hay, start),
            .auto => unreachable,
        };
    }

    fn isWordByte(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn findWord(self: *const Searcher, hay: []const u8, start: usize) ?usize {
        var pos = start;
        while (pos <= hay.len) {
            const m = self.findRaw(hay, pos) orelse return null;
            const end = m + self.needle.len;
            const left_ok = m == 0 or !isWordByte(hay[m - 1]);
            const right_ok = end >= hay.len or !isWordByte(hay[end]);
            if (left_ok and right_ok) return m;
            pos = m + 1;
        }
        return null;
    }

    /// Vectorised scan for `lower` in either case (supporting both ASCII and Latin-1 Unicode).
    fn scanCi(hay: []const u8, from: usize, lower: u8) ?usize {
        var i = from;
        const is_foldable = isCaseFoldable(lower);
        const V = @Vector(32, u8);
        const want: V = @splat(lower);
        const bit: V = @splat(0x20);
        while (i + 32 <= hay.len) : (i += 32) {
            const v: V = hay[i..][0..32].*;
            const m = if (is_foldable) ((v | bit) == want) else (v == want);
            const bits: u32 = @bitCast(m);
            if (bits != 0) return i + @ctz(bits);
        }
        while (i < hay.len) : (i += 1) {
            const c = hay[i];
            if ((if (is_foldable) (c | 0x20) else c) == lower) return i;
        }
        return null;
    }

    fn findCi(self: *const Searcher, hay: []const u8, start: usize) ?usize {
        const nd = self.needle; // lower-cased
        const n = nd.len;
        const roff = self.rarest_offset;
        var p_idx = start + roff;
        while (p_idx < hay.len) {
            const p = scanCi(hay, p_idx, self.rarest_byte) orelse return null;
            const cand = p - roff;
            if (cand + n > hay.len) return null;
            var ok = true;
            for (nd, hay[cand .. cand + n]) |a, b| {
                if (a != toLowerByte(b)) {
                    ok = false;
                    break;
                }
            }
            if (ok) return cand;
            p_idx = p + 1;
        }
        return null;
    }

    fn findRegex(self: *const Searcher, hay: []const u8, start: usize) ?usize {
        const dfa = regex.threadDfa(self.prog.?) catch return null;
        if (self.prefilter) |pf| {
            var pos = start;
            while (pos < hay.len) {
                const m = pf.find(hay, pos) orelse return null;
                const ls = if (std.mem.findScalarLast(u8, hay[pos..m], '\n')) |k| pos + k + 1 else pos;
                const le = std.mem.findScalarPos(u8, hay, m, '\n') orelse hay.len;
                if (dfa.firstMatchingLine(hay, ls, le, self.crlf) != null) return ls;
                if (le >= hay.len) return null;
                pos = le + 1;
            }
            return null;
        }
        if (self.null_data) {
            const m = dfa.nextMatch(hay, start, hay.len) orelse return null;
            return m.start;
        }
        return dfa.firstMatchingLine(hay, start, hay.len, self.crlf);
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
        const roff = self.rarest_offset;
        const rbyte = self.rarest_byte;
        var p_idx = start + roff;
        while (p_idx < hay.len) {
            const p = std.mem.findScalarPos(u8, hay, p_idx, rbyte) orelse return null;
            const cand = p - roff;
            if (cand + n > hay.len) return null;
            if (std.mem.eql(u8, hay[cand .. cand + n], nd)) return cand;
            p_idx = p + 1;
        }
        return null;
    }
};

pub const BuildOptions = struct {
    algo: Algo = .auto,
    /// Treat every pattern as a fixed string (-F).
    fixed: bool = false,
    icase: bool = false,
    word: bool = false,
    /// The pattern must match a whole line (-x).
    line: bool = false,
    /// `--crlf`: `$` also accepts before the CR of a CRLF pair.
    crlf: bool = false,
    /// `--null-data`: NUL separates records, so a record may contain `\n`.
    null_data: bool = false,
    /// `-G`: BRE patterns, translated to ERE before compiling.
    basic: bool = false,
};

pub const BuildError = error{ BadRegex, OutOfMemory };

/// Builds the right matcher for one or more patterns.
///
/// A single pattern that is a plain string (always true with -F, and for any
/// regex without metacharacters) takes the original literal kernels, so the
/// default cost of searching "const" is unchanged. Anything else compiles to a
/// regex DFA. Allocations live for the life of the process.
pub fn build(gpa: Allocator, patterns: []const []const u8, o: BuildOptions) BuildError!Searcher {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // GNU grep -f with an empty pattern file selects nothing. A dedicated
    // kind keeps that distinct from "empty pattern", which matches every line.
    if (patterns.len == 0) {
        var s = Searcher.init("", o.algo);
        s.kind = .never;
        return s;
    }

    if (patterns.len == 1 and !o.line) {
        const pure: ?[]const u8 = if (o.fixed)
            patterns[0]
        else blk: {
            const src = if (o.basic) bre.breToEre(arena, patterns[0]) else patterns[0];
            const n = try regex.parse(arena, src, .{});
            break :blk try regex.asPureLiteral(arena, n);
        };
        if (pure) |lit| {
            const text = try gpa.dupe(u8, lit);
            if (!o.icase and !o.word) return Searcher.init(if (o.fixed) patterns[0] else text, o.algo);
            if (o.icase) for (text) |*c| {
                c.* = toLowerByte(c.*);
            };
            var s = Searcher.init(text, o.algo);
            s.icase = o.icase;
            s.word = o.word;
            return s;
        }
    }

    const nodes = try arena.alloc(*regex.Node, patterns.len);
    for (patterns, 0..) |p, idx| {
        const src = if (o.basic) bre.breToEre(arena, p) else p;
        var n = if (o.fixed)
            try regex.literalNode(arena, src, o.icase)
        else
            try regex.parse(arena, src, .{ .icase = o.icase, .dot_newline = o.null_data });
        if (o.line) n = try regex.lineWrap(arena, n);
        if (o.word) n = try regex.wordWrap(arena, n);
        nodes[idx] = n;
    }
    const root = try regex.altOf(arena, nodes);
    const prog = try regex.compile(gpa, root);

    var s = Searcher.init("", o.algo);
    s.kind = .regex;
    s.prog = prog;
    s.icase = o.icase;
    s.crlf = o.crlf;
    s.null_data = o.null_data;
    if (patterns.len == 1) {
        if (try regex.requiredLiteral(arena, root, o.icase)) |lit| {
            if (lit.len >= 3) {
                const text = try gpa.dupe(u8, lit);
                const pf = try gpa.create(Searcher);
                pf.* = Searcher.init(text, o.algo);
                pf.icase = o.icase;
                s.prefilter = pf;
            }
        }
    }
    return s;
}

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

test "build: plain string keeps the literal fast path, flags select kernels" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    _ = a;
    // build() allocations are process-lifetime; use page_allocator here.
    const pa = std.heap.page_allocator;
    const lit = try build(pa, &.{"const"}, .{});
    try std.testing.expectEqual(Kind.literal, lit.kind);
    const dotted = try build(pa, &.{"a\\.b"}, .{});
    try std.testing.expectEqual(Kind.literal, dotted.kind);
    try std.testing.expectEqualStrings("a.b", dotted.needle);
    const ci = try build(pa, &.{"HeLLo"}, .{ .icase = true });
    try std.testing.expectEqual(@as(?usize, 4), ci.find("say hello", 0));
    try std.testing.expectEqual(@as(?usize, null), lit.find("say CONST", 0));
    const wd = try build(pa, &.{"cat"}, .{ .word = true });
    try std.testing.expectEqual(@as(?usize, null), wd.find("concatenate", 0));
    try std.testing.expectEqual(@as(?usize, 2), wd.find("a cat", 0));
    const re = try build(pa, &.{"fo+bar"}, .{});
    try std.testing.expectEqual(Kind.regex, re.kind);
    try std.testing.expectEqual(@as(?usize, 4), re.find("xxx\nfoobar\n", 0));
    const multi = try build(pa, &.{ "zzz", "bar" }, .{ .fixed = true });
    try std.testing.expectEqual(Kind.regex, multi.kind);
    try std.testing.expectEqual(@as(?usize, 4), multi.find("foo\nbar\n", 0));
    try std.testing.expectError(error.BadRegex, build(pa, &.{"a(b"}, .{}));

    // Unicode Latin-1 case-folding test (ñ, á, é, í, ó, ú)
    const latin_ci = try build(pa, &.{"ñandú"}, .{ .icase = true, .fixed = true });
    try std.testing.expectEqual(@as(?usize, 3), latin_ci.find("El ÑANDÚ veloz", 0));
    const latin_upper = try build(pa, &.{"ÁRBOL"}, .{ .icase = true, .fixed = true });
    try std.testing.expectEqual(@as(?usize, 3), latin_upper.find("un árbol verde", 0));
}

// ---------------------------------------------------------------------------
// Tests: -x whole-line matching and the empty-pattern-list (-f with an empty
// file) case.
// ---------------------------------------------------------------------------

test "build: -x matches whole lines only" {
    const pa = std.heap.page_allocator;
    const s = try build(pa, &.{"cat"}, .{ .line = true });
    try std.testing.expectEqual(Kind.regex, s.kind); // never the literal fast path
    try std.testing.expectEqual(@as(?usize, 0), s.find("cat", 0));
    try std.testing.expectEqual(@as(?usize, null), s.find("concatenate", 0));
    try std.testing.expectEqual(@as(?usize, null), s.find("cat ", 0));
    try std.testing.expectEqual(@as(?usize, null), s.find("a cat", 0));
    // works over a whole buffer: only the exact line answers
    try std.testing.expectEqual(@as(?usize, 0), s.find("cat\ndog\n", 0));
}

test "build: -x with -i folds the whole line" {
    const pa = std.heap.page_allocator;
    const s = try build(pa, &.{"CAT"}, .{ .line = true, .icase = true });
    try std.testing.expectEqual(@as(?usize, 0), s.find("cat", 0));
    try std.testing.expectEqual(@as(?usize, 0), s.find("CaT", 0));
    try std.testing.expectEqual(@as(?usize, null), s.find("scat", 0));
}

test "build: -x with -F is a real whole line" {
    const pa = std.heap.page_allocator;
    const s = try build(pa, &.{"a.b"}, .{ .line = true, .fixed = true });
    try std.testing.expectEqual(@as(?usize, 0), s.find("a.b", 0));
    try std.testing.expectEqual(@as(?usize, null), s.find("aXb", 0));
    try std.testing.expectEqual(@as(?usize, null), s.find("a.b and more", 0));
}

test "build: -x with several patterns ORs the anchors" {
    const pa = std.heap.page_allocator;
    const s = try build(pa, &.{ "cat", "dog" }, .{ .line = true });
    try std.testing.expectEqual(@as(?usize, 0), s.find("dog", 0));
    try std.testing.expectEqual(@as(?usize, null), s.find("hotdog", 0));
    try std.testing.expectEqual(@as(?usize, null), s.find("dog food", 0));
}

test "build: no patterns selects nothing (-f with an empty file)" {
    const pa = std.heap.page_allocator;
    const s = try build(pa, &.{}, .{});
    try std.testing.expectEqual(Kind.never, s.kind);
    try std.testing.expectEqual(@as(?usize, null), s.find("anything", 0));
    try std.testing.expectEqual(@as(?usize, null), s.find("", 0));
    // and it is NOT the same as an empty pattern, which matches every line
    const empty = try build(pa, &.{""}, .{});
    try std.testing.expectEqual(Kind.literal, empty.kind);
    try std.testing.expectEqual(@as(?usize, 0), empty.find("", 0));
}
