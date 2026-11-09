//! Small line-oriented regex engine for zigrep.
//!
//! Pipeline: pattern bytes -> AST -> Thompson NFA (`Program`, immutable and
//! shared by every thread) -> lazily built DFA (`Dfa`, one per thread, cached
//! in a threadlocal). A scan is one table lookup per input byte and never
//! backtracks, so the cost is linear in the haystack.
//!
//! The engine answers exactly one question: "does this line contain a match?"
//! (grep semantics). It therefore never tracks match boundaries or captures.
//!
//! Supported syntax (ERE-like, the same dialect as `rg`):
//!   literals   .   [abc] [^a-z] [[:alpha:]]   \d \D \w \W \s \S   \n \t \r
//!   groups     (re)  (?:re)        alternation  a|b
//!   repeats    *  +  ?  {n}  {n,}  {n,m}   (a trailing `?` is accepted and ignored)
//!   anchors    ^  $   (line anchors; every haystack is split on '\n')
//!   escapes    \. \\ \( \) \[ \] \{ \} \* \+ \? \| \^ \$ \/ \- ...
//! Not supported (reported as errors, never silently mis-matched): `\b`,
//! back-references, lookaround. `.` and classes work on bytes, so a multi-byte
//! UTF-8 character is several bytes; -i folds ASCII only.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Set = [256]bool;

pub const CompileError = error{ BadRegex, OutOfMemory };

/// Human readable reason for the last `BadRegex` on this thread.
pub threadlocal var last_error: []const u8 = "";

fn fail(msg: []const u8) CompileError {
    last_error = msg;
    return error.BadRegex;
}

// ---------------------------------------------------------------------------
// AST
// ---------------------------------------------------------------------------

pub const inf: u32 = std.math.maxInt(u32);

pub const Node = union(enum) {
    empty,
    set: Set,
    bol,
    eol,
    cat: []*Node,
    alt: []*Node,
    rep: struct { child: *Node, min: u32, max: u32 },
};

