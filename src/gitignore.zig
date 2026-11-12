//! gitignore.zig — `.gitignore` / `.dataignore` rules with git's semantics.
//!
//! What git does and this module reproduces (gitignore(5)):
//!   - `#` starts a comment; `\#` and `\!` are literal; trailing spaces are
//!     dropped unless escaped with `\`.
//!   - `!pat` re-includes what an earlier rule excluded.
//!   - `pat/` only matches directories.
//!   - A pattern with a '/' at the start or in the middle is anchored to the
//!     directory of the file it came from (`/build`, `doc/frotz`); one without
//!     '/' matches the name at any depth (`*.log`, `node_modules`).
//!   - `**` spans directories (`**/x`, `a/**`, `a/**/b`), `*` and `?` do not.
//!   - Deeper ignore files override shallower ones, and inside one file the
//!     LAST matching line wins.
//!   - A file under an excluded directory cannot be re-included: the walkers
//!     prune excluded directories, which gives the same result.
//!
//! Rules form an immutable chain (`Node`): the directory tasks of the
//! concurrent swarm carry a pointer to the chain of their directory, so worker
//! threads share it without locks. New nodes are only ever prepended to a
//! lock-free list that owns them until `Store.deinit`.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Rule = struct {
    /// Pattern with the `!`, the leading '/' and the trailing '/' removed.
    glob: []const u8,
    negate: bool,
    dir_only: bool,
    /// Matched against the path relative to the ignore file's directory
    /// (else against the entry name only).
    anchored: bool,
};

pub const Node = struct {
    /// Enclosing (shallower) rules; consulted after this node.
    parent: ?*const Node,
    /// Directory string, exactly as the walker spells it, that these rules
    /// are relative to (a search root or a directory below one).
    base: []const u8,
    /// Path from the ignore file's directory down to `base`, '/'-separated.
    /// Empty when the ignore file lives in `base` itself; `src/app` when the
    /// file is two levels above a search root `src/app`.
    prefix: []const u8,
    rules: []const Rule,
    has_anchored: bool,
    /// Ownership list of every node the Store created (not a scope link).
    next_owned: ?*Node = null,
};

/// Signature shared by every glob in filter.zig: `match(text, pattern)`.
pub const MatchFn = *const fn ([]const u8, []const u8) bool;

/// Parses ignore-file text into rules allocated with `gpa`.
pub fn parse(gpa: Allocator, content: []const u8) Allocator.Error![]Rule {
    var rules: std.ArrayList(Rule) = .empty;
    errdefer {
        for (rules.items) |r| gpa.free(r.glob);
        rules.deinit(gpa);
    }
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        // Trailing spaces are ignored unless escaped ("a\ " keeps one).
        while (line.len > 0 and (line[line.len - 1] == ' ' or line[line.len - 1] == '\t')) {
            if (line.len >= 2 and line[line.len - 2] == '\\') break;
            line = line[0 .. line.len - 1];
        }
        if (line.len == 0 or line[0] == '#') continue;

        var negate = false;
        if (line[0] == '!') {
            negate = true;
            line = line[1..];
        } else if (line.len >= 2 and line[0] == '\\' and (line[1] == '!' or line[1] == '#')) {
            line = line[1..];
        }
        var dir_only = false;
        if (line.len > 0 and line[line.len - 1] == '/') {
            dir_only = true;
            line = line[0 .. line.len - 1];
        }
        const anchored = std.mem.indexOfScalar(u8, line, '/') != null;
        while (line.len > 0 and line[0] == '/') line = line[1..];
        if (line.len == 0) continue;

        const glob = try gpa.dupe(u8, line);
        errdefer gpa.free(glob);
        try rules.append(gpa, .{ .glob = glob, .negate = negate, .dir_only = dir_only, .anchored = anchored });
    }
    return rules.toOwnedSlice(gpa);
}

