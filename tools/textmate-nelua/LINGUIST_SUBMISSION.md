# Native GitHub Nelua highlighting preparation

GitHub's website uses Linguist plus TextMate grammars, rather than loading a
repository's Tree-sitter grammar. This grammar uses `source.nelua` and `.nelua`;
no `.gitattributes` Lua fallback is supplied. Publishing this source alone does
not activate GitHub website highlighting.

The maintained grammar schema is `grammar.lua`, deliberately emitted into
TextMate's required external tool format by `generate.lua`. CI regenerates it
without repair and exercises real vscode-textmate 9.2.0 / Oniguruma 2.0.1 tokens.
The JavaScript probe is only the foreign TextMate engine adapter. Tree-sitter's
native scanner separately remains Nelua with compiler-produced C.

For a Linguist submission:

1. Link this maintained, MIT-licensed grammar and representative public Nelua
   source with its original license. Never publish private Atlas samples.
2. Add a language entry using `name: Nelua`, `type: programming`,
   `tm_scope: source.nelua`, `extensions: [.nelua]` and an upstream-assigned
   language id, then register the grammar through Linguist's grammar tooling.
3. Provide the required public usage evidence and representative real-world
   samples; follow the current CONTRIBUTING template and run Linguist's suite.
4. After upstream merge, await GitHub's Linguist deployment before claiming
   website support. Repository-local grammars cannot force that deployment.

As checked October 12, 2026, Linguist has no Nelua entry. Its current admission
guidelines ask for at least 2,000 recently indexed non-fork files for a repeating
extension and reasonable distribution across authors/repos. That criterion is
an upstream gate; this preparation makes no acceptance claim.

References:
- https://github.com/github-linguist/linguist/blob/master/CONTRIBUTING.md
- https://github.com/github-linguist/linguist/blob/master/lib/linguist/languages.yml
