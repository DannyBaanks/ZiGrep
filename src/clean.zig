//! clean.zig — `zgrep --cache`: analiza y limpia las caches de Zig.
//!
//! El mismo análisis que se haría a mano (recorrer, medir con `du`, mirar
//! quién apunta a qué) pero hecho por la herramienta, y con una decisión
//! explícita del usuario antes de borrar nada.
//!
//! Modo de uso:
//!   zgrep --cache                 # analiza, muestra, pregunta S/N, borra tras S
//!   zgrep --cache --dry-run       # solo el análisis
//!   zgrep --cache --force         # sin pregunta (para scripts)
//!
//! Reglas de seguridad (son las que hacen que sea "0 riesgo"):
//!   * una `.zig-cache` es siempre segura: se regenera al compilar;
//!   * un `zig-out` NO se toca por defecto (puede contener un binario
//!     instalado), y aun con --include-out se protege si algo apunta a él;
//!   * nunca se borra un enlace simbólico, solo lo que hay dentro;
//!   * la respuesta por defecto es N.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const vfs = @import("vfs.zig");
const platform = @import("platform.zig");

/// Escritor minimalista: formatea a un búfer y lo manda a stdout. Así el
/// módulo no depende de `std.fmt` sobre un `File` (no existe en 0.16).
const W = struct {
    fn s(io: std.Io, text: []const u8) void {
        _ = platform.writeStdout(io, text);
    }

    fn f(io: std.Io, comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
        _ = platform.writeStdout(io, text);
    }
};

pub const Options = struct {
    roots: []const [:0]const u8 = &.{},
    /// Include `$XDG_CACHE_HOME/zig` (or ~/.cache/zig), the global cache.
    include_global: bool = true,
    /// Also consider `zig-out` directories (off by default: installs live there).
    include_out: bool = false,
    /// How deep below each root to look for cache directories.
    depth: usize = 2,
    /// Show the manifest but delete nothing.
    dry_run: bool = false,
    /// Skip the interactive prompt.
    force: bool = false,
};

const Kind = enum {
    /// A per-repo build cache: safe, regenerates on the next build.
    local_cache,
    /// The global user cache: safe, regenerates.
    global_cache,
    /// Build output: DANGEROUS by default, it may hold an installed binary.
    out_dir,
};

const Target = struct {
    path: []const u8,
    kind: Kind,
    size: u64,
    /// Set when something in a well-known bin dir symlinks into this path.
    protected: bool = false,
    /// Set when a build looks in flight for this tree (Zig running or a lock
    /// file inside): deleting it would break the build, so it needs --force.
    active: bool = false,
    err: bool = false,
};

/// Directories whose symlinks are checked when deciding whether a `zig-out`
/// is actually installed somewhere.
const install_dirs = [_][]const u8{
    ".local/bin",
    "bin",
    "/usr/local/bin",
    "/usr/bin",
};

/// `~/.cache/zig` (the global user cache).
fn globalCachePath(gpa: Allocator, home: []const u8) ?[]const u8 {
    return std.fs.path.join(gpa, &.{ home, ".cache", "zig" }) catch null;
}

/// Recursive size in bytes, like `du -sb` but counting only regular files.
/// Errors are swallowed: an unreadable subtree just contributes 0.
fn dirSize(io: std.Io, path: []const u8) u64 {
    var stream = vfs.DirStream.open(io, z(path)) catch return 0;
    defer stream.close();
    var total: u64 = 0;
    while (true) {
        const entry = stream.next() catch return total;
        const e = entry orelse break;
        if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
        const child = vfs.joinPathSentinel(std.heap.page_allocator, path, e.name) catch continue;
        defer std.heap.page_allocator.free(child);
        switch (e.kind) {
            .file => {
                if (vfs.stat(io, child, false)) |m| total += m.size;
            },
            .directory => total += dirSize(io, child),
            else => {},
        }
    }
    return total;
}

