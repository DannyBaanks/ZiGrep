//! Static type registry for `-t` / `--type-not` / `--type-list`.
//!
//! Mirrors the rg registry in spirit (name -> extensions) with a curated
//! subset: enough for everyday source trees, not the 150 languages rg lists.
//! Unknown type names are a usage error, exactly like rg.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Type = struct {
    name: []const u8,
    exts: []const []const u8,
};

pub const registry = [_]Type{
    .{ .name = "asm", .exts = &.{ ".s", ".S", ".asm" } },
    .{ .name = "bash", .exts = &.{".sh", ".bash", ".zsh"} },
    .{ .name = "c", .exts = &.{ ".c", ".h", ".H", ".hh", ".hpp", ".hxx" } },
    .{ .name = "clojure", .exts = &.{ ".clj", ".cljs", ".cljc", ".edn" } },
    .{ .name = "cmake", .exts = &.{".cmake"} },
    .{ .name = "cpp", .exts = &.{ ".cpp", ".cc", ".cxx", ".c++", ".hpp", ".hxx", ".hh", ".inl" } },
    .{ .name = "csharp", .exts = &.{ ".cs", ".csx" } },
    .{ .name = "css", .exts = &.{".css", ".scss", ".sass", ".less"} },
    .{ .name = "csv", .exts = &.{".csv"} },
    .{ .name = "dart", .exts = &.{".dart"} },
    .{ .name = "docker", .exts = &.{ "Dockerfile", ".dockerfile" } },
    .{ .name = "elixir", .exts = &.{ ".ex", ".exs" } },
    .{ .name = "erlang", .exts = &.{ ".erl", ".hrl" } },
    .{ .name = "go", .exts = &.{".go"} },
    .{ .name = "graphql", .exts = &.{".graphql", ".gql"} },
    .{ .name = "haskell", .exts = &.{ ".hs", ".lhs", ".hsc" } },
    .{ .name = "html", .exts = &.{ ".html", ".htm", ".xhtml" } },
    .{ .name = "java", .exts = &.{ ".java", ".jsp" } },
    .{ .name = "js", .exts = &.{ ".js", ".jsx", ".mjs", ".cjs", ".vue" } },
    .{ .name = "json", .exts = &.{".json", ".jsonl", ".json5"} },
    .{ .name = "julia", .exts = &.{".jl"} },
    .{ .name = "kotlin", .exts = &.{ ".kt", ".kts" } },
    .{ .name = "lisp", .exts = &.{ ".lisp", ".lsp", ".el", ".cl" } },
    .{ .name = "lua", .exts = &.{".lua"} },
    .{ .name = "make", .exts = &.{ "Makefile", ".mk", ".mak" } },
    .{ .name = "md", .exts = &.{ ".md", ".markdown", ".mdown", ".mkd" } },
    .{ .name = "nim", .exts = &.{".nim"} },
    .{ .name = "objc", .exts = &.{ ".m", ".mm" } },
    .{ .name = "ocaml", .exts = &.{ ".ml", ".mli" } },
    .{ .name = "perl", .exts = &.{ ".pl", ".pm", ".pod", ".t" } },
    .{ .name = "php", .exts = &.{".php", ".phtml"} },
    .{ .name = "proto", .exts = &.{".proto"} },
    .{ .name = "py", .exts = &.{ ".py", ".pyi", ".pyw" } },
    .{ .name = "r", .exts = &.{".r", ".R", ".Rmd"} },
    .{ .name = "ruby", .exts = &.{".rb", ".rake", ".gemspec"} },
    .{ .name = "rust", .exts = &.{".rs"} },
    .{ .name = "scala", .exts = &.{ ".scala", ".sbt" } },
    .{ .name = "sh", .exts = &.{".sh", ".bash", ".zsh", ".ksh"} },
    .{ .name = "sql", .exts = &.{".sql"} },
    .{ .name = "swift", .exts = &.{".swift"} },
    .{ .name = "tex", .exts = &.{".tex", ".bib", ".sty"} },
    .{ .name = "toml", .exts = &.{".toml"} },
    .{ .name = "ts", .exts = &.{ ".ts", ".tsx", ".mts", ".cts" } },
    .{ .name = "txt", .exts = &.{".txt"} },
    .{ .name = "vim", .exts = &.{".vim"} },
    .{ .name = "yaml", .exts = &.{ ".yaml", ".yml" } },
    .{ .name = "zig", .exts = &.{".zig", ".zon"} },
    .{ .name = "zsh", .exts = &.{".zsh", ".zshrc"} },
};

/// Looks a type up by name (case-insensitive, like rg).
pub fn lookup(name: []const u8) ?Type {
    for (registry) |t| {
        if (std.ascii.eqlIgnoreCase(t.name, name)) return t;
    }
    return null;
}

/// Appends `--type-list` to `buf`: one `name: ext1, ext2` per line.
pub fn writeList(buf: *std.ArrayList(u8), gpa: Allocator) Allocator.Error!void {
    for (registry) |t| {
        try buf.appendSlice(gpa, t.name);
        try buf.append(gpa, ':');
        for (t.exts, 0..) |ext, i| {
            if (i != 0) try buf.append(gpa, ',');
            try buf.append(gpa, ' ');
            try buf.appendSlice(gpa, ext);
        }
        try buf.append(gpa, '\n');
    }
}

test "types: lookup and case-insensitive names" {
    try std.testing.expectEqualStrings("py", lookup("py").?.name);
    try std.testing.expectEqualStrings("py", lookup("PY").?.name);
    try std.testing.expect(lookup("nope") == null);
    try std.testing.expect(lookup("rust").?.exts.len > 0);
}

test "types: --type-list prints every type" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try writeList(&buf, std.testing.allocator);
    const out = buf.items;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (line.len > 0) count += 1;
    }
    try std.testing.expectEqual(registry.len, count);
}
