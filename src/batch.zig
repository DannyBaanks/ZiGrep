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
//!   * tokens = el estimador por clases de caracteres de M7 (calibrado contra
//!     un BPE real, no subestima en la validacion confirmatoria), declarado en
//!     `summary.token_estimate`; bytes/4 subestimaba en el 100 % de los bloques.
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

/// M7: tokens estimados por clases de caracteres, una pasada por byte. Pesos
/// ajustados contra un BPE real (Qwen, vocab 151936) en la corrida confirmatoria
/// de `evidence/agent-native/m7/estimator_study.py` (seed 11, bloques de 30
/// lineas), escalados para no subestimar en su mitad de ajuste y con +1 % de
/// margen declarado: 0 bloques subestimados de 245 de validacion, sesgo medio
/// +10 %. bytes/4 (lo de M3) subestimaba en 245/245, hasta 2,33x.
pub const token_estimator_name = "zgrep-classes-v1";
const est_scale: f64 = 1.112 * 1.01;
const w_bytes: f64 = 0.2413;
const w_digits: f64 = 1.0526;
const w_punct: f64 = 0.0954;
const w_space_runs: f64 = 0.1128;
const w_nonascii: f64 = 0.4598;

pub fn estimateTokens(b: []const u8) f64 {
    var digits: usize = 0;
    var punct: usize = 0;
    var space_runs: usize = 0;
    var nonascii: usize = 0;
    var in_space = false;
    for (b) |c| {
        const is_space = c == ' ' or c == '\t' or c == '\n' or c == '\r';
        if (is_space) {
            if (!in_space) space_runs += 1;
        } else if (c >= 0x80) {
            nonascii += 1;
        } else if (c >= '0' and c <= '9') {
            digits += 1;
        } else if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_')) {
            punct += 1;
        }
        in_space = is_space;
    }
    const f = w_bytes * @as(f64, @floatFromInt(b.len)) + w_digits * @as(f64, @floatFromInt(digits)) +
        w_punct * @as(f64, @floatFromInt(punct)) + w_space_runs * @as(f64, @floatFromInt(space_runs)) +
        w_nonascii * @as(f64, @floatFromInt(nonascii));
    return f * est_scale;
}

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
    /// Tokens estimados (`estimateTokens`) de los eventos de busqueda emitidos.
    output_tokens_est: f64 = 0,
    /// Linea de salida armada antes de decidir si cabe en el presupuesto.
    line_buf: std.ArrayList(u8) = .empty,
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
        self.line_buf.deinit(self.gpa);
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

    fn overTokenBudget(self: *const Emitter, est: f64) bool {
        const t = self.max_output_tokens orelse return false;
        return self.output_tokens_est + est > @as(f64, @floatFromInt(t));
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
        self.line_buf.clearRetainingCapacity();
        try self.line_buf.appendSlice(self.gpa, self.pending_header.items);
        try self.line_buf.appendSlice(self.gpa, line);
        try self.line_buf.append(self.gpa, '\n');
        // Siempre: summary.output_tokens_est es un dato del contrato, no un
        // subproducto del presupuesto (con 0 cuando no habia tope mentia).
        const est = estimateTokens(self.line_buf.items);
        if (self.reason == null) {
            if (result) {
                if (self.max_results) |m| {
                    if (self.returned >= m) self.reason = .max_results;
                }
            }
            if (self.reason == null and self.overTokenBudget(est)) self.reason = .max_output_tokens;
        }
        if (self.reason != null) {
            self.pending_header.clearRetainingCapacity();
            if (result) {
                self.omitted += 1;
                self.q_omitted += 1;
            }
            return;
        }
        try self.staged.appendSlice(self.gpa, self.line_buf.items);
        self.pending_header.clearRetainingCapacity();
        self.output_bytes += self.line_buf.items.len;
        self.output_tokens_est += est;
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
        self.line_buf.clearRetainingCapacity();
        try self.line_buf.appendSlice(self.gpa, json_prefix);
        if (self.query_id) |id| {
            try self.line_buf.appendSlice(self.gpa, "\"query_id\":");
            try self.line_buf.appendSlice(self.gpa, id);
            try self.line_buf.append(self.gpa, ',');
        }
        try self.line_buf.appendSlice(self.gpa, line[json_prefix.len..]);
        try self.line_buf.append(self.gpa, '\n');
        // Siempre: summary.output_tokens_est es un dato del contrato, no un
        // subproducto del presupuesto (con 0 cuando no habia tope mentia).
        const est = estimateTokens(self.line_buf.items);

        if (self.reason == null) {
            if (result) {
                if (self.max_results) |m| {
                    if (self.returned >= m) self.reason = .max_results;
                }
            }
            if (self.reason == null and self.overTokenBudget(est)) self.reason = .max_output_tokens;
        }
        if (self.reason != null) {
            if (result) {
                self.omitted += 1;
                self.q_omitted += 1;
            }
            return;
        }
        try self.staged.appendSlice(self.gpa, self.line_buf.items);
        self.output_bytes += self.line_buf.items.len;
        self.output_tokens_est += est;
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
        try self.staged.appendSlice(g, ",\"output_tokens_est\":");
        try appendInt(&self.staged, g, @intFromFloat(@ceil(self.output_tokens_est)));
        try self.staged.appendSlice(g, ",\"token_estimate\":\"" ++ token_estimator_name ++ "\",\"dropped_non_event\":");
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
    const m = "{\"schema\":\"zgrep/1\",\"type\":\"match\"}\n";
    // presupuesto = lo que estima UN evento: cabe uno entero, el segundo no.
    const one: usize = @intFromFloat(@ceil(estimateTokens(m)));
    var e: Emitter = .{ .io = undefined, .gpa = gpa, .max_output_tokens = one };
    defer e.deinit();
    try e.feed(m ++ m);
    try std.testing.expectEqualStrings(m, e.staged.items);
    try std.testing.expectEqual(@as(usize, 1), e.omitted);
    try std.testing.expectEqual(Reason.max_output_tokens, e.reason.?);
}

test "estimateTokens: vacio es 0, aditivo, y cuenta mas los digitos y lo no-ASCII" {
    try std.testing.expectEqual(@as(f64, 0), estimateTokens(""));
    const a = estimateTokens("abcdef ");
    const b = estimateTokens("123456 ");
    const c = estimateTokens("ñññ ");
    try std.testing.expect(b > a); // un BPE parte los numeros mucho mas que las palabras
    try std.testing.expect(c > estimateTokens("nnn "));
    // aditivo por lineas (lo que usa el presupuesto: suma de eventos)
    try std.testing.expectApproxEqAbs(estimateTokens("ab 12\n") + estimateTokens("cd 34\n"), estimateTokens("ab 12\ncd 34\n"), 1e-9);
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
