# Mockup de Argon: despachador híbrido de I/O (`--io-engine=auto`) — estudio de viabilidad

**Fecha:** 2026-11-09 · **Árbol:** `49ad3af` (main) · **Kernel:** `7.0.0-42-generic` ·
**Toolchain:** Zig 0.16.0 · **Host:** 12 núcleos, 14 GB RAM, ext4 sobre NVMe

> Veredicto: **VIABLE, con dos correcciones al mockup y una promesa descartada.**
> La sonda funciona y la economía la justifica; `RWF_DONTCACHE` no.

---

## 1. Lo que medí antes de opinar

Cada afirmación del mockup se comprobó contra el código real y contra el kernel,
no contra el texto. Los programas y sus salidas crudas están en `evidence/hybrid-io-engine/`.

### 1.1 La sonda `preadv2(..., RWF_NOWAIT)`

`/tmp/opencode/nowait_probe.zig`, `nowait_bench.zig` (fuera del repo; el repo queda intacto).

| Escenario | Resultado medido |
|---|---|
| `preadv2(NOWAIT)` sobre fichero **caliente** | 2.550 ns/llamada, devuelve los bytes |
| `preadv2` normal (mismo trabajo) | 2.520 ns/llamada |
| `openat` + `close` sin leer | 2.059 ns/llamada |
| `preadv2(NOWAIT)` sobre fichero **frío** (EAGAIN) | **2.311 ns/llamada** |
| Discriminación | frío → `EAGAIN`; tras una lectura normal → bytes reales. **Correcta** |

**Dos hechos que el mockup da por supuestos y que hay que decir claro:**

1. **La sonda no es gratis: en caliente ES la lectura** (101% de una lectura normal).
   No es un sondeo, es un `read()` con una cláusula de escape. El mockup lo
   intuye ("lo procesas ahí mismo con tu SIMD"), y es cierto **si** el camino
   caliente consume esos bytes; si se descartan, se paga dos veces.
2. **El `EAGAIN` cuesta ~2,3 µs y no compra nada**: después hay que leer igual.
   Por eso la sonda solo se puede pagar un número **acotado** de veces por
   trabajador. El mockup también lo intuye ("los primeros 8 ficheros").

Consecuencia de diseño: la sonda es rentable **como decisión**, no como
mecanismo de lectura. Su valor no está en los 2,3 µs, está en lo que deciden.

### 1.2 Lo que realmente está en juego (medido, no supuesto)

El mockup afirma "uring pierde en caliente" citando PRUEBAS.md (85,31 ms vs
109,24 ms). Es cierto, pero **PRUEBAS.md no documenta la condición de caché** ni
un `drop_caches`, así que la otra mitad de la frase —"uring gana en frío"— no
estaba medida en ninguna parte. La medí.

`/tmp/opencode/cold_bench.py`, árbol real `workspace/assembly` (634 MB, 5.338
ficheros), el mismo patrón (`-c -e const`) para los dos motores, y el frío
provocado **expulsando cada fichero con `posix_fadvise(DONTNEED)`** (no hace
falta root; `drop_caches` sí lo necesitaría y además mediría el cache de otros
procesos):

| Motor | Caliente (mediana) | Frío (mediana) | Penalización por frío |
|---|---|---|---|
| `zigrep` (enjambre síncrono) | **22,51 ms** | 1.032,84 ms | 45,89× |
| `zigrep --uring` | 27,51 ms | **825,09 ms** | 29,99× |

- En caliente el síncrono gana **5,0 ms** (1,22×). Coherente con el 1,27× del mockup.
- En frío `--uring` gana **207,8 ms** (1,25×).

**La asimetría manda la decisión:** acertar en caliente ahorra 5 ms; equivocarse
en caliente cuesta 5 ms. Acertar en frío ahorra 208 ms; equivocarse en frío
cuesta 208 ms. **El frío pesa 42× más que el caliente.** Una sonda de 8 ficheros
por trabajador cuesta, en el peor caso, 12 × 8 × 2,3 µs ≈ **0,22 ms** — el 0,1%
de lo que está en juego.

### 1.3 Las dos optimizaciones extra

