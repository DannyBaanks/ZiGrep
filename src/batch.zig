//! M3 del plan agent-native: lote (`--queries-file`) y presupuesto
//! (`--max-results`, `--max-output-tokens`) con truncado EXPLÍCITO.
//!
//! El emisor se interpone en `platform.writeStdout`: recibe el JSONL que la
//! búsqueda normal ya produce (schema `zgrep/1`), y por cada evento
//!   * le añade `"query_id":<id>` justo después de `"schema"` (en lote),
//!   * lo cuenta como resultado si es `match`/`occurrence`/`file`/`count`
//!     (`context` y `passthru` acompañan, no cuentan),
//!   * lo emite o lo omite según el presupuesto.
//!
//! Reglas, deliberadas:
//!   * nunca se corta un evento a la mitad: el stream es JSONL válido siempre;
//!   * truncar NO detiene el escaneo: lo omitido se cuenta y se informa
//!     (`omitted`), porque evidencia incompleta debe saberse incompleta;
//!   * el presupuesto cubre los eventos de búsqueda; los eventos de control
//!     (`query_end`, `summary`) se emiten siempre y no cuentan;
//!   * tokens = bytes / 4, y el evento `summary` lo declara (`token_estimate`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const out_json = @import("out_json.zig");
const platform = @import("platform.zig");

pub const Reason = enum { max_results, max_output_tokens };

fn reasonName(r: Reason) []const u8 {
    return switch (r) {
        .max_results => "max-results",
        .max_output_tokens => "max-output-tokens",
    };
}

pub const bytes_per_token = 4;

const json_prefix = "{\"schema\":\"zgrep/1\",";

/// Eventos que son resultados (lo que un agente cuenta como "hallazgos").
fn isResult(line: []const u8) bool {
    const rest = line[json_prefix.len..];
    inline for (.{ "match", "occurrence", "file", "count" }) |t| {
        if (std.mem.startsWith(u8, rest, "\"type\":\"" ++ t ++ "\"")) return true;
    }
    return false;
}