const Parser = struct {
    a: Allocator, // arena
    src: []const u8,
    i: usize = 0,
    icase: bool,
    depth: u32 = 0,

    fn peek(self: *Parser) ?u8 {
        return if (self.i < self.src.len) self.src[self.i] else null;
    }

    fn newNode(self: *Parser, n: Node) CompileError!*Node {
        const p = try self.a.create(Node);
        p.* = n;
        return p;
    }

    fn byteSet(self: *Parser, c: u8) Set {
        var s: Set = @splat(false);
        s[c] = true;
        if (self.icase) {
            if (c >= 'a' and c <= 'z') s[c - 32] = true;
            if (c >= 'A' and c <= 'Z') s[c + 32] = true;
        }
        return s;
    }

    fn parseAlt(self: *Parser) CompileError!*Node {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > 200) return fail("regex nested too deeply");
        var branches: std.ArrayList(*Node) = .empty;
        try branches.append(self.a, try self.parseCat());
        while (true) {
            if (self.peek() == '|') {
                self.i += 1;
                try branches.append(self.a, try self.parseCat());
            } else {
                break;
            }
        }
        if (branches.items.len == 1) return branches.items[0];
        return self.newNode(.{ .alt = branches.items });
    }

    fn parseCat(self: *Parser) CompileError!*Node {
        var items: std.ArrayList(*Node) = .empty;
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            const n = try self.parseRepeat();
            // Flatten plain groups so literal runs stay contiguous.
            switch (n.*) {
                .cat => |kids| try items.appendSlice(self.a, kids),
                else => try items.append(self.a, n),
            }
        }
        if (items.items.len == 0) return self.newNode(.empty);
        if (items.items.len == 1) return items.items[0];
        return self.newNode(.{ .cat = items.items });
    }

    fn parseNumber(self: *Parser) ?u32 {
        const st = self.i;
        var v: u64 = 0;
        while (self.peek()) |c| {
            if (c < '0' or c > '9') break;
            v = v * 10 + (c - '0');
            if (v > 1000) return null;
            self.i += 1;
        }
        if (self.i == st) return null;
        return @intCast(v);
    }

    fn parseRepeat(self: *Parser) CompileError!*Node {
        var atom = try self.parseAtom();
        while (self.peek()) |c| {
            var mn: u32 = 0;
            var mx: u32 = inf;
            switch (c) {
                '*' => self.i += 1,
                '+' => {
                    mn = 1;
                    self.i += 1;
                },
                '?' => {
                    mx = 1;
                    self.i += 1;
                },
                '{' => {
                    const save = self.i;
                    self.i += 1;
                    const a = self.parseNumber();
                    if (a == null) {
                        self.i = save;
                        break; // literal '{' handled by the next parseAtom
                    }
                    mn = a.?;
                    mx = mn;
                    if (self.peek() == ',') {
                        self.i += 1;
                        mx = self.parseNumber() orelse inf;
                    }
                    if (self.peek() != '}') {
                        self.i = save;
                        break;
                    }
                    self.i += 1;
                    if (mx != inf and mx < mn) return fail("bad repeat range {n,m}");
                },
                else => break,
            }
            // lazy / possessive suffix has no effect on "does the line match"
            if (self.peek() == '?') self.i += 1;
            atom = try self.newNode(.{ .rep = .{ .child = atom, .min = mn, .max = mx } });
        }
        return atom;
    }

    fn classSet(name: []const u8) ?Set {
        var s: Set = @splat(false);
        for (0..256) |ci| {
            const c: u8 = @intCast(ci);
            const ok = if (std.mem.eql(u8, name, "alpha")) std.ascii.isAlphabetic(c) else if (std.mem.eql(u8, name, "digit")) std.ascii.isDigit(c) else if (std.mem.eql(u8, name, "alnum")) std.ascii.isAlphanumeric(c) else if (std.mem.eql(u8, name, "upper")) std.ascii.isUpper(c) else if (std.mem.eql(u8, name, "lower")) std.ascii.isLower(c) else if (std.mem.eql(u8, name, "space")) (std.ascii.isWhitespace(c)) else if (std.mem.eql(u8, name, "punct")) (std.ascii.isPrint(c) and !std.ascii.isAlphanumeric(c) and c != ' ') else if (std.mem.eql(u8, name, "xdigit")) std.ascii.isHex(c) else if (std.mem.eql(u8, name, "word")) (std.ascii.isAlphanumeric(c) or c == '_') else if (std.mem.eql(u8, name, "blank")) (c == ' ' or c == '\t') else return null;
            if (ok) {
                s[c] = true;
            }
        }
        return s;
    }

    fn shorthand(c: u8) ?Set {
        var s: Set = @splat(false);
        const neg = std.ascii.isUpper(c);
        const lc = std.ascii.toLower(c);
        for (0..256) |ci| {
            const b: u8 = @intCast(ci);
            const in = switch (lc) {
                'd' => std.ascii.isDigit(b),
                'w' => std.ascii.isAlphanumeric(b) or b == '_',
                's' => b == ' ' or b == '\t' or b == '\r' or b == 0x0b or b == 0x0c or b == '\n',
                else => return null,
            };
            s[b] = if (neg) !in else in;
        }
        return s;
    }

    fn escapeByte(self: *Parser, c: u8) CompileError!u8 {
        _ = self;
        return switch (c) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '0' => 0,
            else => if (std.ascii.isAlphanumeric(c))
                fail("unsupported escape (\\b, \\B, back-references and lookaround are not supported)")
            else
                c,
        };
    }

    fn parseClass(self: *Parser) CompileError!*Node {
        // self.i is just past '['
        var negate = false;
        if (self.peek() == '^') {
            negate = true;
            self.i += 1;
        }
        var set: Set = @splat(false);
        var first = true;
        while (true) {
            const c = self.peek() orelse return fail("unterminated [ class");
            if (c == ']' and !first) {
                self.i += 1;
                break;
            }
            first = false;
            var lo: u8 = undefined;
            if (c == '[' and self.i + 1 < self.src.len and self.src[self.i + 1] == ':') {
                const rest = self.src[self.i + 2 ..];
                const end = std.mem.find(u8, rest, ":]") orelse return fail("unterminated [:class:]");
                const cs = classSet(rest[0..end]) orelse return fail("unknown [:class:] name");
                for (0..256) |k| if (cs[k]) {
                    set[k] = true;
                };
                self.i += 2 + end + 2;
                continue;
            } else if (c == '\\') {
                self.i += 1;
                const e = self.peek() orelse return fail("trailing backslash");
                self.i += 1;
                if (shorthand(e)) |sh| {
                    for (0..256) |k| if (sh[k]) {
                        set[k] = true;
                    };
                    continue;
                }
                lo = try self.escapeByte(e);
            } else {
                lo = c;
                self.i += 1;
            }
            var hi = lo;
            if (self.peek() == '-' and self.i + 1 < self.src.len and self.src[self.i + 1] != ']') {
                self.i += 1;
                var h = self.src[self.i];
                self.i += 1;
                if (h == '\\') {
                    const e = self.peek() orelse return fail("trailing backslash");
                    self.i += 1;
                    h = try self.escapeByte(e);
                }
                hi = h;
                if (hi < lo) return fail("invalid range in [ class");
            }
            var k: usize = lo;
            while (k <= hi) : (k += 1) set[k] = true;
        }
        if (self.icase) {
            for ('a'..'z' + 1) |ch| {
                const l: u8 = @intCast(ch);
                if (set[l] or set[l - 32]) {
                    set[l] = true;
                    set[l - 32] = true;
                }
            }
        }
        if (negate) {
            for (0..256) |k| set[k] = !set[k];
        }
        set['\n'] = false; // a line never contains '\n'
        return self.newNode(.{ .set = set });
    }

    fn parseAtom(self: *Parser) CompileError!*Node {
        const c = self.peek().?;
        self.i += 1;
        switch (c) {
            '(' => {
                if (self.i + 1 < self.src.len and self.src[self.i] == '?' and self.src[self.i + 1] == ':') {
                    self.i += 2;
                } else if (self.peek() == '?') {
                    return fail("unsupported group syntax (?...): only (?:...) is allowed");
                }
                const inner = try self.parseAlt();
                if (self.peek() != ')') return fail("unclosed group (");
                self.i += 1;
                return inner;
            },
            ')' => return fail("unmatched )"),
            '*', '+', '?' => return fail("nothing to repeat"),
            '.' => {
                var s: Set = @splat(true);
                s['\n'] = false;
                return self.newNode(.{ .set = s });
            },
            '[' => return self.parseClass(),
            '^' => return self.newNode(.bol),
            '$' => return self.newNode(.eol),
            '\\' => {
                const e = self.peek() orelse return fail("trailing backslash");
                self.i += 1;
                if (shorthand(e)) |sh| return self.newNode(.{ .set = sh });
                const b = try self.escapeByte(e);
                return self.newNode(.{ .set = self.byteSet(b) });
            },
            else => return self.newNode(.{ .set = self.byteSet(c) }),
        }
    }
};