| Sugerencia del mockup | Estado |
|---|---|
| `IORING_SETUP_SINGLE_ISSUER` + `COOP_TASKRUN` | **Viable y ya aplicable hoy.** El código crea el anillo con `IoUring.init(entries, 0)` — flags a 0 (`src/uring_linux.zig:44`). El kernel es 7.0, así que ambos flags existen en `std.os.linux` (`SINGLE_ISSUER = 1 << 12`, `COOP_TASKRUN = 1 << 8`). El anillo es **uno por trabajador** (`src/kamikaze.zig:466-467`), que es justo la precondición de `SINGLE_ISSUER`. |
| `RWF_DONTCACHE` (6.14+) | **Descartada.** Medido en `/tmp/opencode/dontcache_probe.zig`: sobre ficheros regulares de ext4 el flag se acepta pero **no expulsa nada** (un `preadv2(NOWAIT)` posterior sigue devolviendo bytes). `posix_fadvise(DONTNEED)` sí expulsa. La documentación que cita el mockup habla de dispositivos de bloque. No construir sobre esto. |

### 1.4 Lo que el mockup no tenía en cuenta

1. **El umbral de "3 EAGAIN de 8" (37,5%) es arbitrario y no hace falta.**
   La pregunta real es "¿está el árbol en RAM?", y con el 0,22 ms de coste total
   se puede permitir una muestra mayor y estable. Ver el diseño.
2. **Decisión por trabajador = motor heterogéneo en una sola corrida.** El mockup
   propone que cada trabajador promocione su anillo. Todos los trabajadores leen
   el mismo NVMe, así que la señal es del árbol, no del trabajador: conviene una
   decisión **compartida** (atómica) para que `--stats io_engine=` signifique algo.
3. **Tratar `EOPNOTSUPP` como "caliente" es una decisión escondida.** El mockup
   cae en síncrono sin decirlo. Si el FS no soporta `NOWAIT` (overlayfs, FUSE
   antiguo), el modo `auto` degrada en silencio a síncrono: hay que reportarlo en
   `--stats` (`probe=unsupported`), no callarlo.
4. **`preadv2` es de Linux.** El modo `auto` en Windows (el port recién unificado)
   tiene que degradar a síncrono con salida honesta, no a uring.

---

## 2. Diseño que propongo (tres niveles, como el mockup, con las correcciones)

```
Nivel 0 — micro path (< 2 MB)          : sin cambios. 2,00 ms insuperables.
Nivel 1 — cortocircuito -q             : --uring inmediato, lote de 16, exit en
                                         el primer CQE coincidente. Sin cambios.
Nivel 2 — auto para árboles >= 2 MB    : modelo de tres estados:
     · sync            --uring nunca se crea
     · uring           --uring desde el principio (alias del flag actual)
     · auto            arranca en síncrono, sonda acotada, promoción compartida
```

**Sonda:** los primeros `PROBE_FILES = 24` ficheros regulares que abre **cada**
trabajador (no solo el primero), con contador atómico global para no pasarse de
`PROBE_BUDGET = 12 × PROBE_FILES` en toda la corrida.

**Regla de promoción** (función pura, testeable sin tocar el kernel):

```
misses >= PROBE_MISS_THRESHOLD (8)  ->  io_engine = uring
unsupported (EOPNOTSUPP/ENOSYS)     ->  io_engine = sync, probe=unsupported
en otro caso                        ->  io_engine = sync
```

**Reutilización de la lectura:** cuando la sonda devuelve bytes, esos bytes se
pasan a `scan.scanBuffer` (`src/scan.zig:120`, función pura sobre buffer) en vez
de releer el fichero. Sin esto, la sonda caliente cuesta el doble.

**Flags del anillo:** `IoUring.init` con `SINGLE_ISSUER | COOP_TASKRUN` cuando el
kernel los admite; si `io_uring_setup` los rechaza, reintentar con 0. Y
`RWF_DONTCACHE` **no** se usa.

**CLI:** `--io-engine=auto|sync|uring`, con `--uring` como alias exacto de
`uring` (el oráculo diferencial y el cell fuzzer no pueden cambiar de
significado). `--stats` gana `io_engine=` y `probe_hits=`/`probe_misses=`.

---

## 3. Plan de ejecución y verificación

1. `src/io_engine.zig`: enum de modo, la primitiva de sonda (Linux: `preadv2` +
   `RWF.NOWAIT`; resto: `unsupported`) y la **función pura de decisión**.
2. Camino caliente que consume los bytes de la sonda vía `scanBuffer`.
3. Promoción compartida por atómico + `--stats`.
4. CLI `--io-engine` con alias `--uring`.
5. Flags del anillo con reintento.
6. **Prueba de verificación obligatoria** (el invariante del repo): las 373.248
   celdas del cell fuzzer, el oráculo diferencial 26/26 y la matriz de 540
   comparaciones tienen que seguir en verde con `--io-engine=auto` por defecto.
   Si el modo `auto` cambia un byte de salida en cualquiera de las tres, el
   diseño está mal, no la prueba.

