//! setup.zig — `ziggrep --setup`: teach the AI coding agents on this machine
//! to search file contents with ziggrep.
//!
//!   ziggrep --setup            show what would change, ask [s/N], then apply
//!   ziggrep --setup --dry-run  only show
//!   ziggrep --setup --force    no question (scripts, or a model running it)
//!   ziggrep --setup --undo     remove exactly what --setup added
//!
//! What it writes:
//!   * the rule, once: ~/.config/ziggrep/agents.md (its text is built into the
//!     binary, so it works on any machine);
//!   * in each agent's global instruction file a block between
//!     `<!-- ziggrep:setup begin -->` and `<!-- ziggrep:setup end -->`:
//!     Claude Code gets an import of the rule (it resolves `@path`); Codex,
//!     agy/Gemini, OpenISy and opencode get the rule inline (Codex does NOT
//!     resolve `@path` imports: measured on 2026-11-11).
//! Only agents whose config directory exists are touched. Running it twice
//! changes nothing. Before an existing file is changed for the first time a
//! copy `<file>.bak-ziggrep` is kept (never overwritten, so it is always the
//! original). `--undo` removes the block and deletes a file only when the
//! block was all it contained.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const platform = @import("platform.zig");

pub const Options = struct {
    dry_run: bool = false,
    force: bool = false,
    undo: bool = false,
    /// Command name the rule tells agents to run (`ziggrep`, `zigrep`...).
    cmd: []const u8 = "ziggrep",
    /// Warning to print first (e.g. invoked as gzip's name `zgrep`).
    cmd_note: ?[]const u8 = null,
    /// `--setup=claude,codex,...`: only these agent ids (null = every
    /// installed agent).
    only: ?[]const u8 = null,
};

pub const begin_marker = "<!-- ziggrep:setup begin -->";
pub const end_marker = "<!-- ziggrep:setup end -->";
const rule_rel = ".config/ziggrep/agents.md";

const Mode = enum { import, inline_rule };
const Agent = struct { id: []const u8, name: []const u8, dir: []const u8, file: []const u8, mode: Mode };

/// The agents --setup knows. `dir` (relative to HOME) must exist for the
/// agent to count as installed; `file` is its global instruction file.
const agents = [_]Agent{
    .{ .id = "claude", .name = "Claude Code", .dir = ".claude", .file = ".claude/CLAUDE.md", .mode = .import },
    .{ .id = "codex", .name = "Codex", .dir = ".codex", .file = ".codex/AGENTS.md", .mode = .inline_rule },
    .{ .id = "agy", .name = "agy / Gemini", .dir = ".gemini", .file = ".gemini/GEMINI.md", .mode = .inline_rule },
    .{ .id = "openisy", .name = "OpenISy", .dir = ".openisy/config", .file = ".openisy/config/AGENTS.md", .mode = .inline_rule },
    .{ .id = "opencode", .name = "opencode", .dir = ".config/opencode", .file = ".config/opencode/AGENTS.md", .mode = .inline_rule },
};

/// The rule an agent reads, for command name `cmd`.
pub fn ruleText(gpa: Allocator, cmd: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa,
        \\# Content search: use `{0s}`
        \\
        \\On this machine, search file contents with `{0s}` (ZiGrep, grep/rg-compatible) instead of `grep` or `rg`. This overrides any default advice to use `rg`.
        \\
        \\- **Always pass a path**, `.` for the current directory: `{0s} -n PATTERN .`. Without a path it reads standard input like grep, NOT the current directory like rg, and silently reports no matches.
        \\- Line numbers are off by default: add `-n`.
        \\- Patterns are extended regex like `rg` / `grep -E`: alternation is `a|b`, NOT `a\|b` (there `\|` is a literal pipe and silently matches nothing). Use `-G` for grep's basic syntax, `-F` for literal text.
        \\- Usual flags: `-F` literal, `-i` ignore case, `-w` whole word, `-l` file names only, `-c` count, `-C N` context, `-e P` (repeatable).
        \\- Globs work like `rg -g`: `--include='*.{{ts,tsx}}'`, `--include='src/**/*.zig'`, `--exclude='**/test/**'`.
        \\- `--json` gives structured events (path, line, column, byte offsets); `--max-columns N` windows very long lines.
        \\- `.gitignore`, `.dataignore` and built-in noise (`.git`, `node_modules`, `target`, `*.min.js`, …) are skipped, like `rg`; add `--no-ignore` to search everything.
        \\- Do not call `zgrep` unless it is this tool: on Linux that name can be gzip's.
        \\- If `{0s}` is missing or fails, fall back to `rg` or `grep` and say so.
        \\
    , .{cmd});
}

