#!/usr/bin/env python3
"""Builds evidence/feature-corpus/corpus.csv and CORPUS.md.

The option inventory is parsed from the raw `--help` captures in raw/ (so it is
reproducible and version-stamped); the status/decision column is curated by
hand, because "does this flag exist" cannot be derived from help text alone.

Run: python3 evidence/feature-corpus/build_corpus.py
"""
from __future__ import annotations

import csv
import re
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
RAW = HERE / "raw"

# ---------------------------------------------------------------------------
# 1. Extract the option inventory from the three --help captures.
# ---------------------------------------------------------------------------

TOKEN = re.compile(r"(?<![\w-])(--[a-zA-Z0-9][a-zA-Z0-9-]*|-[A-Za-z0-9])")


def extract(path: Path) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.match(r"^(?:  |    )(?:-(?P<s>[A-Za-z0-9]),?\s+)?(?P<rest>--)", line)
        if not m:
            continue
        toks = TOKEN.findall(line)
        if not toks:
            continue
        for t in toks:
            if t not in seen:
                seen.add(t)
                out.append(t)
    return out


INVENTORY = {
    "grep": extract(RAW / "grep-help.txt"),
    "rg": extract(RAW / "rg-help.txt"),
    "zgrep": extract(RAW / "ziggrep-help.txt"),
}