const Lock = struct {
    state: std.atomic.Value(bool) = .init(false),
    fn lock(self: *Lock) void {
        while (self.state.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Lock) void {
        self.state.store(false, .release);
    }
};

pub const Emitter = struct {
    io: std.Io,
    gpa: Allocator,
    max_results: ?usize = null,
    max_output_tokens: ?usize = null,

    /// JSON ya serializado del id de la consulta en curso (`null` = sin lote).
    query_id: ?[]const u8 = null,
    /// `--json=compact` (zgrep/1c): filas `[...]`, cabeceras `{"path"}`; las
    /// filas no llevan query_id (lo marca `{"query_id":..}` al empezar).
    compact: bool = false,
    /// Cabecera `{"path"}` retenida hasta que salga la primera fila de su
    /// fichero: un truncado no deja cabeceras huerfanas.
    pending_header: std.ArrayList(u8) = .empty,

    lock: Lock = .{},
    /// Bytes de una línea que llegó partida entre dos escrituras.
    carry: std.ArrayList(u8) = .empty,
    staged: std.ArrayList(u8) = .empty,

    // Totales de la llamada.
    returned: usize = 0,
    omitted: usize = 0,
    output_bytes: usize = 0,
    reason: ?Reason = null,
    /// Líneas que no eran eventos zgrep/1 (no deberían existir; se cuentan,
    /// no se cuelan en el stream).
    dropped_non_event: usize = 0,

    // Contadores de la consulta en curso.
    q_returned: usize = 0,
    q_omitted: usize = 0,
    q_dropped: usize = 0,

    pub fn deinit(self: *Emitter) void {
        self.carry.deinit(self.gpa);
        self.staged.deinit(self.gpa);
        self.pending_header.deinit(self.gpa);
    }

    pub fn install(self: *Emitter) void {
        platform.stdout_sink = .{ .ctx = self, .write = sinkWrite };
    }

    pub fn uninstall(_: *Emitter) void {
        platform.stdout_sink = null;
    }

    fn sinkWrite(ctx: *anyopaque, bytes: []const u8) bool {
        const self: *Emitter = @ptrCast(@alignCast(ctx));
        self.lock.lock();
        defer self.lock.unlock();
        self.feed(bytes) catch return false;
        return self.flushStaged();
    }

    /// Procesa `bytes`, que pueden traer varias líneas o un trozo de una.
    pub fn feed(self: *Emitter, bytes: []const u8) Allocator.Error!void {
        var rest = bytes;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            if (self.carry.items.len > 0) {
                try self.carry.appendSlice(self.gpa, rest[0..nl]);
                const line = try self.gpa.dupe(u8, self.carry.items);
                defer self.gpa.free(line);
                self.carry.clearRetainingCapacity();
                try self.event(line);
            } else {
                try self.event(rest[0..nl]);
            }
            rest = rest[nl + 1 ..];
        }
        if (rest.len > 0) try self.carry.appendSlice(self.gpa, rest);
    }

    fn budgetBytes(self: *const Emitter) ?usize {
        const t = self.max_output_tokens orelse return null;
        return t *| bytes_per_token;
    }

    fn compactEvent(self: *Emitter, line: []const u8) Allocator.Error!void {
        if (std.mem.startsWith(u8, line, "{\"schema\":\"zgrep/1c\"")) {
            // cabecera de stream: control, siempre, no cuenta
            try self.staged.appendSlice(self.gpa, line);
            try self.staged.append(self.gpa, '\n');
            return;
        }
        if (std.mem.startsWith(u8, line, "{\"path\":")) {
            self.pending_header.clearRetainingCapacity();
            try self.pending_header.appendSlice(self.gpa, line);
            try self.pending_header.append(self.gpa, '\n');
            return;
        }
        if (line.len < 4 or line[0] != '[' or line[1] != '"') {
            self.dropped_non_event += 1;
            self.q_dropped += 1;
            return;
        }
        const tag_end = std.mem.indexOfScalarPos(u8, line, 2, '"') orelse line.len;
        const tag = line[2..tag_end];
        const result = !(tag.len > 0 and (tag[0] == 'c' or tag[0] == 'p'));
        const out_len = line.len + 1 + self.pending_header.items.len;
        if (self.reason == null) {
            if (result) {
                if (self.max_results) |m| {
                    if (self.returned >= m) self.reason = .max_results;
                }
            }
            if (self.reason == null) {
                if (self.budgetBytes()) |b| {
                    if (self.output_bytes + out_len > b) self.reason = .max_output_tokens;
                }
            }
        }
        if (self.reason != null) {
            self.pending_header.clearRetainingCapacity();
            if (result) {
                self.omitted += 1;
                self.q_omitted += 1;
            }
            return;
        }
        try self.staged.appendSlice(self.gpa, self.pending_header.items);
        self.pending_header.clearRetainingCapacity();
        try self.staged.appendSlice(self.gpa, line);
        try self.staged.append(self.gpa, '\n');
        self.output_bytes += out_len;
        if (result) {
            self.returned += 1;
            self.q_returned += 1;
        }
    }

    fn event(self: *Emitter, line: []const u8) Allocator.Error!void {
        if (self.compact) return self.compactEvent(line);
        if (!std.mem.startsWith(u8, line, json_prefix)) {
            self.dropped_non_event += 1;
            self.q_dropped += 1;
            return;
        }
        const result = isResult(line);
        const id_extra: usize = if (self.query_id) |id| "\"query_id\":".len + id.len + 1 else 0;
        const out_len = line.len + id_extra + 1;

        if (self.reason == null) {
            if (result) {
                if (self.max_results) |m| {
                    if (self.returned >= m) self.reason = .max_results;
                }
            }
            if (self.reason == null) {
                if (self.budgetBytes()) |b| {
                    if (self.output_bytes + out_len > b) self.reason = .max_output_tokens;
                }
            }
        }
        if (self.reason != null) {
            if (result) {
                self.omitted += 1;
                self.q_omitted += 1;
            }
            return;
        }
        try self.staged.appendSlice(self.gpa, json_prefix);
        if (self.query_id) |id| {
            try self.staged.appendSlice(self.gpa, "\"query_id\":");
            try self.staged.appendSlice(self.gpa, id);
            try self.staged.append(self.gpa, ',');
        }
        try self.staged.appendSlice(self.gpa, line[json_prefix.len..]);
        try self.staged.append(self.gpa, '\n');
        self.output_bytes += out_len;
        if (result) {
            self.returned += 1;
            self.q_returned += 1;
        }
    }

    fn flushStaged(self: *Emitter) bool {
        if (self.staged.items.len == 0) return true;
        const ok = platform.writeStdoutRaw(self.io, self.staged.items);
        self.staged.clearRetainingCapacity();
        return ok;
    }

    /// Una línea sin `\n` final al acabar una consulta también es un evento.
    fn drainCarry(self: *Emitter) Allocator.Error!void {
        if (self.carry.items.len == 0) return;
        const line = try self.gpa.dupe(u8, self.carry.items);
        defer self.gpa.free(line);
        self.carry.clearRetainingCapacity();
        try self.event(line);
    }

    pub fn beginQuery(self: *Emitter, id_json: []const u8) Allocator.Error!void {
        self.query_id = id_json;
        self.q_returned = 0;
        self.q_omitted = 0;
        self.q_dropped = 0;
        if (self.compact) {
            // las filas compactas no llevan id: este marcador abre la consulta
            self.lock.lock();
            defer self.lock.unlock();
            self.pending_header.clearRetainingCapacity();
            try self.staged.appendSlice(self.gpa, "{\"query_id\":");
            try self.staged.appendSlice(self.gpa, id_json);
            try self.staged.appendSlice(self.gpa, "}\n");
            _ = self.flushStaged();
        }
    }

    /// Cierra la consulta en curso con su evento `query_end`.
    pub fn endQuery(self: *Emitter, rc: u8, err: ?[]const u8) Allocator.Error!bool {
        self.lock.lock();
        defer self.lock.unlock();
        try self.drainCarry();
        self.pending_header.clearRetainingCapacity();
        const g = self.gpa;
        try self.staged.appendSlice(g, json_prefix ++ "\"query_id\":");
        try self.staged.appendSlice(g, self.query_id orelse "null");
        try self.staged.appendSlice(g, ",\"type\":\"query_end\",\"rc\":");
        try appendInt(&self.staged, g, rc);
        try self.staged.appendSlice(g, ",\"returned\":");
        try appendInt(&self.staged, g, self.q_returned);
        try self.staged.appendSlice(g, ",\"omitted\":");
        try appendInt(&self.staged, g, self.q_omitted);
        try self.staged.appendSlice(g, ",\"truncated\":");
        try self.staged.appendSlice(g, if (self.q_omitted > 0) "true" else "false");
        try self.staged.appendSlice(g, ",\"dropped_non_event\":");
        try appendInt(&self.staged, g, self.q_dropped);
        try self.staged.appendSlice(g, ",\"error\":");
        if (err) |e| try out_json.appendJsonString(&self.staged, g, e) else try self.staged.appendSlice(g, "null");
        try self.staged.appendSlice(g, "}\n");
        self.query_id = null;
        return self.flushStaged();
    }

    /// Evento final, siempre el último del stream.
    pub fn summary(self: *Emitter, queries: ?usize) Allocator.Error!bool {
        self.lock.lock();
        defer self.lock.unlock();
        try self.drainCarry();
        const g = self.gpa;
        try self.staged.appendSlice(g, json_prefix ++ "\"type\":\"summary\",\"queries\":");
        if (queries) |q| try appendInt(&self.staged, g, q) else try self.staged.appendSlice(g, "null");
        try self.staged.appendSlice(g, ",\"returned\":");
        try appendInt(&self.staged, g, self.returned);
        try self.staged.appendSlice(g, ",\"omitted\":");
        try appendInt(&self.staged, g, self.omitted);
        try self.staged.appendSlice(g, ",\"truncated\":");
        try self.staged.appendSlice(g, if (self.reason != null) "true" else "false");
        try self.staged.appendSlice(g, ",\"reason\":");
        if (self.reason) |r| {
            try self.staged.append(g, '"');
            try self.staged.appendSlice(g, reasonName(r));
            try self.staged.append(g, '"');
        } else try self.staged.appendSlice(g, "null");
        try self.staged.appendSlice(g, ",\"output_bytes\":");
        try appendInt(&self.staged, g, self.output_bytes);
        try self.staged.appendSlice(g, ",\"max_results\":");
        if (self.max_results) |m| try appendInt(&self.staged, g, m) else try self.staged.appendSlice(g, "null");
        try self.staged.appendSlice(g, ",\"max_output_tokens\":");
        if (self.max_output_tokens) |m| try appendInt(&self.staged, g, m) else try self.staged.appendSlice(g, "null");
        try self.staged.appendSlice(g, ",\"token_estimate\":\"bytes/4\",\"dropped_non_event\":");
        try appendInt(&self.staged, g, self.dropped_non_event);
        try self.staged.appendSlice(g, "}\n");
        return self.flushStaged();
    }
};