/// Text between the markers, or null when there is no complete block.
pub fn blockOf(content: []const u8) ?[]const u8 {
    const b = std.mem.indexOf(u8, content, begin_marker) orelse return null;
    const after = b + begin_marker.len;
    const e = std.mem.indexOfPos(u8, content, after, end_marker) orelse return null;
    return std.mem.trim(u8, content[after..e], "\r\n");
}

/// `existing` with the block set to `body`: replaced in place when present,
/// appended (after a blank line) otherwise.
pub fn withBlock(gpa: Allocator, existing: []const u8, body: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (std.mem.indexOf(u8, existing, begin_marker)) |b| {
        if (std.mem.indexOfPos(u8, existing, b + begin_marker.len, end_marker)) |e| {
            try out.appendSlice(gpa, existing[0..b]);
            try appendBlock(&out, gpa, body);
            try out.appendSlice(gpa, existing[e + end_marker.len ..]);
            return out.toOwnedSlice(gpa);
        }
    }
    try out.appendSlice(gpa, existing);
    if (existing.len > 0) {
        if (existing[existing.len - 1] != '\n') try out.append(gpa, '\n');
        try out.append(gpa, '\n');
    }
    try appendBlock(&out, gpa, body);
    try out.append(gpa, '\n');
    return out.toOwnedSlice(gpa);
}

fn appendBlock(out: *std.ArrayList(u8), gpa: Allocator, body: []const u8) Allocator.Error!void {
    try out.appendSlice(gpa, begin_marker);
    try out.append(gpa, '\n');
    try out.appendSlice(gpa, std.mem.trim(u8, body, "\r\n"));
    try out.append(gpa, '\n');
    try out.appendSlice(gpa, end_marker);
}

/// `existing` without the block (and the blank line --setup put before it),
/// or null when there is no block.
pub fn withoutBlock(gpa: Allocator, existing: []const u8) Allocator.Error!?[]u8 {
    const b = std.mem.indexOf(u8, existing, begin_marker) orelse return null;
    const e = std.mem.indexOfPos(u8, existing, b + begin_marker.len, end_marker) orelse return null;
    var head = existing[0..b];
    var tail = existing[e + end_marker.len ..];
    if (std.mem.startsWith(u8, tail, "\n")) tail = tail[1..];
    if (std.mem.endsWith(u8, head, "\n\n")) head = head[0 .. head.len - 1];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, head);
    try out.appendSlice(gpa, tail);
    return try out.toOwnedSlice(gpa);
}

const Action = enum { create, add, update, already, remove, delete_file, absent, not_installed, skipped };

fn actionText(a: Action) []const u8 {
    return switch (a) {
        .create => "se crea",
        .add => "se añade la regla (respaldo .bak-ziggrep)",
        .update => "se actualiza la regla",
        .already => "ya configurado",
        .remove => "se quita la regla (respaldo .bak-ziggrep)",
        .delete_file => "se borra (solo tenía la regla)",
        .absent => "no tenía la regla",
        .not_installed => "no instalado",
        .skipped => "omitido (no está en la lista)",
    };
}

const Planned = struct { agent: Agent, action: Action, path: []const u8, new_content: ?[]u8 = null };

fn readMaybe(io: std.Io, arena: Allocator, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch null;
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn say(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = platform.writeStdout(io, text);
}

fn prompt(io: std.Io, question: []const u8) bool {
    _ = platform.writeStdout(io, question);
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    const stdin = std.Io.File.stdin();
    while (n < buf.len) {
        var one: [1]u8 = undefined;
        const got = stdin.readStreaming(io, &.{one[0..]}) catch break;
        if (got == 0 or one[0] == '\n') break;
        buf[n] = one[0];
        n += 1;
    }
    const t = std.mem.trim(u8, buf[0..n], " \r\t");
    return std.ascii.eqlIgnoreCase(t, "s") or std.ascii.eqlIgnoreCase(t, "si") or
        std.ascii.eqlIgnoreCase(t, "sí") or std.ascii.eqlIgnoreCase(t, "y") or std.ascii.eqlIgnoreCase(t, "yes");
}

fn writeFileMkdir(io: std.Io, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// Is agent `id` selected by `--setup=LIST` (comma-separated; "gemini" is
/// accepted for agy)?
pub fn selected(only: ?[]const u8, id: []const u8) bool {
    const list = only orelse return true;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const want = std.mem.trim(u8, raw, " ");
        if (std.ascii.eqlIgnoreCase(want, id)) return true;
        if (std.mem.eql(u8, id, "agy") and std.ascii.eqlIgnoreCase(want, "gemini")) return true;
        if (std.mem.eql(u8, id, "claude") and std.ascii.eqlIgnoreCase(want, "claude-code")) return true;
    }
    return false;
}

/// The ids `--setup=LIST` accepts, for the usage error.
pub fn unknownId(only: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, only, ',');
    outer: while (it.next()) |raw| {
        const want = std.mem.trim(u8, raw, " ");
        if (want.len == 0) continue;
        for (agents) |ag| if (selected(want, ag.id)) continue :outer;
        return want;
    }
    return null;
}

