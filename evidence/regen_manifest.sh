#!/usr/bin/env bash
# Regenera evidence/SHA256SUMS.unified.txt de forma determinista.
#
# Reglas (ver evidence/PROVENANCE.unified.md):
#   - rutas relativas a la raiz del repo, con separadores POSIX
#   - ordenadas con LC_ALL=C (reproducible byte a byte)
#   - sin duplicados (el manifiesto raiz historico si los tenia)
#   - cubre: evidence/** (todo), src/**, scripts/**, build.zig, build.zig.zon,
#     README.md, GUIA.md, PRUEBAS.md y .github/workflows/ci.yml
#   - NO cubre el propio manifiesto ni PROVENANCE.unified.md (evita circularidad)
#
# Uso: bash evidence/regen_manifest.sh   (desde la raiz del repo)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="evidence/SHA256SUMS.unified.txt"

{
  find evidence -type f \
    ! -path "$OUT" \
    ! -name "PROVENANCE.unified.md" \
    -print0
  find src scripts -type f -print0 2>/dev/null
  printf '%s\0' build.zig build.zig.zon README.md GUIA.md PRUEBAS.md .github/workflows/ci.yml
} | LC_ALL=C sort -z | xargs -0 sha256sum > "$OUT"

echo "escrito: $OUT ($(wc -l < "$OUT") entradas)"