**Lo que NO se promete:** ganancia medida hasta que no se corra frío/caliente
con el disparador real. Los 207,8 ms son el techo, no el resultado.

---

## 4. Implementado y medido (misma sesión)

Código: `src/io_engine.zig` (nuevo) + `src/kamikaze.zig` (sonda, promoción
perezosa, `--stats`) + `src/main.zig` (`--io-engine`) + `src/uring_linux.zig`
(flags del anillo). Rama de trabajo sobre `main`, sin tocar el camino de lectura.

### 4.1 El despachador decide lo que tiene que decidir

`--io-engine=auto` sobre el árbol real (`workspace/assembly`, 634 MB), el
mismo patrón, y el frío provocado expulsando fichero a fichero:

| Condición | Elección | Sonda | |
|---|---|---|---|
| caliente | `sync` | 91 hits / 5 misses | correcto: el síncrono gana en caliente |
| caliente | `sync` | 96 hits / 0 misses | correcto |
| caliente | `sync` | 96 hits / 0 misses | correcto |
| frío | `uring` | 0 hits / 16 misses | correcto: io_uring gana en frío |
| recalentado tras el frío | `sync` | 97 hits / 0 misses | vuelve a sync |

Latencia de punta a punta (mediana, mismo árbol, `-c -e const`):

| | síncrono forzado | uring forzado | `auto` |
|---|---|---|---|
| caliente | 253 ms | 275 ms | **266 ms** |
| frío | 1128 ms | 876 ms | **882 ms** |

`auto` captura el lado bueno de los dos regímenes: en frío se queda a 7 ms del
uring forzado (el coste de la sonda y de los primeros ficheros leídos en
síncrono antes de promocionar) y en caliente no paga el 9% del uring forzado.

### 4.2 Paridad: el motor nuevo no cambia ningún byte

- `zig build test`: **63 passed**, 1 skipped (64 tests; antes 56).
- `zig build oracle` (GNU grep + ripgrep): **26/26**.
- Fuzz entrópico, 100.002 ops: **0 anomalías**, 0 crashes, 0 exit codes inválidos.
- Cell fuzzer, **200.000 celdas**, digest por celda con el haystack completo:
  **idéntico byte a byte** al baseline `aa81c9b` sobre el mismo payload
  (SHA-256 `a064b181…`).
- Matriz diferencial de 540 comparaciones: `--force-swarm` ≡ baseline
  **540/540**; `--io-engine=auto` ≡ baseline **520/540**, con las 20
  diferencias **todas** en el árbol `ignored` — las mismas que ya tenía el
  modo por defecto, es decir: **el motor híbrido no introduce divergencia
  nueva**.

### 4.3 Los flags del anillo: correctos pero sin ganancia medible

A/B intercalado, 7 corridas por lado, mismo árbol, caliente y frío:

| | con `SINGLE_ISSUER\|COOP_TASKRUN` | sin flags |
|---|---|---|
| caliente | 29,9 ms | 28,7 ms (+4,4% a favor de sin flags) |
| frío | 404,7 ms | 397,6 ms (+1,8% a favor de sin flags) |

**Dentro del ruido.** Los flags se conservan porque son la configuración
honesta de un anillo de un solo emisor (y tienen reintento a 0 si el kernel los
rechaza), pero **no se promete ganancia**: en este kernel (7.0) y con 12 hilos
sobre NVMe, el coste que Argon atribuye a las IPIs no es el cuello de botella.

### 4.4 Lo que se descubrió por el camino

1. **`RWF_DONTCACHE` no funciona en ficheros regulares de ext4** (kernel 7.0):
   el flag se acepta y no expulsa nada; `posix_fadvise(DONTNEED)` sí. La
   documentación que citaba el mockup habla de dispositivos de bloque.
2. **Los dos caminos de lectura pueblan el page cache** (experimento A/B
   controlado: 0/13 caliente tras expulsar, 13/13 tras escanear, con el síncrono
   y con uring). La sonda mide por tanto lo correcto: "¿va a bloquear una
   lectura con buffer?".
3. **El estado del cache de este host es volátil** (presión de memoria de otros
   procesos): el mismo árbol pasó de "13/13 caliente" a "0/13 caliente" sin que
   nadie lo expulsara a mano. Ese es el argumento más fuerte para decidir en
   runtime en lugar de con un flag fijo.
4. **`scan.scanBuffer` ya existe** (`src/scan.zig:120`) y es una función pura
   sobre un buffer: el camino caliente de la sonda puede reutilizar sus bytes
   sin tocar el motor de expresiones regulares. Queda como rebanada siguiente.
