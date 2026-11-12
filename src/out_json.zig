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

/// `--json=compact` (schema `zgrep/1c`, M5): la MISMA informacion que zgrep/1
/// en ~0,4x los tokens (medido: evidence/agent-native/m5/format_study.py).
/// Fijado una vez por ejecucion antes de escanear; los hilos solo lo leen.
///
///   * cabecera de stream: `{"schema":"zgrep/1c"}` (una vez);
///   * cabecera de fichero: `{"path":P}` antes de las filas de ese fichero
///     (con `--provenance` lleva ademas sha256_b64u/size/mtime_ns/source:
///     el sha256 en base64url sin relleno, que tokeniza ~44 % mejor que hex);
///   * filas de linea, una por linea JSON: `[t, line, col, byte_start, len,
///     text]` con span, `[t, line, text]` sin span; t = m|c|o|p, con `v` si la
///     linea sale por `-v`. `match` = text[col-1 .. col-1+len] en bytes; solo
///     si NO se deriva asi (`--replace`) va como 7o elemento;
///   * `-l`/`-L`: `["l",P]` / `["L",P]`; `-c`: `["#",P,n]`;
///     `--count-matches`: `["#m",P,n]` (llevan el path: no tienen cabecera).
pub var compact: bool = false;
/// Solo el schema: la leyenda de las filas costaba ~65 bytes por llamada y
/// hacia el compacto MAS pesado que zgrep/1 en salidas diminutas (medido por
/// compact_conformance.py). Esta documentada en la GUIA §4p.
pub const compact_stream_header = "{\"schema\":\"zgrep/1c\"}\n";

/// M9: `--max-columns N` (JSON only, per call): the `text` of a row whose line
/// is longer than N bytes is emitted as a WINDOW of at most N bytes around the
/// match, with where the window starts and how long the whole line is. Fixed
/// once per run before scanning; the workers only read it (0 = off, the byte
/// for byte pre-M9 behaviour).
///
/// Why: on a real tree with `node_modules` (minified and generated lines),
/// cutting long lines to a window around the match saves ~58 % of the compact
/// output's REAL tokens (58.4 % at N=400 with the real implementation; the
/// pre-implementation simulation said 64.9 %) with the match intact in every row — measured against a
/// real BPE, register in `evidence/agent-native/m9/`. The rule fixed before the
/// run (>= 20 % saving, match never cut) says IMPLEMENT.
///
/// The contract (GUIA §4s), all of it verified by `m9_conformance.py`:
///   * only rows whose emitted text IS the line are windowed; a row without a
///     span (context, `-v`, `--passthru`) and a `--replace` row (the
///     substituted line, where the match no longer marks a position) are
///     emitted WHOLE;
///   * the match is never cut: the window always contains it, and if the match
///     alone does not fit in N bytes the window IS the match;
///   * a UTF-8 character is never split (the window is aligned to codepoint
///     boundaries), so every windowed `text` decodes;
///   * `col`, `byte_start` and `len` keep their whole-line meaning, so nothing
///     is lost: `line_start = byte_start - (col - 1)`, the whole line is
///     `file[line_start .. line_start + line_len]` and the window starts at
///     `line_start + win_start` (with `--provenance`, verifiable by hash).
///
/// Where the extra information travels (additive, and ONLY when a row is
/// windowed): `zgrep/1` gains `win_start` + `line_len` next to `text`;
/// `zgrep/1c` gains the `w` suffix on the row tag and two positional elements,
/// `[t+"w",line,col,byte_start,len,ventana,win_start,line_len]` (+ `match` when
/// it is not derivable inside the window). An unwindowed row is byte-identical
/// to pre-M9 output, so a reader that does not know the flag sees nothing new.
pub var max_columns: usize = 0;

/// A window over a row's own text: `bytes` = `text[start ..]`, at most the
/// budget long, never cutting the match and never splitting a character.
const Window = struct { start: usize, bytes: []const u8 };

