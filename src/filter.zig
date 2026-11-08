//! filter.zig — Universal Filter & Ignore Engine for zigrep.
//!
//! Features:
//!   1. Default noisy directories & file extensions (caches, virtualenvs, binaries).
//!   2. .dataignore (native zigrep ignore format) and .gitignore file parsing.
//!   3. CLI chaining:
//!      --exclude-dir=DIR1,DIR2
//!      --exclude-ext=EXT1,EXT2
//!      --include-ext=EXT1,EXT2
//!      --exclude=GLOB
//!      --include=GLOB
//!   4. Zero-cost fast filtering in raw dirent buffers before statx/openat.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vfs = @import("vfs.zig");

pub const default_excluded_dirs = [_][]const u8{
    ".git",
    ".zig-cache",
    "__pycache__",
    "node_modules",
    ".venv",
    "venv",
    "target",
    ".cache",
    ".idea",
    ".vscode",
};

pub const default_excluded_exts = [_][]const u8{
    ".pyc",
    ".pyo",
    ".o",
    ".a",
    ".so",
    ".dylib",
    ".dll",
    ".class",
    ".jar",
    ".log",
    ".min.js",
    ".min.css",
    ".map",
    ".lock",
    ".swp",
    ".DS_Store",
};

/// High-performance wildcard matcher (supports * and ? and trailing /).
pub fn matchPattern(name: []const u8, pattern: []const u8) bool {
    var p = pattern;
    if (p.len > 0 and p[p.len - 1] == '/') {
        p = p[0 .. p.len - 1];
    }
    var n_idx: usize = 0;
    var p_idx: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (n_idx < name.len) {
        if (p_idx < p.len and (p[p_idx] == '?' or p[p_idx] == name[n_idx])) {
            n_idx += 1;
            p_idx += 1;
        } else if (p_idx < p.len and p[p_idx] == '*') {
            star_idx = p_idx;
            match_idx = n_idx;
            p_idx += 1;
        } else if (star_idx != null) {
            p_idx = star_idx.? + 1;
            match_idx += 1;
            n_idx = match_idx;
        } else {
            return false;
        }
    }

    while (p_idx < p.len and p[p_idx] == '*') {
        p_idx += 1;
    }

    return p_idx == p.len;
}

pub fn matchesExt(name: []const u8, ext: []const u8) bool {
    if (ext.len == 0) return false;
    if (ext[0] == '.') {
        return std.mem.endsWith(u8, name, ext);
    }
    if (name.len > ext.len + 1 and name[name.len - ext.len - 1] == '.') {
        return std.mem.endsWith(u8, name, ext);
    }
    return false;
}