pub const ParseOptions = struct {
    icase: bool = false,
    word: bool = false,
};

/// Parses `pattern` into an AST allocated in `arena`.
pub fn parse(arena: Allocator, pattern: []const u8, o: ParseOptions) CompileError!*Node {
    var p: Parser = .{ .a = arena, .src = pattern, .icase = o.icase };
    const n = try p.parseAlt();
    if (p.i != pattern.len) return fail("unmatched )");
    return n;
}

/// AST of a fixed string (every byte literal, optionally case-folded).
pub fn literalNode(arena: Allocator, text: []const u8, icase: bool) CompileError!*Node {
    var p: Parser = .{ .a = arena, .src = text, .icase = icase };
    var items: std.ArrayList(*Node) = .empty;
    for (text) |c| try items.append(arena, try p.newNode(.{ .set = p.byteSet(c) }));
    if (items.items.len == 0) return p.newNode(.empty);
    if (items.items.len == 1) return items.items[0];
    return p.newNode(.{ .cat = items.items });
}

fn nonWordSet() Set {
    var s: Set = @splat(true);
    for (0..256) |k| {
        const b: u8 = @intCast(k);
        if (std.ascii.isAlphanumeric(b) or b == '_') s[k] = false;
    }
    s['\n'] = false;
    return s;
}

/// Wraps `inner` so it only matches as a whole word (`grep -w`).
pub fn wordWrap(arena: Allocator, inner: *Node) CompileError!*Node {
    const mk = struct {
        fn n(a: Allocator, v: Node) CompileError!*Node {
            const p = try a.create(Node);
            p.* = v;
            return p;
        }
    }.n;
    const nw = try mk(arena, .{ .set = nonWordSet() });
    const bol = try mk(arena, .bol);
    const eol = try mk(arena, .eol);
    const left_alts = try arena.alloc(*Node, 2);
    left_alts[0] = bol;
    left_alts[1] = nw;
    const right_alts = try arena.alloc(*Node, 2);
    right_alts[0] = eol;
    right_alts[1] = nw;
    const left = try mk(arena, .{ .alt = left_alts });
    const right = try mk(arena, .{ .alt = right_alts });
    var items: std.ArrayList(*Node) = .empty;
    try items.append(arena, left);
    switch (inner.*) {
        .cat => |kids| try items.appendSlice(arena, kids),
        else => try items.append(arena, inner),
    }
    try items.append(arena, right);
    return mk(arena, .{ .cat = items.items });
}

/// Wraps `inner` so it must match a whole line (`grep -x`).
pub fn lineWrap(arena: Allocator, inner: *Node) CompileError!*Node {
    const mk = struct {
        fn n(a: Allocator, v: Node) CompileError!*Node {
            const p = try a.create(Node);
            p.* = v;
            return p;
        }
    }.n;
    const bol = try mk(arena, .bol);
    const eol = try mk(arena, .eol);
    var items: std.ArrayList(*Node) = .empty;
    try items.append(arena, bol);
    switch (inner.*) {
        .cat => |kids| try items.appendSlice(arena, kids),
        else => try items.append(arena, inner),
    }
    try items.append(arena, eol);
    return mk(arena, .{ .cat = items.items });
}