# ---------------------------------------------------------------------------
# 2. Curated matrix. Fields:
#    category, names, grep, rg, zgrep, decision, effort, value, note
#    grep/rg/zgrep: "si" | "no" | "no-op" | "parcial" | "n/a"
# ---------------------------------------------------------------------------
R = [
 ("Patron", "-e / --regexp", "si", "si", "si",
  "mantener", "-", "-",
  "zgrep acepta hasta 16 patrones; grep/rg no tienen limite practico. -e con -f se combina."),
 ("Patron", "-f / --file", "si", "si", "si (nuevo)",
  "hecho", "S", "alta",
  "NUEVO esta ronda: un patron por linea, \\r final recortado, vacio = sin patron. Un fichero de patrones no lee stdin (-f - sigue sin existir)."),
 ("Patron", "-F / --fixed-strings", "si", "si", "si",
  "mantener", "-", "-", ""),
 ("Patron", "-E / --extended-regexp", "si", "no", "si (default)",
  "mantener", "-", "-",
  "COLISION: en rg -E es --encoding. zgrep sigue a grep: -E es ERE y es el dialecto por defecto."),
 ("Patron", "-G / --basic-regexp", "si", "no", "no-op",
  "integrar despues", "M", "baja",
  "-G se acepta en silencio pero NO es BRE: \\( \\) \\{ no significan lo que grep. O se implementa el subconjunto BRE o el help lo dice. Legacy; paridad baja."),
 ("Patron", "-P / --perl-regexp / --pcre2", "si", "si", "no",
  "no vale", "L", "-",
  "Exigiria enlazar PCRE2. El motor propio (Thompson NFA -> DFA perezoso) es lineal y sin backtracking; el coste de una dependencia no lo paga."),
 ("Patron", "-i / --ignore-case", "si", "si", "si (ASCII+Latin-1)",
  "mantener", "-", "-",
  "zgrep pliega ASCII + Latin-1 (no UTF-8 completo como grep con locale UTF-8 ni rg)."),
 ("Patron", "-S / --smart-case", "no", "si", "no",
  "integrar ahora", "S", "alta",
  "Campo libre (grep no lo tiene): caso sensible si el patron lleva mayuscula, insensible si no. Decision triviaL de implementar."),
 ("Patron", "-s / --case-sensitive", "no", "si", "no (ocupado)",
  "no aplica", "-", "-",
  "COLISION: en grep -s es --no-messages. zgrep resolvio a favor de grep; --case-sensitive no existe porque ya es el default."),
 ("Patron", "-w / --word-regexp", "si", "si", "si",
  "mantener", "-", "-", ""),
 ("Patron", "-x / --line-regexp", "si", "si", "si (nuevo)",
  "hecho", "S", "alta",
  "NUEVO esta ronda: ancla el AST con ^...$ (regex.lineWrap); pierde el camino literal rapido a proposito."),
 ("Patron", "-v / --invert-match", "si", "si", "si",
  "mantener", "-", "-", ""),
 ("Patron", "-z / --null-data", "si", "no", "no",
  "integrar despues", "M", "media",
  "COLISION: en rg -z es --search-zip. Si se implementa, sera --null-data largo. Cambia el separador de linea en scanBuffer."),
 ("Patron", "-z / --search-zip", "no", "si", "no",
  "no vale", "L", "-",
  "Necesita inflarse gzip en el momento del scan; no encaja con el recorrido en crudo."),
 ("Patron", "-U / --multiline", "no", "si", "no",
  "no vale", "L", "-",
  "COLISION: en grep -U es --binary (MS-DOS). El motor responde por linea; multilinea exige repensar el scan."),
 ("Patron", "--multiline-dotall", "no", "si", "no",
  "no vale", "L", "-", "Cuelga de -U."),
 ("Patron", "--crlf", "no", "si", "no",
  "integrar despues", "M", "media",
  "Recortar \\r antes de comparar. Relevante en Windows, donde los ficheros CRLF son la norma."),
 ("Patron", "-E / --encoding", "no", "si", "no",
  "no vale", "L", "-",
  "Motor orientado a bytes salvo BOM UTF-16. -E en zgrep es ERE (colision resuelta a favor de grep)."),
 ("Patron", "--no-unicode", "no", "si", "no",
  "no aplica", "-", "-", "zgrep ya trata el patron como bytes."),
 ("Patron", "--engine", "no", "si", "no",
  "no aplica", "-", "-", "Detalle interno de rg."),
 ("Patron", "--dfa-size-limit / --regex-size-limit", "no", "si", "no",
  "no aplica", "-", "-", "Limites internos del DFA de rg; zgrep tiene los suyos fijos."),
 ("Patron", "--auto-hybrid-regex", "no", "si", "no",
  "no aplica", "-", "-", "Estrategia interna de rg."),
 ("Patron", "--no-pcre2-unicode / --pcre2-version", "no", "si", "no",
  "no vale", "-", "-", "Cuelgan de PCRE2."),
 ("Patron", "--stop-on-nonmatch", "no", "si", "no",
  "integrar despues", "M", "baja", "Semantica de streaming con AND."),

 ("Salida", "-n / --line-number", "si", "si", "si (siempre)",
  "mantener", "-", "-", "zgrep imprime numero siempre; -n queda como no-op valido."),
 ("Salida", "-N / --no-line-number", "no", "si", "si (nuevo)",
  "hecho", "S", "alta",
  "NUEVO (solo largo): -N ya esta ocupado por la navegacion Befunge en zgrep."),
 ("Salida", "-A / -B / -C", "si", "si", "si (nuevo)",
  "hecho", "M", "muy alta",
  "NUEVO: bucle ordenado por linea, separador -- entre grupos disjuntos, -m drena el contexto posterior, -v compatible."),
 ("Salida", "-o / --only-matching", "si", "si", "no",
  "bloqueado por motor", "L", "alta",
  "El motor contesta si/no por linea y NO guarda posiciones de match. Hace falta leftmost-longest en el DFA; esa inversion desbloquea -o, --color, --replace y --column de golpe."),
 ("Salida", "-b / --byte-offset", "si", "si", "no",
  "integrar despues", "M", "media",
  "El scanner ya conoce los offsets de linea; falta exponerlos. No depende del cambio de motor."),
 ("Salida", "--column", "no", "si", "no",
  "bloqueado por motor", "M", "media", "Necesita la posicion del match dentro de la linea."),
 ("Salida", "--count / -c", "si", "si", "si",
  "mantener", "-", "-",
  "zgrep imprime los ceros (como grep); rg los omite salvo --include-zero."),
 ("Salida", "--include-zero", "no", "si", "no",
  "no vale", "-", "-", "zgrep sigue la semantica de grep: el 0 ya sale."),
 ("Salida", "--count-matches", "no", "si", "no",
  "bloqueado por motor", "M", "baja", "Cuenta matches, no lineas."),
 ("Salida", "-l / --files-with-matches", "si", "si", "si",
  "mantener", "-", "-", ""),
 ("Salida", "-L / --files-without-match", "si", "si", "si",
  "mantener", "-", "-",
  "COLISION: en rg -L es --follow. zgrep sigue a grep."),
 ("Salida", "--files-without-match (rg, largo)", "no", "si", "si",
  "mantener", "-", "-", "El largo coincide en todos."),
 ("Salida", "-q / --quiet / --silent", "si", "si", "si",
  "mantener", "-", "-", ""),
 ("Salida", "-H / --with-filename", "si", "si", "si",
  "mantener", "-", "-", ""),
 ("Salida", "-h / --no-filename", "si", "no", "si",
  "mantener", "-", "-",
  "COLISION: en rg -h es --help. zgrep sigue a grep; en rg es -I."),
 ("Salida", "-I / --no-filename (rg)", "no", "si", "no-op",
  "mantener", "-", "-",
  "zgrep ya salta binarios por defecto, que es lo que -I pide en grep."),
 ("Salida", "-Z / --null  ·  -0", "si", "si (-0)", "si (nuevo)",
  "hecho", "S", "media",
  "NUEVO: -Z (grep), -0 (rg) y --null. NUL tras el nombre en lineas, -c y -l/-L."),
 ("Salida", "--color / --colors / --pretty / --vimgrep", "no", "si", "no",
  "bloqueado por motor", "L", "media",
  "El resaltado necesita la posicion del match; --vimgrep ademas necesita --column."),
 ("Salida", "-r / --replace", "no", "si", "no",
  "bloqueado por motor", "L", "media",
  "COLISION: en grep -r es --recursive. Necesita capturas; no las hay."),
 ("Salida", "--json", "no", "si", "si",
  "hecho", "M", "alta",
  "Schema zgrep/1 (JSONL): match, context, passthru, occurrence, file y count, con path, line, column, byte_start, byte_end y text. Solo anadir campos. Diferencial texto<->json: 45/45."),
 ("Salida", "--line-buffered / --block-buffered", "si (line)", "si", "no",
  "integrar despues", "M", "baja",
  "zgrep ya vacia por lote; el modo interactivo ganaria poco."),
 ("Salida", "--heading / --no-heading", "no", "si", "no",
  "integrar despues", "S", "media", "Agrupar por fichero con cabecera."),
 ("Salida", "--group-separator (grep) / --context-separator (rg)", "si", "si", "no",
  "integrar despues", "S", "baja", "El separador es fijo '--' hoy; parametrizarlo es facil."),
 ("Salida", "--field-context-separator / --field-match-separator", "no", "si", "no",
  "no vale", "-", "-", " Campos de --json/--pretty."),
 ("Salida", "--trim", "no", "si", "no",
  "integrar despues", "S", "baja", "Recorta espacios al imprimir."),
 ("Salida", "--path-separator", "no", "si", "no",
  "integrar despues", "S", "baja", "Fuerza / o \\ en las rutas impresas."),
 ("Salida", "-M / --max-columns, --max-columns-preview", "no", "si", "no",
  "integrar despues", "M", "baja", "Trunca lineas largas."),
 ("Salida", "--passthru", "no", "si", "no",
  "integrar despues", "M", "media", "Imprime tambien las lineas sin match; depende del bucle ordenado que ya existe."),
 ("Salida", "--label", "si", "no", "no",
  "integrar despues", "S", "baja", "Etiqueta para stdin."),
 ("Salida", "-T / --initial-tab", "si", "no", "no",
  "no vale", "S", "baja",
  "COLISION: en rg -T es --type-not. Formato legacy de grep."),
 ("Salida", "--hostname-bin / --hyperlink-format / --generate / --no-config", "no", "si", "no",
  "no vale", "-", "-", "Integracion de terminal y bootstrap de rg."),
 ("Salida", "--debug / --trace", "no", "si", "no",
  "no aplica", "-", "-", "zgrep tiene --stats."),
 ("Salida", "--stats", "no", "si", "si",
  "mantener", "-", "-", "zgrep: dirs/files/bytes/matched/threads/micro_path/io_engine/probes/elapsed/throughput."),
 ("Salida", "--no-messages / -s", "si", "si", "si (nuevo)",
  "hecho", "S", "media",
  "ARREGLO: -s estaba aceptado como no-op y LOS ERRORES SEGUIAN SALIENDO. Ahora suprime los mensajes de fichero ilegible."),
 ("Salida", "--no-ignore-messages", "no", "si", "no",
  "no aplica", "-", "-", "zgrep no depende de git para los ignore files."),

 ("Ficheros", "-r / --recursive", "si", "si", "si (no-op)",
  "mantener", "-", "-", "zgrep siempre es recursivo."),
 ("Ficheros", "-R / --dereference-recursive", "si", "no", "no",
  "integrar despues", "M", "media", "Seguir simlinks; el walker hoy los ignora siempre."),
 ("Ficheros", "--follow", "no", "si (-L)", "no",
  "integrar despues", "M", "media", "Largo libre; -L es de grep."),
 ("Ficheros", "--include / --exclude / --exclude-dir", "si", "si", "si",
  "mantener", "-", "-", ""),
 ("Ficheros", "-g / --glob, --iglob, --glob-case-insensitive", "no", "si", "parcial",
  "integrar despues", "M", "media",
  "zgrep ya tiene --include/--exclude/--exclude-dir; falta el alias -g con negacion ! y las variantes insensibles."),
 ("Ficheros", "--exclude-from", "si", "no", "no",
  "integrar ahora", "S", "media", "Fichero con globs, uno por linea. Barato y cerra la paridad con grep."),
 ("Ficheros", "-t / --type, -T / --type-not, --type-list", "no", "si", "no",
  "integrar ahora", "M", "muy alta",
  "Registro estatico nombre->extensiones reaprovechando include/ext. -t es libre (grep no lo tiene); -T NO, es --initial-tab en grep."),
 ("Ficheros", "-d / --max-depth", "no", "si", "no",
  "integrar ahora", "S", "alta",
  "El walker ya lleva depth; nav=v^ cubre solo profundidad 1. Solo largo: -d es --directories en grep."),
 ("Ficheros", "--max-filesize", "no", "si", "no",
  "integrar ahora", "S", "media", "Salta ficheros mayores que el limite."),
 ("Ficheros", "--one-file-system", "no", "si", "no",
  "integrar despues", "M", "baja", "Comparar stx_dev al recorrer."),
 ("Ficheros", "--ignore-file, --ignore-file-case-insensitive", "no", "si", "parcial",
  "integrar despues", "M", "media",
  "zgrep lee .dataignore/.gitignore subiendo hasta la raiz git; faltan listas explicitas."),
 ("Ficheros", "--no-ignore-vcs / -dot / -global / -files / -exclude", "no", "si", "no",
  "no aplica", "-", "-", "zgrep solo tiene esos dos ficheros; --no-ignore ya los cubre todos."),
 ("Ficheros", "--no-require-git", "no", "si", "n/a",
  "no aplica", "-", "-", "zgrep NO exige repo git para leer .gitignore (comportamiento ya distinto de rg)."),
 ("Ficheros", "--hidden / --no-hidden", "si (ocultos)", "si", "parcial",
  "integrar despues", "S", "media",
  "zgrep tiene --no-hidden; los ocultos se buscan por defecto. Falta el --hidden explicito de rg."),
 ("Ficheros", "-u / --unrestricted", "no", "si", "no",
  "integrar despues", "S", "media",
  "Repetible: 1ª = sin ignore, 2ª = sin ocultos, 3ª = binarios tambien."),
 ("Ficheros", "--binary-files=TYPE, --text/-a", "si", "si (-a)", "parcial",
  "integrar ahora", "S", "media",
  "-a existe y ahora --text; falta el formulario con valor (text|without-match) y --binary-files=without-match como alias de -I."),
 ("Ficheros", "-d / --directories, -D / --devices", "si", "no", "no",
  "no aplica", "-", "-", "zgrep recorre siempre y solo ve ficheros regulares."),
 ("Ficheros", "--files", "no", "si", "no",
  "integrar despues", "M", "media", "Lista lo que se buscaria, sin buscar."),
 ("Ficheros", "--sort / --sortr / --sort-files", "si (sort -u)", "si", "parcial",
  "integrar despues", "S", "baja",
  "zgrep tiene --sort/--deterministic; falta --sortr y el alias --sort-files."),
 ("Ficheros", "-j / --threads", "no", "si", "si",
  "mantener", "-", "-", ""),
 ("Ficheros", "--mmap / --no-mmap", "no", "si", "no",
  "no aplica", "-", "-", "zgrep decide solo (scratch/mmap/lectura unica)."),
 ("Ficheros", "--pre / --pre-glob", "no", "si", "no",
  "no vale", "L", "-", "Ejecutar un filtro externo por fichero."),

 ("Propio", "--nav/-N/--befunge, -k/--kamikaze, --sort, --io-engine, --uring, --algo, --force-swarm, --stats, --exclude-ext, --include-ext, --no-default-ignore",
  "no", "no", "si",
  "mantener", "-", "-",
  "Superficie propia de zgrep (sin equivalente en grep ni rg)."),
]