/// The M9 window of `ev`, or null when the row must be emitted whole. The order
/// of the checks is the contract: no span, short enough, span inside the text,
/// and the text really is the line (that is what rules out `--replace` and
/// `-o`, where the emitted text is not the line).
fn windowOf(ev: *const LineEvent, w: usize) ?Window {
    if (w == 0) return null;
    const sp = ev.span orelse return null;
    if (ev.text.len <= w) return null;
    if (sp.end > ev.text.len) return null;
    if (!std.mem.eql(u8, ev.text, ev.line_bytes)) return null;
    const m0 = sp.start;
    const m1 = sp.end;
    var start: usize = undefined;
    var end: usize = undefined;
    if (m1 - m0 >= w) {
        // The match alone does not fit: the window is the match. Nothing is
        // gained, but the "never cut the match" rule holds unconditionally.
        start = m0;
        end = m1;
    } else {
        // Centre the budget on the match and clamp to the line.
        const pad = (w - (m1 - m0)) / 2;
        const s0 = if (m0 > pad) m0 - pad else 0;
        var s = s0;
        var e = @min(ev.text.len, s0 + w);
        s = if (e > w) e - w else 0;
        // Align to codepoint boundaries without ever entering the match.
        while (s < m0 and (ev.text[s] & 0xC0) == 0x80) s += 1;
        // `e` is an exclusive end: at `e == text.len` the window already ends
        // on the line's last byte, and `text[e]` would read past the slice
        // (panic in Debug/ReleaseSafe, undefined behaviour in ReleaseFast).
        while (e > m1 and e < ev.text.len and (ev.text[e] & 0xC0) == 0x80) e -= 1;
        start = s;
        end = e;
    }
    return .{ .start = start, .bytes = ev.text[start..end] };
}

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
    // M9: computed once per event; null when this row goes out whole.
    const win: ?Window = if (max_columns > 0) windowOf(&ev, max_columns) else null;
    if (compact) return emitLineRow(out, gpa, ev, win);
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
    try appendJsonString(out, gpa, if (win) |w| w.bytes else ev.text);
    // M9: the two fields travel ONLY on a windowed row, so a row that fits is
    // byte-identical to the pre-M9 event (the additive rule costs nothing in
    // the common case). Their presence is the signal: this `text` is a window,
    // it starts `win_start` bytes into the line and the line is `line_len` long.
    if (win) |w| {
        try out.appendSlice(gpa, ",\"win_start\":");
        try appendInt(out, gpa, w.start);
        try out.appendSlice(gpa, ",\"line_len\":");
        try appendInt(out, gpa, ev.text.len);
    }
    try out.appendSlice(gpa, ",\"inverted\":");
    try out.appendSlice(gpa, if (ev.inverted) "true" else "false");
    try out.appendSlice(gpa, "}\n");
}

/// M4: procedencia del fichero, UNA vez por fichero y ANTES de sus eventos.
/// `sha256` y `size` son de los bytes que zgrep leyó y buscó (no de una
/// relectura): así la afirmación "este match está en este contenido" es
/// verificable con `sha256sum`. `mtime_ns` sale de `statx` (null si no hay
/// fichero, p. ej. stdin). `source`: `file`, `file-utf16` (offsets sobre el
/// texto decodificado, hash del fichero crudo), `pre` (hash de la salida del
/// preprocesador) o `stdin`.
pub fn emitProvenanceEvent(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    path: []const u8,
    sha256: *const [32]u8,
    size: usize,
    mtime_ns: ?i128,
    source: []const u8,
) Allocator.Error!void {
    try out.appendSlice(gpa, json_prefix ++ "\"type\":\"provenance\",\"path\":");
    try appendJsonString(out, gpa, path);
    try out.appendSlice(gpa, ",\"sha256\":\"");
    const hex = std.fmt.bytesToHex(sha256.*, .lower);
    try out.appendSlice(gpa, &hex);
    try out.appendSlice(gpa, "\",\"size\":");
    try appendInt(out, gpa, size);
    try out.appendSlice(gpa, ",\"mtime_ns\":");
    if (mtime_ns) |m| {
        var buf: [48]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "{d}", .{m}) catch unreachable;
        try out.appendSlice(gpa, t);
    } else try out.appendSlice(gpa, "null");
    try out.appendSlice(gpa, ",\"source\":\"");
    try out.appendSlice(gpa, source);
    try out.appendSlice(gpa, "\"}\n");
}

