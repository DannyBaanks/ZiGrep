//! Salida estructurada `--json` (JSONL, schema `zgrep/1`).
//!
//! Un evento por línea de salida que la herramienta emitiría en modo texto, más
//! los eventos de fichero (`-l`/`-L`) y de recuento (`-c`/`--count-matches`). El
//! schema lleva versión explícita y la regla es **solo añadir campos**: un campo
//! nuevo es un release, un campo renombrado o quitado es un release mayor.
//!
//! Diseño deliberado:
//!   * `--json` fuerza el camino por líneas (el de spans), así que hay un solo
//!     emisor y un solo orden, no dos comportamientos que puedan divergir;
//!   * los `byte_start`/`byte_end` son absolutos en el fichero, y el test
//!     diferencial los verifica rebanando el fichero real;
//!   * cuando un evento no tiene span (contexto, `-v`, passthru) los campos
//!     salen `null`, nunca inventados;
//!   * `--color`, `--heading`, `--column` y los separadores `--` son decoración
//!     de texto: en JSON no existen (la información va en los campos).
//!
//! M1 del plan agent-native (`planes/zigrep-agent-native.md`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Match = @import("search.zig").Match;

pub const schema = "zgrep/1";
const json_prefix = "{\"schema\":\"zgrep/1\",";

pub const Kind = enum {
    /// Una línea coincide (o no, con `-v`): es la línea emitida en modo texto.
    match,
    /// Línea de contexto `-A`/`-B`/`-C`.
    context,
    /// `--passthru`: línea no coincidente impresa.
    passthru,
    /// `-o`/`--vimgrep`: una por ocurrencia, con span.
    occurrence,
};

/// Un evento de línea. `span` es el span dentro de `line_bytes`; `line_start` es
/// el offset absoluto de la línea en el fichero, para que los bytes absolutos
/// sean `line_start + span.start`.
pub const LineEvent = struct {
    path: []const u8,
    line_no: usize,
    line_start: usize,
    line_bytes: []const u8,
    span: ?Match,
    kind: Kind,
    /// Texto efectivamente emitido en modo texto (con `--replace` es la línea
    /// ya sustituida; sin él, la línea tal cual).
    text: []const u8,
    /// La línea se emitió porque NO coincide y se pidió `-v`. Viene del flag,
    /// no se deduce de "match sin span" (eso etiquetaba mal el passthru).
    inverted: bool = false,
};

pub fn emitLineEvent(out: *std.ArrayList(u8), gpa: Allocator, ev: LineEvent) Allocator.Error!void {
    try out.appendSlice(gpa, json_prefix ++ "\"type\":\"");
    try out.appendSlice(gpa, switch (ev.kind) {
        .match => "match",
        .context => "context",
        .passthru => "passthru",
        .occurrence => "occurrence",
    });
    try out.appendSlice(gpa, "\",\"path\":");
    try appendJsonString(out, gpa, ev.path);
    try out.appendSlice(gpa, ",\"line\":");
    try appendInt(out, gpa, ev.line_no);
    if (ev.span) |sp| {
        const col = sp.start + 1;
        const bstart = ev.line_start + sp.start;
        const bend = ev.line_start + sp.end;
        try out.appendSlice(gpa, ",\"column\":");
        try appendInt(out, gpa, col);
        try out.appendSlice(gpa, ",\"byte_start\":");
        try appendInt(out, gpa, bstart);
        try out.appendSlice(gpa, ",\"byte_end\":");
        try appendInt(out, gpa, bend);
        try out.appendSlice(gpa, ",\"match\":");
        try appendJsonString(out, gpa, ev.line_bytes[sp.start..sp.end]);
    } else {
        try out.appendSlice(gpa, ",\"column\":null,\"byte_start\":null,\"byte_end\":null,\"match\":null");
    }
    try out.appendSlice(gpa, ",\"text\":");
    try appendJsonString(out, gpa, ev.text);
    try out.appendSlice(gpa, ",\"inverted\":");
    try out.appendSlice(gpa, if (ev.inverted) "true" else "false");
    try out.appendSlice(gpa, "}\n");
}

/// `-l` / `-L`.
pub fn emitFileEvent(out: *std.ArrayList(u8), gpa: Allocator, path: []const u8, with_match: bool) Allocator.Error!void {
    try out.appendSlice(gpa, json_prefix ++ "\"type\":\"file\",\"path\":");
    try appendJsonString(out, gpa, path);
    try out.appendSlice(gpa, ",\"mode\":\"");
    try out.appendSlice(gpa, if (with_match) "with-match" else "without-match");
    try out.appendSlice(gpa, "\"}\n");
}

