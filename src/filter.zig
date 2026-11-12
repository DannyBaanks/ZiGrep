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

/// Glob dialect for `--include` / `--exclude` / `--exclude-dir` / `--pre-glob`,
/// aligned with ripgrep's `-g` (globset):
///   `*`      any run of characters except '/'
///   `?`      one character except '/'
///   `**`     any number of path segments (`a/**/b`, `**/x`, `a/**`)
///   `[abc]`  a class; `[!a-z]` / `[^a-z]` negated; ranges; `]` first is literal
///   `{a,b}`  alternatives, nestable (`*.{ts,tsx}`)
///   `\x`     a literal x
/// A trailing '/' (directory marker) is ignored. Case-sensitive, like rg.
/// A pattern WITH a '/' is matched against the path relative to the search
/// root (a leading '/' anchors it there); one without '/' against the name.
/// That split is the caller's (FilterEngine); this function matches one text.
pub fn globMatch(text: []const u8, pattern: []const u8) bool {
    return globMatchOpts(text, pattern, true);
}

/// `.gitignore` / `.dataignore` lines: the same matcher without braces (in
/// gitignore `{a,b}` is literal text).
pub fn matchPattern(name: []const u8, pattern: []const u8) bool {
    return globMatchOpts(name, pattern, false);
}

fn globMatchOpts(text: []const u8, pattern: []const u8, braces: bool) bool {
    var p = pattern;
    if (p.len > 1 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    if (braces and std.mem.indexOfScalar(u8, p, '{') != null) {
        var buf: [max_glob_len]u8 = undefined;
        var budget: usize = max_brace_alternatives;
        return braceMatch(text, p, &buf, 0, &budget);
    }
    return globCore(text, p);
}

const max_glob_len = 1024;
/// Caps the brace expansion (a pathological `{a,b}{a,b}...` cannot explode).
const max_brace_alternatives = 256;

/// Expands the FIRST top-level `{...}` of `rest` into its alternatives, each
/// appended to `prefix_buf[0..plen]`, and recurses on the remainder.
fn braceMatch(text: []const u8, rest: []const u8, prefix_buf: *[max_glob_len]u8, plen: usize, budget: *usize) bool {
    // Find the first unescaped '{' with its matching '}'.
    var i: usize = 0;
    var open: ?usize = null;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '\\') {
            i += 1;
            continue;
        }
        if (rest[i] == '[') {
            // A class may contain '{' or ',' literally: skip it whole.
            var j = i + 1;
            if (j < rest.len and (rest[j] == '!' or rest[j] == '^')) j += 1;
            if (j < rest.len and rest[j] == ']') j += 1;
            while (j < rest.len and rest[j] != ']') j += 1;
            if (j < rest.len) i = j;
            continue;
        }
        if (rest[i] == '{') {
            open = i;
            break;
        }
    }
    const o = open orelse {
        if (plen + rest.len > max_glob_len) return false;
        @memcpy(prefix_buf[plen .. plen + rest.len], rest);
        if (budget.* == 0) return false;
        budget.* -= 1;
        return globCore(text, prefix_buf[0 .. plen + rest.len]);
    };
    // Matching '}' and the top-level commas between.
    var depth: usize = 0;
    var close: ?usize = null;
    var k = o;
    while (k < rest.len) : (k += 1) {
        const c = rest[k];
        if (c == '\\') {
            k += 1;
            continue;
        }
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) {
                close = k;
                break;
            }
        }
    }
    const cl = close orelse {
        // Unbalanced: the '{' is literal.
        if (plen + rest.len > max_glob_len) return false;
        @memcpy(prefix_buf[plen .. plen + rest.len], rest);
        return globCore(text, prefix_buf[0 .. plen + rest.len]);
    };
    const head = rest[0..o];
    const body = rest[o + 1 .. cl];
    const tail = rest[cl + 1 ..];
    if (plen + head.len > max_glob_len) return false;
    @memcpy(prefix_buf[plen .. plen + head.len], head);
    const base = plen + head.len;
    var start: usize = 0;
    depth = 0;
    var m: usize = 0;
    while (m <= body.len) : (m += 1) {
        const at_end = m == body.len;
        if (!at_end) {
            const c = body[m];
            if (c == '\\') {
                m += 1;
                continue;
            }
            if (c == '{') depth += 1;
            if (c == '}') depth -= 1;
        }
        if (at_end or (body[m] == ',' and depth == 0)) {
            const alt = body[start..m];
            // alt + tail is a new `rest` (alt may hold nested braces).
            var tmp: [max_glob_len]u8 = undefined;
            if (alt.len + tail.len > max_glob_len) return false;
            @memcpy(tmp[0..alt.len], alt);
            @memcpy(tmp[alt.len .. alt.len + tail.len], tail);
            var pb: [max_glob_len]u8 = undefined;
            @memcpy(pb[0..base], prefix_buf[0..base]);
            if (braceMatch(text, tmp[0 .. alt.len + tail.len], &pb, base, budget)) return true;
            if (budget.* == 0) return false;
            start = m + 1;
        }
    }
    return false;
}