/// Owns the nodes of one run. Thread-safe: `push` is a lock-free prepend.
pub const Store = struct {
    gpa: Allocator,
    head: std.atomic.Value(?*Node) = .init(null),

    pub fn deinit(self: *Store) void {
        var cur = self.head.load(.acquire);
        while (cur) |n| {
            cur = n.next_owned;
            for (n.rules) |r| self.gpa.free(r.glob);
            self.gpa.free(n.rules);
            self.gpa.free(n.base);
            self.gpa.free(n.prefix);
            self.gpa.destroy(n);
        }
        self.head.store(null, .release);
    }

    /// Creates a node that takes ownership of `rules`; null (and `rules`
    /// freed) when there is nothing to add or memory runs out.
    pub fn push(
        self: *Store,
        parent: ?*const Node,
        base: []const u8,
        prefix: []const u8,
        rules: []Rule,
    ) ?*const Node {
        if (rules.len == 0) {
            self.gpa.free(rules);
            return null;
        }
        const node = self.newNode(parent, base, prefix, rules) catch {
            for (rules) |r| self.gpa.free(r.glob);
            self.gpa.free(rules);
            return null;
        };
        var old = self.head.load(.acquire);
        while (true) {
            node.next_owned = old;
            old = self.head.cmpxchgWeak(old, node, .acq_rel, .acquire) orelse break;
        }
        return node;
    }

    fn newNode(self: *Store, parent: ?*const Node, base: []const u8, prefix: []const u8, rules: []Rule) Allocator.Error!*Node {
        const node = try self.gpa.create(Node);
        errdefer self.gpa.destroy(node);
        const base_dup = try self.gpa.dupe(u8, base);
        errdefer self.gpa.free(base_dup);
        const prefix_dup = try self.gpa.dupe(u8, prefix);
        for (prefix_dup) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        var has_anchored = false;
        for (rules) |r| has_anchored = has_anchored or r.anchored;
        node.* = .{
            .parent = parent,
            .base = base_dup,
            .prefix = prefix_dup,
            .rules = rules,
            .has_anchored = has_anchored,
        };
        return node;
    }
};

fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

/// `dir` relative to `base`, or null when `dir` is not `base` or below it.
fn subdirOf(dir: []const u8, base: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, dir, base)) return "";
    // The walkers join "." and "x" as "x" (vfs.joinPathSentinel), so a root
    // of "." owns every relative path that does not climb out of it.
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "./")) {
        if (std.fs.path.isAbsolute(dir) or std.mem.startsWith(u8, dir, "..")) return null;
        var d = dir;
        while (d.len >= 2 and d[0] == '.' and isSep(d[1])) d = d[2..];
        return if (std.mem.eql(u8, d, ".")) "" else d;
    }
    if (!std.mem.startsWith(u8, dir, base)) return null;
    if (base.len > 0 and isSep(base[base.len - 1])) return dir[base.len..];
    if (dir.len > base.len and isSep(dir[base.len])) return dir[base.len + 1 ..];
    return null;
}

