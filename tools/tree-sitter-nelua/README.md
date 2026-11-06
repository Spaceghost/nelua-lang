# Nelua Tree-sitter grammar

Grammar rules follow the compiler's existing `syntaxdefs.lua`, pinned to
`Spaceghost/nelua-lang@b8ea333eca77eabc8add419f88f9ce5a4d0d00f5`.
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

## Fork syntax

`grammar.nelua` follows the fork's `syntaxdefs.lua` at the pin above for the
syntax added after the original `b0cbfdb` pin: const pointers (`*const T`,
`*const [0]cchar`, `*const *const T`; `const` after `*` is a keyword, elsewhere
it stays an ordinary identifier such as the `<const>` annotation or `x * const`),
variant types (`A|B`, `A|B|C`, `variant(A, B)`, nested in `function(...)` and
`variant(...)` arguments) wherever a type expression is accepted, and anonymous
`function(...) ... end` expressions. `test/corpus/fork-syntax.txt` and
`queries/highlights.scm` cover them. `src/` and `PROVENANCE.txt` are the
`generate.lua --generate` outputs for that pin with Tree-sitter CLI 0.25.10;
`tree-sitter generate` resolves `* const` through `pointer_type`'s precedence
and reported no unresolved conflict.

## Changing the compiler pin

The pin lives in three places and must move together, or CI fails at
`generate.lua`'s `wrong compiler pin` assertion: `pin` in `generate.lua`, the
`git checkout --detach <pin>` line in `.github/workflows/tree-sitter-nelua.yml`,
and this README. The compiler directory handed to `generate.lua` must be a
checkout whose `git rev-parse HEAD` equals the pin. After the bump run
`generate.lua --generate`, `tree-sitter test`, and commit every changed file
under `src/` plus `PROVENANCE.txt`.