/// `*`, `?`, `**`, `[...]` and `\x` over one text, no braces.
fn globCore(text: []const u8, pat: []const u8) bool {
    var t: usize = 0;
    var p: usize = 0;
    while (p < pat.len) {
        const c = pat[p];
        if (c == '*') {
            if (p + 1 < pat.len and pat[p + 1] == '*') {
                // `**`: any number of segments. `**/x` may match zero
                // segments; a trailing `**` matches everything below.
                var q = p + 2;
                while (q < pat.len and pat[q] == '*') q += 1;
                if (q == pat.len) return true;
                if (pat[q] == '/') {
                    const rest = pat[q + 1 ..];
                    // zero segments, then after every '/'
                    if (globCore(text[t..], rest)) return true;
                    var k = t;
                    while (k < text.len) : (k += 1) {
                        if (text[k] == '/' and globCore(text[k + 1 ..], rest)) return true;
                    }
                    return false;
                }
                // `**x` (not followed by '/') behaves like `*` across '/'.
                const rest = pat[q..];
                var k = t;
                while (k <= text.len) : (k += 1) {
                    if (globCore(text[k..], rest)) return true;
                }
                return false;
            }
            // `*`: any run without '/'.
            const rest = pat[p + 1 ..];
            var k = t;
            while (true) {
                if (globCore(text[k..], rest)) return true;
                if (k >= text.len or text[k] == '/') return false;
                k += 1;
            }
        }
        if (t >= text.len) return false;
        switch (c) {
            '?' => {
                if (text[t] == '/') return false;
                t += 1;
                p += 1;
            },
            '[' => {
                const r = classMatch(pat[p..], text[t]) orelse {
                    // No closing ']': a literal '['.
                    if (text[t] != '[') return false;
                    t += 1;
                    p += 1;
                    continue;
                };
                if (!r.matched or text[t] == '/') return false;
                t += 1;
                p += r.len;
            },
            '\\' => {
                if (p + 1 >= pat.len) {
                    if (text[t] != '\\') return false;
                    t += 1;
                    p += 1;
                    continue;
                }
                if (text[t] != pat[p + 1]) return false;
                t += 1;
                p += 2;
            },
            else => {
                if (text[t] != c) return false;
                t += 1;
                p += 1;
            },
        }
    }
    return t == text.len;
}

const ClassResult = struct { matched: bool, len: usize };