/// �Queda algún fichero de bloqueo dentro? Zig no crea locks (verificado),
/// pero otros sistemas de build sí, así que se comprueba por si acaso.
fn hasLockFile(io: std.Io, path: []const u8) bool {
    var stream = vfs.DirStream.open(io, z(path)) catch return false;
    defer stream.close();
    while (true) {
        const entry = stream.next() catch return false;
        const e = entry orelse break;
        if (std.mem.indexOf(u8, e.name, "lock") != null) return true;
        if (e.kind == .directory and
            !std.mem.eql(u8, e.name, ".") and !std.mem.eql(u8, e.name, ".."))
        {
            const joined = std.mem.join(std.heap.page_allocator, "/", &.{ path, e.name }) catch continue;
            defer std.heap.page_allocator.free(joined);
            const child = std.heap.page_allocator.dupeZ(u8, joined) catch continue;
            defer std.heap.page_allocator.free(child);
            if (hasLockFile(io, child)) return true;
        }
    }
    return false;
}

/// �Hay un compilador vivo sobre este árbol?
///
/// Medido: Zig no deja ficheros de bloqueo; lo que sí queda es el proceso. Dos
/// señales, ambas por /proc (solo en Linux; en otros sistemas se omite y se
/// dice):
///   * la caché GLOBAL es compartida por todos los repos: un `zig` vivo en
///     cualquier sitio la deja activa;
///   * una caché LOCAL queda activa si algún `zig` tiene su cwd en el repo que
///     la contiene (que es exactamente lo que hace `zig build`).
fn procsHomeActive(io: std.Io, gpa: Allocator, path: []const u8, kind: Kind) bool {
    if (builtin.os.tag != .linux) return false;
    const parent = std.fs.path.dirname(path) orelse path;
    var stream = vfs.DirStream.open(io, "/proc") catch return false;
    defer stream.close();
    var buf: [4096]u8 = undefined;
    var cwdbuf: [4096]u8 = undefined;
    var exebuf: [4096]u8 = undefined;
    while (true) {
        const entry = stream.next() catch return false;
        const e = entry orelse break;
        if (e.kind != .directory) continue;
        var digits = true;
        for (e.name) |c| {
            if (c < '0' or c > '9') digits = false;
        }
        if (!digits) continue;
        const exe = std.fmt.bufPrint(&buf, "/proc/{s}/exe", .{e.name}) catch continue;
        const exen = std.Io.Dir.cwd().readLink(io, exe, &exebuf) catch continue;
        var exe_target = exebuf[0..exen];
        // El kernel añade " (deleted)" cuando el binario se reemplazó en
        // caliente, que es justo lo que hace `zig build` sobre su caché.
        if (std.mem.endsWith(u8, exe_target, " (deleted)"))
            exe_target = exe_target[0 .. exe_target.len - " (deleted)".len];
        // SOLO cuenta un compilador de Zig. Medido el falso positivo: con
        // `indexOf(exe, "/zig")` bastaba ejecutar este programa —su ruta pasa
        // por `/zig-out/bin/zigrep`— para marcarse a sí mismo; y en la rama
        // local no se miraba el exe en absoluto, así que cualquier shell con
        // cwd en el repo también activaba la caché. Ahora: basename exacto.
        const base = std.fs.path.basename(exe_target);
        const is_zig = std.mem.eql(u8, base, "zig") or std.mem.eql(u8, base, "zig.exe");
        if (!is_zig) continue;
        if (kind == .global_cache) {
            // Cualquier compilador vivo usa la caché global compartida.
            return true;
        }
        const cwdpath = std.fmt.bufPrint(&buf, "/proc/{s}/cwd", .{e.name}) catch continue;
        const cwdn = std.Io.Dir.cwd().readLink(io, cwdpath, &cwdbuf) catch continue;
        const cwd = cwdbuf[0..cwdn];
        // El compilador arranca con cwd = el repo (o un subdirectorio suyo),
        // no dentro de la caché.
        if (std.mem.eql(u8, cwd, parent)) return true;
        var pbuf: [4096]u8 = undefined;
        if (std.fmt.bufPrint(&pbuf, "{s}/", .{parent})) |pref| {
            if (std.mem.startsWith(u8, cwd, pref)) return true;
        } else |_| {}
        if (std.mem.startsWith(u8, exe_target, path)) return true;
        _ = gpa;
    }
    return false;
}

/// Estado de riesgo de un objetivo, compartido por `parseSelection` y `run`.
pub const Risk = struct { protected: bool, active: bool };

const z = struct {
    fn f(p: []const u8) [:0]const u8 {
        return @ptrCast(p.ptr[0..p.len :0]);
    }
}.f;