# ---------------------------------------------------------------------------
# 3. Emit CSV + Markdown.
# ---------------------------------------------------------------------------
CSV = HERE / "corpus.csv"
MD = HERE / "CORPUS.md"

with CSV.open("w", newline="", encoding="utf-8") as fh:
    w = csv.writer(fh)
    w.writerow(["categoria", "opcion", "grep", "ripgrep", "zgrep", "decision", "esfuerzo", "valor", "nota"])
    w.writerows(R)

bullets = {
    "hecho": "hecho (esta ronda)",
    "integrar ahora": "INTEGRAR AHORA",
    "integrar despues": "integrar despues",
    "bloqueado por motor": "BLOQUEADO por el motor",
    "no vale": "NO VALE",
    "no aplica": "no aplica",
    "mantener": "mantener",
}

md = ["# Corpus sistematico de superficie: GNU grep 3.11 · ripgrep 14.1.0 · "]
md.append("# zgrep (revision con contexto, -x, -f, -Z, --no-line-number, -s)\n")
md.append("Generado por `build_corpus.py` a partir de las capturas de `raw/` "
          "(inventario) mas una tabla curada a mano (estado y decision).\n")
md.append("\n## Inventario extraido de los --help\n")
for tool, opts in INVENTORY.items():
    md.append(f"- **{tool}**: {len(opts)} tokens de opcion\n")

