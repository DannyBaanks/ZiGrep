//! Differential fuzzer: ZiGrep's matcher against an independent reference.
//!
//! Behaviour copied from the ISyCo neuro-symbolic fuzz oracle (ISyCo-IA-Lab,
//! inspired by WINS): everything in process, millions of cases, a reference
//! oracle that shares NO code with the engine under test, inputs biased
//! towards boundaries, and a minimal counterexample when they disagree.
//!
//! Each case generates a regex AST (or -F literals), prints it as ERE for
//! ZiGrep, and evaluates the SAME AST with a set-of-positions matcher written
//! here (byte semantics, like ZiGrep and `LC_ALL=C grep -E`). Checked:
//!   1. which lines are selected (with -i, -w, -x, -v, several -e, -F);
//!   2. `-o` spans: leftmost-longest, non-overlapping, absolute offsets;
//!   3. internal consistency: -c == printed lines, -q/-l == (count > 0), the
//!      fast path == the line-by-line path (`--json` forces it), and the
//!      literal kernels (auto / bmh / memchr) agree.
//! A divergence is shrunk (lines, then bytes) and written to
//! `--out=DIR/divergences.jsonl` with the pattern, flags and haystack; the
//! judge (`scripts/diff_fuzz_triage.py`) replays it under GNU grep to say
//! who is wrong.
//!
//! Entropy knob (`--knob=1..5`, or `auto` = every level in turn):
//!   1 tiny alphabet, short lines, shallow patterns: dense matches
//!   2 + classes, anchors, repeats
//!   3 + nesting, alternation inside repeats, several -e
//!   4 + nullable stars ((a*)*), {m,n} stacks, empty branches
//!   5 + raw high bytes, CR, TAB, NUL inside lines, long lines
//!
//! Usage:
//!   zig build diff-fuzz -Doptimize=ReleaseFast -- [CASES] [--threads=N]
//!       [--seed=S] [--knob=1..5|auto] [--out=DIR] [--max-reports=N]
const std = @import("std");
const zgrep = @import("zgrep");

const search = zgrep.search;
const scan = zgrep.scan;
const Searcher = search.Searcher;
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// RNG (xorshift64*, boundary-biased bytes: from the neuro fuzz oracle)
// ---------------------------------------------------------------------------

const Rng = struct {
    state: u64,
    fn init(seed: u64) Rng {
        return .{ .state = if (seed == 0) 0x9E3779B97F4A7C15 else seed };
    }
    fn next(self: *Rng) u64 {
        var x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        return x *% 0x2545F4914F6CDD1D;
    }
    fn below(self: *Rng, n: usize) usize {
        return @intCast(self.next() % n);
    }
    fn chance(self: *Rng, percent: usize) bool {
        return self.below(100) < percent;
    }
    fn boolean(self: *Rng) bool {
        return self.next() & 1 == 1;
    }
};

// ---------------------------------------------------------------------------
// Pattern AST
// ---------------------------------------------------------------------------

const max_line = 120; // positions 0..120 fit a u128 bitset
const Set = u128;

const Node = union(enum) {
    lit: u8,
    dot,
    class: struct { set: [256]bool, negated: bool },
    concat: []const *const Node,
    alt: []const *const Node,
    star: *const Node,
    plus: *const Node,
    quest: *const Node,
    repeat: struct { child: *const Node, min: u8, max: ?u8 },
    bol,
    eol,
};