fn emitLineRow(out: *std.ArrayList(u8), gpa: Allocator, ev: LineEvent, win: ?Window) Allocator.Error!void {
    try out.appendSlice(gpa, "[\"");
    try out.append(gpa, switch (ev.kind) {
        .match => 'm',
        .context => 'c',
        .passthru => 'p',
        .occurrence => 'o',
    });
    if (ev.inverted) try out.append(gpa, 'v');
    // M9: the `w` suffix marks a windowed row, which carries two extra
    // elements after the text.
    if (win != null) try out.append(gpa, 'w');
    try out.appendSlice(gpa, "\",");
    try appendInt(out, gpa, ev.line_no);
    if (ev.span) |sp| {
        const len = sp.end - sp.start;
        try out.append(gpa, ',');
        try appendInt(out, gpa, sp.start + 1);
        try out.append(gpa, ',');
        try appendInt(out, gpa, ev.line_start + sp.start);
        try out.append(gpa, ',');
        try appendInt(out, gpa, len);
        try out.append(gpa, ',');
        const text: []const u8 = if (win) |w| w.bytes else ev.text;
        try appendJsonString(out, gpa, text);
        // The match is derivable from the EMITTED text only. With a window the
        // column counts from the start of the line, so the match moves inside
        // the text by the window start.
        const shift: usize = if (win) |w| sp.start - w.start else sp.start;
        const m = ev.line_bytes[sp.start..sp.end];
        const derivable = shift + len <= text.len and std.mem.eql(u8, text[shift .. shift + len], m);
        if (!derivable) {
            try out.append(gpa, ',');
            try appendJsonString(out, gpa, m);
        }
        if (win) |w| {
            try out.append(gpa, ',');
            try appendInt(out, gpa, w.start);
            try out.append(gpa, ',');
            try appendInt(out, gpa, ev.text.len);
        }
    } else {
        try out.append(gpa, ',');
        try appendJsonString(out, gpa, ev.text);
    }
    try out.appendSlice(gpa, "]\n");
}

/// Cabecera de fichero en `--json=compact`: `{"path":P}` o, con
/// `--provenance`, `{"path":P,"sha256":..,"size":..,"mtime_ns":..,"source":..}`.
pub fn emitCompactFileHeader(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    path: []const u8,
    prov: ?struct { sha256: *const [32]u8, size: usize, mtime_ns: ?i128, source: []const u8 },
) Allocator.Error!void {
    try out.appendSlice(gpa, "{\"path\":");
    try appendJsonString(out, gpa, path);
    if (prov) |p| {
        // base64url sin relleno (RFC 4648 §5): el MISMO hash en 43 caracteres.
        // Medido con un BPE real: 31,9 tokens por hash frente a 56,5 en hex.
        // zgrep/1 sigue en hex (lo que imprime sha256sum).
        try out.appendSlice(gpa, ",\"sha256_b64u\":\"");
        var b64: [43]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&b64, p.sha256);
        try out.appendSlice(gpa, &b64);
        try out.appendSlice(gpa, "\",\"size\":");
        try appendInt(out, gpa, p.size);
        try out.appendSlice(gpa, ",\"mtime_ns\":");
        if (p.mtime_ns) |m| {
            var buf: [48]u8 = undefined;
            try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "{d}", .{m}) catch unreachable);
        } else try out.appendSlice(gpa, "null");
        try out.appendSlice(gpa, ",\"source\":\"");
        try out.appendSlice(gpa, p.source);
        try out.append(gpa, '"');
    }
    try out.appendSlice(gpa, "}\n");
}

/// `-l` / `-L`.
pub fn emitFileEvent(out: *std.ArrayList(u8), gpa: Allocator, path: []const u8, with_match: bool) Allocator.Error!void {
    if (compact) {
        try out.appendSlice(gpa, if (with_match) "[\"l\"," else "[\"L\",");
        try appendJsonString(out, gpa, path);
        try out.appendSlice(gpa, "]\n");
        return;
    }
    try out.appendSlice(gpa, json_prefix ++ "\"type\":\"file\",\"path\":");
    try appendJsonString(out, gpa, path);
    try out.appendSlice(gpa, ",\"mode\":\"");
    try out.appendSlice(gpa, if (with_match) "with-match" else "without-match");
    try out.appendSlice(gpa, "\"}\n");
}