/// Joins several patterns into one alternation.
pub fn altOf(arena: Allocator, nodes: []*Node) CompileError!*Node {
    if (nodes.len == 1) return nodes[0];
    const p = try arena.create(Node);
    p.* = .{ .alt = nodes };
    return p;
}

/// If the AST is a pure string of single bytes (case-sensitive), returns it.
pub fn asPureLiteral(arena: Allocator, n: *const Node) CompileError!?[]u8 {
    switch (n.*) {
        .empty => return try arena.alloc(u8, 0),
        .set => |s| {
            const b = singleByte(s) orelse return null;
            const out = try arena.alloc(u8, 1);
            out[0] = b;
            return out;
        },
        .cat => |kids| {
            const out = try arena.alloc(u8, kids.len);
            for (kids, 0..) |k, idx| {
                switch (k.*) {
                    .set => |s| out[idx] = singleByte(s) orelse return null,
                    else => return null,
                }
            }
            return out;
        },
        else => return null,
    }
}

fn singleByte(s: Set) ?u8 {
    var found: ?u8 = null;
    for (0..256) |k| {
        if (s[k]) {
            if (found != null) return null;
            found = @intCast(k);
        }
    }
    return found;
}

/// Longest run of required literal bytes at the top level of the AST. With
/// `icase`, a letter pair {a,A} counts and the run is returned lower-cased.
pub fn requiredLiteral(arena: Allocator, n: *const Node, icase: bool) CompileError!?[]u8 {
    const kids: []const *Node = switch (n.*) {
        .cat => |k| k,
        .set => blk: {
            const one = try arena.alloc(*Node, 1);
            one[0] = @constCast(n);
            break :blk one;
        },
        else => return null,
    };
    var best: []u8 = &.{};
    var cur: std.ArrayList(u8) = .empty;
    for (kids) |k| {
        var byte: ?u8 = null;
        switch (k.*) {
            .set => |s| byte = litByte(s, icase),
            else => {},
        }
        if (byte) |b| {
            try cur.append(arena, b);
        } else {
            if (cur.items.len > best.len) best = cur.items;
            cur = .empty;
        }
    }
    if (cur.items.len > best.len) best = cur.items;
    if (best.len == 0) return null;
    return best;
}

fn litByte(s: Set, icase: bool) ?u8 {
    var first: ?u8 = null;
    var second: ?u8 = null;
    for (0..256) |k| {
        if (!s[k]) continue;
        if (first == null) {
            first = @intCast(k);
        } else if (second == null) {
            second = @intCast(k);
        } else return null;
    }
    const f = first orelse return null;
    if (second == null) return if (icase) std.ascii.toLower(f) else f;
    if (!icase) return null;
    const sc = second.?;
    if (std.ascii.isAlphabetic(f) and std.ascii.isAlphabetic(sc) and std.ascii.toLower(f) == std.ascii.toLower(sc)) return std.ascii.toLower(f);
    return null;
}

// ---------------------------------------------------------------------------
// NFA program
// ---------------------------------------------------------------------------

const Kind = enum(u8) { set, split, bol, eol, match };

const NNode = struct {
    kind: Kind,
    set: u32 = 0,
    out: u32 = 0,
    out1: u32 = 0,
};

pub const Program = struct {
    id: u64 = 0,
    nodes: []NNode,
    sets: []Set,
    start: u32,
    match_node: u32,
    /// True when some pattern needs bol/eol handling (informational).
    anchored: bool,
};

const max_nfa_nodes = 60_000;

const Builder = struct {
    a: Allocator,
    nodes: std.ArrayList(NNode) = .empty,
    sets: std.ArrayList(Set) = .empty,

    fn add(self: *Builder, n: NNode) CompileError!u32 {
        if (self.nodes.items.len >= max_nfa_nodes) return fail("regex too large");
        try self.nodes.append(self.a, n);
        return @intCast(self.nodes.items.len - 1);
    }

    fn emit(self: *Builder, n: *const Node, next: u32) CompileError!u32 {
        switch (n.*) {
            .empty => return next,
            .set => |s| {
                try self.sets.append(self.a, s);
                return self.add(.{ .kind = .set, .set = @intCast(self.sets.items.len - 1), .out = next });
            },
            .bol => return self.add(.{ .kind = .bol, .out = next }),
            .eol => return self.add(.{ .kind = .eol, .out = next }),
            .cat => |kids| {
                var cur = next;
                var k = kids.len;
                while (k > 0) {
                    k -= 1;
                    cur = try self.emit(kids[k], cur);
                }
                return cur;
            },
            .alt => |kids| {
                var entry = try self.emit(kids[kids.len - 1], next);
                var k = kids.len - 1;
                while (k > 0) {
                    k -= 1;
                    const e = try self.emit(kids[k], next);
                    entry = try self.add(.{ .kind = .split, .out = e, .out1 = entry });
                }
                return entry;
            },
            .rep => |r| {
                var cur = next;
                if (r.max == inf) {
                    const s = try self.add(.{ .kind = .split, .out = 0, .out1 = next });
                    const body = try self.emit(r.child, s);
                    self.nodes.items[s].out = body;
                    cur = s;
                } else {
                    var k: u32 = 0;
                    while (k < r.max - r.min) : (k += 1) {
                        const body = try self.emit(r.child, cur);
                        cur = try self.add(.{ .kind = .split, .out = body, .out1 = next });
                    }
                }
                var m: u32 = 0;
                while (m < r.min) : (m += 1) cur = try self.emit(r.child, cur);
                return cur;
            },
        }
    }
};

