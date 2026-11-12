//! Directory walk. The VFS adapter retains the Linux getdents64 fast path and
//! supplies native directory iteration on Windows.
const std = @import("std");
const Allocator = std.mem.Allocator;
const filter = @import("filter.zig");
const vfs = @import("vfs.zig");
const FilterEngine = filter.FilterEngine;
const nav = @import("nav.zig");
const NavPlan = nav.NavPlan;

pub const walk_max_depth = 512;

pub const Error = error{
    OutOfMemory,
    OpenFailed,
    ReadFailed,
    TooDeep,
};

pub const Item = struct {
    path: [:0]const u8,
    kind: vfs.EntryKind,

    pub fn lessThan(_: void, a: Item, b: Item) bool {
        return std.mem.order(u8, a.path, b.path) == .lt;
    }

    pub fn greaterThan(_: void, a: Item, b: Item) bool {
        return std.mem.order(u8, a.path, b.path) == .gt;
    }
};

/// Appends every regular file reachable from `roots` to `out`.
/// If `filter_engine` is provided, noisy directories (.git, node_modules, etc.)
/// and ignored files are pruned during directory enumeration.
/// If `nav_plan` is provided, Befunge 2D vector instructions (^, v, >, <, ^v, v^)
/// control depth scanning, trampoline skips, and sibling ordering.
pub fn walk(
    io: std.Io,
    gpa: Allocator,
    roots: []const [:0]const u8,
    out: *std.ArrayList([:0]const u8),
    filter_engine: ?*const FilterEngine,
    nav_plan: ?NavPlan,
    max_depth: usize,
    max_filesize: usize,
) Error!void {
    for (roots) |root| {
        const ign = if (filter_engine) |fe| fe.rootNode(root) else null;
        try walkOne(io, gpa, root, out, 0, filter_engine, ign, nav_plan, max_depth, max_filesize);
    }
}

fn walkOne(
    io: std.Io,
    gpa: Allocator,
    dir: [:0]const u8,
    out: *std.ArrayList([:0]const u8),
    depth: usize,
    filter_engine: ?*const FilterEngine,
    parent_ign: ?*const filter.IgnoreNode,
    nav_plan: ?NavPlan,
    max_depth: usize,
    max_filesize: usize,
) Error!void {
    if (depth > walk_max_depth) return error.TooDeep;

    const metadata = vfs.stat(io, dir, true) orelse return error.OpenFailed;
    if (metadata.kind == .file) {
        try out.append(gpa, dir);
        return;
    }
    if (metadata.kind != .directory) return;

    var stream = try vfs.DirStream.open(io, dir);
    defer stream.close();

    // A root's chain already holds its own ignore files.
    const ign = if (depth == 0) parent_ign else if (filter_engine) |fe| fe.enterDir(io, parent_ign, dir) else null;

    var items: std.ArrayList(Item) = .empty;
    defer items.deinit(gpa);

    const scan_files = if (nav_plan) |np| np.shouldScanFiles(depth) else true;
    const recurse_subdirs = if (nav_plan) |np| np.shouldRecurseSubdirs(depth) else true;

    while (true) {
        const maybe_entry = stream.next() catch return error.ReadFailed;
        const entry = maybe_entry orelse break;
        var kind = entry.kind;
        if (kind == .unknown) {
            const child = try vfs.joinPathSentinel(gpa, dir, entry.name);
            const child_meta = vfs.stat(io, child, false);
            gpa.free(child);
            kind = if (child_meta) |info| info.kind else .other;
        }

        if (kind == .directory) {
            if (!recurse_subdirs) continue;
            if (filter_engine) |fe| {
                if (fe.isDirExcludedAt(ign, dir, entry.name)) continue;
            }
        } else if (kind == .file) {
            if (!scan_files) continue;
            if (filter_engine) |fe| {
                if (fe.isFileExcludedAt(ign, dir, entry.name)) continue;
            }
            if (max_filesize > 0) {
                const child = try vfs.joinPathSentinel(gpa, dir, entry.name);
                defer gpa.free(child);
                const meta = vfs.statFile(io, child, .{ .follow_symlinks = false }) catch null;
                if (meta) |m| {
                    if (m.size > max_filesize) continue;
                }
            }
        } else {
            continue;
        }

        const child = try vfs.joinPathSentinel(gpa, dir, entry.name);
        try items.append(gpa, .{ .path = child, .kind = kind });
    }

    // Keep directory traversal deterministic; Befunge '<' reverses siblings.
    if (nav_plan != null and nav_plan.?.reverse_siblings) {
        std.sort.pdq(Item, items.items, {}, Item.greaterThan);
    } else {
        std.sort.pdq(Item, items.items, {}, Item.lessThan);
    }

    for (items.items) |item| {
        if (item.kind == .directory) {
            // rg's --max-depth counts from the root, so depth 0 is the root
            // itself: `--max-depth 1` never descends into a subdirectory.
            if (max_depth != 0 and depth + 1 >= max_depth) {
                gpa.free(item.path);
                continue;
            }
            try walkOne(io, gpa, item.path, out, depth + 1, filter_engine, ign, nav_plan, max_depth, max_filesize);
        } else {
            try out.append(gpa, item.path);
        }
    }
}

test "childPath: no doubled separator and root handled" {
    const gpa = std.testing.allocator;
    {
        const p = try vfs.joinPathSentinel(gpa, "a/b", "c.txt");
        defer gpa.free(p);
        try std.testing.expectEqualStrings(if (@import("builtin").os.tag == .windows) "a/b\\c.txt" else "a/b/c.txt", p);
    }
    {
        const p = try vfs.joinPathSentinel(gpa, "a/b/", "c.txt");
        defer gpa.free(p);
        try std.testing.expectEqualStrings("a/b/c.txt", p);
    }
    {
        const p = try vfs.joinPathSentinel(gpa, "/", "etc");
        defer gpa.free(p);
        try std.testing.expectEqualStrings("/etc", p);
    }
}