/// Un fichero tratado como binario (`--binary-files=note|binary`): nunca su
/// contenido, solo el formato (`pdf`, `elf`, ..., o `nul`), si se busco y, si
/// se busco, si coincidio. compact: `["b",P,fmt,searched,matched]`.
pub fn emitBinaryEvent(out: *std.ArrayList(u8), gpa: Allocator, path: []const u8, format: []const u8, searched: bool, matched: ?bool) Allocator.Error!void {
    if (compact) {
        try out.appendSlice(gpa, "[\"b\",");
        try appendJsonString(out, gpa, path);
        try out.append(gpa, ',');
        try appendJsonString(out, gpa, format);
        try out.appendSlice(gpa, if (searched) ",true," else ",false,");
        try out.appendSlice(gpa, if (matched) |m| (if (m) "true" else "false") else "null");
        try out.appendSlice(gpa, "]\n");
        return;
    }
    try out.appendSlice(gpa, json_prefix ++ "\"type\":\"binary\",\"path\":");
    try appendJsonString(out, gpa, path);
    try out.appendSlice(gpa, ",\"format\":");
    try appendJsonString(out, gpa, format);
    try out.appendSlice(gpa, if (searched) ",\"searched\":true" else ",\"searched\":false");
    try out.appendSlice(gpa, ",\"matched\":");
    try out.appendSlice(gpa, if (matched) |m| (if (m) "true" else "false") else "null");
    try out.appendSlice(gpa, "}\n");
}

/// `-c` (recuento de líneas) o `--count-matches` (recuento de ocurrencias). Uno
/// de los dos campos viene informado; el otro `null`, para que el schema no
/// cambie entre modos.
pub fn emitCountEvent(out: *std.ArrayList(u8), gpa: Allocator, path: []const u8, lines: ?usize, matches: ?usize) Allocator.Error!void {
    if (compact) {
        try out.appendSlice(gpa, if (lines != null) "[\"#\"," else "[\"#m\",");
        try appendJsonString(out, gpa, path);
        try out.append(gpa, ',');
        try appendInt(out, gpa, lines orelse matches orelse 0);
        try out.appendSlice(gpa, "]\n");
        return;
    }
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

test "zgrep/1c: filas posicionales; match solo si no se deriva del texto" {
    const gpa = std.testing.allocator;
    compact = true;
    defer compact = false;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const m = Match{ .start = 5, .end = 8 };
    try emitLineEvent(&out, gpa, .{ .path = "a", .line_no = 2, .line_start = 10, .line_bytes = "beta HIT", .span = m, .kind = .match, .text = "beta HIT" });
    try emitLineEvent(&out, gpa, .{ .path = "a", .line_no = 2, .line_start = 10, .line_bytes = "beta HIT", .span = m, .kind = .match, .text = "beta XX" });
    try emitLineEvent(&out, gpa, .{ .path = "a", .line_no = 3, .line_start = 19, .line_bytes = "gamma", .span = null, .kind = .context, .text = "gamma" });
    try emitLineEvent(&out, gpa, .{ .path = "a", .line_no = 4, .line_start = 25, .line_bytes = "x", .span = null, .kind = .match, .text = "x", .inverted = true });
    try emitFileEvent(&out, gpa, "b", true);
    try emitCountEvent(&out, gpa, "c", null, 7);
    try std.testing.expectEqualStrings(
        \\["m",2,6,15,3,"beta HIT"]
        \\["m",2,6,15,3,"beta XX","HIT"]
        \\["c",3,"gamma"]
        \\["mv",4,"x"]
        \\["l","b"]
        \\["#m","c",7]
        \\
    , out.items);
}

// ---------------------------------------------------------------------------
// M9: --max-columns (ventana alrededor del match)
// ---------------------------------------------------------------------------

/// Línea de `n` bytes con HIT en `m0`. Los rellenos son letras distintas para
/// que un off-by-one sea visible en la aserción de cadena.
fn longLine(buf: []u8, m0: usize) []const u8 {
    @memset(buf[0..m0], 'x');
    @memcpy(buf[m0 .. m0 + 3], "HIT");
    @memset(buf[m0 + 3 ..], 'y');
    return buf;
}

test "M9: ventana zgrep/1: text recorta, win_start/line_len dicen dónde está" {
    const gpa = std.testing.allocator;
    max_columns = 20;
    defer max_columns = 0;
    var buf: [60]u8 = undefined;
    const line = longLine(&buf, 28); // 28 x + HIT + 29 y
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try emitLineEvent(&out, gpa, .{
        .path = "a.txt", .line_no = 1, .line_start = 1000, .line_bytes = line, .span = .{ .start = 28, .end = 31 }, .kind = .match, .text = line,
    });
    // 28 bytes de margen a cada lado del recorte; col y byte_start siguen
    // contando la línea ENTERA (col 29, byte_start 1028, byte_end 1031).
    try std.testing.expectEqualStrings(
        \\{"schema":"zgrep/1","type":"match","path":"a.txt","line":1,"column":29,"byte_start":1028,"byte_end":1031,"match":"HIT","text":"xxxxxxxxHITyyyyyyyyy","win_start":20,"line_len":60,"inverted":false}
        \\
    , out.items);
}

test "M9: sin ventana cuando la línea cabe: bytes idénticos a los de antes" {
    const gpa = std.testing.allocator;
    max_columns = 400;
    defer max_columns = 0;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try emitLineEvent(&out, gpa, .{
        .path = "a.txt", .line_no = 1, .line_start = 0, .line_bytes = "short HIT line", .span = .{ .start = 6, .end = 9 }, .kind = .match, .text = "short HIT line",
    });
    try std.testing.expect(std.mem.indexOf(u8, out.items, "win_start") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"text\":\"short HIT line\"") != null);
}

