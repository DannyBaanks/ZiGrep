#!/usr/bin/env bash
# Conformance rebANADA de paridad, en igualdad de condiciones:
#  - rutas normalizadas sin './' (grep lo añade, zgrep no)
#  - desde 0.4.0 zgrep NO numera por defecto (como grep y como rg en pipe):
#    los --no-line-number que quedan son compatibilidad, no una traduccion
# La raiz se resuelve ANTES del cd: despues, "$0" ya es relativo al directorio
# de fixtures y la ruta deja de resolver (bug que dejo el arnes en 2/25 cuando
# /tmp/opencode/znew desaparecio con el reinicio del servidor).
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
Z="${ZGREP_BIN:-$ROOT/zig-out/bin/zgrep}"
B="${PARITY_DIR:-/tmp/opencode/parity}"
rm -rf $B && mkdir -p $B && cd $B || exit 1
norm(){ sed 's|^\./||' | rg -v '(^|/)\.[^/]+$' | LC_ALL=C sort; }

mkdir -p tree/sub/deeper
printf 'def uno():\n    pass\n' > tree/a.py
printf 'var uno = 1;\n' > tree/b.js
printf 'const uno = 1;\n' > tree/c.ts
printf '# uno\n' > tree/sub/d.md
printf 'UNO grande\n' > tree/sub/deeper/e.py
printf 'uno mas\n' > tree/sub/deeper/f.txt
printf 'uno grande\n' > tree/g.py
printf 'nada\n' > tree/README
printf 'uno\n' > tree/.hidden.py

pass=0; fail=0
chk(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); printf 'PASS %s\n' "$1"; else fail=$((fail+1)); printf 'FAIL %s\n  ref  : %s\n  nuevo: %s\n' "$1" "$(echo "$2"|tr '\n' '|')" "$(echo "$3"|tr '\n' '|')"; fi; }

echo "===== -t / --type-not ====="
chk "-t py" "$(grep -rl --include='*.py' uno tree | norm)" "$("$Z" --sort -t py -l uno tree | norm)"
chk "-t py == rg -tpy" "$(rg -tpy -l uno tree | norm)" "$("$Z" --sort -t py -l uno tree | norm)"
chk "--type-not py" "$(grep -rl --exclude='*.py' uno tree | norm)" "$("$Z" --sort --type-not py -l uno tree | norm)"
chk "-t py --type-not txt" "$(grep -rl --include='*.py' --exclude='*.txt' uno tree | norm)" "$("$Z" --sort -t py --type-not txt -l uno tree | norm)"
chk "-tpy pegado" "$(rg -tpy -l uno tree | norm)" "$("$Z" --sort -tpy -l uno tree | norm)"
chk "-t md profundidad" "$(rg -tmd -l uno tree | norm)" "$("$Z" --sort -t md -l uno tree | norm)"

echo "===== --exclude-from ====="
printf '*.js\n*.md\n' > excl.txt
chk "--exclude-from" "$(grep -rl --exclude='*.js' --exclude='*.md' uno tree | norm)" "$("$Z" --sort --exclude-from=excl.txt -l uno tree | norm)"

echo "===== --max-depth (rg -d como referencia) ====="
for d in 1 2 3; do
  chk "--max-depth $d" "$(rg --max-depth $d -l uno tree | norm)" "$("$Z" --sort --max-depth $d -l uno tree | norm)"
done
chk "--max-depth 1 == nav v^" "$("$Z" --sort -m v^ -l uno tree | norm)" "$("$Z" --sort --max-depth 1 -l uno tree | norm)"

echo "===== --max-filesize ====="
python3 -c "open('big.txt','w').write('uno\n'*500000)"
printf 'uno\n' > small.txt
chk "--max-filesize 1M (salta el grande)" "$(grep -rl --exclude='big.txt' uno tree | norm)" "$("$Z" --sort --max-filesize 1M -l uno tree | norm)"
chk "--max-filesize 10M (todo)" "$(grep -rl uno tree | norm)" "$("$Z" --sort --max-filesize 10M -l uno tree | norm)"
chk "--max-filesize 5 (micro == swarm)" "$(printf 'small.txt\n')" "$("$Z" --sort --max-filesize 5 -l uno . | norm)"

echo "===== -b / --byte-offset ====="
chk "-b -n -H" "$(grep -bnH uno tree/a.py)" "$("$Z" -bnH uno tree/a.py)"
chk "-b -o" "$(grep -bo uno tree/a.py)" "$("$Z" --no-line-number -bo uno tree/a.py)"
chk "-b -n" "$(grep -bn uno tree/a.py)" "$("$Z" -bn uno tree/a.py)"
chk "-b" "$(grep -b uno tree/b.js)" "$("$Z" --no-line-number -b uno tree/b.js)"
chk "-b multioccurrencias" "$(grep -bo uno tree/g.py)" "$("$Z" --no-line-number -bo uno tree/g.py)"

echo "===== -S / --smart-case ====="
chk "-S minuscula" "$(grep -i -rl uno tree | norm)" "$("$Z" --sort -S -l uno tree | norm)"
chk "-S con mayuscula" "$(grep -rl Uno tree | norm)" "$("$Z" --sort -S -l Uno tree | norm)"
chk "-S == rg -S" "$(rg -S -l uno tree | norm)" "$("$Z" --sort -S -l uno tree | norm)"

echo "===== --binary-files ====="
printf 'uno\x00binario\n' > bin.dat
chk "--binary-files=text == -a" "$(grep -a -c uno bin.dat)" "$("$Z" --binary-files=text -c uno bin.dat)"
chk "--binary-files=without-match == -I" "$(grep -I -c uno bin.dat)" "$("$Z" --binary-files=without-match -c uno bin.dat)"

echo "===== error de tipo desconocido ====="
chk "tipo desconocido" "zgrep: unknown type name (see --type-list): 'nosuchca'" "$("$Z" -t nosuchca 2>&1 | head -1)"

echo
printf 'TOTAL pass=%d fail=%d\n' "$pass" "$fail"
