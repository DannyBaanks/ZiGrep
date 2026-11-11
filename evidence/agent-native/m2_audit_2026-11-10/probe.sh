#!/usr/bin/env bash
# Sonda diferencial de la auditoria e2e de M2: cada fila compara zgrep contra
# GNU grep (/usr/bin/grep, nunca la funcion del shell) o rg: stdout + rc
# (el texto de stderr difiere a proposito entre herramientas).
# Uso: bash evidence/agent-native/m2_audit_2026-11-10/probe.sh [ZGREP_BIN]
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
Z="${1:-$ROOT/zig-out/bin/zgrep}"
G=/usr/bin/grep; R="$(command -v rg)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/d"; printf 'alpha\nbeta HIT\ngamma\nHIT two\nend\n' > "$T/a.txt"
printf 'x HIT\n' > "$T/d/b.txt"; for f in m z c; do echo HIT > "$T/$f.txt"; done
cd "$T"; pass=0; fail=0
row() { local ref="$1"; shift; local a b
  a=$("$Z" "$@" 2>/dev/null; echo "rc=$?"); b=$("$ref" "$@" 2>/dev/null; echo "rc=$?")
  if [ "$a" = "$b" ]; then pass=$((pass+1)); echo "PASS ${ref##*/} $*"
  else fail=$((fail+1)); echo "FAIL ${ref##*/} $*"; echo "  zgrep: $(echo "$a"|tr '\n' '|')"; echo "  ref:   $(echo "$b"|tr '\n' '|')"; fi; }
echo "zgrep: $("$Z" --version) | $($G --version|head -1) | $($R --version|head -1)"
row "$R" --column HIT a.txt
row "$R" --column --no-line-number HIT a.txt
row "$R" --no-line-number --column HIT a.txt
row "$R" --column -H HIT a.txt
row "$R" --vimgrep HIT a.txt
row "$G" HIT a.txt
row "$G" HIT z.txt a.txt m.txt c.txt
row "$G" -l HIT z.txt a.txt m.txt
row "$G" -c HIT z.txt a.txt
row "$G" -h HIT a.txt d/b.txt
row "$G" -n HIT a.txt d/b.txt
row "$G" -q HIT a.txt nope
row "$R" -q HIT a.txt nope
row "$G" -q ZZZ a.txt nope
row "$G" HIT a.txt nope
types=$("$Z" --json --passthru HIT a.txt | python3 -c 'import sys,json;print(",".join(json.loads(l)["type"]+":"+str(json.loads(l)["inverted"]) for l in sys.stdin))')
[ "$types" = "passthru:False,match:False,passthru:False,match:False,passthru:False" ] && { pass=$((pass+1)); echo "PASS json --passthru: $types"; } || { fail=$((fail+1)); echo "FAIL json --passthru: $types"; }
out=$("$Z" --json --exec echo HIT a.txt 2>/dev/null); rc=$?
[ -z "$out" ] && [ $rc -eq 2 ] && { pass=$((pass+1)); echo "PASS json --exec: rc=2, stdout vacio"; } || { fail=$((fail+1)); echo "FAIL json --exec: rc=$rc stdout=$out"; }
echo "TOTAL pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