/// `-c` (recuento de líneas) o `--count-matches` (recuento de ocurrencias). Uno
/// de los dos campos viene informado; el otro `null`, para que el schema no
/// cambie entre modos.
pub fn emitCountEvent(out: *std.ArrayList(u8), gpa: Allocator, path: []const u8, lines: ?usize, matches: ?usize) Allocator.Error!void {
    try out.appendSlice(gpa, json_prefix ++ "\"type\":\"count\",\"path\":");
    try appendJsonString(out, gpa, path);
    try out.appendSlice(gpa, ",\"lines\":");
    if (lines) |n| try appendInt(out, gpa, n) else try out.appendSlice(gpa, "null");
    try out.appendSlice(gpa, ",\"matches\":");
    if (matches) |n| try appendInt(out, gpa, n) else try out.appendSlice(gpa, "null");
    try out.appendSlice(gpa, "}\n");
}

fn appendInt(out: *std.ArrayList(u8), gpa: Allocator, value: usize) Allocator.Error!void {
    var buf: [24]u8 = undefined;
    const t = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    try out.appendSlice(gpa, t);
}

/// Comillas JSON con escapes: `"` `\` y los controles (< 0x20). El resto de
/// bytes sale tal cual (la salida es UTF-8, igual que el fichero leído).
pub fn appendJsonString(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8) Allocator.Error!void {
    try out.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            0x08 => try out.appendSlice(gpa, "\\b"),
            0x0c => try out.appendSlice(gpa, "\\f"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    const t = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try out.appendSlice(gpa, t);
                } else {
                    try out.append(gpa, c);
                }
            },
        }
    }
    try out.append(gpa, '"');
}

test "appendJsonString: escapes los caracteres JSON" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendJsonString(&out, std.testing.allocator, "a\"b\\c\nd\x01");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\u0001\"", out.items);
}

test "emitLineEvent: match con span, bytes absolutos e inverted=false" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const line = "the cat sat";
    try emitLineEvent(&out, std.testing.allocator, .{
        .path = "a.txt",
        .line_no = 2,
        .line_start = 10,
        .line_bytes = line,
        .span = .{ .start = 4, .end = 7 },
        .kind = .match,
        .text = line,
    });
    try std.testing.expectEqualStrings(
        \\{"schema":"zgrep/1","type":"match","path":"a.txt","line":2,"column":5,"byte_start":14,"byte_end":17,"match":"cat","text":"the cat sat","inverted":false}
        \\
    , out.items);
}

test "emitLineEvent: contexto sin span, campos null" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try emitLineEvent(&out, std.testing.allocator, .{
        .path = "a.txt",
        .line_no = 1,
        .line_start = 0,
        .line_bytes = "one",
        .span = null,
        .kind = .context,
        .text = "one",
    });
    try std.testing.expectEqualStrings(
        \\{"schema":"zgrep/1","type":"context","path":"a.txt","line":1,"column":null,"byte_start":null,"byte_end":null,"match":null,"text":"one","inverted":false}
        \\
    , out.items);
}

test "emitLineEvent: -v es match sin span, inverted=true" {
    // `inverted` lo fija el emisor desde -v; ya no se deduce de "sin span"
    // (esa heuristica marcaba como invertidas las lineas de --passthru).
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try emitLineEvent(&out, std.testing.allocator, .{
        .path = "a.txt",
        .line_no = 3,
        .line_start = 20,
        .line_bytes = "plain",
        .span = null,
        .kind = .match,
        .text = "plain",
        .inverted = true,
    });
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"type\":\"match\",\"path\":\"a.txt\",\"line\":3,\"column\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"inverted\":true") != null);
}

test "emitFileEvent y emitCountEvent" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try emitFileEvent(&out, std.testing.allocator, "x.txt", true);
    try emitCountEvent(&out, std.testing.allocator, "x.txt", 2, null);
    try std.testing.expectEqualStrings(
        \\{"schema":"zgrep/1","type":"file","path":"x.txt","mode":"with-match"}
        \\{"schema":"zgrep/1","type":"count","path":"x.txt","lines":2,"matches":null}
        \\
    , out.items);
}