/// Does a symlink in a well-known bin dir point inside `path`?
/// That is the signal that a `zig-out` is actually deployed.
fn hasInstallLink(io: std.Io, gpa: Allocator, home: []const u8, target: []const u8) bool {
    for (install_dirs) |rel| {
        const is_abs = rel.len > 0 and rel[0] == '/';
        const dir = if (is_abs)
            gpa.dupeZ(u8, rel) catch continue
        else
            std.fs.path.joinZ(gpa, &.{ home, rel }) catch continue;
        defer if (is_abs) gpa.free(dir) else gpa.free(dir);
        var stream = vfs.DirStream.open(io, dir) catch continue;
        defer stream.close();
        while (true) {
            const entry = stream.next() catch break;
            const e = entry orelse break;
            if (e.kind != .symlink) continue;
            const link = std.fs.path.joinZ(gpa, &.{ dir, e.name }) catch continue;
            defer gpa.free(link);
            // Resolve the link with the same call the platform uses: if it
            // points inside `target`, something is installed there.
            var buf: [4096]u8 = undefined;
            const n = std.Io.Dir.cwd().readLink(io, link, &buf) catch continue;
            const resolved = std.fs.path.resolve(gpa, &.{ dir, buf[0..n] }) catch continue;
            defer gpa.free(resolved);
            if (std.mem.startsWith(u8, resolved, target)) return true;
        }
    }
    return false;
}

/// Recursively collects cache directories under `root`, up to `depth`.
fn collect(io: std.Io, gpa: Allocator, home: []const u8, root: [:0]const u8, depth: usize, opts: Options, list: *std.ArrayList(Target)) void {
    if (depth == 0) return;
    var stream = vfs.DirStream.open(io, root) catch return;
    defer stream.close();
    var subdirs: std.ArrayList([:0]const u8) = .empty;
    defer subdirs.deinit(gpa);
    while (true) {
        const entry = stream.next() catch return;
        const e = entry orelse break;
        if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
        const child = vfs.joinPathSentinel(gpa, root, e.name) catch continue;
        if (e.kind == .directory) {
            if (std.mem.eql(u8, e.name, ".zig-cache")) {
                const dup = gpa.dupeZ(u8, child) catch continue;
                add(list, dup, .local_cache, io, gpa, home) catch gpa.free(dup);
            } else if (opts.include_out and std.mem.eql(u8, e.name, "zig-out")) {
                const dup = gpa.dupeZ(u8, child) catch continue;
                add(list, dup, .out_dir, io, gpa, home) catch gpa.free(dup);
            } else {
                subdirs.append(gpa, child) catch {
                    gpa.free(child);
                    continue;
                };
            }
        } else gpa.free(child);
    }
    for (subdirs.items) |sd| {
        collect(io, gpa, home, sd, depth - 1, opts, list);
        gpa.free(sd);
    }
}

/// The root itself may BE a cache directory (when the user points --cache-root
/// straight at a repo). Listing it here keeps that case, which the recursion
/// above would miss because it only looks one level down.
fn collectSelf(io: std.Io, gpa: Allocator, home: []const u8, root: [:0]const u8, opts: Options, list: *std.ArrayList(Target)) void {
    const name = std.fs.path.basename(root);
    if (std.mem.eql(u8, name, ".zig-cache")) {
        const dup = gpa.dupeZ(u8, root) catch return;
        add(list, dup, .local_cache, io, gpa, home) catch gpa.free(dup);
    } else if (opts.include_out and std.mem.eql(u8, name, "zig-out")) {
        const dup = gpa.dupeZ(u8, root) catch return;
        add(list, dup, .out_dir, io, gpa, home) catch gpa.free(dup);
    }
}

fn add(list: *std.ArrayList(Target), path: [:0]const u8, kind: Kind, io: std.Io, gpa: Allocator, home: []const u8) !void {
    const target_path = gpa.dupe(u8, path) catch return error.OutOfMemory;
    const size = dirSize(io, path);
    const protected = if (kind == .out_dir) hasInstallLink(io, gpa, home, target_path) else false;
    const active = hasLockFile(io, target_path) or procsHomeActive(io, gpa, target_path, kind);
    try list.append(gpa, .{ .path = target_path, .kind = kind, .size = size, .protected = protected, .active = active });
}