var next_prog_id: std.atomic.Value(u64) = .init(1);

/// Builds a `Program` that matches if ANY line substring matches `root`.
/// `gpa` owns the result for the life of the process.
pub fn compile(gpa: Allocator, root: *const Node) CompileError!*Program {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    var b: Builder = .{ .a = arena_inst.allocator() };
    const m = try b.add(.{ .kind = .match });
    const start = try b.emit(root, m);

    const prog = try gpa.create(Program);
    prog.* = .{
        .id = next_prog_id.fetchAdd(1, .monotonic),
        .nodes = try gpa.dupe(NNode, b.nodes.items),
        .sets = try gpa.dupe(Set, b.sets.items),
        .start = start,
        .match_node = m,
        .anchored = false,
    };
    return prog;
}

// ---------------------------------------------------------------------------
// Lazy DFA
// ---------------------------------------------------------------------------

const unknown: u32 = std.math.maxInt(u32);
/// A match location inside a line: `data[start..end)`.
pub const Span = struct {
    start: usize,
    end: usize,

    pub fn slice(self: Span, data: []const u8) []const u8 {
        return data[self.start..self.end];
    }
};

const match_state: u32 = 0;
const max_states = 3000;

const State = struct {
    nodes: []const u32,
    /// -1 unknown, 0 no, 1 yes: does the state accept at end of line?
    accept_end: i8 = -1,
    /// True when the state's NFA set contains the match node: a match just
    /// completed. Used by the span runner (`nextMatch`) to recover WHERE.
    accepting: bool = false,
};

