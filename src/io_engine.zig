//! io_engine.zig — Despachador híbrido de I/O: síncrono vs io_uring.
//!
//! El modo `uring` y el modo `auto` comparten un único mecanismo: una sonda
//! acotada de page cache con `preadv2(..., RWF_NOWAIT)`. La sonda devuelve los
//! bytes si la página ya está en RAM y `EAGAIN` si el kernel tendría que dormir
//! el hilo esperando al almacenamiento. Eso la convierte en una decisión, no en
//! un mecanismo de lectura: en caliente cuesta lo mismo que la lectura (101%,
//! medido) y en frío cuesta 2,3 µs sin comprar nada, por lo que se paga un
//! número acotado de veces y nunca por fichero.
//!
//! Evidencia completa: evidence/hybrid-io-engine/DISENO.md.
//!
//! No se usa `RWF_DONTCACHE`: medido en ext4/kernel 7.0, se acepta pero no
//! expulsa páginas (posix_fadvise(DONTNEED) sí).

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

/// Lo que la CLI acepta y lo que el pipeline recibe.
pub const Mode = enum { sync, uring, auto };

/// Presupuesto de sondas por corrida. 12 trabajadores x 8 ficheros = 96 como
/// máximo, medido: 96 x 2,3 µs = 0,22 ms, el 0,1% de lo que está en juego.
pub const probe_budget: u32 = 96;
/// Con esta proporción de misses ya se ve que el árbol no está en RAM.
pub const promote_misses: u32 = 16;

pub const Decision = enum {
    /// El árbol está caliente en RAM: el enjambre síncrono gana (medido 1,22x).
    sync,
    /// El árbol está frío: io_uring gana (medido 1,25x, 208 ms de diferencia).
    uring,
};

pub const Probe = union(enum) {
    cached: usize,
    cold,
    /// El FS o el kernel no admiten RWF_NOWAIT (overlayfs, FUSE, no-Linux).
    /// No es una señal: el modo `auto` degrada a síncrono y lo dice.
    unsupported,
};

/// Sonda de page cache sin bloqueo. Linux-only por construcción: `preadv2` es
/// de Linux, así que en cualquier otro objetivo la respuesta honesta es
/// "no sé", no "caliente".
pub fn probe(fd: linux.fd_t, buf: []u8) Probe {
    if (builtin.os.tag != .linux) return .unsupported;
    var iov = [1]std.posix.iovec{.{ .base = buf.ptr, .len = buf.len }};
    const rc = linux.preadv2(fd, &iov, 1, 0, linux.RWF.NOWAIT);
    return switch (linux.errno(rc)) {
        .SUCCESS => .{ .cached = rc },
        .AGAIN => .cold,
        // NOSYS (syscall ausente) / EOPNOTSUPP / EINVAL = el flag no se puede
        // usar aquí. No es una señal: se contesta "no sé".
        .NOSYS, .OPNOTSUPP, .INVAL => .unsupported,
        else => .unsupported,
    };
}

/// Sonda de page cache sin bloqueo sobre una ruta: abre, pregunta y cierra.
/// El `open` va aquí para que `kamikaze.zig` no tenga que importar nada de
/// Linux: el modulo entero es Linux-only por construcción, y fuera de Linux
/// responde `unsupported` sin abrir nada.
pub fn probePath(io: std.Io, path: [:0]const u8) Probe {
    if (builtin.os.tag != .linux) return .unsupported;
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return .unsupported;
    const fd: linux.fd_t = @intCast(@as(isize, @bitCast(rc)));
    defer _ = linux.close(fd);
    var buf: [256 * 1024]u8 = undefined;
    _ = io;
    return probe(fd, &buf);
}

