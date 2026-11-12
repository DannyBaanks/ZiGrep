# Differential fuzzer (2026-11-12)

`scripts/diff_fuzz.zig` + `scripts/diff_fuzz_run.py`. Behaviour copied from
the ISyCo neuro-symbolic fuzz oracle (in process, millions of cases, a
reference that shares no code with the engine, boundary-biased inputs,
shrunk counterexamples).

## How it works

- Each case: a random regex AST (or `-F` literals), 1-3 patterns, random
  `-i -w -x -v`, and a haystack of short lines. An entropy knob (1-5) grows
  the alphabet (up to `\r \t \x80 \xff` and NUL), nesting, line length,
  nullable stars, `{m,n}` and empty branches; `auto` cycles all five.
- The AST is printed as ERE for ZiGrep and evaluated by a reference written
  in the fuzzer: sets of positions over one line (byte semantics, like
  ZiGrep and `LC_ALL=C grep -E`).
- Checked per case: selected lines; `-o` spans (leftmost-longest,
  non-overlapping, absolute offsets); `-c`, `-q`, `-l` against them; the
  line-by-line path (what `--json` uses) against the fast path; `-F` with the
  `auto`, `bmh` and `memchr` kernels.
- A divergence is shrunk (lines, then bytes) and replayed through the CLI
  against `LC_ALL=C grep -a` (and `--json -c` against `grep -c`):
  `zgrep_bug` if they differ, `oracle_bug` if they agree. The judge was
  validated both ways: the pre-fix binary on the first findings gives
  200/200 `zgrep_bug`, the fixed one 0.
- Processes, not threads: every case compiles a new pattern and the per-thread
  DFA is mapped with `page_allocator`, so threads of one process queue on the
  kernel's mmap lock (12 threads: ~9 000 cases/s; 12 processes: ~57 000-66 000).

## Bugs found and fixed (all confirmed by GNU grep; rg agrees on each)

| # | bug | example | fix |
|---|---|---|---|
| 1 | a pattern that matches the empty string skipped empty lines | `x*`, `^`, `(a\|)` on `a\n\nb` printed lines 1 and 3 | `regex.zig` `firstMatchingLine`: accept the start state |
| 2 | same, on the line-by-line path (`--json`, `-v`, context) | `c*$` on an empty line | `firstMatchingLine`: an empty slice is an empty line |
| 3 | `-o` not leftmost-longest when a nullable branch matched first | `-o -e '.$' -e 'x*'` on `C` printed nothing | `nextMatchImpl`: a `$` match at line end always extends |
| 4 | `-w ''` selected every line (phantom line after the last `\n`) | `-w ''` on `b` | `findWord`: no empty match past a trailing newline |
| 5 | `-i` regex prefilter dropped true matches whose literal held a 0x80-0x9E byte | `xa\x80.` -i on `xa\x80x` | prefilter needle folded like the text |
| 6 | `-i` literals folded 0x80-0x9E after ANY lead byte | `Ā`=`Ġ`, `ā`=`ġ`, `Ł`=`š`; raw `\x80`=`\xa0` | fold only inside `C3 xx` (`toLowerByteAfter`) |

Bugs 1-4 came from the first 20 000-100 000 cases; bug 5 from the first 20 M
run (`run_20m_before_fix6.json`, 25 unique, all `zgrep_bug`); bug 6 was
found while minimising bug 5 (the fuzzer's alphabet has no `C3`/`C4`, so it is
covered by a unit test instead). Each has a unit test in `src/scan.zig` or
`src/search.zig`.

## Round 2: a wider oracle (2026-11-12, same day)

The reference and the generator now also cover `\b \B \< \>`, `\w \W
\d \D \s \S`, POSIX classes (`[[:alpha:]]` ... `[[:blank:]]`), BRE (`-G`,
the AST printed with `\( \| \{ \+ \?`), `-m N` and `-A/-B` context (the
exact text, with `N:` / `N-` and `--` between groups). Rejections count too:
the generator only emits valid patterns, so a rejection is judged ("does GNU
grep accept it?"). The judge gives grep `[0-9]` for `\d` (grep -E has no
`\d`; zgrep and rg do), and has a 5 s timeout: GNU grep backtracks
exponentially on `((((\B){2,4})+)+)+` (ZiGrep's DFA does not).

Found and fixed in this round (all confirmed by GNU grep):

| # | bug | example | fix |
|---|---|---|---|
| 7 | `\<` and `\>` silently matched a literal `<` / `>` | `\<f` on "foo" found nothing, no error | new `ws`/`we` assertions in `regex.zig` |
| 8 | after `\b`/`\B`, a following group was evaluated one byte late | `\b(foo\|bar)\b` missed "foo"; `\b(ab\|c)` matched "bc" | `step`: `seedAfterAssert` resolves splits/assertions at the same position |
| 9 | a run of zero-width items stopped after the first | `(\>){2,3}`, `(\b\b\b){1}` never matched | `acceptEnd`/`acceptWord`: `zeroWidthMatch` |
| 10 | BRE: `*` right after a leading `^` repeated the anchor | `-G '^*'` selected every line | `bre.zig`: `^` keeps "start of branch" |
| 11 | BRE: `]` right after `[` / `[^` closed the class | `-G '[]a]'` "unterminated [ class" | `bre.zig` |
| 12 | BRE: backslash inside `[...]` read as an escape | `-G '[\]'` rejected (POSIX: literal) | `bre.zig` doubles it |

Bugs 7, 8, 10 came from probing the new features by hand against grep
before writing the oracle; 9, 11, 12 from the fuzzer (300 000 cases: 138
divergences and 1 294 rejected patterns before, 0 after).

## Runs

- `run_20m_before_fix6.json`: 20 000 000 cases, seed 20261112, 12 processes,
  25 divergences, all `zgrep_bug` (bug 5).
- `run_20m_after.json`: the same 20 000 000 cases after the fixes: 0.
- `early_findings.jsonl`: the shrunk findings of the first short runs.
- CI: 300 000 cases with seed 20261112 on every push.

## Not covered (NOT_DEMONSTRATED by this fuzzer)

- Back-references (rejected on purpose), `-U` multiline, `--crlf`, `-z`,
  `--replace`, `-m` combined with context, `-o` with `-w/-x/-v`.
- In ERE, ZiGrep reads `\` inside `[...]` as an escape (like rg); POSIX ERE
  (GNU grep -E) reads it as a literal. Deliberate rg parity; the generator
  never puts a backslash in a class.
- Unicode: byte semantics only. The Latin-1 folding of literal `-i` is not
  in the reference (only bug 6's unit test covers it); regex `-i` does not
  fold Latin-1 at all, so `À` and `À.` behave differently under `-i`.
- `-o` together with `-w`, `-x` or `-v` (GNU's semantics there are an
  implementation detail).
- Invalid patterns: the generator only emits valid ERE (`rejected_patterns`
  is 0); `zig build fuzz` covers rejection paths.
