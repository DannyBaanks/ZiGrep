#!/usr/bin/env bash
B="/home/danny/Development/ISyCo Git/ZigGrep/zig-out/bin/zigrep"
cd "$(dirname "$0")" || exit 1
printf 'a cat sat\nconcatenate\ncategory\n(cat)\ncat-dog\na_cat_b\nabc 123 def\nabc123def\ncat\nun perro y un gato juntos dog\n' > wb.txt
pass=0; fail=0
for p in '\bcat\b' '\Bcat\B' '\bcat' 'cat\b' '\b[0-9]+\b' '^\bcat\b$' '\bcat\b.*\bdog\b' '\bthe\b' '\Bcat'; do
  g=$(grep -Eo "$p" wb.txt 2>/dev/null | LC_ALL=C sort)
  z=$("$B" --no-line-number -o -e "$p" wb.txt 2>/dev/null | LC_ALL=C sort)
  if [ "$g" = "$z" ]; then pass=$((pass+1)); printf 'PASS -o %-20s (%s matches)\n' "$p" "$(echo "$g" | rg -c . || echo 0)"
  else fail=$((fail+1)); printf 'FAIL -o %-20s\n  grep: %s\n  zgrep: %s\n' "$p" "$(echo "$g"|tr '\n' '|')" "$(echo "$z"|tr '\n' '|')"; fi
done
# modo lineas (sin -o) tambien
for p in '\bcat\b' '\bthe\b' '^\bcat\b$'; do
  g=$(grep -E "$p" wb.txt | LC_ALL=C sort)
  z=$("$B" --no-line-number -e "$p" wb.txt | LC_ALL=C sort)
  if [ "$g" = "$z" ]; then pass=$((pass+1)); printf 'PASS lineas %-16s\n' "$p"
  else fail=$((fail+1)); printf 'FAIL lineas %-16s\n  grep: %s\n  zgrep: %s\n' "$p" "$(echo "$g"|tr '\n' '|')" "$(echo "$z"|tr '\n' '|')"; fi
done
printf '\nTOTAL %d pass / %d fail\n' "$pass" "$fail"