fn appendInt(out: *std.ArrayList(u8), gpa: Allocator, value: usize) Allocator.Error!void {
    var buf: [24]u8 = undefined;
    const t = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    try out.appendSlice(gpa, t);
}

// ---------------------------------------------------------------------------
// Fichero de consultas (JSONL): {"id": "a"|1, "pattern": "...", "paths"?: [...], "flags"?: [...]}

pub const Query = struct {
    /// JSON del id, ya serializado (string con comillas o entero).
    id_json: []const u8,
    pattern: []const u8,
    paths: ?[]const []const u8,
    flags: []const []const u8,
};

pub const ParseError = struct {
    line_no: usize,
    what: []const u8,
};

const RawQuery = struct {
    id: std.json.Value,
    pattern: []const u8,
    paths: ?[]const []const u8 = null,
    flags: ?[]const []const u8 = null,
};

/// Parsea el fichero entero antes de ejecutar nada (falla cerrado: una línea
/// mala no deja un lote a medias). Las líneas vacías se ignoran.
pub fn parseQueries(arena: Allocator, text: []const u8, err_out: *ParseError) error{ Invalid, OutOfMemory }![]Query {
    var list: std.ArrayList(Query) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (it.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSliceLeaky(RawQuery, arena, line, .{}) catch {
            err_out.* = .{ .line_no = line_no, .what = "not a query object {\"id\", \"pattern\", \"paths\"?, \"flags\"?} (unknown fields are rejected)" };
            return error.Invalid;
        };
        var id_buf: std.ArrayList(u8) = .empty;
        switch (parsed.id) {
            .string => |s| try out_json.appendJsonString(&id_buf, arena, s),
            .integer => |n| {
                if (n < 0) {
                    err_out.* = .{ .line_no = line_no, .what = "\"id\" must be a string or a non-negative integer" };
                    return error.Invalid;
                }
                try appendInt(&id_buf, arena, @intCast(n));
            },
            else => {
                err_out.* = .{ .line_no = line_no, .what = "\"id\" must be a string or a non-negative integer" };
                return error.Invalid;
            },
        }
        for (list.items) |q| {
            if (std.mem.eql(u8, q.id_json, id_buf.items)) {
                err_out.* = .{ .line_no = line_no, .what = "duplicate \"id\"" };
                return error.Invalid;
            }
        }
        try list.append(arena, .{
            .id_json = id_buf.items,
            .pattern = parsed.pattern,
            .paths = parsed.paths,
            .flags = parsed.flags orelse &.{},
        });
    }
    return list.items;
}

