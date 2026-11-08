#!/usr/bin/env bash
# CLI flag controls: zgrep vs GNU grep 3.11 on a hand-made 3-file tree.
set -u
cd "/home/danny/Development/ISyCo Git/ZigGrep"
Z="$PWD/zig-out/bin/zgrep"
T=/tmp/opencode/cli_ctrl2
rm -rf "$T"
mkdir -p "$T"
printf 'hello world\nsecond line\n' > "$T/a.txt"
printf 'no match here\n' > "$T/b.txt"
printf 'hello \000 binary\n' > "$T/c.bin"

echo "### 05 — CLI flag controls (zgrep vs GNU grep 3.11)"
echo "date: $(date -Is)"
echo "note: an earlier run of this control was overwritten in place (same path)."
echo "      Its mismatches were harness bugs, not tool divergences:"
echo "        (1) it passed the literal path 'T' instead of \"\$T\" to grep, so grep"
echo "            exited 2 with \"No such file or directory\";"
echo "        (2) it used 'grep -rnaIF', where -I overrides -a, so grep skipped the"
echo "            binary files that 'zgrep -a' correctly searched."
echo "      Both are corrected below."
echo "tree:"
for f in "$T"/*; do
  nul=$(tr -cd '\000' < "$f" | wc -c)
  echo "  $f  ($(stat -c%s "$f") bytes, NUL bytes=$nul)"
done
echo

run() {
  local label="$1"
  shift
  local out rc
  out=$("$@" 2>&1)
  rc=$?
  out=${out//$'\n'/<NL>}
  printf '%-30s exit=%d | %s\n' "$label" "$rc" "${out:0:300}"
}

echo "--- -q (quiet), match present / absent ---"
run "zgrep -rqF hello DIR"    "$Z" -rqF hello "$T"
run "grep -rqIF hello DIR"    grep -rqIF hello "$T"
run "zgrep -rqF nothere DIR"  "$Z" -rqF nothere "$T"
run "grep -rqIF nothere DIR"  grep -rqIF nothere "$T"
echo "--- default: binary files skipped ---"
run "zgrep -rnF hello DIR"    "$Z" -rnF hello "$T"
run "grep -rnIF hello DIR"    grep -rnIF hello "$T"
echo "--- -a: binary treated as text (grep: -a after -I so -a wins) ---"
run "zgrep -rnaF hello DIR"   "$Z" -rnaF hello "$T"
run "grep -rnaF hello DIR"    grep -rnaF hello "$T"
echo "--- -H forces path, -h suppresses it (single-file operand) ---"
run "zgrep -rnF -H hello a"   "$Z" -rnF -H hello "$T/a.txt"
run "grep -rnIF -H hello a"   grep -rnIF -H hello "$T/a.txt"
run "zgrep -rnF -h hello a"   "$Z" -rnF -h hello "$T/a.txt"
run "grep -rnIF -h hello a"   grep -rnIF -h hello "$T/a.txt"
run "zgrep -rnF hello a"      "$Z" -rnF hello "$T/a.txt"
run "grep -rnIF hello a"      grep -rnIF hello "$T/a.txt"
echo "--- clustered short flags ---"
run "zgrep -rnFq hello DIR"   "$Z" -rnFq hello "$T"
run "grep -rnIFq hello DIR"   grep -rnIFq hello "$T"
run "zgrep -rc hello DIR"     "$Z" -rc hello "$T"
run "grep -rcIF hello DIR"    grep -rcIF hello "$T"
echo "--- error paths (expect exit 2) ---"
run "zgrep (no args)"         "$Z"
run "zgrep -r (no pattern)"   "$Z" -r
run "zgrep PATTERN (no path)" "$Z" hello
run "zgrep missing path"      "$Z" -rnF hello /nonexistent/xyz
run "zgrep bad flag"          "$Z" -Z hello "$T"
run "zgrep newline pattern"   "$Z" -rnF "$(printf 'a\nb')" "$T"
run "zgrep -V"                "$Z" -V