pub const FilterEngine = struct {
    gpa: Allocator,
    use_defaults: bool = true,
    skip_hidden: bool = false,
    no_ignore: bool = false,

    excluded_dirs: std.ArrayList([]const u8),
    excluded_exts: std.ArrayList([]const u8),
    included_exts: std.ArrayList([]const u8),
    excluded_patterns: std.ArrayList([]const u8),
    included_patterns: std.ArrayList([]const u8),
    ignore_patterns: std.ArrayList([]const u8),

    pub fn init(gpa: Allocator) FilterEngine {
        return .{
            .gpa = gpa,
            .excluded_dirs = .empty,
            .excluded_exts = .empty,
            .included_exts = .empty,
            .excluded_patterns = .empty,
            .included_patterns = .empty,
            .ignore_patterns = .empty,
        };
    }

    pub fn deinit(self: *FilterEngine) void {
        for (self.excluded_dirs.items) |item| self.gpa.free(item);
        self.excluded_dirs.deinit(self.gpa);
        for (self.excluded_exts.items) |item| self.gpa.free(item);
        self.excluded_exts.deinit(self.gpa);
        for (self.included_exts.items) |item| self.gpa.free(item);
        self.included_exts.deinit(self.gpa);
        for (self.excluded_patterns.items) |item| self.gpa.free(item);
        self.excluded_patterns.deinit(self.gpa);
        for (self.included_patterns.items) |item| self.gpa.free(item);
        self.included_patterns.deinit(self.gpa);
        for (self.ignore_patterns.items) |item| self.gpa.free(item);
        self.ignore_patterns.deinit(self.gpa);
    }

    pub fn addExcludedDirs(self: *FilterEngine, comma_separated: []const u8) !void {
        var it = std.mem.splitScalar(u8, comma_separated, ',');
        while (it.next()) |raw| {
            const trimmed = std.mem.trim(u8, raw, " ");
            if (trimmed.len > 0) {
                const dup = try self.gpa.dupe(u8, trimmed);
                try self.excluded_dirs.append(self.gpa, dup);
            }
        }
    }

    pub fn addExcludedExts(self: *FilterEngine, comma_separated: []const u8) !void {
        var it = std.mem.splitScalar(u8, comma_separated, ',');
        while (it.next()) |raw| {
            const trimmed = std.mem.trim(u8, raw, " ");
            if (trimmed.len > 0) {
                const dup = try self.gpa.dupe(u8, trimmed);
                try self.excluded_exts.append(self.gpa, dup);
            }
        }
    }

    pub fn addIncludedExts(self: *FilterEngine, comma_separated: []const u8) !void {
        var it = std.mem.splitScalar(u8, comma_separated, ',');
        while (it.next()) |raw| {
            const trimmed = std.mem.trim(u8, raw, " ");
            if (trimmed.len > 0) {
                const dup = try self.gpa.dupe(u8, trimmed);
                try self.included_exts.append(self.gpa, dup);
            }
        }
    }

    pub fn addExcludedPattern(self: *FilterEngine, pattern: []const u8) !void {
        const dup = try self.gpa.dupe(u8, pattern);
        try self.excluded_patterns.append(self.gpa, dup);
    }

    pub fn addIncludedPattern(self: *FilterEngine, pattern: []const u8) !void {
        const dup = try self.gpa.dupe(u8, pattern);
        try self.included_patterns.append(self.gpa, dup);
    }

    pub fn loadIgnoreFile(self: *FilterEngine, io: std.Io, dir_path: []const u8, file_name: []const u8) void {
        if (self.no_ignore) return;
        const full_path = std.fs.path.join(self.gpa, &.{ dir_path, file_name }) catch return;
        defer self.gpa.free(full_path);
        const file = std.Io.Dir.cwd().openFile(io, full_path, .{}) catch return;
        defer file.close(io);

        var buf: [32 * 1024]u8 = undefined;
        const n = file.readPositionalAll(io, &buf, 0) catch return;
        if (n == 0) return;
        const content = buf[0..n];

        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \r\t");
            if (line.len == 0 or line[0] == '#') continue;
            const dup = self.gpa.dupe(u8, line) catch continue;
            self.ignore_patterns.append(self.gpa, dup) catch continue;
        }
    }

    /// Recursively discovers .dataignore and .gitignore walking upwards to the git/project root.
    pub fn loadUpwardIgnoreFiles(self: *FilterEngine, io: std.Io, start_path: []const u8) void {
        if (self.no_ignore) return;
        var cur: []const u8 = start_path;
        if (cur.len == 0) cur = ".";

        while (true) {
            self.loadIgnoreFile(io, cur, ".dataignore");
            self.loadIgnoreFile(io, cur, ".gitignore");

            // If this directory contains a .git folder or file, it's the repo root; stop after reading it
            const git_path = std.fs.path.join(self.gpa, &.{ cur, ".git" }) catch break;
            defer self.gpa.free(git_path);
            if (vfs.stat(io, git_path, false) != null) break;

            const parent = std.fs.path.dirname(cur) orelse break;
            if (parent.len == 0 or std.mem.eql(u8, parent, cur) or std.mem.eql(u8, parent, "/")) break;
            cur = parent;
        }
    }

    pub fn isDirExcluded(self: *const FilterEngine, dir_name: []const u8) bool {
        if (self.no_ignore) return false;

        if (self.skip_hidden and dir_name.len > 0 and dir_name[0] == '.') {
            return true;
        }

        if (self.use_defaults) {
            for (default_excluded_dirs) |d| {
                if (std.mem.eql(u8, dir_name, d)) return true;
            }
        }

        for (self.excluded_dirs.items) |ex| {
            if (matchPattern(dir_name, ex)) return true;
        }

        for (self.ignore_patterns.items) |pat| {
            if (matchPattern(dir_name, pat)) return true;
        }

        return false;
    }

    pub fn isFileExcluded(self: *const FilterEngine, file_name: []const u8) bool {
        if (self.no_ignore) return false;

        if (self.skip_hidden and file_name.len > 0 and file_name[0] == '.') {
            return true;
        }

        if (self.use_defaults) {
            for (default_excluded_exts) |ext| {
                if (matchesExt(file_name, ext)) return true;
            }
        }

        for (self.excluded_exts.items) |ext| {
            if (matchesExt(file_name, ext)) return true;
        }

        for (self.excluded_patterns.items) |pat| {
            if (matchPattern(file_name, pat)) return true;
        }

        for (self.ignore_patterns.items) |pat| {
            if (matchPattern(file_name, pat)) return true;
        }

        // If specific extensions or patterns were requested via --include,
        // any file not matching at least one is excluded:
        if (self.included_exts.items.len > 0) {
            var matched = false;
            for (self.included_exts.items) |ext| {
                if (matchesExt(file_name, ext)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) return true;
        }

        if (self.included_patterns.items.len > 0) {
            var matched = false;
            for (self.included_patterns.items) |pat| {
                if (matchPattern(file_name, pat)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) return true;
        }

        return false;
    }
};

test "matchPattern wildcards" {
    try std.testing.expect(matchPattern("foo.zig", "*.zig"));
    try std.testing.expect(matchPattern("test_foo.zig", "test_*.zig"));
    try std.testing.expect(matchPattern("target", "target/"));
    try std.testing.expect(matchPattern("file1.log", "file?.log"));
    try std.testing.expect(!matchPattern("file10.log", "file?.log"));
    try std.testing.expect(!matchPattern("foo.rs", "*.zig"));
}

test "matchesExt" {
    try std.testing.expect(matchesExt("main.zig", "zig"));
    try std.testing.expect(matchesExt("main.zig", ".zig"));
    try std.testing.expect(matchesExt("bundle.min.js", "min.js"));
    try std.testing.expect(!matchesExt("zig.txt", "zig"));
}

test "FilterEngine default exclusions" {
    const gpa = std.testing.allocator;
    var engine = FilterEngine.init(gpa);
    defer engine.deinit();

    try std.testing.expect(engine.isDirExcluded(".git"));
    try std.testing.expect(engine.isDirExcluded(".zig-cache"));
    try std.testing.expect(engine.isDirExcluded("node_modules"));
    try std.testing.expect(engine.isDirExcluded("target"));
    try std.testing.expect(!engine.isDirExcluded("src"));

    try std.testing.expect(engine.isFileExcluded("app.pyc"));
    try std.testing.expect(engine.isFileExcluded("debug.log"));
    try std.testing.expect(engine.isFileExcluded("bundle.min.js"));
    try std.testing.expect(!engine.isFileExcluded("main.zig"));
}

test "FilterEngine custom CLI exclusions and inclusions" {
    const gpa = std.testing.allocator;
    var engine = FilterEngine.init(gpa);
    defer engine.deinit();

    try engine.addExcludedExts("csv,tsv");
    try std.testing.expect(engine.isFileExcluded("data.csv"));
    try std.testing.expect(engine.isFileExcluded("data.tsv"));

    try engine.addIncludedExts("zig");
    try std.testing.expect(!engine.isFileExcluded("main.zig"));
    try std.testing.expect(engine.isFileExcluded("script.py")); // Excluded because not .zig!
}