const Gen = struct {
    rng: *Rng,
    arena: Allocator,
    knob: u8,

    fn alphabet(self: *const Gen) []const u8 {
        return switch (self.knob) {
            1 => "ab",
            2 => "abcA _",
            3 => "abcAB _-.0",
            4 => "abcABC _-.09x",
            else => "abcABC _-.09x\r\t\x80\xff",
        };
    }

    fn byte(self: *Gen) u8 {
        const a = self.alphabet();
        return a[self.rng.below(a.len)];
    }

    fn node(self: *Gen, depth: u8) Allocator.Error!*const Node {
        const n = try self.arena.create(Node);
        const max_depth: u8 = switch (self.knob) {
            1 => 1,
            2 => 2,
            3 => 3,
            else => 4,
        };
        const leaf = depth >= max_depth or self.rng.chance(45);
        if (leaf) {
            const r = self.rng.below(10);
            if (r < 6) {
                n.* = .{ .lit = self.byte() };
            } else if (r < 7) {
                n.* = .dot;
            } else {
                var set = [_]bool{false} ** 256;
                const a = self.alphabet();
                const k = 1 + self.rng.below(3);
                for (0..k) |_| set[a[self.rng.below(a.len)]] = true;
                if (self.knob >= 2 and self.rng.chance(30)) {
                    // a range: a-c or 0-9
                    if (self.rng.boolean()) {
                        for ("abc") |c| set[c] = true;
                    } else {
                        for ("0123456789") |c| set[c] = true;
                    }
                }
                n.* = .{ .class = .{ .set = set, .negated = self.knob >= 2 and self.rng.chance(30) } };
            }
            return n;
        }
        const r = self.rng.below(10);
        if (r < 4) {
            const k = 2 + self.rng.below(3);
            const kids = try self.arena.alloc(*const Node, k);
            for (kids) |*kid| kid.* = try self.node(depth + 1);
            n.* = .{ .concat = kids };
        } else if (r < 6) {
            const k = 2 + self.rng.below(2);
            const kids = try self.arena.alloc(*const Node, k);
            for (kids) |*kid| {
                // knob 4+: empty branches, `(a|)`
                if (self.knob >= 4 and self.rng.chance(15)) {
                    const e = try self.arena.create(Node);
                    e.* = .{ .concat = &.{} };
                    kid.* = e;
                } else kid.* = try self.node(depth + 1);
            }
            n.* = .{ .alt = kids };
        } else if (r < 7) {
            n.* = .{ .star = try self.node(depth + 1) };
        } else if (r < 8) {
            n.* = .{ .plus = try self.node(depth + 1) };
        } else if (r < 9) {
            n.* = .{ .quest = try self.node(depth + 1) };
        } else {
            const min: u8 = @intCast(self.rng.below(3));
            const max: ?u8 = if (self.rng.chance(25)) null else min + @as(u8, @intCast(self.rng.below(3)));
            n.* = .{ .repeat = .{ .child = try self.node(depth + 1), .min = min, .max = max } };
        }
        return n;
    }

    /// A top-level pattern: optional ^ and $ only at its edges (POSIX allows
    /// them inside too, but GNU grep and ZiGrep may disagree on purpose).
    fn pattern(self: *Gen) Allocator.Error!*const Node {
        const body = try self.node(0);
        const bol = self.knob >= 2 and self.rng.chance(12);
        const eol = self.knob >= 2 and self.rng.chance(12);
        if (!bol and !eol) return body;
        var parts: std.ArrayList(*const Node) = .empty;
        if (bol) {
            const b = try self.arena.create(Node);
            b.* = .bol;
            try parts.append(self.arena, b);
        }
        try parts.append(self.arena, body);
        if (eol) {
            const e = try self.arena.create(Node);
            e.* = .eol;
            try parts.append(self.arena, e);
        }
        const n = try self.arena.create(Node);
        n.* = .{ .concat = try parts.toOwnedSlice(self.arena) };
        return n;
    }

    fn haystack(self: *Gen) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        const lines = self.rng.below(if (self.knob >= 3) 10 else 6) + 1;
        const max_len: usize = if (self.knob >= 5) max_line else if (self.knob >= 3) 40 else 12;
        for (0..lines) |li| {
            const len = self.rng.below(max_len + 1);
            for (0..len) |_| {
                var c = self.byte();
                if (self.knob >= 5 and self.rng.chance(2)) c = 0;
                try out.append(self.arena, c);
            }
            if (li + 1 < lines or self.rng.boolean()) try out.append(self.arena, '\n');
        }
        return out.toOwnedSlice(self.arena);
    }
};

// --- printing the AST as ERE ----------------------------------------------

fn isMeta(c: u8) bool {
    return switch (c) {
        '.', '[', ']', '(', ')', '*', '+', '?', '{', '}', '|', '^', '$', '\\' => true,
        else => false,
    };
}