// ---------------------------------------------------------------------------

test "Emitter: añade query_id y cuenta resultados" {
    const gpa = std.testing.allocator;
    var e: Emitter = .{ .io = undefined, .gpa = gpa };
    defer e.deinit();
    try e.beginQuery("\"q1\"");
    try e.feed("{\"schema\":\"zgrep/1\",\"type\":\"match\",\"path\":\"a\"}\n{\"schema\":\"zgrep/1\",\"type\":\"context\",\"path\":\"a\"}\n");
    try std.testing.expectEqualStrings(
        \\{"schema":"zgrep/1","query_id":"q1","type":"match","path":"a"}
        \\{"schema":"zgrep/1","query_id":"q1","type":"context","path":"a"}
        \\
    , e.staged.items);
    try std.testing.expectEqual(@as(usize, 1), e.returned);
}

test "Emitter: una línea partida entre dos escrituras es un solo evento" {
    const gpa = std.testing.allocator;
    var e: Emitter = .{ .io = undefined, .gpa = gpa };
    defer e.deinit();
    try e.feed("{\"schema\":\"zgrep/1\",\"type\":\"ma");
    try std.testing.expectEqual(@as(usize, 0), e.staged.items.len);
    try e.feed("tch\"}\n");
    try std.testing.expectEqualStrings("{\"schema\":\"zgrep/1\",\"type\":\"match\"}\n", e.staged.items);
}

