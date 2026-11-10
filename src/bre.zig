//! BRE -> ERE translation (zgrep speaks ERE, like rg).
//!
//! GNU grep's default dialect is BRE, which is *not* a subset of ERE: the
//! escapes are inverted. Accepting `-G` and parsing the pattern as ERE (what
//! zgrep used to do) silently changes the meaning of the pattern. This module
//! translates BRE into the ERE zgrep already understands, so `-G` either
//! works or reports a real error.

const std = @import("std");

/// Translates a BRE pattern into ERE, allocating in `arena`.
///
/// The mapping (outside a bracket expression):
///   BRE        ERE          meaning
///   `\(`  ->   `(`          group open
///   `\)`  ->   `)`          group close
///   `\{`  ->   `{`          repeat open
///   `\}`  ->   `}`          repeat close
///   `\|`  ->   `|`          alternation
///   `\+`  ->   `+`          one or more
///   `\?`  ->   `?`          zero or one
///   `(`   ->   `\(`         literal parenthesis
///   `)`   ->   `\)`
///   `{`   ->   `\{`         literal brace
///   `}`   ->   `\}`
///   `|`   ->   `\|`         literal pipe
///   `+`   ->   `\+`         literal plus
///   `?`   ->   `\?`         literal question
///   `*` at the start of a pattern, branch or group is a LITERAL in BRE
///
/// Inside `[...]` both dialects agree except for `[[:class:]]`, which is POSIX
/// and works in both.
pub fn breToEre(arena: std.mem.Allocator, pattern: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    // Zgrep runs are bounded; a failed allocation just returns the pattern
    // unchanged, which then fails parsing with a clear message.
    breToEreInto(arena, pattern, &out) catch {
        out.deinit(arena);
        return pattern;
    };
    if (out.items.len == 0) return "";
    return out.toOwnedSlice(arena) catch pattern;
}

fn breToEreInto(arena: std.mem.Allocator, pattern: []const u8, out: *std.ArrayList(u8)) !void {
    var in_class = false; // inside [...]
    var at_branch_start = true; // start of pattern, or after ( | or \(
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        if (c == '\\' and i + 1 < pattern.len) {
            const e = pattern[i + 1];
            if (in_class) {
                try out.append(arena, c);
                try out.append(arena, e);
                i += 1;
                continue;
            }
            switch (e) {
                '(', ')', '{', '}', '|', '+', '?' => {
                    // In BRE these are the OPERATORS, so they lose the escape.
                    try out.append(arena, e);
                },
                else => {
                    try out.append(arena, c);
                    try out.append(arena, e);
                },
            }
            if (e == '(' or e == '|') {
                at_branch_start = true;
                i += 1;
                continue;
            }
            at_branch_start = false;
            i += 1;
            continue;
        }
        if (in_class) {
            // A POSIX class `[:alpha:]` has its own `]`: that one does NOT
            // close the bracket expression, or `[[:digit:]]+` would translate
            // into `[[:digit:]\]\+` and match nothing.
            if (c == '[' and i + 1 < pattern.len and pattern[i + 1] == ':') {
                const rest = pattern[i + 2 ..];
                if (std.mem.indexOf(u8, rest, ":]")) |k| {
                    try out.appendSlice(arena, pattern[i .. i + 2 + k + 2]);
                    i += 2 + k + 1;
                    continue;
                }
            }
            try out.append(arena, c);
            if (c == ']') in_class = false;
            continue;
        }
        switch (c) {
            '[' => {
                try out.append(arena, c);
                in_class = true;
                at_branch_start = false;
            },
            ']' => {
                // Outside a class, `]` is a literal in both dialects, but ERE
                // would read it as an unmatched class terminator.
                try out.appendSlice(arena, "\\]");
                at_branch_start = false;
            },
            '(' => {
                try out.appendSlice(arena, "\\(");
                at_branch_start = true;
            },
            ')' => {
                try out.appendSlice(arena, "\\)");
                at_branch_start = false;
            },
            '{' => {
                try out.appendSlice(arena, "\\{");
                at_branch_start = false;
            },
            '}' => {
                try out.appendSlice(arena, "\\}");
                at_branch_start = false;
            },
            '|' => {
                try out.appendSlice(arena, "\\|");
                at_branch_start = true;
            },
            '+' => {
                try out.appendSlice(arena, "\\+");
                at_branch_start = false;
            },
            '?' => {
                try out.appendSlice(arena, "\\?");
                at_branch_start = false;
            },
            '*' => {
                // A leading `*` is a literal star in BRE (POSIX), and ERE
                // rejects "nothing to repeat".
                if (at_branch_start) {
                    try out.appendSlice(arena, "\\*");
                } else {
                    try out.append(arena, c);
                }
                at_branch_start = false;
            },
            else => {
                try out.append(arena, c);
                at_branch_start = false;
            },
        }
    }
}

test "breToEre: the inverted escapes" {
    const a = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "a\\(b\\)c", "a(b)c" },
        .{ "a\\{2\\}", "a{2}" },
        .{ "a\\|b", "a|b" },
        .{ "a\\+", "a+" },
        .{ "a\\?", "a?" },
        .{ "a(b)c", "a\\(b\\)c" },
        .{ "a{2}", "a\\{2\\}" },
        .{ "a|b", "a\\|b" },
        .{ "a+b", "a\\+b" },
        .{ "a?b", "a\\?b" },
        .{ "a*", "a*" },
    };
    for (cases) |c| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const got = breToEre(arena.allocator(), c[0]);
        try std.testing.expectEqualStrings(c[1], got);
    }
}

test "breToEre: a leading * stays literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("\\*ab", breToEre(arena.allocator(), "*ab"));
    try std.testing.expectEqualStrings("a*b", breToEre(arena.allocator(), "a*b"));
    try std.testing.expectEqualStrings("(ab)*c", breToEre(arena.allocator(), "\\(ab\\)*c"));
}

test "breToEre: classes are left alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("[abc]", breToEre(arena.allocator(), "[abc]"));
    // In BRE a `+` after a class is a LITERAL plus, so it must be escaped.
    try std.testing.expectEqualStrings("[[:digit:]]\\+", breToEre(arena.allocator(), "[[:digit:]]+"));
    // A `(` inside a class is a literal in both dialects.
    try std.testing.expectEqualStrings("[(]", breToEre(arena.allocator(), "[(]"));
}