test "M9: fila sin span no se recorta NUNCA (no hay match que centrar)" {
    const gpa = std.testing.allocator;
    max_columns = 8;
    defer max_columns = 0;
    var buf: [300]u8 = undefined;
    const line = longLine(&buf, 100);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try emitLineEvent(&out, gpa, .{ .path = "a", .line_no = 7, .line_start = 0, .line_bytes = line, .span = null, .kind = .context, .text = line });
    // El text del evento es la línea ENTERA: se localiza el campo y se compara.
    const marker = ",\"text\":\"";
    const at = std.mem.indexOf(u8, out.items, marker).? + marker.len;
    try std.testing.expectEqualStrings(line, out.items[at .. at + line.len]);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "win_start") == null);
}

test "M9: si el match solo no cabe en N, la ventana ES el match" {
    max_columns = 3;
    defer max_columns = 0;
    var buf: [200]u8 = undefined;
    const line = longLine(&buf, 50);
    const w = windowOf(&.{ .path = "a", .line_no = 1, .line_start = 0, .line_bytes = line, .span = .{ .start = 50, .end = 53 }, .kind = .match, .text = line }, 3).?;
    try std.testing.expectEqual(@as(usize, 50), w.start);
    try std.testing.expectEqualStrings("HIT", w.bytes);
}

test "M9: la ventana no parte un carácter UTF-8 (ni al inicio ni al final)" {
    max_columns = 9;
    defer max_columns = 0;
    // 8a + ññññ (8 B) + HIT + 40b: el corte cae en el segundo byte de una ñ.
    var line: [71]u8 = undefined;
    @memset(line[0..8], 'a');
    @memcpy(line[8..16], "\xC3\xB1\xC3\xB1\xC3\xB1\xC3\xB1"[0..]);
    @memcpy(line[16..19], "HIT");
    @memset(line[19..], 'b');
    const w1 = windowOf(&.{ .path = "a", .line_no = 1, .line_start = 0, .line_bytes = &line, .span = .{ .start = 16, .end = 19 }, .kind = .match, .text = &line }, 9).?;
    try std.testing.expectEqual(@as(usize, 14), w1.start);
    try std.testing.expectEqualStrings("ñHITbbb", w1.bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(w1.bytes));

    // 10a + HIT + ññññ + 30b: el corte derecho cae dentro de una ñ.
    var line2: [51]u8 = undefined;
    @memset(line2[0..10], 'a');
    @memcpy(line2[10..13], "HIT");
    @memcpy(line2[13..21], "\xC3\xB1\xC3\xB1\xC3\xB1\xC3\xB1"[0..]);
    @memset(line2[21..], 'b');
    const w2 = windowOf(&.{ .path = "a", .line_no = 1, .line_start = 0, .line_bytes = &line2, .span = .{ .start = 10, .end = 13 }, .kind = .match, .text = &line2 }, 8).?;
    try std.testing.expectEqual(@as(usize, 8), w2.start);
    try std.testing.expectEqualStrings("aaHITñ", w2.bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(w2.bytes));
}