/// Returns the process exit code: 0 done (or nothing to do), 1 declined, 2 error.
pub fn run(io: std.Io, gpa: Allocator, home: []const u8, opts: Options) u8 {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    if (opts.cmd_note) |note| say(io, "aviso: {s}\n\n", .{note});

    const rule = ruleText(arena, opts.cmd) catch return 2;
    const rule_path = std.fs.path.join(arena, &.{ home, rule_rel }) catch return 2;
    const rule_now = readMaybe(io, arena, rule_path);
    const import_body = std.fmt.allocPrint(arena, "@~/{s}", .{rule_rel}) catch return 2;

    var plan: std.ArrayList(Planned) = .empty;
    for (agents) |ag| {
        const dir = std.fs.path.join(arena, &.{ home, ag.dir }) catch return 2;
        const path = std.fs.path.join(arena, &.{ home, ag.file }) catch return 2;
        if (!exists(io, dir)) {
            plan.append(arena, .{ .agent = ag, .action = .not_installed, .path = path }) catch return 2;
            continue;
        }
        if (!selected(opts.only, ag.id)) {
            plan.append(arena, .{ .agent = ag, .action = .skipped, .path = path }) catch return 2;
            continue;
        }
        const body: []const u8 = if (ag.mode == .import) import_body else rule;
        const current = readMaybe(io, arena, path);
        var p: Planned = .{ .agent = ag, .action = .already, .path = path };
        if (opts.undo) {
            if (current) |c| {
                if (withoutBlock(arena, c) catch return 2) |rest| {
                    const empty = std.mem.trim(u8, rest, " \t\r\n").len == 0;
                    p.action = if (empty) .delete_file else .remove;
                    p.new_content = rest;
                } else p.action = .absent;
            } else p.action = .absent;
        } else if (current) |c| {
            if (blockOf(c)) |inner| {
                if (std.mem.eql(u8, inner, std.mem.trim(u8, body, "\r\n"))) {
                    p.action = .already;
                } else {
                    p.action = .update;
                    p.new_content = withBlock(arena, c, body) catch return 2;
                }
            } else {
                p.action = .add;
                p.new_content = withBlock(arena, c, body) catch return 2;
            }
        } else {
            p.action = .create;
            p.new_content = withBlock(arena, "", body) catch return 2;
        }
        plan.append(arena, p) catch return 2;
    }

    const rule_action: Action = if (opts.undo)
        .already
    else if (rule_now == null) .create else if (std.mem.eql(u8, rule_now.?, rule)) .already else .update;

    // --- what will happen ----------------------------------------------------
    say(io, "{s} los agentes de IA de esta máquina (comando: {s})\n\n", .{ if (opts.undo) "Quitar ZiGrep de" else "Configurar ZiGrep en", opts.cmd });
    var changes: usize = 0;
    for (plan.items) |p| {
        const shown = if (std.mem.startsWith(u8, p.path, home)) p.path[home.len..] else p.path;
        say(io, "  {s:<14} ~{s:<30} {s}\n", .{ p.agent.name, shown, actionText(p.action) });
        switch (p.action) {
            .create, .add, .update, .remove, .delete_file => changes += 1,
            else => {},
        }
    }
    if (!opts.undo) {
        say(io, "  {s:<14} ~/{s:<29} {s}\n", .{ "regla", rule_rel, actionText(rule_action) });
        if (rule_action != .already) changes += 1;
    }
    say(io, "\n", .{});
    if (changes == 0) {
        say(io, "Nada que cambiar.\n", .{});
        return 0;
    }
    if (opts.dry_run) {
        say(io, "--dry-run: no se cambió nada.\n", .{});
        return 0;
    }
    if (!opts.force and !prompt(io, "¿Aplicar estos cambios? [s/N] ")) {
        say(io, "No se cambió nada.\n", .{});
        return 1;
    }

    // --- apply -----------------------------------------------------------------
    var failed = false;
    if (!opts.undo and rule_action != .already) {
        writeFileMkdir(io, rule_path, rule) catch |e| {
            say(io, "error: {s}: {s}\n", .{ rule_path, @errorName(e) });
            failed = true;
        };
    }
    for (plan.items) |p| {
        switch (p.action) {
            .create, .add, .update, .remove, .delete_file => {},
            else => continue,
        }
        if (p.action != .create) {
            // First change to a file we did not create: keep the original.
            const bak = std.fmt.allocPrint(arena, "{s}.bak-ziggrep", .{p.path}) catch return 2;
            if (!exists(io, bak)) {
                if (readMaybe(io, arena, p.path)) |orig| {
                    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = bak, .data = orig }) catch |e| {
                        say(io, "error: no se pudo respaldar {s}: {s}; no se toca\n", .{ p.path, @errorName(e) });
                        failed = true;
                        continue;
                    };
                }
            }
        }
        if (p.action == .delete_file) {
            std.Io.Dir.cwd().deleteFile(io, p.path) catch |e| {
                say(io, "error: {s}: {s}\n", .{ p.path, @errorName(e) });
                failed = true;
            };
            continue;
        }
        writeFileMkdir(io, p.path, p.new_content.?) catch |e| {
            say(io, "error: {s}: {s}\n", .{ p.path, @errorName(e) });
            failed = true;
        };
    }
    if (failed) return 2;
    say(io, "Listo. {s}\n", .{if (opts.undo) "Para volver a configurarlo: ziggrep --setup" else "Los agentes nuevos ya lo leen; las sesiones abiertas, al reiniciarse. Deshacer: ziggrep --setup --undo"});
    return 0;
}