/// `[...]` at the start of `pat`; null when there is no closing ']'.
fn classMatch(pat: []const u8, ch: u8) ?ClassResult {
    var i: usize = 1;
    var negate = false;
    if (i < pat.len and (pat[i] == '!' or pat[i] == '^')) {
        negate = true;
        i += 1;
    }
    var matched = false;
    var first = true;
    while (i < pat.len) {
        if (pat[i] == ']' and !first) return .{ .matched = matched != negate, .len = i + 1 };
        first = false;
        var lo = pat[i];
        if (lo == '\\' and i + 1 < pat.len) {
            i += 1;
            lo = pat[i];
        }
        if (i + 2 < pat.len and pat[i + 1] == '-' and pat[i + 2] != ']') {
            var hi = pat[i + 2];
            var adv: usize = 3;
            if (hi == '\\' and i + 3 < pat.len) {
                hi = pat[i + 3];
                adv = 4;
            }
            if (ch >= lo and ch <= hi) matched = true;
            i += adv;
        } else {
            if (ch == lo) matched = true;
            i += 1;
        }
    }
    return null;
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

/// A glob with a '/' (other than a trailing one) names a PATH, not a name.
pub fn isPathGlob(pattern: []const u8) bool {
    const p = if (pattern.len > 1 and pattern[pattern.len - 1] == '/') pattern[0 .. pattern.len - 1] else pattern;
    return std.mem.indexOfScalar(u8, p, '/') != null;
}

/// An `--include` / `--exclude` glob against a file: path globs against the
/// relative path (a leading '/' anchors at the root), the rest against the
/// name. A path glob never matches when the relative path is unknown.
fn cliGlob(pat: []const u8, name: []const u8, rel: ?[]const u8) bool {
    if (isPathGlob(pat)) {
        const r = rel orelse return false;
        const anchored = if (pat.len > 0 and pat[0] == '/') pat[1..] else pat;
        return globMatch(r, anchored);
    }
    return globMatch(name, pat);
}

pub const FilterEngine = struct {
    gpa: Allocator,
    use_defaults: bool = true,
    skip_hidden: bool = false,
    no_ignore: bool = false,
    /// Set once `loadIgnoreFiles` has run. The upward `.dataignore` /
    /// `.gitignore` walk is deferred until a run actually needs it, so a
    /// micro-tree never pays for it.
    ignore_files_loaded: bool = false,

    excluded_dirs: std.ArrayList([]const u8),
    excluded_exts: std.ArrayList([]const u8),
    included_exts: std.ArrayList([]const u8),
    excluded_patterns: std.ArrayList([]const u8),
    included_patterns: std.ArrayList([]const u8),
    /// Exact file names from the type registry (`Dockerfile`, `Makefile`):
    /// they are not extensions, so `matchesExt` (which needs a '.' before the
    /// extension) never matched them and `-t docker` missed `Dockerfile`.
    /// An include name counts as one more alternative of the include-ext set.
    excluded_names: std.ArrayList([]const u8),
    included_names: std.ArrayList([]const u8),
    ignore_patterns: std.ArrayList([]const u8),
    /// Search roots (the operands), used to turn `dir/name` into the path
    /// relative to its root for `--include`/`--exclude` globs that contain
    /// a '/' (rg matches those against the relative path). Borrowed.
    roots: []const []const u8 = &.{},
    /// True when some include/exclude glob contains a '/': only then do the
    /// callers' `...In(dir, name)` checks build the relative path.
    has_path_patterns: bool = false,

    pub fn init(gpa: Allocator) FilterEngine {
        return .{
            .gpa = gpa,
            .excluded_dirs = .empty,
            .excluded_exts = .empty,
            .included_exts = .empty,
            .excluded_patterns = .empty,
            .included_patterns = .empty,
            .excluded_names = .empty,
            .included_names = .empty,
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
        for (self.excluded_names.items) |item| self.gpa.free(item);
        self.excluded_names.deinit(self.gpa);
        for (self.included_names.items) |item| self.gpa.free(item);
        self.included_names.deinit(self.gpa);
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

    pub fn addExcludedName(self: *FilterEngine, name: []const u8) !void {
        const dup = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(dup);
        try self.excluded_names.append(self.gpa, dup);
    }

    pub fn addIncludedName(self: *FilterEngine, name: []const u8) !void {
        const dup = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(dup);
        try self.included_names.append(self.gpa, dup);
    }

    pub fn addExcludedPattern(self: *FilterEngine, pattern: []const u8) !void {
        if (isPathGlob(pattern)) self.has_path_patterns = true;
        const dup = try self.gpa.dupe(u8, pattern);
        try self.excluded_patterns.append(self.gpa, dup);
    }

    pub fn addIncludedPattern(self: *FilterEngine, pattern: []const u8) !void {
        if (isPathGlob(pattern)) self.has_path_patterns = true;
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

    /// Loads `.dataignore` / `.gitignore` for the current directory and every
    /// search root, walking upwards to the project root.
    ///
    /// Idempotent on purpose: the micro-tree fast path defers this call until
    /// it knows the tree is too big for the single-threaded path, so a tiny
    /// tree never pays for the upward walk, and a big one never pays twice.
    pub fn loadIgnoreFiles(self: *FilterEngine, io: std.Io, roots: []const [:0]const u8) void {
        if (self.ignore_files_loaded) return;
        self.ignore_files_loaded = true;
        if (self.no_ignore) return;

        self.loadUpwardIgnoreFiles(io, ".");
        for (roots) |root| {
            self.loadUpwardIgnoreFiles(io, root);
        }
    }

    /// `--no-ignore` turns off what comes from ignore FILES and the built-in
    /// default lists: the loaders skip `.gitignore`/`.dataignore` and the
    /// caller clears `use_defaults`, so `ignore_patterns` stays empty. It must
    /// NOT cancel what the user asked for explicitly (`--no-hidden`,
    /// `--exclude-dir`, `--exclude`, `--include`, `--include-ext`,
    /// `--exclude-ext`), as in ripgrep, where `--no-ignore` keeps `-g` globs.
    /// An early `return false` on `no_ignore` used to cancel all of them.
    pub fn isDirExcluded(self: *const FilterEngine, dir_name: []const u8) bool {
        if (self.skip_hidden and dir_name.len > 0 and dir_name[0] == '.') {
            return true;
        }

        if (self.use_defaults) {
            for (default_excluded_dirs) |d| {
                if (std.mem.eql(u8, dir_name, d)) return true;
            }
        }

        for (self.excluded_dirs.items) |ex| {
            if (globMatch(dir_name, ex)) return true;
        }

        for (self.ignore_patterns.items) |pat| {
            if (matchPattern(dir_name, pat)) return true;
        }

        return false;
    }

    pub fn isFileExcluded(self: *const FilterEngine, file_name: []const u8) bool {
        return self.fileExcluded(file_name, null);
    }

    /// The same decision for a file found in directory `dir` (as the walker
    /// built it, i.e. starting with one of `roots`). Globs that contain a '/'
    /// are matched against the path relative to that root, like rg's `-g`.
    /// Without such globs this costs nothing more than `isFileExcluded`.
    pub fn isFileExcludedIn(self: *const FilterEngine, dir: []const u8, file_name: []const u8) bool {
        if (!self.has_path_patterns) return self.fileExcluded(file_name, null);
        var buf: [4096]u8 = undefined;
        return self.fileExcluded(file_name, self.relPath(&buf, dir, file_name));
    }

    /// `dir/name` relative to the longest root that prefixes `dir`, with '/'
    /// separators. null if it does not fit the buffer.
    pub fn relPath(self: *const FilterEngine, buf: []u8, dir: []const u8, name: []const u8) ?[]const u8 {
        var sub: []const u8 = dir;
        var best: usize = 0;
        var found = false;
        for (self.roots) |root0| {
            var root = root0;
            while (root.len > 1 and (root[root.len - 1] == '/' or root[root.len - 1] == '\\')) root = root[0 .. root.len - 1];
            if (std.mem.eql(u8, dir, root)) {
                if (!found or root.len >= best) {
                    sub = "";
                    best = root.len;
                    found = true;
                }
            } else if (dir.len > root.len and std.mem.startsWith(u8, dir, root) and (dir[root.len] == '/' or dir[root.len] == '\\')) {
                if (!found or root.len >= best) {
                    sub = dir[root.len + 1 ..];
                    best = root.len;
                    found = true;
                }
            }
        }
        if (!found) {
            // No known root: use the path as given, minus a leading "./".
            sub = dir;
            while (sub.len >= 2 and sub[0] == '.' and (sub[1] == '/' or sub[1] == '\\')) sub = sub[2..];
            if (std.mem.eql(u8, sub, ".")) sub = "";
        }
        const need = sub.len + @intFromBool(sub.len > 0) + name.len;
        if (need > buf.len) return null;
        @memcpy(buf[0..sub.len], sub);
        var at = sub.len;
        if (sub.len > 0) {
            buf[at] = '/';
            at += 1;
        }
        @memcpy(buf[at .. at + name.len], name);
        const out = buf[0..need];
        for (out) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        return out;
    }

    fn fileExcluded(self: *const FilterEngine, file_name: []const u8, rel: ?[]const u8) bool {
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

        for (self.excluded_names.items) |n| {
            if (std.mem.eql(u8, file_name, n)) return true;
        }

        for (self.excluded_patterns.items) |pat| {
            if (cliGlob(pat, file_name, rel)) return true;
        }

        for (self.ignore_patterns.items) |pat| {
            if (matchPattern(file_name, pat)) return true;
        }

        // If specific extensions or patterns were requested via --include,
        // any file not matching at least one is excluded:
        if (self.included_exts.items.len > 0 or self.included_names.items.len > 0) {
            var matched = false;
            for (self.included_exts.items) |ext| {
                if (matchesExt(file_name, ext)) {
                    matched = true;
                    break;
                }
            }
            for (self.included_names.items) |n| {
                if (std.mem.eql(u8, file_name, n)) matched = true;
            }
            if (!matched) return true;
        }

        if (self.included_patterns.items.len > 0) {
            var matched = false;
            for (self.included_patterns.items) |pat| {
                if (cliGlob(pat, file_name, rel)) {
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

test "--no-ignore keeps the explicit filters and drops ignore files and defaults" {
    var engine = FilterEngine.init(std.testing.allocator);
    defer engine.deinit();
    // What main.zig does for --no-ignore: no ignore files, no default lists.
    engine.no_ignore = true;
    engine.use_defaults = false;
    // Explicit user filters.
    engine.skip_hidden = true;
    try engine.addExcludedDirs("skipme");
    try engine.addExcludedExts("log");

    // Explicit filters still apply (each one was cancelled before the fix).
    try std.testing.expect(engine.isDirExcluded(".hidden"));
    try std.testing.expect(engine.isFileExcluded(".hfile"));
    try std.testing.expect(engine.isDirExcluded("skipme"));
    try std.testing.expect(engine.isFileExcluded("k.log"));
    // Default lists stay off: node_modules and *.min.js are searched.
    try std.testing.expect(!engine.isDirExcluded("node_modules"));
    try std.testing.expect(!engine.isFileExcluded("bundle.min.js"));
    try std.testing.expect(!engine.isFileExcluded("main.zig"));
}

test "exact names from the type registry (Dockerfile, Makefile)" {
    var engine = FilterEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.use_defaults = false;
    // What applyTypes does for -t docker.
    try engine.addIncludedName("Dockerfile");
    try engine.addIncludedExts(".dockerfile");
    try std.testing.expect(!engine.isFileExcluded("Dockerfile"));
    try std.testing.expect(!engine.isFileExcluded("app.dockerfile"));
    try std.testing.expect(engine.isFileExcluded("main.zig"));
    // An exact name is not a suffix: "MyDockerfile" is not Dockerfile.
    try std.testing.expect(engine.isFileExcluded("MyDockerfile"));

    var ex = FilterEngine.init(std.testing.allocator);
    defer ex.deinit();
    ex.use_defaults = false;
    // What applyTypes does for --type-not make.
    try ex.addExcludedName("Makefile");
    try ex.addExcludedExts(".mk");
    try std.testing.expect(ex.isFileExcluded("Makefile"));
    try std.testing.expect(ex.isFileExcluded("rules.mk"));
    try std.testing.expect(!ex.isFileExcluded("main.zig"));
}

test "globMatch: rg-style globs (braces, **, classes, escapes)" {
    const T = std.testing;
    // braces
    try T.expect(globMatch("a.ts", "*.{ts,tsx}"));
    try T.expect(globMatch("a.tsx", "*.{ts,tsx}"));
    try T.expect(!globMatch("a.js", "*.{ts,tsx}"));
    try T.expect(globMatch("x.zig", "*.{zig,py}"));
    try T.expect(globMatch("lib.d.ts", "*.{d.ts,{js,mjs}}"));
    try T.expect(globMatch("a.mjs", "*.{d.ts,{js,mjs}}"));
    // * does not cross '/', ** does
    try T.expect(!globMatch("src/a.ts", "*.ts"));
    try T.expect(globMatch("src/a.ts", "**/*.ts"));
    try T.expect(globMatch("a.ts", "**/*.ts"));
    try T.expect(globMatch("packages/core/src/x/y.ts", "packages/core/**/*.ts"));
    try T.expect(globMatch("packages/core/y.ts", "packages/core/**/*.ts"));
    try T.expect(!globMatch("packages/cli/y.ts", "packages/core/**/*.ts"));
    try T.expect(globMatch("vendor/a/b/c", "vendor/**"));
    // classes
    try T.expect(globMatch("a1", "a[0-9]"));
    try T.expect(!globMatch("ax", "a[0-9]"));
    try T.expect(globMatch("ax", "a[!0-9]"));
    try T.expect(globMatch("a]", "a[]]"));
    try T.expect(!globMatch("a/", "a[/]"));
    // escapes and literals
    try T.expect(globMatch("a*b", "a\\*b"));
    try T.expect(!globMatch("axb", "a\\*b"));
    try T.expect(globMatch("{x}", "\\{x\\}"));
    try T.expect(globMatch("a{b", "a{b")); // unbalanced brace is literal
    // trailing '/' (dir marker) and ?
    try T.expect(globMatch("target", "target/"));
    try T.expect(globMatch("file1.log", "file?.log"));
    try T.expect(!globMatch("file10.log", "file?.log"));
    // gitignore flavour: braces are literal there
    try T.expect(!matchPattern("a.ts", "*.{ts,tsx}"));
    try T.expect(matchPattern("a.ts", "*.ts"));
}

test "FilterEngine: path globs use the path relative to the search root" {
    var engine = FilterEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.use_defaults = false;
    const roots = [_][]const u8{ ".", "/repo" };
    engine.roots = &roots;
    try engine.addIncludedPattern("packages/core/**/*.ts");
    try std.testing.expect(engine.has_path_patterns);
    try std.testing.expect(!engine.isFileExcludedIn("./packages/core/src", "a.ts"));
    try std.testing.expect(!engine.isFileExcludedIn("/repo/packages/core", "b.ts"));
    try std.testing.expect(engine.isFileExcludedIn("./packages/cli/src", "a.ts"));
    try std.testing.expect(engine.isFileExcludedIn("./packages/core/src", "a.js"));

    var ex = FilterEngine.init(std.testing.allocator);
    defer ex.deinit();
    ex.use_defaults = false;
    const r2 = [_][]const u8{"src"};
    ex.roots = &r2;
    try ex.addExcludedPattern("/gen/**");
    try ex.addExcludedPattern("*.{lock,min.js}");
    try std.testing.expect(ex.isFileExcludedIn("src/gen/x", "a.zig"));
    try std.testing.expect(!ex.isFileExcludedIn("src/core", "a.zig"));
    try std.testing.expect(ex.isFileExcludedIn("src/core", "yarn.lock"));
    try std.testing.expect(ex.isFileExcludedIn("src", "app.min.js"));
    // A root-level file: the relative path is just the name.
    try std.testing.expect(!ex.isFileExcludedIn("src", "main.zig"));
}