fn printNode(out: *std.ArrayList(u8), a: Allocator, n: *const Node, parent_binds: bool) Allocator.Error!void {
    switch (n.*) {
        .lit => |c| {
            if (isMeta(c)) try out.append(a, '\\');
            try out.append(a, c);
        },
        .dot => try out.append(a, '.'),
        .bol => try out.append(a, '^'),
        .eol => try out.append(a, '$'),
        .class => |cl| {
            try out.append(a, '[');
            if (cl.negated) try out.append(a, '^');
            // ']' first is literal; '-' last is literal; '^' not first.
            if (cl.set[']']) try out.append(a, ']');
            for (0..256) |i| {
                const c: u8 = @intCast(i);
                if (!cl.set[i] or c == ']' or c == '-' or c == '^' or c == '\n') continue;
                if (c == '\\') {
                    try out.appendSlice(a, "\\\\");
                    continue;
                }
                try out.append(a, c);
            }
            if (cl.set['^']) try out.append(a, '^');
            if (cl.set['-']) try out.append(a, '-');
            try out.append(a, ']');
        },
        .concat => |kids| {
            if (kids.len == 0) return; // empty branch of an alternation
            const wrap = parent_binds and kids.len > 1;
            if (wrap) try out.append(a, '(');
            for (kids) |k| try printNode(out, a, k, true);
            if (wrap) try out.append(a, ')');
        },
        .alt => |kids| {
            try out.append(a, '(');
            for (kids, 0..) |k, i| {
                if (i > 0) try out.append(a, '|');
                try printNode(out, a, k, false);
            }
            try out.append(a, ')');
        },
        .star, .plus, .quest => |child| {
            try printAtom(out, a, child);
            try out.append(a, switch (n.*) {
                .star => '*',
                .plus => '+',
                else => '?',
            });
        },
        .repeat => |r| {
            try printAtom(out, a, r.child);
            var buf: [16]u8 = undefined;
            const s = if (r.max) |mx|
                (if (mx == r.min) std.fmt.bufPrint(&buf, "{{{d}}}", .{r.min}) else std.fmt.bufPrint(&buf, "{{{d},{d}}}", .{ r.min, mx }))
            else
                std.fmt.bufPrint(&buf, "{{{d},}}", .{r.min});
            try out.appendSlice(a, s catch unreachable);
        },
    }
}

/// The operand of a postfix operator: always parenthesised unless a single
/// literal, dot or class (so `(ab)*`, `(a*)*`, `(^)` never become ambiguous).
fn printAtom(out: *std.ArrayList(u8), a: Allocator, n: *const Node) Allocator.Error!void {
    switch (n.*) {
        .lit, .dot, .class => try printNode(out, a, n, true),
        .alt => try printNode(out, a, n, true),
        else => {
            try out.append(a, '(');
            try printNode(out, a, n, false);
            try out.append(a, ')');
        },
    }
}

// ---------------------------------------------------------------------------
// Reference matcher: sets of positions over one line (no shared code)
// ---------------------------------------------------------------------------

