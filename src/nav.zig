//! nav.zig — Befunge-Inspired 2D Vector Grid Directory Navigator for Kernel VFS.
//!
//! Concept ("Befunge Scout"):
//!   Models the filesystem hierarchy as a 2D Cartesian grid:
//!     X-axis = Sibling entries within a directory (0..N)
//!     Y-axis = Tree depth (subdirectories, openat descent)
//!
//! Primitive Directions (2 bits per op):
//!   'v' or 'd' (Down):  Dive into subdirectories (openat), increment Y depth.
//!   '^' or 'u' (Up):    Ascend / prune branch, pop directory.
//!   '>' or 'r' (Right): Forward sibling scan (0..N in inode/directory order).
//!   '<' or 'l' (Left):  Reverse sibling scan (N..0, ideal for recent logs/files).
//!
//! Vector Contraposition Combos (Trampolines & Ceilings):
//!   "v^" / "du" (Down-Up / Depth Ceiling):
//!       Scan regular files in current directory, but immediately bounce on
//!       subdirectories without descending (equivalent to maxdepth=1 with zero counters).
//!   "^v" / "ud" (Up-Down / Trampoline Leapfrog):
//!       Skip (prune) regular files in the root/current directory, but dive
//!       straight into subdirectories (e.g. leapfrog root clutter, search src/ and lib/).
//!   "v<>" / "dlr" (Full Sweep):
//!       Dive into all subdirectories and scan all sibling files bidirectionally.

const std = @import("std");

pub const NavOp = enum(u2) {
    down = 0,  // 'v' or 'd'
    up = 1,    // '^' or 'u'
    right = 2, // '>' or 'r'
    left = 3,  // '<' or 'l'
};

pub const NavPlan = struct {
    ops: [32]NavOp = undefined,
    len: usize = 0,
    has_ceiling: bool = false,      // "v^" or "du"
    has_trampoline: bool = false,   // "^v" or "ud"
    reverse_siblings: bool = false, // '<' or 'l'

    pub fn parse(spec: []const u8) !NavPlan {
        var plan = NavPlan{};
        for (spec) |c| {
            const op: NavOp = switch (c) {
                'v', 'd', 'D' => .down,
                '^', 'u', 'U' => .up,
                '>', 'r', 'R' => .right,
                '<', 'l', 'L' => .left,
                ' ', '\t', ',' => continue,
                else => return error.InvalidNavOp,
            };
            if (plan.len < plan.ops.len) {
                plan.ops[plan.len] = op;
                plan.len += 1;
            }
        }

        // Detect 2D vector contraposition combos
        var i: usize = 0;
        while (i + 1 < plan.len) : (i += 1) {
            const a = plan.ops[i];
            const b = plan.ops[i + 1];
            if (a == .down and b == .up) {
                plan.has_ceiling = true;
            } else if (a == .up and b == .down) {
                plan.has_trampoline = true;
            }
        }

        for (plan.ops[0..plan.len]) |op| {
            if (op == .left) plan.reverse_siblings = true;
        }

        // A ceiling (no descent) plus a trampoline (no root files) leaves
        // nothing to search: `v^v` used to run, find nothing and exit 1 with
        // no message (M11 round 2, R18). It is a contradiction, so it is an
        // error the caller can explain.
        if (plan.has_ceiling and plan.has_trampoline) return error.ContradictoryNavPlan;
        return plan;
    }

    /// Determines whether regular files at the given directory depth should be scanned.
    pub inline fn shouldScanFiles(self: NavPlan, depth: usize) bool {
        if (self.len == 0) return true;
        // Trampoline (^v / ud): Skip files in the root level (depth 0), but scan deeper.
        if (self.has_trampoline and depth == 0) return false;
        return true;
    }

    /// Determines whether subdirectories at the given directory depth should be descended into.
    pub inline fn shouldRecurseSubdirs(self: NavPlan, depth: usize) bool {
        if (self.len == 0) return true;
        // Ceiling (v^ / du): Bounce back at depth 0, do not enter subdirectories.
        if (self.has_ceiling and depth >= 0) return false;
        return true;
    }
};

test "nav: parse primitive arrows and letter tokens" {
    const p1 = try NavPlan.parse("v><^");
    try std.testing.expectEqual(@as(usize, 4), p1.len);
    try std.testing.expectEqual(NavOp.down, p1.ops[0]);
    try std.testing.expectEqual(NavOp.right, p1.ops[1]);
    try std.testing.expectEqual(NavOp.left, p1.ops[2]);
    try std.testing.expectEqual(NavOp.up, p1.ops[3]);

    const p2 = try NavPlan.parse("drlu");
    try std.testing.expectEqual(@as(usize, 4), p2.len);
    try std.testing.expectEqual(NavOp.down, p2.ops[0]);
    try std.testing.expectEqual(NavOp.right, p2.ops[1]);
    try std.testing.expectEqual(NavOp.left, p2.ops[2]);
    try std.testing.expectEqual(NavOp.up, p2.ops[3]);
}

test "nav: contraposition combos: ceiling and trampoline" {
    // Ceiling: v^ or du (depth limit = 0 subdirs)
    const ceiling = try NavPlan.parse("v^");
    try std.testing.expect(ceiling.has_ceiling);
    try std.testing.expect(!ceiling.has_trampoline);
    try std.testing.expect(ceiling.shouldScanFiles(0));
    try std.testing.expect(!ceiling.shouldRecurseSubdirs(0));

    // Trampoline: ^v or ud (leapfrog root files, dive into subdirs)
    const trampoline = try NavPlan.parse("^v");
    try std.testing.expect(!trampoline.has_ceiling);
    try std.testing.expect(trampoline.has_trampoline);
    try std.testing.expect(!trampoline.shouldScanFiles(0)); // root files skipped!
    try std.testing.expect(trampoline.shouldScanFiles(1));  // subfolder files scanned!
    try std.testing.expect(trampoline.shouldRecurseSubdirs(0));

    // Reverse sibling flag
    const rev = try NavPlan.parse("dl");
    try std.testing.expect(rev.reverse_siblings);
}

test "nav: ceiling + trampoline together is rejected (it would search nothing)" {
    try std.testing.expectError(error.ContradictoryNavPlan, NavPlan.parse("v^v"));
    try std.testing.expectError(error.ContradictoryNavPlan, NavPlan.parse("^v^"));
    try std.testing.expectError(error.ContradictoryNavPlan, NavPlan.parse("du ud"));
    // Each one alone still works.
    const c = try NavPlan.parse("v^");
    try std.testing.expect(c.has_ceiling and !c.has_trampoline);
    const t = try NavPlan.parse("^v");
    try std.testing.expect(t.has_trampoline and !t.has_ceiling);
}

