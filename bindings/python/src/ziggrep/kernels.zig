//! kernels.zig — kernels nativos para el binding de Python.
//!
//! Se compilan con `zig build-lib -dynamic -OReleaseFast` y se cargan con
//! ctypes. Son el MISMO trabajo que hace ziggrep (contar líneas que contienen
//! una aguja, y la variante con plegado), exportado con ABI de C.
const std = @import("std");

const LineIter = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(self: *LineIter) ?[]const u8 {
        if (self.pos >= self.data.len) return null;
        const idx = std.mem.indexOfScalarPos(u8, self.data, self.pos, '\n') orelse self.data.len;
        const line = self.data[self.pos..idx];
        self.pos = if (idx < self.data.len) idx + 1 else self.data.len;
        return line;
    }
};

/// Líneas que contienen `needle`.
/// Si `out_total`/`out_bytes` no son null, escribe el número de líneas y de
/// bytes recorridos (para no llamar dos veces desde Python).
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

/// Ocurrencias TOTALES de `needle` (no líneas): equivalente a
/// `zgrep --count-matches`. `overlapping=true` cuenta también las que se
/// solapan (grep no lo hace).
export fn zg_count_matches(
    data: [*]const u8,
    len: usize,
    needle: [*]const u8,
    needle_len: usize,
    overlapping: bool,
) usize {
    var n: usize = 0;
    var i: usize = 0;
    const d = data[0..len];
    const nd = needle[0..needle_len];
    if (nd.len == 0) return 0;
    while (i + nd.len <= d.len) {
        if (std.mem.indexOf(u8, d[i..], nd)) |rel| {
            n += 1;
            i += if (overlapping) rel + 1 else rel + nd.len;
        } else break;
    }
    return n;
}

/// Igual que `zg_count` pero plegando mayúsculas ASCII. Es el caso `-i`, y
/// el más caro de Python porque `.lower()` copia el buffer entero.
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
    if (nd.len == 0) return true;
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

/// Suma de los bytes de todas las líneas (para benchmarks y para ver que el
/// cruce es real).
export fn zg_line_sum(data: [*]const u8, len: usize) u64 {
    var total: u64 = 0;
    var it = LineIter{ .data = data[0..len] };
    while (it.next()) |line| {
        for (line) |c| total +%= c;
    }
    return total;
}

/// Payload diminuto: aísla el coste del cruce.
export fn zg_tiny(a: [*]const u8, len: usize) u64 {
    var s: u64 = 0;
    for (a[0..len]) |c| s +%= c;
    return s;
}