const Ref = struct {
    line: []const u8,
    icase: bool,

    fn bit(p: usize) Set {
        return @as(Set, 1) << @intCast(p);
    }

    fn fold(c: u8) u8 {
        return if (c >= 'A' and c <= 'Z') c + 32 else c;
    }

    fn eqByte(self: *const Ref, a: u8, b: u8) bool {
        return a == b or (self.icase and fold(a) == fold(b) and std.ascii.isAlphabetic(a));
    }

    fn inClass(self: *const Ref, set: *const [256]bool, c: u8) bool {
        if (set[c]) return true;
        if (self.icase and std.ascii.isAlphabetic(c)) {
            return set[std.ascii.toLower(c)] or set[std.ascii.toUpper(c)];
        }
        return false;
    }

    /// End positions reachable by matching `n` from any position in `s`.
    fn ends(self: *const Ref, n: *const Node, s: Set) Set {
        const len = self.line.len;
        switch (n.*) {
            .lit => |c| {
                var out: Set = 0;
                for (0..len) |p| {
                    if (s & bit(p) != 0 and self.eqByte(self.line[p], c)) out |= bit(p + 1);
                }
                return out;
            },
            .dot => {
                var out: Set = 0;
                for (0..len) |p| {
                    if (s & bit(p) != 0) out |= bit(p + 1);
                }
                return out;
            },
            .class => |*cl| {
                var out: Set = 0;
                for (0..len) |p| {
                    if (s & bit(p) == 0) continue;
                    const m = self.inClass(&cl.set, self.line[p]);
                    if (m != cl.negated) out |= bit(p + 1);
                }
                return out;
            },
            .bol => return s & bit(0),
            .eol => return s & bit(len),
            .concat => |kids| {
                var cur = s;
                for (kids) |k| cur = self.ends(k, cur);
                return cur;
            },
            .alt => |kids| {
                var out: Set = 0;
                for (kids) |k| out |= self.ends(k, s);
                return out;
            },
            .star => |child| return self.closure(child, s),
            .plus => |child| return self.closure(child, self.ends(child, s)),
            .quest => |child| return s | self.ends(child, s),
            .repeat => |r| {
                var cur = s;
                for (0..r.min) |_| cur = self.ends(r.child, cur);
                if (r.max) |mx| {
                    var acc = cur;
                    for (r.min..mx) |_| {
                        cur = self.ends(r.child, cur);
                        acc |= cur;
                    }
                    return acc;
                }
                return self.closure(r.child, cur);
            },
        }
    }

    fn closure(self: *const Ref, child: *const Node, s: Set) Set {
        var acc = s;
        while (true) {
            const nxt = acc | self.ends(child, acc);
            if (nxt == acc) return acc;
            acc = nxt;
        }
    }
};

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

const Opts = struct {
    icase: bool = false,
    word: bool = false,
    line: bool = false,
    invert: bool = false,
    fixed: bool = false,
};

/// The patterns, as ASTs (regex) or literal bytes (-F).
const Pats = struct {
    asts: []const *const Node = &.{},
    lits: []const []const u8 = &.{},
};

/// End positions of pattern `i` starting exactly at `start`.
fn patEnds(r: *const Ref, pats: Pats, i: usize, start: usize) Set {
    if (pats.lits.len > 0) {
        const lit = pats.lits[i];
        if (start + lit.len > r.line.len) return 0;
        for (lit, 0..) |c, k| {
            if (!r.eqByte(r.line[start + k], c)) return 0;
        }
        return Ref.bit(start + lit.len);
    }
    return r.ends(pats.asts[i], Ref.bit(start));
}

fn npats(pats: Pats) usize {
    return if (pats.lits.len > 0) pats.lits.len else pats.asts.len;
}

/// Does the line contain a match that satisfies -w / -x?
fn refLineMatches(line: []const u8, pats: Pats, o: Opts) bool {
    const r = Ref{ .line = line, .icase = o.icase };
    for (0..npats(pats)) |i| {
        for (0..line.len + 1) |start| {
            if (o.line and start != 0) break;
            if (o.word and start > 0 and isWordByte(line[start - 1])) continue;
            const e = patEnds(&r, pats, i, start);
            if (e == 0) continue;
            for (start..line.len + 1) |j| {
                if (e & Ref.bit(j) == 0) continue;
                if (o.line and j != line.len) continue;
                if (o.word and j < line.len and isWordByte(line[j])) continue;
                return true;
            }
        }
    }
    return false;
}

/// `-o` spans of one line (no -w/-x/-v): leftmost, then longest over every
/// pattern, non-overlapping, empty matches skipped (GNU grep -o).
fn refSpans(line: []const u8, pats: Pats, o: Opts, out: *std.ArrayList([2]usize), a: Allocator) Allocator.Error!void {
    const r = Ref{ .line = line, .icase = o.icase };
    var pos: usize = 0;
    while (pos <= line.len) {
        var found = false;
        var start = pos;
        while (start <= line.len) : (start += 1) {
            var e: Set = 0;
            for (0..npats(pats)) |i| e |= patEnds(&r, pats, i, start);
            e &= ~(Ref.bit(start + 1) - 1); // drop empty (end == start) and earlier
            if (e != 0) {
                const j = 127 - @clz(e);
                try out.append(a, .{ start, j });
                pos = j;
                found = true;
                break;
            }
        }
        if (!found) return;
    }
}

// ---------------------------------------------------------------------------
// One case
// ---------------------------------------------------------------------------