/// `du`-style: 1.5G, 367M, 79K, 512. One decimal below 10.
pub fn humanSize(out: []u8, bytes: u64) []const u8 {
    const units = [_]struct { s: []const u8, v: f64 }{ .{ .s = "T", .v = 1e12 }, .{ .s = "G", .v = 1e9 }, .{ .s = "M", .v = 1e6 }, .{ .s = "K", .v = 1e3 } };
    for (units) |u| {
        const n = @as(f64, @floatFromInt(bytes)) / u.v;
        if (n >= 1.0) {
            if (n >= 10 or n == @floor(n)) {
                return std.fmt.bufPrint(out, "{d:.0}{s}", .{ n, u.s }) catch "?";
            }
            return std.fmt.bufPrint(out, "{d:.1}{s}", .{ n, u.s }) catch "?";
        }
    }
    return std.fmt.bufPrint(out, "{d}B", .{bytes}) catch "?";
}

/// Deletes a whole tree, files first. Returns bytes freed (from the size we
/// already measured) or an error count.
fn deleteTree(io: std.Io, gpa: Allocator, path: []const u8) usize {
    var removed: usize = 0;
    var stream = vfs.DirStream.open(io, z(path)) catch return 0;
    defer stream.close();
    var names: std.ArrayList([:0]const u8) = .empty;
    defer names.deinit(gpa);
    while (true) {
        const entry = stream.next() catch break;
        const e = entry orelse break;
        if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
        const child = vfs.joinPathSentinel(gpa, path, e.name) catch continue;
        defer gpa.free(child);
        switch (e.kind) {
            .directory => {
                removed += deleteTree(io, gpa, child);
                names.append(gpa, child) catch {};
            },
            .file => {
                std.Io.Dir.deleteFileAbsolute(io, child) catch {};
                removed += 1;
            },
            else => {},
        }
    }
    // el directorio ya está vacío de ficheros: quitar los subdirectorios
    for (names.items) |sd| {
        std.Io.Dir.deleteDirAbsolute(io, sd) catch {};
    }
    std.Io.Dir.deleteDirAbsolute(io, path) catch {};
    return removed;
}