pub const Dfa = struct {
    prog: *const Program,
    prog_id: u64 = 0,
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    states: std.ArrayList(State) = .empty,
    trans: std.ArrayList(u32) = .empty,
    /// Same transitions as `trans`, but WITHOUT injecting `prog.start` on
    /// every byte. That second table is what makes the span runner possible:
    /// "match anywhere" collapses the instant a match completes (it cannot
    /// say where it started), while "match from position p" runs anchored.
    trans_span: std.ArrayList(u32) = .empty,
    index: std.StringHashMapUnmanaged(u32) = .empty,
    init_bol: u32 = 0,
    init_mid: u32 = 0,
    /// Incremented whenever the state cache is flushed (state ids die).
    flushes: u32 = 0,
    // scratch
    mark: []u32,
    gen: u32 = 0,
    stack: std.ArrayList(u32) = .empty,
    work: std.ArrayList(u32) = .empty,
    seeds: std.ArrayList(u32) = .empty,

    pub fn create(gpa: Allocator, prog: *const Program) Allocator.Error!*Dfa {
        const d = try gpa.create(Dfa);
        d.* = .{
            .prog = prog,
            .prog_id = prog.id,
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .mark = try gpa.alloc(u32, prog.nodes.len),
        };
        @memset(d.mark, 0);
        try d.reset();
        return d;
    }

    pub fn deinit(self: *Dfa) void {
        self.arena.deinit();
        self.gpa.free(self.mark);
        self.states.deinit(self.gpa);
        self.trans.deinit(self.gpa);
        self.trans_span.deinit(self.gpa);
        self.index.deinit(self.gpa);
        self.stack.deinit(self.gpa);
        self.work.deinit(self.gpa);
        self.seeds.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn reset(self: *Dfa) Allocator.Error!void {
        self.states.clearRetainingCapacity();
        self.trans.clearRetainingCapacity();
        self.trans_span.clearRetainingCapacity();
        self.index.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        self.flushes +%= 1;
        // state 0 is the absorbing dead state (kept for id stability).
        try self.states.append(self.gpa, .{ .nodes = &.{}, .accept_end = 0 });
        try self.trans.appendNTimes(self.gpa, 0, 256);
        try self.trans_span.appendNTimes(self.gpa, 0, 256);
        self.seeds.clearRetainingCapacity();
        try self.seeds.append(self.gpa, self.prog.start);
        self.init_bol = try self.intern(try self.closure(true, false));
        self.seeds.clearRetainingCapacity();
        try self.seeds.append(self.gpa, self.prog.start);
        self.init_mid = try self.intern(try self.closure(false, false));
    }

    /// Epsilon closure of `self.seeds`, collecting the set, eol and match
    /// nodes into a sorted list. The match node stays IN the list (instead of
    /// aborting the closure): that is what lets a state mean "a match just
    /// completed here" and keeps scanning for a longer one.
    fn closure(self: *Dfa, at_bol: bool, at_eol: bool) Allocator.Error![]const u32 {
        self.gen +%= 1;
        if (self.gen == 0) {
            @memset(self.mark, 0);
            self.gen = 1;
        }
        self.work.clearRetainingCapacity();
        self.stack.clearRetainingCapacity();
        for (self.seeds.items) |s| try self.stack.append(self.gpa, s);
        const nodes = self.prog.nodes;
        while (self.stack.pop()) |id| {
            if (self.mark[id] == self.gen) continue;
            self.mark[id] = self.gen;
            const n = nodes[id];
            switch (n.kind) {
                .set => try self.work.append(self.gpa, id),
                .split => {
                    try self.stack.append(self.gpa, n.out1);
                    try self.stack.append(self.gpa, n.out);
                },
                .bol => if (at_bol) try self.stack.append(self.gpa, n.out),
                .eol => if (at_eol) {
                    try self.stack.append(self.gpa, n.out);
                } else {
                    try self.work.append(self.gpa, id);
                },
                .match => try self.work.append(self.gpa, id),
            }
        }
        std.mem.sort(u32, self.work.items, {}, std.sort.asc(u32));
        return self.work.items;
    }

    /// Does the interned node list mean "a match completed"?
    fn has_match(list: []const u32, match_node: u32) bool {
        for (list) |id| {
            if (id == match_node) return true;
        }
        return false;
    }

    pub fn isAccepting(self: *const Dfa, s: u32) bool {
        return self.states.items[s].accepting;
    }

    /// True when no NFA thread is alive in `s` (it can never accept again).
    fn is_dead(self: *const Dfa, s: u32) bool {
        const nodes = self.states.items[s].nodes;
        for (nodes) |id| {
            if (id != self.prog.match_node) return false;
        }
        return true;
    }

    fn intern(self: *Dfa, nodes: []const u32) Allocator.Error!u32 {
        const key = std.mem.sliceAsBytes(nodes);
        if (self.index.get(key)) |id| return id;
        if (self.states.items.len >= max_states) {
            // Cache full: flush and start over. Callers must not reuse old ids.
            const copy = try self.gpa.dupe(u32, nodes);
            defer self.gpa.free(copy);
            try self.reset();
            return self.internFresh(copy);
        }
        return self.internFresh(nodes);
    }

    fn internFresh(self: *Dfa, list: []const u32) Allocator.Error!u32 {
        const key = std.mem.sliceAsBytes(list);
        if (self.index.get(key)) |id| return id;
        const owned = try self.arena.allocator().dupe(u32, list);
        const id: u32 = @intCast(self.states.items.len);
        try self.states.append(self.gpa, .{
            .nodes = owned,
            .accepting = has_match(list, self.prog.match_node),
        });
        try self.trans.appendNTimes(self.gpa, unknown, 256);
        try self.trans_span.appendNTimes(self.gpa, unknown, 256);
        try self.index.put(self.gpa, std.mem.sliceAsBytes(owned), id);
        return id;
    }

    fn acceptEnd(self: *Dfa, s: u32) Allocator.Error!bool {
        const st = &self.states.items[s];
        if (st.accept_end >= 0) return st.accept_end == 1;
        self.seeds.clearRetainingCapacity();
        const prog = self.prog;
        for (st.nodes) |id| {
            const n = prog.nodes[id];
            if (n.kind == .eol) try self.seeds.append(self.gpa, n.out);
        }
        var ok = false;
        if (self.seeds.items.len > 0) {
            ok = has_match(try self.closure(false, true), prog.match_node);
        }
        // `st` may dangle only if states grew; closure() never interns.
        self.states.items[s].accept_end = if (ok) 1 else 0;
        return ok;
    }

    /// Scans data[from..to) as whole lines. Returns the start offset of the
    /// first line that matches, or null.
    pub fn firstMatchingLine(self: *Dfa, data: []const u8, from: usize, to: usize) ?usize {
        return self.firstMatchingLineImpl(data, from, to) catch null;
    }

    fn firstMatchingLineImpl(self: *Dfa, data: []const u8, from: usize, to: usize) Allocator.Error!?usize {
        var s = self.init_bol;
        var ls = from;
        var i = from;
        while (i < to) {
            const b = data[i];
            if (b == '\n') {
                if (try self.acceptEnd(s)) return ls;
                s = self.init_bol;
                i += 1;
                ls = i;
                continue;
            }
            var t = self.trans.items[@as(usize, s) * 256 + b];
            if (t == unknown) t = try self.step(s, b, true);
            if (self.isAccepting(t)) return ls;
            s = t;
            i += 1;
        }
        if (ls < to and try self.acceptEnd(s)) return ls;
        return null;
    }

    /// Computes (and caches) the transition of `s` on byte `b`.
    ///
    /// `inject` re-seeds `prog.start` every step, which is what "the regex
    /// matches somewhere after here" needs. The span runner passes `false`:
    /// it must know where a match STARTED, so no new threads may appear
    /// mid-run.
    fn step(self: *Dfa, s: u32, b: u8, inject: bool) Allocator.Error!u32 {
        const gen_before = self.flushes;
        self.seeds.clearRetainingCapacity();
        const prog = self.prog;
        for (self.states.items[s].nodes) |id| {
            const n = prog.nodes[id];
            if (n.kind == .set and prog.sets[n.set][b]) try self.seeds.append(self.gpa, n.out);
        }
        if (inject) try self.seeds.append(self.gpa, prog.start);
        const r = try self.closure(false, false);
        const target = try self.intern(r);
        // Never cache across a flush: `s` no longer names the same state.
        if (self.flushes == gen_before) {
            const table = if (inject) &self.trans else &self.trans_span;
            table.items[@as(usize, s) * 256 + b] = target;
        }
        return target;
    }

    /// Leftmost-longest match inside `data[from..to)`, with both ends.
    /// `data` is a single line (no '\n' expected); position 0 is BOL.
    ///
    /// Restarting at every position makes this the classic $O(n^2)$ worst
    /// case, which is exactly what a POSIX leftmost-longest engine does; in
    /// practice callers only reach it for lines that already matched.
    pub fn nextMatch(self: *Dfa, data: []const u8, from: usize, to: usize) ?Span {
        return self.nextMatchImpl(data, from, to) catch null;
    }

    fn nextMatchImpl(self: *Dfa, data: []const u8, from: usize, to: usize) Allocator.Error!?Span {
        var p = from;
        while (p <= to) : (p += 1) {
            var s = if (p == 0) self.init_bol else self.init_mid;
            var best_end: ?usize = null;
            // `$` is an end-of-LINE assertion, and `nextMatch` is handed one
            // line: it can only fire once the whole slice is consumed (or
            // immediately on an empty line). Asking acceptEnd at every step
            // would let `a$` match the first 'a' of "aaaa".
            if (self.isAccepting(s)) best_end = p;
            if (best_end == null and to == p and try self.acceptEnd(s)) best_end = p;
            var i = p;
            while (i < to) : (i += 1) {
                const b = data[i];
                var t = self.trans_span.items[@as(usize, s) * 256 + b];
                if (t == unknown) t = try self.step(s, b, false);
                if (self.isAccepting(t)) best_end = i + 1;
                if (best_end == null and i + 1 == to and try self.acceptEnd(t)) best_end = i + 1;
                if (self.is_dead(t)) break;
                s = t;
            }
            if (best_end) |e| return .{ .start = p, .end = e };
            if (p == to) break;
        }
        return null;
    }
};

threadlocal var tl_dfa: ?*Dfa = null;

/// This thread's DFA for `prog`, building it on first use.
pub fn threadDfa(prog: *const Program) Allocator.Error!*Dfa {
    if (tl_dfa) |d| {
        if (d.prog_id == prog.id) return d;
        d.deinit();
        tl_dfa = null;
    }
    const d = try Dfa.create(std.heap.page_allocator, prog);
    tl_dfa = d;
    return d;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testMatch(pattern: []const u8, line: []const u8, o: ParseOptions) !bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var root = try parse(arena.allocator(), pattern, o);
    if (o.word) root = try wordWrap(arena.allocator(), root);
    const prog = try compile(std.heap.page_allocator, root);
    const d = try Dfa.create(std.heap.page_allocator, prog);
    return d.firstMatchingLine(line, 0, line.len) != null;
}

const plain: ParseOptions = .{};

test "regex: literals, dot, classes" {
    try std.testing.expect(try testMatch("abc", "xxabcxx", plain));
    try std.testing.expect(!try testMatch("abc", "xxabxcxx", plain));
    try std.testing.expect(try testMatch("a.c", "xxabcxx", plain));
    try std.testing.expect(try testMatch("[a-c]+z", "xxbbz", plain));
    try std.testing.expect(!try testMatch("[^a-c]z", "bz az", plain));
    try std.testing.expect(try testMatch("[[:digit:]]{3}", "ab123", plain));
    try std.testing.expect(!try testMatch("[[:digit:]]{3}", "ab12c3", plain));
    try std.testing.expect(try testMatch("\\d+\\.\\d+", "v 3.14", plain));
    try std.testing.expect(!try testMatch("\\d+\\.\\d+", "v 314", plain));
}

test "regex: repeats and alternation" {
    try std.testing.expect(try testMatch("ab*c", "ac", plain));
    try std.testing.expect(try testMatch("ab*c", "abbbc", plain));
    try std.testing.expect(!try testMatch("ab+c", "ac", plain));
    try std.testing.expect(try testMatch("colou?r", "color", plain));
    try std.testing.expect(try testMatch("cat|dog", "hotdog", plain));
    try std.testing.expect(!try testMatch("cat|dog", "bird", plain));
    // ERE, same dialect as rg and `grep -E`: `\|` is a LITERAL pipe.
    try std.testing.expect(!try testMatch("cat\\|dog", "hotdog", plain));
    try std.testing.expect(try testMatch("cat\\|dog", "cat|dog", plain));
    try std.testing.expect(!try testMatch("webgpu\\|wgpu\\|dawn", "this is dawn here", plain));
    try std.testing.expect(try testMatch("webgpu\\|wgpu\\|dawn", "webgpu|wgpu|dawn", plain));
    try std.testing.expect(!try testMatch("webgpu\\|wgpu\\|dawn", "vulkan only", plain));
    try std.testing.expect(try testMatch("(ab){2}", "xababx", plain));
    try std.testing.expect(!try testMatch("(ab){2}", "xabax", plain));
    try std.testing.expect(try testMatch("a{2,3}", "baab", plain));
    try std.testing.expect(!try testMatch("a{2,3}", "bab", plain));
    try std.testing.expect(try testMatch("fn\\s+\\w+\\(", "pub fn main() {", plain));
}

test "regex: anchors are per line" {
    try std.testing.expect(try testMatch("^abc", "abcdef", plain));
    try std.testing.expect(!try testMatch("^abc", "xabc", plain));
    try std.testing.expect(try testMatch("abc$", "xxabc", plain));
    try std.testing.expect(!try testMatch("abc$", "abcx", plain));
    try std.testing.expect(try testMatch("^$", "a\n\nb", plain));
    try std.testing.expect(try testMatch("^a.*z$", "abcz", plain));
}

test "regex: case-insensitive and whole word" {
    try std.testing.expect(try testMatch("hello", "Say HeLLo", .{ .icase = true }));
    try std.testing.expect(!try testMatch("hello", "Say HeLLo", plain));
    try std.testing.expect(try testMatch("[a-c]x", "BX", .{ .icase = true }));
    try std.testing.expect(try testMatch("cat", "a cat sat", .{ .word = true }));
    try std.testing.expect(!try testMatch("cat", "concatenate", .{ .word = true }));
    try std.testing.expect(try testMatch("cat", "cat", .{ .word = true }));
    try std.testing.expect(try testMatch("cat", "(cat)", .{ .word = true }));
}

test "regex: multiline buffer returns the first matching line start" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), "b+c", plain);
    const prog = try compile(std.heap.page_allocator, root);
    const d = try Dfa.create(std.heap.page_allocator, prog);
    const data = "aaa\nxbbc\nzzz\nbc";
    try std.testing.expectEqual(@as(?usize, 4), d.firstMatchingLine(data, 0, data.len));
    try std.testing.expectEqual(@as(?usize, 13), d.firstMatchingLine(data, 9, data.len));
}

