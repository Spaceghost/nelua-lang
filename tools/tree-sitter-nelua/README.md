# Nelua Tree-sitter grammar

Grammar rules follow the compiler's existing `syntaxdefs.lua`, pinned to
`Spaceghost/nelua-lang@b0cbfdb86959b7e5d94943729016d8cc4c4cc115`.
This is editor parsing/highlighting, not compiler validation or a language change.
The external scanner is maintained in Nelua, with allocation-free generated C.
It matches arbitrary long-bracket string/comment/preprocessor delimiter levels;
short preprocessing bodies remain opaque Lua code, rather than Nelua statements.

Generate with Tree-sitter CLI 0.25.10, then generate the scanner using the pinned
fork and host compiler. Corpus, scanner sanitizer harness and real Atlas-source
parsing run in GitHub Actions. Parser C and its headers are Tree-sitter outputs,
not a second maintained Nelua implementation. `grammar.js` uses Tree-sitter's
required JavaScript DSL; no JavaScript enters product runtime.

```sh
tree-sitter generate --abi 14
/path/to/pinned/nelua -c -C -r -P nogc -P noentrypoint --cc gcc \
  --cflags=-Isrc -o src/scanner.c src/scanner.nelua
tree-sitter test
tree-sitter parse /path/to/example.nelua
```

This is an initial grammar. Real-source parse failures are release blockers for
its declared coverage; no claim of complete compiler equivalence is made.