/// Lee UNA línea de stdin, byte a byte. `readStreaming` devuelve de golpe todo
/// lo que hacia que el segundo prompt (el S/N)
fn readLine(io: std.Io, buf: []u8) []const u8 {
    var n: usize = 0;
    const stdin = std.Io.File.stdin();
    while (n < buf.len) {
        var one: [1]u8 = undefined;
        const got = stdin.readStreaming(io, &.{one[0..]}) catch return buf[0..n];
        if (got == 0) break;
        const c = one[0];
        if (c == '\n') break;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

fn prompt(io: std.Io, question: []const u8) bool {
    _ = platform.writeStdout(io, question);
    var buf: [64]u8 = undefined;
    const line = readLine(io, &buf);
    var t = line;
    while (t.len > 0 and (t[t.len - 1] == '\r')) t = t[0 .. t.len - 1];
    return std.ascii.eqlIgnoreCase(t, "y") or std.ascii.eqlIgnoreCase(t, "yes") or eqlSi(t);
}

fn eqlSi(t: []const u8) bool {
    // 's' y 'si' cuentan como afirmativa en español.
    return std.ascii.eqlIgnoreCase(t, "s") or std.ascii.eqlIgnoreCase(t, "si");
}

/// Síntomas de la respuesta a "qué borrar?". Devuelve los índices elegidos.
/// Reglas: vacío/s/n/no/nada → ninguno. "all"/"todo" → todos los seguros.
/// "safe"/"seguros" → solo los seguros (no activos, no protegidos). En otro
/// caso una lista de números con rangos (`1,3-5`).
const sel_max = 512;

pub const Selection = struct {
    items: [sel_max]usize = undefined,
    len: usize = 0,

    pub fn slice(self: *const Selection) []const usize {
        return self.items[0..self.len];
    }
};

pub fn parseSelection(input: []const u8, count: usize, flags: []const Risk) Selection {
    var out = Selection{};
    const t = std.mem.trim(u8, input, " \t\r\n");
    if (t.len == 0) return out;
    if (std.ascii.eqlIgnoreCase(t, "s") or std.ascii.eqlIgnoreCase(t, "n") or
        std.ascii.eqlIgnoreCase(t, "no") or std.ascii.eqlIgnoreCase(t, "none") or
        std.ascii.eqlIgnoreCase(t, "nada"))
    {
        return out;
    }
    if (std.ascii.eqlIgnoreCase(t, "all") or std.ascii.eqlIgnoreCase(t, "todo") or
        std.ascii.eqlIgnoreCase(t, "safe") or std.ascii.eqlIgnoreCase(t, "seguros"))
    {
        const only_safe = std.ascii.eqlIgnoreCase(t, "safe") or std.ascii.eqlIgnoreCase(t, "seguros");
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (only_safe and (flags[i].protected or flags[i].active)) continue;
            if (out.len < sel_max) out.items[out.len] = i;
            out.len += 1;
        }
        return out;
    }
    var it = std.mem.splitScalar(u8, t, ',');
    while (it.next()) |tok| {
        const part = std.mem.trim(u8, tok, " ");
        if (part.len == 0) continue;
        if (std.mem.indexOfScalar(u8, part, '-')) |d| {
            if (d > 0 and d + 1 < part.len) {
                const a = std.fmt.parseInt(usize, part[0..d], 10) catch continue;
                const b = std.fmt.parseInt(usize, part[d + 1 ..], 10) catch continue;
                if (b < a) continue;
                var k = a;
                while (k <= b and k <= count + 1) : (k += 1) {
                    if (k >= 1 and k <= count and out.len < sel_max) {
                out.items[out.len] = k - 1;
                out.len += 1;
            }
                }
            }
        } else {
            const n = std.fmt.parseInt(usize, part, 10) catch continue;
            if (n >= 1 and n <= count and out.len < sel_max) out.items[out.len] = n - 1;
            if (out.len < sel_max) out.len += 1;
        }
    }
    return out;
}

test "parseSelection: sintaxis de marcado" {
    const flags = [_]Risk{
        .{ .protected = false, .active = false },
        .{ .protected = false, .active = false },
        .{ .protected = false, .active = true },
        .{ .protected = true, .active = false },
    };
    {
        const got = parseSelection("1", 4, &flags);
        try std.testing.expectEqual(@as(usize, 1), got.len);
        try std.testing.expectEqual(@as(usize, 0), got.slice()[0]);
    }
    {
        const got = parseSelection("1,2", 4, &flags);
        try std.testing.expectEqual(@as(usize, 2), got.len);
        try std.testing.expectEqual(@as(usize, 1), got.slice()[1]);
    }
    {
        const got = parseSelection("2-4", 4, &flags);
        try std.testing.expectEqual(@as(usize, 3), got.len);
    }
    {
        const got = parseSelection("", 4, &flags);
        try std.testing.expectEqual(@as(usize, 0), got.len);
    }
    {
        const got = parseSelection("n", 4, &flags);
        try std.testing.expectEqual(@as(usize, 0), got.len);
    }
    {
        // all incluye activos y protegidos; safe no
        try std.testing.expectEqual(@as(usize, 4), parseSelection("all", 4, &flags).len);
        try std.testing.expectEqual(@as(usize, 2), parseSelection("safe", 4, &flags).len);
    }
}


pub fn run(io: std.Io, gpa: Allocator, home: []const u8, opts: Options) u8 {
    var list: std.ArrayList(Target) = .empty;
    defer list.deinit(gpa);

    for (opts.roots) |root| {
        collect(io, gpa, home, root, opts.depth + 1, opts, &list);
        collectSelf(io, gpa, home, root, opts, &list);
    }
    if (opts.include_global) {
        if (globalCachePath(gpa, home)) |gc| {
            const gz = gpa.dupeZ(u8, gc) catch null;
            gpa.free(gc);
            if (gz) |zc| {
                defer gpa.free(zc);
                add(&list, zc, .global_cache, io, gpa, home) catch {};
            }
        }
    }

    if (list.items.len == 0) {
        W.s(io, "zgrep --cache: no se encontró ninguna cache de Zig\n");
        return 1;
    }

    // --- tabla numerada: qué hay, cuánto pesa y qué riesgo tiene ---
    var buf: [64]u8 = undefined;
    var total: u64 = 0;
    var skipped: u64 = 0;
    W.s(io, "\n== caches de Zig encontradas ==\n\n");
    W.s(io, "   #  tamaño  estado      ruta\n");
    var row: usize = 0;
    while (row < list.items.len) : (row += 1) {
        const t = list.items[row];
        const sz = humanSize(&buf, t.size);
        const state = if (t.active) "ACTIVA   " else if (t.protected) "PROTEGIDA" else if (t.kind == .out_dir) "peligrosa" else "segura   ";
        W.f(io, "  {d:>2}  {s:>5}  {s}  {s}\n", .{ row + 1, sz, state, t.path });
        if (t.active) {
            skipped += t.size;
        } else {
            total += t.size;
        }
    }
    W.f(io, "\n  total a liberar: {s}", .{humanSize(&buf, total)});
    if (skipped > 0) W.f(io, "   (activas, se omiten: {s})", .{humanSize(&buf, skipped)});
    W.s(io, "\n\n  segura      = se regenera al compilar\n");
    W.s(io, "  peligrosa   = zig-out: puede tener un binario instalado\n");
    W.s(io, "  ACTIVA      = hay una compilación en marcha: no se toca\n");
    W.s(io, "  PROTEGIDA   = algo apunta a ella (instalada)\n");
    W.s(io, "\n  ¿qué borrar?  1,3-5 | all | safe | nada  (vacío = nada)\n");

    if (opts.dry_run) {
        W.s(io, "\n  --dry-run: no se borró nada\n");
        return 0;
    }

    const flags = gpa.alloc(Risk, list.items.len) catch return 2;
    defer gpa.free(flags);
    for (list.items, 0..) |t, i| {
        flags[i] = .{ .protected = t.protected, .active = t.active };
    }

    var selection: []const usize = &.{};
    if (opts.force) {
        const chosen = parseSelection("safe", flags.len, flags);
        const own = gpa.dupe(usize, chosen.slice()) catch return 2;
        selection = own;
    } else {
        var buf2: [128]u8 = undefined;
        const chosen = parseSelection(readLine(io, &buf2), flags.len, flags);
        if (chosen.len == 0) {
            W.s(io, "\n  cancelado: no se borró nada\n");
            return 1;
        }
        const own = gpa.dupe(usize, chosen.slice()) catch return 2;
        selection = own;
    }

    // --- confirmacion final, con la seleccion ya hecha ---
    W.s(io, "\n  se borrará:\n");
    var confirm_total: u64 = 0;
    for (selection) |idx| confirm_total += list.items[idx].size;
    for (selection) |idx| {
        W.f(io, "    - {s}  ({s})\n", .{ list.items[idx].path, humanSize(&buf, list.items[idx].size) });
    }
    W.f(io, "  total: {s}", .{humanSize(&buf, confirm_total)});
    if (opts.force) {
        W.s(io, "\n  --force: sin preguntar\n");
    } else if (!prompt(io, "\n\nconfirmar? [s/N] ")) {
        W.s(io, "\n  cancelado: no se borró nada\n");
        return 1;
    }

    var freed: u64 = 0;
    var failed: usize = 0;
    for (selection) |idx| {
        const t = list.items[idx];
        const n = deleteTree(io, gpa, t.path);
        if (n == 0 and vfs.stat(io, t.path, false) != null) {
            failed += 1;
            W.f(io, "  NO se pudo borrar: {s}\n", .{t.path});
        } else {
            freed += t.size;
            W.f(io, "  borrado: {s} ({s})", .{ t.path, humanSize(&buf, t.size) });
        }
    }
    W.f(io, "\n  liberado: {s}", .{humanSize(&buf, freed)});
    if (failed > 0) W.f(io, "   (no se pudo borrar {d} ruta(s))", .{failed});
    W.s(io, "\n");
    return if (failed > 0) 2 else 0;
}

test "humanSize: formato tipo du" {
    var buf: [32]u8 = undefined;
    // du -sh usa unidades decimales: 1 GB = 1e9, 1 MB = 1e6.
    try std.testing.expectEqualStrings("512B", humanSize(&buf, 512));
    try std.testing.expectEqualStrings("1.6G", humanSize(&buf, 1536 * 1024 * 1024));
    try std.testing.expectEqualStrings("11G", humanSize(&buf, 11_000_000_000));
    try std.testing.expectEqualStrings("385M", humanSize(&buf, 367 * 1024 * 1024));
    try std.testing.expectEqualStrings("83M", humanSize(&buf, 79 * 1024 * 1024));
    try std.testing.expectEqualStrings("4.1K", humanSize(&buf, 4096));
}