test "regex: errors" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    try std.testing.expectError(error.BadRegex, parse(arena.allocator(), "a(b", plain));
    try std.testing.expectError(error.BadRegex, parse(arena.allocator(), "*a", plain));
    try std.testing.expectError(error.BadRegex, parse(arena.allocator(), "[abc", plain));
    try std.testing.expectError(error.BadRegex, parse(arena.allocator(), "a\\bz", plain));
    try std.testing.expectError(error.BadRegex, parse(arena.allocator(), "a)", plain));
}

test "regex: cache flush keeps results correct" {
    // Many distinct states: (a|b)*a(a|b){10} needs 2^11 DFA states.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), "a(a|b){11}c", plain);
    const prog = try compile(std.heap.page_allocator, root);
    const d = try Dfa.create(std.heap.page_allocator, prog);
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    var buf: [20000]u8 = undefined;
    for (&buf) |*c| c.* = if (rnd.boolean()) 'a' else 'b';
    // no 'c' in the haystack -> must not match, even across flushes
    try std.testing.expectEqual(@as(?usize, null), d.firstMatchingLine(&buf, 0, buf.len));
    buf[19000] = 'c';
    buf[18988] = 'a';
    try std.testing.expectEqual(@as(?usize, 0), d.firstMatchingLine(&buf, 0, buf.len));
}