/// Writes `prefix/sub/name` ('/' separators, empty parts skipped) into buf.
fn joinRel(buf: []u8, prefix: []const u8, sub: []const u8, name: []const u8) ?[]const u8 {
    var at: usize = 0;
    for ([_][]const u8{ prefix, sub, name }) |part| {
        var p = part;
        while (p.len >= 2 and p[0] == '.' and isSep(p[1])) p = p[2..];
        if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
        const need = at + @intFromBool(at > 0) + p.len;
        if (need > buf.len) return null;
        if (at > 0) {
            buf[at] = '/';
            at += 1;
        }
        @memcpy(buf[at .. at + p.len], p);
        at += p.len;
    }
    const out = buf[0..at];
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

/// The verdict of the chain for entry `name` in directory `dir`:
/// true = ignored, false = re-included by a `!` rule, null = no rule matched.
pub fn decide(node: ?*const Node, dir: []const u8, name: []const u8, is_dir: bool, match: MatchFn) ?bool {
    var buf: [4096]u8 = undefined;
    var cur = node;
    while (cur) |n| : (cur = n.parent) {
        var rel: ?[]const u8 = null;
        if (n.has_anchored) {
            if (subdirOf(dir, n.base)) |sub| rel = joinRel(&buf, n.prefix, sub, name);
        }
        var i = n.rules.len;
        while (i > 0) {
            i -= 1;
            const r = n.rules[i];
            if (r.dir_only and !is_dir) continue;
            const hit = if (r.anchored)
                (if (rel) |p| match(p, r.glob) else false)
            else
                match(name, r.glob);
            if (hit) return !r.negate;
        }
    }
    return null;
}

const testing = std.testing;

fn testGlob(text: []const u8, pat: []const u8) bool {
    // Minimal stand-in for filter.globCore: '*' within a segment, '**' across.
    return @import("filter.zig").matchPattern(text, pat);
}

test "parse: comments, negation, anchoring, dir-only, escapes, trailing spaces" {
    const rules = try parse(testing.allocator, "# c\n\n*.log\n!keep.log\n/build\ndoc/frotz/\nout/  \n\\#lit\n\\!bang\nsp\\ \n");
    defer {
        for (rules) |r| testing.allocator.free(r.glob);
        testing.allocator.free(rules);
    }
    try testing.expectEqual(@as(usize, 8), rules.len);
    try testing.expect(!rules[0].anchored and !rules[0].negate);
    try testing.expect(rules[1].negate);
    try testing.expectEqualStrings("build", rules[2].glob);
    try testing.expect(rules[2].anchored);
    try testing.expect(rules[3].anchored and rules[3].dir_only);
    try testing.expect(!rules[4].anchored and rules[4].dir_only);
    try testing.expectEqualStrings("#lit", rules[5].glob);
    try testing.expectEqualStrings("!bang", rules[6].glob);
    try testing.expect(!rules[6].negate);
    try testing.expectEqualStrings("sp\\ ", rules[7].glob);
}

test "decide: git semantics over a chain" {
    var store: Store = .{ .gpa = testing.allocator };
    defer store.deinit();
    const root = store.push(null, ".", "", try parse(testing.allocator, "*.log\n!important.log\n/build\nsub/gen/\ncache/\n")).?;
    // nested .gitignore in ./pkg re-includes one log and ignores everything in ./pkg/tmp
    const pkg = store.push(root, "./pkg", "", try parse(testing.allocator, "!debug.log\ntmp/*\n")).?;

    try testing.expectEqual(@as(?bool, true), decide(root, ".", "a.log", false, testGlob));
    try testing.expectEqual(@as(?bool, false), decide(root, ".", "important.log", false, testGlob));
    try testing.expectEqual(@as(?bool, true), decide(root, ".", "build", true, testGlob));
    // `/build` is anchored: a nested build/ is not ignored.
    try testing.expectEqual(@as(?bool, null), decide(root, "./src", "build", true, testGlob));
    try testing.expectEqual(@as(?bool, true), decide(root, "./sub", "gen", true, testGlob));
    // The walkers spell children of "." without the "./".
    try testing.expectEqual(@as(?bool, true), decide(root, "sub", "gen", true, testGlob));
    try testing.expectEqual(@as(?bool, null), decide(root, "src", "build", true, testGlob));
    try testing.expectEqual(@as(?bool, null), decide(root, "./other", "gen", true, testGlob));
    // `cache/` is dir-only and unanchored.
    try testing.expectEqual(@as(?bool, true), decide(root, "./x/y", "cache", true, testGlob));
    try testing.expectEqual(@as(?bool, null), decide(root, "./x/y", "cache", false, testGlob));
    // Deeper file wins.
    try testing.expectEqual(@as(?bool, false), decide(pkg, "./pkg", "debug.log", false, testGlob));
    try testing.expectEqual(@as(?bool, true), decide(pkg, "./pkg/a", "other.log", false, testGlob));
    try testing.expectEqual(@as(?bool, true), decide(pkg, "./pkg/tmp", "x.txt", false, testGlob));
    try testing.expectEqual(@as(?bool, null), decide(pkg, "./pkg", "tmp", true, testGlob));
}

test "decide: rules from an ancestor of the search root use the prefix" {
    var store: Store = .{ .gpa = testing.allocator };
    defer store.deinit();
    // repo/.gitignore has `/src/gen` and `src/*.tmp`; the search root is repo/src.
    const n = store.push(null, "/r/src", "src", try parse(testing.allocator, "/src/gen\nsrc/*.tmp\n/top\n")).?;
    try testing.expectEqual(@as(?bool, true), decide(n, "/r/src", "gen", true, testGlob));
    try testing.expectEqual(@as(?bool, true), decide(n, "/r/src", "a.tmp", false, testGlob));
    try testing.expectEqual(@as(?bool, null), decide(n, "/r/src/deep", "a.tmp", false, testGlob));
    try testing.expectEqual(@as(?bool, null), decide(n, "/r/src", "top", true, testGlob));
}