from collections import Counter

cnt = Counter(r[5] for r in R)
md.append("\n## Decisiones\n")
for k, n in sorted(cnt.items(), key=lambda kv: -kv[1]):
    md.append(f"- {bullets.get(k, k)}: **{n}** opciones\n")

md.append("\n## Lo que hay que tocar del motor para desbloquear el resto\n")
md.append(
    "`-o`, `--color`, `--replace`, `--column`, `--count-matches`, `--pretty` y "
    "`--vimgrep` comparten una unica carencia: el motor (`search.zig` + "
    "`regex.zig`) responde *contiene o no un match* por linea y no guarda la "
    "posicion. Anadir leftmost-longest al DFA perezoso es una sola inversion "
    "que los desbloquea todos; hasta entonces ninguno de esos flags puede "
    "entregarse completo.\n")

cur = None
for cat in [c[0] for c in R]:
    pass
md.append("\n## Matriz\n")
md.append("| Categoria | Opcion | grep | rg | zgrep | Decision | Esf. | Valor | Nota |")
md.append("|---|---|---|---|---|---|---|---|---|")
for r in R:
    md.append("| " + " | ".join(x.replace("|", "\\|") for x in r) + " |")

MD.write_text("\n".join(md) + "\n", encoding="utf-8")
print(f"corpus.csv: {len(R)} filas")
print(f"CORPUS.md escrito ({len(R)} filas)")
