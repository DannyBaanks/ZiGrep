#!/usr/bin/env bash
# M0 del plan agent-native: matriz de codigos de salida y clases de stderr.
# Salida: evidencia cruda pegada tal cual (nada resumido a mano).
set -u
cd "$(dirname "$0")/../.." || exit 1
Z="/home/danny/Development/ISyCo Git/ZigGrep/zig-out/bin/zgrep"
T=/tmp/opencode/contract_fixture
rm -rf "$T"; mkdir -p "$T"
printf 'alpha\nbeta\ngamma\n' > "$T/x.txt"
: > "$T/empty_pats"

one() { # etiqueta, cmd...
  local label="$1"; shift
  local out err rc
  out=$("$@" 2>/tmp/opencode/contract_err); rc=$?
  err=$(cat /tmp/opencode/contract_err)
  printf '%-34s rc=%-2s out=[%s] err=[%s]\n' "$label" "$rc" "$(echo "$out" | tr '\n' '|')" "$(echo "$err" | head -2 | tr '\n' '|')"
}

echo "== matriz de salida (zgrep | grep | rg sobre el mismo caso) =="
for tool in zgrep grep rg; do
  BIN="$Z"; [ "$tool" = grep ] && BIN=grep; [ "$tool" = rg ] && BIN=rg
  echo "--- $tool"
  one "  match"                 "$BIN" alpha "$T/x.txt"
  one "  no-match"              "$BIN" zzz "$T/x.txt"
  one "  fichero inexistente"   "$BIN" alpha "$T/no.txt"
  one "  inexistente con -s"    "$BIN" -s alpha "$T/no.txt"
  one "  directorio sin -r"     "$BIN" alpha "$T"
  one "  flag invalido"         "$BIN" --no-existe alpha "$T/x.txt"
  one "  -f patron vacio"       "$BIN" -f "$T/empty_pats" "$T/x.txt"
    case "$tool" in
    zgrep) zstdin() { cat "$T/x.txt" | "$Z" "$@"; } ;;
    grep)  zstdin() { cat "$T/x.txt" | grep "$@"; } ;;
    rg)    zstdin() { cat "$T/x.txt" | rg "$@"; } ;;
  esac
  one "  stdin match"           zstdin alpha
  one "  stdin no-match"        zstdin zzz
done

echo
echo "== comportamiento en pipe (numeracion por defecto) =="
echo "--- grep (pipe)"; grep beta "$T/x.txt" | cat
echo "--- rg (pipe)";   rg beta "$T/x.txt" | cat
echo "--- zgrep (pipe)"; "$Z" beta "$T/x.txt" | cat
echo "--- zgrep -n";     "$Z" -n beta "$T/x.txt" | cat

echo
echo "== operaciones interactivas con EOF en stdin (no-tty) =="
R="/tmp/opencode/ct5"
rm -rf "$R"; mkdir -p "$R/repoA/.zig-cache" "$R/repoA/zig-out"
dd if=/dev/zero of="$R/repoA/.zig-cache/blob" bs=1024 count=800 2>/dev/null
printf '' | timeout 10 "$Z" --cache --dry-run --cache-root "$R" --cache-no-global >/tmp/opencode/eof1 2>&1
echo "--cache (dry-run) con EOF: rc=$? -> $(tail -2 /tmp/opencode/eof1 | tr '\n' '|')"
printf '' | timeout 10 "$Z" --cache --force --cache-root "$R" --cache-no-global >/tmp/opencode/eof2 2>&1
echo "--cache --force con EOF: rc=$? -> $(tail -1 /tmp/opencode/eof2 | tr '\n' '|')"
