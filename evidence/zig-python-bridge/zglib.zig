//! Zig → Python: kernels nativos exportados con ABI de C.
//!
//! El trabajo que ziggrep ya hace: contar líneas que contienen una aguja (y
//! la variante con plegado de mayúsculas, que es la cara de Python).
//! Exportado como ABI de C para que Python lo cargue por ctypes sin rehacer
//! nada del lenguaje.
const std = @import("std");

/// Iterador de líneas sobre un buffer, con el offset correcto.
const LineIter = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(self: *LineIter) ?[]const u8 {
        if (self.pos >= self.data.len) return null;
        // indexOfScalarPos toma un índice ABSOLUTO dentro de `data` y devuelve
        // el absoluto del '\n' (o data.len si no hay más saltos).
        const idx = std.mem.indexOfScalarPos(u8, self.data, self.pos, '\n') orelse self.data.len;
        const line = self.data[self.pos..idx];
        self.pos = if (idx < self.data.len) idx + 1 else self.data.len;
        return line;
    }
};

/// Líneas que contienen `needle`. Si `out_total`/`out_bytes` no son null,
/// escribe el número de líneas y de bytes recorridos.
export fn zg_count(
    data: [*]const u8,
    len: usize,
    needle: [*]const u8,
    needle_len: usize,
    out_total: ?*usize,
    out_bytes: ?*usize,
) usize {
    var it = LineIter{ .data = data[0..len] };
    var hits: usize = 0;
    var lines: usize = 0;
    while (it.next()) |line| {
        lines += 1;
        if (std.mem.indexOf(u8, line, needle[0..needle_len]) != null) hits += 1;
    }
    if (out_total) |o| o.* = lines;
    if (out_bytes) |b| b.* = len;
    return hits;
}

/// Igual, plegando mayúsculas ASCII (el caso `-i`).
export fn zg_count_icase(
    data: [*]const u8,
    len: usize,
    needle_lower: [*]const u8,
    needle_len: usize,
) usize {
    const nd = needle_lower[0..needle_len];
    var it = LineIter{ .data = data[0..len] };
    var hits: usize = 0;
    while (it.next()) |line| {
        if (containsFolded(line, nd)) hits += 1;
    }
    return hits;
}

fn containsFolded(line: []const u8, nd: []const u8) bool {
    if (nd.len > line.len) return false;
    var i: usize = 0;
    while (i + nd.len <= line.len) : (i += 1) {
        var ok = true;
        for (nd, 0..) |c, k| {
            const b = line[i + k];
            const folded = if (b >= 'A' and b <= 'Z') b + 32 else b;
            if (folded != c) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

/// Suma de los bytes de todas las líneas (un cómputo que Python paga por
/// iteración y por objeto).
export fn zg_line_sum(data: [*]const u8, len: usize) u64 {
    var total: u64 = 0;
    var it = LineIter{ .data = data[0..len] };
    while (it.next()) |line| {
        for (line) |c| total +%= c;
    }
    return total;
}

/// Payload diminuto: mide el coste del cruce en sí.
export fn zg_tiny(a: [*]const u8, len: usize) u64 {
    var s: u64 = 0;
    for (a[0..len]) |c| s +%= c;
    return s;
}