test "M9: --replace (el texto emitido no ES la línea) no se recorta" {
    var buf: [200]u8 = undefined;
    const line = longLine(&buf, 50);
    const replaced = "SUSTITUIDA";
    try std.testing.expect(windowOf(&.{ .path = "a", .line_no = 1, .line_start = 0, .line_bytes = line, .span = .{ .start = 50, .end = 53 }, .kind = .match, .text = replaced }, 8) == null);
}

test "M9: fila compacta ventana: sufijo w y dos elementos posicionales" {
    const gpa = std.testing.allocator;
    compact = true;
    max_columns = 20;
    defer compact = false;
    defer max_columns = 0;
    var buf: [60]u8 = undefined;
    const line = longLine(&buf, 28);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try emitLineEvent(&out, gpa, .{
        .path = "a", .line_no = 1, .line_start = 1000, .line_bytes = line, .span = .{ .start = 28, .end = 31 }, .kind = .match, .text = line,
    });
    // [t=w, line, col, byte_start, len, ventana, win_start, line_len]
    try std.testing.expectEqualStrings(
        \\["mw",1,29,1028,3,"xxxxxxxxHITyyyyyyyyy",20,60]
        \\
    , out.items);
}

test "M9: fila compacta windowed en contexto invertido (-v) lleva mvW" {
    const gpa = std.testing.allocator;
    compact = true;
    max_columns = 20;
    defer compact = false;
    defer max_columns = 0;
    var buf: [60]u8 = undefined;
    const line = longLine(&buf, 28);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try emitLineEvent(&out, gpa, .{
        .path = "a", .line_no = 3, .line_start = 0, .line_bytes = line, .span = .{ .start = 28, .end = 31 }, .kind = .match, .text = line, .inverted = true,
    });
    try std.testing.expect(std.mem.startsWith(u8, out.items, "[\"mvw\",3,29,28,3,"));
}

test "M9: ventana que llega al final de la línea no lee fuera del slice" {
    // Match cerca del final: e = min(len, s0 + w) = len. Antes de la
    // corrección, la alineación UTF-8 leía text[len] (panic en Debug).
    var line: [105]u8 = undefined;
    @memset(line[0..100], 'x');
    @memcpy(line[100..103], "HIT");
    @memcpy(line[103..105], "yy");
    const w = windowOf(&.{ .path = "a", .line_no = 1, .line_start = 0, .line_bytes = &line, .span = .{ .start = 100, .end = 103 }, .kind = .match, .text = &line }, 10).?;
    try std.testing.expectEqual(@as(usize, 95), w.start);
    try std.testing.expectEqualStrings("xxxxxHITyy", w.bytes);

    // La línea termina en un carácter multibyte completo: la ventana lo
    // conserva entero (el último byte es de continuación, pero e == len).
    var line2: [105]u8 = undefined;
    @memset(line2[0..100], 'x');
    @memcpy(line2[100..103], "HIT");
    @memcpy(line2[103..105], "\xC3\xB1");
    const w2 = windowOf(&.{ .path = "a", .line_no = 1, .line_start = 0, .line_bytes = &line2, .span = .{ .start = 100, .end = 103 }, .kind = .match, .text = &line2 }, 10).?;
    try std.testing.expectEqual(@as(usize, 95), w2.start);
    try std.testing.expectEqualStrings("xxxxxHITñ", w2.bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(w2.bytes));
}
