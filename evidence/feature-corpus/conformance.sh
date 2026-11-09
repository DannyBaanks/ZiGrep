#!/bin/bash
# Differential conformance: zgrep (build) vs GNU grep 3.11 (and rg where the
# semantics coincide). Every case was chosen so the expected output is known.
cd "$(dirname "$0")" || exit 1
pass=0; fail=0
z() { "/home/danny/Development/ISyCo Git/ZigGrep/zig-out/bin/zgrep" "$@"; }
chk() {
  local name="$1" ref="$2" got="$3"
  if [ "$ref" = "$got" ]; then pass=$((pass+1)); printf 'PASS %-26s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %-26s\n  ref  : %s\n  zgrep: %s\n' "$name" "$(echo "$ref" | head -4 | tr '\n' '|')" "$(echo "$got" | head -4 | tr '\n' '|')"; fi
}
run() { "$@" 2>&1; }
hex() { od -An -c | tr -s ' '; }

echo "===== -x ====="
chk "-x cat"           "$(run grep -nx cat x.txt)"              "$(run z -x cat x.txt)"
chk "-x -i CAT"        "$(run grep -nx -i CAT x.txt)"           "$(run z -x -i CAT x.txt)"
chk "-x -F a.b"        "$(run grep -x -F a.b x.txt)"           "$(run z -x -F a.b x.txt)"
chk "-x -e dog -e cat" "$(run grep -nx -e dog -e cat x.txt)"    "$(run z -x -e dog -e cat x.txt)"
chk "-x -c"            "$(run grep -x -c cat x.txt)"           "$(run z -x -c cat x.txt)"
chk "-x -l (2f)"       "$(run grep -x -l cat x.txt b.txt)"     "$(run z -x -l cat x.txt b.txt)"
chk "-x (arbol)"       "$(run grep -nrx cat . | sed 's|^\./||' | LC_ALL=C sort)" "$(run z --sort -x cat . | LC_ALL=C sort)"                 "$(run z -x cat .)"

echo "===== -f ====="
chk "-f pats"          "$(run grep -n -f pats x.txt)"             "$(run z -f pats x.txt)"
chk "-f pats2 (vacia)" "$(run grep -n -f pats2 x.txt)"            "$(run z -f pats2 x.txt)"
chk "-f empty"         "$(run grep -n -f empty_pats x.txt)"       "$(run z -f empty_pats x.txt)"
run grep -f empty_pats x.txt >/dev/null; r1=$?
run z -f empty_pats x.txt >/dev/null; r2=$?
chk "rc -f empty"      "$r1"                                   "$r2"
chk "-e + -f"          "$(run grep -n -e dog -f pats x.txt)"      "$(run z -e dog -f pats x.txt)"

echo "===== -s ====="
o1=$(run grep -s cat /nonexistent 2>/dev/null); r1=$?
o2=$(run z -s cat /nonexistent 2>/dev/null); r2=$?
chk "rc -s"            "$r1" "$r2"
chk "stderr -s vacio"  "$([ -z "$o1" ] && echo yes || echo no)" "$([ -z "$o2" ] && echo yes || echo no)"

echo "===== --no-line-number (grep sin -n / rg -N) ====="
chk "sin numeros 1f"   "$(run grep -A1 -B1 HIT a.txt)"         "$(run z --no-line-number -A1 -B1 HIT a.txt)"
chk "sin numeros 2f"   "$(run grep -A1 -B1 HIT a.txt b.txt)"   "$(run z --sort --no-line-number -A1 -B1 HIT a.txt b.txt)"
chk "sin numeros rg"   "$(run rg -N -A1 -B1 HIT a.txt)"        "$(run z --no-line-number -A1 -B1 HIT a.txt)"
chk "sin numeros -c"   "$(run grep -c HIT a.txt b.txt)"        "$(run z --sort --no-line-number -c HIT a.txt b.txt)"

echo "===== -Z ====="
chk "-Z -l"            "$(run grep -Z -l HIT a.txt b.txt | hex)" "$(run z --sort -Z -l HIT a.txt b.txt | hex)"
chk "-Z -c"            "$(run grep -Z -c HIT a.txt b.txt | hex)" "$(run z --sort -Z -c HIT a.txt b.txt | hex)"
chk "-Z -H"            "$(run grep -Z -n -H HIT a.txt | hex)"       "$(run z -Z -H HIT a.txt | hex)"
chk "-Z -L"            "$(run grep -Z -L HIT c.txt | hex)"       "$(run z -Z -L HIT c.txt | hex)"
chk "-Z -A1"           "$(run grep -Z -n -H -A1 HIT a.txt | hex)"   "$(run z -Z -H -A1 HIT a.txt | hex)"

echo "===== contexto ====="
chk "-A1 -B1"          "$(run grep -n -A1 -B1 HIT a.txt)"        "$(run z -n -A1 -B1 HIT a.txt)"
chk "-A2 -B2 2f"       "$(run grep -n -A2 -B2 HIT a.txt b.txt)"  "$(run z --sort -n -A2 -B2 HIT a.txt b.txt)"
chk "-A1"              "$(run grep -n -A1 HIT a.txt)"            "$(run z -n -A1 HIT a.txt)"
chk "-B1"              "$(run grep -n -B1 HIT a.txt)"            "$(run z -n -B1 HIT a.txt)"
chk "-C2"              "$(run grep -n -C2 HIT a.txt)"            "$(run z -n -C2 HIT a.txt)"
chk "-m1 -A2"         "$(run grep -n -m1 -A2 HIT a.txt)"        "$(run z -n -m1 -A2 HIT a.txt)"
chk "-v -A1"           "$(run grep -n -v -A1 HIT a.txt)"         "$(run z -n -v -A1 HIT a.txt)"
chk "-A1 --sort"       "$(run grep -n -A1 HIT a.txt b.txt)"      "$(run z --sort -n -A1 HIT a.txt b.txt)"
chk "-A1 swarm"        "$(run grep -n -A1 HIT a.txt b.txt)"      "$(run z --force-swarm --sort -n -A1 HIT a.txt b.txt)"
chk "-A1 uring"        "$(run grep -n -A1 HIT a.txt b.txt)"      "$(run z --io-engine=uring --sort -n -A1 HIT a.txt b.txt)"
chk "-A 1 (arg)"       "$(run grep -n -A 1 HIT a.txt)"           "$(run z -n -A 1 HIT a.txt)"
chk "--context=1"      "$(run grep -n --context=1 HIT a.txt)"    "$(run z -n --context=1 HIT a.txt)"
chk "rg es igual"      "$(run rg -n -A1 HIT a.txt)"              "$(run z -n -A1 HIT a.txt)"
chk "-A1 stdin"        "$(run grep -n -A1 HIT a.txt)"            "$(cat a.txt | z -n -A1 HIT)"
chk "-A1 3f"           "$(run grep -n -A1 HIT a.txt b.txt c.txt)" "$(run z --sort -n -A1 HIT a.txt b.txt c.txt)"
chk "-A999 (bordes)"   "$(run grep -n -A999 HIT a.txt)"          "$(run z -n -A999 HIT a.txt)"
chk "-B999 (bordes)"   "$(run grep -n -B999 HIT a.txt)"          "$(run z -n -B999 HIT a.txt)"

echo
printf 'TOTAL pass=%d fail=%d\n' "$pass" "$fail"