/// Estado compartido por los trabajadores de una corrida. Los contadores son
/// atómicos porque la señal es del árbol (todos leen el mismo almacenamiento),
/// no del trabajador: un motor heterogéneo en una sola corrida haría que
/// `--stats io_engine=` no significara nada.
pub const State = struct {
    /// 0 = sin decidir, 1 = sync, 2 = uring, 3 = sync forzado por "unsupported".
    verdict: std.atomic.Value(u8) = .init(0),
    probes: std.atomic.Value(u32) = .init(0),
    misses: std.atomic.Value(u32) = .init(0),
    hits: std.atomic.Value(u32) = .init(0),

    pub fn settled(self: *const State) bool {
        return self.verdict.load(.acquire) != 0;
    }

    pub fn decision(self: *const State) Decision {
        return if (self.verdict.load(.acquire) == 2) .uring else .sync;
    }

    /// Registra una sonda y devuelve la decisión si esta sonda cierra la
    /// muestra. `null` = aún sin decidir.
    pub fn record(self: *State, p: Probe) ?Decision {
        const probes = self.probes.fetchAdd(1, .monotonic) + 1;
        var misses = self.misses.load(.monotonic);
        switch (p) {
            .cached => _ = self.hits.fetchAdd(1, .monotonic),
            .cold => misses = self.misses.fetchAdd(1, .monotonic) + 1,
            .unsupported => {
                _ = self.verdict.cmpxchgStrong(0, 3, .release, .acquire);
                return .sync;
            },
        }
        const d = decide(probes, misses) orelse return null;
        // `uring` tiene prioridad: equivocarse en frío cuesta 42x mas que en
        // caliente (208 ms frente a 5 ms, medido), asi que si hay carreras se
        // resuelve hacia el motor asincrono.
        if (d == .uring) {
            _ = self.verdict.cmpxchgStrong(0, 2, .release, .acquire);
        } else if (self.misses.load(.acquire) < promote_misses) {
            _ = self.verdict.cmpxchgStrong(0, 1, .release, .acquire);
        }
        return d;
    }

    /// Función PURA: la política de promoción, sin kernel ni heap.
    /// `unsupported` ya viene resuelto en `verdict` por `record`.
    pub fn decide(probes: u32, misses: u32) ?Decision {
        if (misses >= promote_misses) return .uring;
        if (probes >= probe_budget) return .sync;
        return null;
    }
};

// ---------------------------------------------------------------------------
// tests

const testing = std.testing;

test "decision: una sola miss no promociona" {
    try testing.expect(State.decide(1, 1) == null);
}

test "decision: el umbral de misses promociona a uring" {
    try testing.expect(State.decide(8, promote_misses) == .uring);
}

test "decision: el umbral de misses se respeta exactamente" {
    try testing.expect(State.decide(8, promote_misses - 1) == null);
    try testing.expect(State.decide(probe_budget - 1, promote_misses - 1) == null);
    try testing.expect(State.decide(8, promote_misses) == .uring);
    // agotar el presupuesto cierra la muestra en sincrono, no en null
    try testing.expect(State.decide(probe_budget, promote_misses - 1) == .sync);
}

test "decision: agotar el presupuesto sin misses deja el síncrono" {
    try testing.expect(State.decide(probe_budget, promote_misses - 1) == .sync);
    try testing.expect(State.decide(probe_budget + 500, 0) == .sync);
}

test "estado: unsupported resuelve en síncrono sin más pruebas" {
    var st = State{};
    try testing.expect(st.record(.{ .cached = 0 }) == null);
    try testing.expectEqual(Decision.sync, st.record(.unsupported));
    try testing.expect(st.settled());
    try testing.expectEqual(Decision.sync, st.decision());
}

test "estado: los contadores son acumulativos" {
    var st = State{};
    try testing.expect(st.record(.{ .cached = 0 }) == null);
    try testing.expect(st.record(.cold) == null);
    try testing.expect(st.record(.{ .cached = 0 }) == null);
    try testing.expectEqual(@as(u32, 3), st.probes.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), st.misses.load(.monotonic));
    try testing.expectEqual(@as(u32, 2), st.hits.load(.monotonic));
    try testing.expect(!st.settled());
}

test "estado: promote_misses misses cierran la muestra en uring" {
    var st = State{};
    var i: u32 = 0;
    var dec: ?Decision = null;
    while (i < promote_misses) : (i += 1) dec = st.record(.cold);
    try testing.expectEqual(Decision.uring, dec.?);
    try testing.expectEqual(Decision.uring, st.decision());
}

test "sonda: fuera de Linux responde unsupported, nunca caliente" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;
    // Ojo: `undefined[0..0]` no compila en Windows (el slice de un `undefined`
    // tipado no es válido allí), y eso rompía el job de Windows del CI.
    var empty: [0]u8 = undefined;
    try testing.expect(probe(0, empty[0..0]) == .unsupported);
    // Y sobre una ruta tampoco debe abrir nada: contesta "no sé" y ya.
    try testing.expect(probePath(undefined, "src/main.zig") == .unsupported);
}
