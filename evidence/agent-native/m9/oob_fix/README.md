# M9: lectura fuera del slice en `windowOf` (auditoria 2026-11-11)

**Defecto (e2d7c07):** `src/out_json.zig`, alineacion UTF-8 del final de la
ventana: `while (e > m1 and (ev.text[e] & 0xC0) == 0x80)`. `e` es un final
exclusivo; cuando la ventana llega al final de la linea, `e == text.len` y se
lee `text[len]`, un byte que no es de la linea.

* Debug / ReleaseSafe: `panic: index out of bounds: index 105, len 105`, rc 134.
  Reproduccion: una linea `x`*100 + `HIT` + `yy`, `zgrep --json --max-columns 10 HIT`.
* ReleaseFast (lo desplegado): comportamiento indefinido. La salida salia bien
  porque el byte siguiente suele ser `\n`. Si fuese un byte de continuacion
  UTF-8 (0x80-0xBF), la ventana se recortaba de mas.

**Por que los gates no lo vieron:** `m9_conformance.py` solo corria contra
ReleaseFast. El mismo diferencial contra un binario Debug daba 318 pass / 8 fail
(los casos de ventana + contexto/passthru abortan con SIGABRT, rc -6):
`m9_conformance_debug_BEFORE_e2d7c07.txt`.

**Correccion:** `e < ev.text.len` en la condicion del bucle; test unitario
nuevo (match cerca del final, con y sin caracter multibyte final), que falla
con el codigo de e2d7c07 y pasa con el corregido; paso nuevo de CI que corre el
diferencial M9 contra un Debug. Despues: 446 pass / 0 fail en Debug
(`m9_conformance_debug_AFTER.txt`).

Comando de ambas corridas (Linux, zig 0.16.0):
`zig build -Doptimize=Debug --prefix <dir>` y
`python3 evidence/agent-native/m9_conformance.py --zgrep <dir>/bin/zgrep`.

En la misma auditoria: `fix/SHA256SUMS.txt` se listaba a si mismo (un hash que
no puede cuadrar nunca, `sha256sum -c` rc 1); `make_fixture.py` ya no lo
incluye. Los ficheros del fixture no cambiaron (mismos tres hashes).
