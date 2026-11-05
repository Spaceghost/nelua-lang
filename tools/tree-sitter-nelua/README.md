# Nelua Tree-sitter grammar

Grammar rules follow the compiler's existing `syntaxdefs.lua`, pinned to
`Spaceghost/nelua-lang@b0cbfdb86959b7e5d94943729016d8cc4c4cc115`.
This is editor parsing/highlighting, not compiler validation or a language change.
The grammar graph and external scanner are maintained in Nelua, with generated C.
It matches arbitrary long-bracket string/comment/preprocessor delimiter levels;
short preprocessing bodies remain opaque Lua code, rather than Nelua statements.

Generate with Tree-sitter CLI 0.25.10, then generate the scanner using the pinned
fork and host compiler. Corpus, scanner sanitizer harness and real Atlas-source
parsing run in GitHub Actions. Parser C and its headers are Tree-sitter outputs,
not a second maintained Nelua implementation. `grammar.nelua` generates a bounded
host tool that emits Tree-sitter's external JSON grammar schema. The tool uses
GNU C11, matching the fork's statement-expression output. Lua drives generation;
no JavaScript grammar DSL or hidden C bodies are maintained.

```sh
/path/to/pinned/nelua-lua generate.lua --generate /path/to/pinned/nelua /path/to/tree-sitter
tree-sitter test
tree-sitter parse /path/to/example.nelua
```

This is an initial grammar. Real-source parse failures are release blockers for
its declared coverage; no claim of complete compiler equivalence is made.

## Fork syntax and pending regeneration

`grammar.nelua` now follows the fork's `syntaxdefs.lua` at `1ad3d5ce` for the
syntax added after the `b0cbfdb` pin: const pointers (`*const T`, `*const [0]cchar`,
`*const *const T`; `const` after `*` is a keyword, elsewhere it stays an ordinary
identifier such as the `<const>` annotation), variant types (`A|B`, `A|B|C`,
`variant(A, B)`) wherever a type expression is accepted, and anonymous
`function(...) ... end` expressions. `test/corpus/fork-syntax.txt` and
`queries/highlights.scm` cover them.

**Regeneration is pending.** `src/parser.c`, `src/grammar.json`,
`src/node-types.json`, `src/grammar_generator.c` and `PROVENANCE.txt` are still
the outputs of the `b0cbfdb` pin and do not parse the fork syntax above; they were
not hand-edited. No Tree-sitter CLI was available in the build container when the
grammar changed, so the new corpus expectations are written from the grammar rules
and have not been run. To finish: bump `pin` in `generate.lua` to `1ad3d5ce`,
run `generate.lua --generate` with Tree-sitter CLI 0.25.10 and that compiler,
then `tree-sitter test`. `generate.lua --check` is expected to fail until then.