const Case = struct {
    pats_src: []const []const u8,
    pats: Pats,
    opts: Opts,
    hay: []const u8,
    knob: u8,
};

const Verdict = struct {
    ok: bool,
    what: []const u8 = "",
};

fn buildSearcher(a: Allocator, c: *const Case, algo: search.Algo) ?Searcher {
    return search.build(a, c.pats_src, .{
        .algo = algo,
        .fixed = c.opts.fixed,
        .icase = c.opts.icase,
        .word = c.opts.word,
        .line = c.opts.line,
    }) catch null;
}

fn lineStarts(a: Allocator, hay: []const u8) Allocator.Error![]const [2]usize {
    var v: std.ArrayList([2]usize) = .empty;
    var s: usize = 0;
    while (s < hay.len) {
        const e = std.mem.indexOfScalarPos(u8, hay, s, '\n') orelse hay.len;
        try v.append(a, .{ s, e });
        s = e + 1;
    }
    return v.toOwnedSlice(a);
}

/// Line numbers printed by `-n` output (1-based).
fn printedLines(a: Allocator, out: []const u8) Allocator.Error![]usize {
    var v: std.ArrayList(usize) = .empty;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |l| {
        if (l.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        const n = std.fmt.parseInt(usize, l[0..colon], 10) catch continue;
        if (v.items.len == 0 or v.items[v.items.len - 1] != n) try v.append(a, n);
    }
    return v.toOwnedSlice(a);
}

fn check(a: Allocator, c: *const Case, stats: *Stats) Allocator.Error!Verdict {
    const s = buildSearcher(a, c, .auto) orelse {
        _ = stats.rejected.fetchAdd(1, .monotonic);
        return .{ .ok = true };
    };
    const lines = try lineStarts(a, c.hay);

    // Reference: selected lines.
    var want: std.ArrayList(usize) = .empty;
    for (lines, 0..) |ln, i| {
        const m = refLineMatches(c.hay[ln[0]..ln[1]], c.pats, c.opts);
        if (m != c.opts.invert) try want.append(a, i + 1);
    }

    // ZiGrep: lines mode with -n.
    var out: std.ArrayList(u8) = .empty;
    const cfg: scan.ScanConfig = .{ .show_line_no = true, .invert = c.opts.invert };
    const br = try scan.scanBuffer(a, c.hay, &s, "f", false, .lines, cfg, &out);
    const got = try printedLines(a, out.items);
    if (!std.mem.eql(usize, want.items, got)) return .{ .ok = false, .what = "selected lines differ from the reference" };
    if (br.lines != got.len) return .{ .ok = false, .what = "lines-mode count != printed lines" };

    // -c, -q, -l agree with it.
    var sink: std.ArrayList(u8) = .empty;
    const bc = try scan.scanBuffer(a, c.hay, &s, "f", false, .count, .{ .invert = c.opts.invert }, &sink);
    if (bc.lines != want.items.len) return .{ .ok = false, .what = "-c differs from the reference" };
    const bq = try scan.scanBuffer(a, c.hay, &s, "f", false, .quiet, .{ .invert = c.opts.invert }, &sink);
    if (bq.matched != (want.items.len > 0)) return .{ .ok = false, .what = "-q differs from the reference" };
    const bl = try scan.scanBuffer(a, c.hay, &s, "f", false, .files, .{ .invert = c.opts.invert }, &sink);
    if (bl.matched != (want.items.len > 0)) return .{ .ok = false, .what = "-l differs from the reference" };

    // The line-by-line path (forced by --json) agrees with the fast path.
    sink.clearRetainingCapacity();
    const bj = try scan.scanBuffer(a, c.hay, &s, "f", false, .count, .{ .invert = c.opts.invert, .json = true }, &sink);
    if (bj.lines != want.items.len) return .{ .ok = false, .what = "line-by-line path (--json) count differs" };

    // Literal kernels agree (-F).
    if (c.opts.fixed) {
        for ([_]search.Algo{ .bmh, .memchr }) |algo| {
            const s2 = buildSearcher(a, c, algo) orelse return .{ .ok = false, .what = "algo variant rejected a pattern auto accepted" };
            const b2 = try scan.scanBuffer(a, c.hay, &s2, "f", false, .count, .{ .invert = c.opts.invert }, &sink);
            if (b2.lines != want.items.len) return .{ .ok = false, .what = if (algo == .bmh) "-F bmh kernel differs" else "-F memchr kernel differs" };
        }
    }

    // -o spans (no -w/-x/-v: their -o semantics are a GNU implementation detail).
    if (!c.opts.word and !c.opts.line and !c.opts.invert) {
        var spans: std.ArrayList([2]usize) = .empty;
        for (lines) |ln| {
            var ls: std.ArrayList([2]usize) = .empty;
            try refSpans(c.hay[ln[0]..ln[1]], c.pats, c.opts, &ls, a);
            for (ls.items) |sp| try spans.append(a, .{ ln[0] + sp[0], ln[0] + sp[1] });
        }
        var oo: std.ArrayList(u8) = .empty;
        _ = try scan.scanBuffer(a, c.hay, &s, "f", false, .lines, .{ .only_matching = true, .byte_offset = true }, &oo);
        var gs: std.ArrayList([2]usize) = .empty;
        var it = std.mem.splitScalar(u8, oo.items, '\n');
        var parsed_ok = true;
        // A match may contain bytes but never '\n': one record per line.
        while (it.next()) |l| {
            if (l.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, l, ':') orelse {
                parsed_ok = false;
                break;
            };
            const off = std.fmt.parseInt(usize, l[0..colon], 10) catch {
                parsed_ok = false;
                break;
            };
            try gs.append(a, .{ off, off + (l.len - colon - 1) });
        }
        if (parsed_ok and !std.mem.eql([2]usize, spans.items, gs.items)) {
            return .{ .ok = false, .what = "-o spans differ from the reference (leftmost-longest)" };
        }
    }
    return .{ .ok = true };
}

// ---------------------------------------------------------------------------
// Generation of a whole case
// ---------------------------------------------------------------------------

fn genCase(a: Allocator, rng: *Rng, knob: u8) Allocator.Error!Case {
    var g = Gen{ .rng = rng, .arena = a, .knob = knob };
    var o: Opts = .{
        .icase = rng.chance(30),
        .word = rng.chance(20),
        .line = rng.chance(10),
        .invert = rng.chance(15),
        .fixed = rng.chance(25),
    };
    if (o.word and o.line) o.word = false;
    const k: usize = if (knob >= 3 and rng.chance(30)) 2 + rng.below(2) else 1;
    const srcs = try a.alloc([]const u8, k);
    var pats: Pats = .{};
    if (o.fixed) {
        const lits = try a.alloc([]const u8, k);
        for (lits, srcs) |*l, *src| {
            const len = rng.below(5) + @intFromBool(!rng.chance(5)); // sometimes empty
            const b = try a.alloc(u8, len);
            for (b) |*c| c.* = g.byte();
            l.* = b;
            src.* = b;
        }
        pats.lits = lits;
    } else {
        const asts = try a.alloc(*const Node, k);
        for (asts, srcs) |*n, *src| {
            n.* = try g.pattern();
            var buf: std.ArrayList(u8) = .empty;
            try printNode(&buf, a, n.*, false);
            src.* = try buf.toOwnedSlice(a);
        }
        pats.asts = asts;
    }
    return .{ .pats_src = srcs, .pats = pats, .opts = o, .hay = try g.haystack(), .knob = knob };
}

/// Shrinks the haystack while the case still fails: drop whole lines, then
/// single bytes. The pattern stays as generated.
fn shrink(a: Allocator, c: Case, stats: *Stats) Allocator.Error!Case {
    var cur = c;
    var changed = true;
    var rounds: usize = 0;
    while (changed and rounds < 64) : (rounds += 1) {
        changed = false;
        const lines = try lineStarts(a, cur.hay);
        for (0..lines.len) |drop| {
            var h: std.ArrayList(u8) = .empty;
            for (lines, 0..) |ln, i| {
                if (i == drop) continue;
                try h.appendSlice(a, cur.hay[ln[0]..ln[1]]);
                try h.append(a, '\n');
            }
            var t = cur;
            t.hay = h.items;
            if (!(try check(a, &t, stats)).ok) {
                cur = t;
                changed = true;
                break;
            }
        }
        if (changed) continue;
        var i: usize = 0;
        while (i < cur.hay.len) : (i += 1) {
            if (cur.hay[i] == '\n') continue;
            const h = try a.alloc(u8, cur.hay.len - 1);
            @memcpy(h[0..i], cur.hay[0..i]);
            @memcpy(h[i..], cur.hay[i + 1 ..]);
            var t = cur;
            t.hay = h;
            if (!(try check(a, &t, stats)).ok) {
                cur = t;
                changed = true;
                break;
            }
        }
    }
    return cur;
}

// ---------------------------------------------------------------------------
// Swarm
// ---------------------------------------------------------------------------

const Stats = struct {
    cases: std.atomic.Value(u64) = .init(0),
    divergences: std.atomic.Value(u64) = .init(0),
    rejected: std.atomic.Value(u64) = .init(0),
    reported: std.atomic.Value(u64) = .init(0),
    per_knob: [5]std.atomic.Value(u64) = @splat(.init(0)),
    div_knob: [5]std.atomic.Value(u64) = @splat(.init(0)),
};

const Report = struct {
    lock: std.atomic.Value(bool) = .init(false),
    buf: std.ArrayList(u8) = .empty,
    gpa: Allocator,
    seen: std.StringHashMapUnmanaged(void) = .empty,
};

const Ctx = struct {
    gpa: Allocator,
    stats: *Stats,
    report: *Report,
    target: u64,
    seed: u64,
    knob: u8, // 0 = auto
    max_reports: u64,
    tid: usize,
};

fn appendJsonBytes(out: *std.ArrayList(u8), a: Allocator, bytes: []const u8) Allocator.Error!void {
    try out.append(a, '"');
    for (bytes) |c| {
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try out.append(a, c),
            else => {
                var b: [8]u8 = undefined;
                try out.appendSlice(a, std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch unreachable);
            },
        }
    }
    try out.append(a, '"');
}