test "Emitter: --max-results corta, sigue contando lo omitido y no cuenta el contexto" {
    const gpa = std.testing.allocator;
    var e: Emitter = .{ .io = undefined, .gpa = gpa, .max_results = 1 };
    defer e.deinit();
    const m = "{\"schema\":\"zgrep/1\",\"type\":\"match\"}\n";
    const c = "{\"schema\":\"zgrep/1\",\"type\":\"context\"}\n";
    try e.feed(m ++ c ++ m ++ m);
    try std.testing.expectEqualStrings(m ++ c, e.staged.items);
    try std.testing.expectEqual(@as(usize, 1), e.returned);
    try std.testing.expectEqual(@as(usize, 2), e.omitted);
    try std.testing.expectEqual(Reason.max_results, e.reason.?);
}

test "Emitter: --max-output-tokens nunca parte un evento" {
    const gpa = std.testing.allocator;
    const m = "{\"schema\":\"zgrep/1\",\"type\":\"match\"}\n"; // 36 bytes
    // 10 tokens = 40 bytes: cabe uno entero, el segundo no.
    var e: Emitter = .{ .io = undefined, .gpa = gpa, .max_output_tokens = 10 };
    defer e.deinit();
    try e.feed(m ++ m);
    try std.testing.expectEqualStrings(m, e.staged.items);
    try std.testing.expectEqual(@as(usize, 1), e.omitted);
    try std.testing.expectEqual(Reason.max_output_tokens, e.reason.?);
}

test "Emitter: lo que no es evento zgrep/1 no entra al stream" {
    const gpa = std.testing.allocator;
    var e: Emitter = .{ .io = undefined, .gpa = gpa };
    defer e.deinit();
    try e.feed("zgrep 0.4.0\n");
    try std.testing.expectEqual(@as(usize, 0), e.staged.items.len);
    try std.testing.expectEqual(@as(usize, 1), e.dropped_non_event);
}

test "parseQueries: ids string y entero, rechaza duplicados y campos desconocidos" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var perr: ParseError = undefined;
    const ok = try parseQueries(arena.allocator(),
        \\{"id":"a","pattern":"x"}
        \\
        \\{"id":7,"pattern":"y","paths":["src"],"flags":["-i"]}
    , &perr);
    try std.testing.expectEqual(@as(usize, 2), ok.len);
    try std.testing.expectEqualStrings("\"a\"", ok[0].id_json);
    try std.testing.expectEqualStrings("7", ok[1].id_json);
    try std.testing.expectEqualStrings("src", ok[1].paths.?[0]);

    try std.testing.expectError(error.Invalid, parseQueries(arena.allocator(),
        \\{"id":"a","pattern":"x"}
        \\{"id":"a","pattern":"y"}
    , &perr));
    try std.testing.expectEqual(@as(usize, 2), perr.line_no);
    try std.testing.expectError(error.Invalid, parseQueries(arena.allocator(),
        \\{"id":"a","pattern":"x","path":["typo"]}
    , &perr));
}