// ---------------------------------------------------------------------------

test "setup: withBlock appends once and replaces in place" {
    const gpa = std.testing.allocator;
    const a = try withBlock(gpa, "", "RULE v1");
    defer gpa.free(a);
    try std.testing.expectEqualStrings(begin_marker ++ "\nRULE v1\n" ++ end_marker ++ "\n", a);
    try std.testing.expectEqualStrings("RULE v1", blockOf(a).?);

    const b = try withBlock(gpa, "@/x/RTK.md\n", "RULE v1");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("@/x/RTK.md\n\n" ++ begin_marker ++ "\nRULE v1\n" ++ end_marker ++ "\n", b);

    // Replacing keeps everything around the block byte for byte.
    const c = try withBlock(gpa, b, "RULE v2");
    defer gpa.free(c);
    try std.testing.expectEqualStrings("@/x/RTK.md\n\n" ++ begin_marker ++ "\nRULE v2\n" ++ end_marker ++ "\n", c);

    // No trailing newline in the original.
    const d = try withBlock(gpa, "user text", "R");
    defer gpa.free(d);
    try std.testing.expectEqualStrings("user text\n\n" ++ begin_marker ++ "\nR\n" ++ end_marker ++ "\n", d);
}

test "setup: withoutBlock restores the original exactly" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "@/x/RTK.md\n", "user text", "", "a\n\nb\n" }) |orig| {
        const with = try withBlock(gpa, orig, "RULE");
        defer gpa.free(with);
        const back = (try withoutBlock(gpa, with)).?;
        defer gpa.free(back);
        const want = if (orig.len > 0 and orig[orig.len - 1] != '\n') try std.fmt.allocPrint(gpa, "{s}\n", .{orig}) else try gpa.dupe(u8, orig);
        defer gpa.free(want);
        try std.testing.expectEqualStrings(want, back);
    }
    try std.testing.expect((try withoutBlock(gpa, "no block here\n")) == null);
}

test "setup: --setup=LIST selection" {
    try std.testing.expect(selected(null, "codex"));
    try std.testing.expect(selected("claude,codex", "codex"));
    try std.testing.expect(!selected("claude,codex", "opencode"));
    try std.testing.expect(selected("gemini", "agy"));
    try std.testing.expect(selected(" Claude , agy", "claude"));
    try std.testing.expect(unknownId("claude,codex,agy,openisy") == null);
    try std.testing.expectEqualStrings("cursor", unknownId("claude,cursor").?);
}

test "setup: the rule names the command and keeps rg glob braces" {
    const gpa = std.testing.allocator;
    const r = try ruleText(gpa, "zigrep");
    defer gpa.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "`zigrep -n PATTERN .`") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "'*.{ts,tsx}'") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "alternation is `a|b`, NOT `a\\|b`") != null);
}