fn record(ctx: *Ctx, a: Allocator, c: Case, what: []const u8, seed: u64) void {
    _ = ctx.stats.divergences.fetchAdd(1, .monotonic);
    _ = ctx.stats.div_knob[c.knob - 1].fetchAdd(1, .monotonic);
    if (ctx.stats.reported.load(.monotonic) >= ctx.max_reports) return;
    const small = shrink(a, c, ctx.stats) catch c;
    var line: std.ArrayList(u8) = .empty;
    line.appendSlice(a, "{\"what\":") catch return;
    appendJsonBytes(&line, a, what) catch return;
    var sig: std.ArrayList(u8) = .empty;
    sig.appendSlice(a, what) catch return;
    line.appendSlice(a, ",\"patterns\":[") catch return;
    for (small.pats_src, 0..) |p, i| {
        if (i > 0) line.append(a, ',') catch return;
        appendJsonBytes(&line, a, p) catch return;
        sig.appendSlice(a, p) catch return;
    }
    var b: [256]u8 = undefined;
    const flags = std.fmt.bufPrint(&b, "],\"fixed\":{},\"icase\":{},\"word\":{},\"line\":{},\"invert\":{},\"knob\":{d},\"seed\":{d},\"haystack\":", .{
        small.opts.fixed, small.opts.icase, small.opts.word, small.opts.line, small.opts.invert, small.knob, seed,
    }) catch return;
    line.appendSlice(a, flags) catch return;
    sig.appendSlice(a, flags[0..std.mem.indexOf(u8, flags, ",\"knob\"").?]) catch return;
    appendJsonBytes(&line, a, small.hay) catch return;
    line.appendSlice(a, "}\n") catch return;

    while (ctx.report.lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    defer ctx.report.lock.store(false, .release);
    // One report per (what, patterns, flags): the same bug found a thousand
    // times is one entry.
    const key = ctx.report.gpa.dupe(u8, sig.items) catch return;
    const gop = ctx.report.seen.getOrPut(ctx.report.gpa, key) catch return;
    if (gop.found_existing) {
        ctx.report.gpa.free(key);
        return;
    }
    if (ctx.stats.reported.fetchAdd(1, .monotonic) >= ctx.max_reports) return;
    ctx.report.buf.appendSlice(ctx.report.gpa, line.items) catch {};
}

fn worker(ctx: *Ctx) void {
    var arena_inst = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_inst.deinit();
    var n: u64 = 0;
    while (true) {
        const idx = ctx.stats.cases.fetchAdd(1, .monotonic);
        if (idx >= ctx.target) break;
        const seed = ctx.seed ^ (idx *% 0x9E3779B97F4A7C15) ^ 0xD1B54A32D192ED03;
        var rng = Rng.init(seed);
        const knob: u8 = if (ctx.knob == 0) @intCast(1 + idx % 5) else ctx.knob;
        _ = ctx.stats.per_knob[knob - 1].fetchAdd(1, .monotonic);
        const a = arena_inst.allocator();
        if (genCase(a, &rng, knob)) |c| {
            const v = check(a, &c, ctx.stats) catch Verdict{ .ok = true };
            if (!v.ok) record(ctx, a, c, v.what, seed);
        } else |_| {}
        n += 1;
        if (n % 256 == 0) _ = arena_inst.reset(.retain_capacity);
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var target: u64 = 1_000_000;
    var threads: usize = std.Thread.getCpuCount() catch 4;
    var seed: u64 = @truncate(@as(u128, @bitCast(@as(i128, std.Io.Clock.now(.real, init.io).nanoseconds))));
    var knob: u8 = 0;
    var out_dir: []const u8 = "fuzz-out";
    var max_reports: u64 = 200;
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--threads=")) {
            threads = try std.fmt.parseInt(usize, arg["--threads=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--knob=")) {
            const v = arg["--knob=".len..];
            knob = if (std.mem.eql(u8, v, "auto")) 0 else try std.fmt.parseInt(u8, v, 10);
            if (knob > 5) return error.BadKnob;
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
            out_dir = arg["--out=".len..];
        } else if (std.mem.startsWith(u8, arg, "--max-reports=")) {
            max_reports = try std.fmt.parseInt(u64, arg["--max-reports=".len..], 10);
        } else {
            target = try std.fmt.parseInt(u64, arg, 10);
        }
    }
    if (threads == 0) threads = 1;

    var stats: Stats = .{};
    var report: Report = .{ .gpa = gpa };
    defer {
        var it = report.seen.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        report.seen.deinit(gpa);
        report.buf.deinit(gpa);
    }
    const ctxs = try arena.alloc(Ctx, threads);
    const handles = try arena.alloc(std.Thread, threads);
    const t0 = std.Io.Clock.now(.awake, init.io).nanoseconds;
    for (ctxs, handles, 0..) |*c, *h, i| {
        c.* = .{ .gpa = gpa, .stats = &stats, .report = &report, .target = target, .seed = seed, .knob = knob, .max_reports = max_reports, .tid = i };
        h.* = try std.Thread.spawn(.{}, worker, .{c});
    }
    for (handles) |h| h.join();
    const t1 = std.Io.Clock.now(.awake, init.io).nanoseconds;
    const secs = @as(f64, @floatFromInt(t1 - t0)) / 1e9;

    try std.Io.Dir.cwd().createDirPath(init.io, out_dir);
    const path = try std.fs.path.join(arena, &.{ out_dir, "divergences.jsonl" });
    {
        const f = try std.Io.Dir.cwd().createFile(init.io, path, .{});
        defer f.close(init.io);
        try f.writeStreamingAll(init.io, report.buf.items);
    }

    const done = @min(stats.cases.load(.acquire), target);
    std.debug.print(
        \\diff-fuzz: cases={d} seed={d} threads={d} elapsed_s={d:.2} cases_per_s={d:.0}
        \\  divergences={d} (unique reported={d}, file {s})
        \\  rejected_patterns={d}
        \\
    , .{ done, seed, threads, secs, @as(f64, @floatFromInt(done)) / secs, stats.divergences.load(.acquire), @min(stats.reported.load(.acquire), max_reports), path, stats.rejected.load(.acquire) });
    for (0..5) |k| {
        std.debug.print("  knob {d}: cases={d} divergences={d}\n", .{ k + 1, stats.per_knob[k].load(.acquire), stats.div_knob[k].load(.acquire) });
    }
    if (stats.divergences.load(.acquire) > 0) std.process.exit(1);
}
