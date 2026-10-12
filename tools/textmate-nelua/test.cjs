// Foreign TextMate/Oniguruma engine probe. Maintained grammar data/tooling is Lua.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const modules = process.env.NELUA_TEXTMATE_MODULES;
assert(modules, 'NELUA_TEXTMATE_MODULES must name the pinned test dependency directory');
const tm = require(path.join(modules, 'node_modules/vscode-textmate'));
const onig = require(path.join(modules, 'node_modules/vscode-oniguruma'));
assert.equal(require(path.join(modules, 'node_modules/vscode-textmate/package.json')).version, '9.2.0');
assert.equal(require(path.join(modules, 'node_modules/vscode-oniguruma/package.json')).version, '2.0.1');
(async () => {
  const wasm = fs.readFileSync(path.join(modules, 'node_modules/vscode-oniguruma/release/onig.wasm'));
  await onig.loadWASM(wasm.buffer.slice(wasm.byteOffset, wasm.byteOffset + wasm.byteLength));
  const raw = fs.readFileSync('syntaxes/nelua.tmLanguage.json', 'utf8');
  const registry = new tm.Registry({
    onigLib: Promise.resolve({createOnigScanner: sources => new onig.OnigScanner(sources), createOnigString: s => new onig.OnigString(s)}),
    loadGrammar: async scope => scope === 'source.nelua' ? tm.parseRawGrammar(raw, 'nelua.tmLanguage.json') : null,
  });
  const grammar = await registry.loadGrammar('source.nelua');
  const line = (s, stack = tm.INITIAL) => grammar.tokenizeLine(s, stack);
  const scopeAt = (result, index, scope) => result.tokens.some(t => t.startIndex <= index && t.endIndex > index && t.scopes.includes(scope));
  let s = "global Bytes: type <cimport,nodecl,codename 'const uint8_t*'> = @*[0]uint8";
  let result = line(s);
  assert(scopeAt(result, 0, 'storage.modifier.nelua'));
  assert(scopeAt(result, s.indexOf('cimport'), 'entity.other.attribute-name.nelua'));
  assert(scopeAt(result, s.indexOf("'const"), 'string.quoted.single.nelua'));
  result = line('local function check(record: *uint8): boolean <cexport>');
  assert(scopeAt(result, 15, 'entity.name.function.nelua'));
  assert(!scopeAt(result, 21, 'storage.type.nelua'), 'record is contextual, not a reserved name');
  result = line('--[==[ long comment');
  result = line('local amount = 3 ]=] still comment', result.ruleStack);
  assert(scopeAt(result, 0, 'comment.block.nelua'));
  result = line(']==] local amount = 0xff_u32', result.ruleStack);
  assert(scopeAt(result, 5, 'storage.modifier.nelua'));
  assert(scopeAt(result, 20, 'constant.numeric.nelua'));
  s = "local message = '-- not a comment'"; result = line(s);
  assert(scopeAt(result, s.indexOf('--'), 'string.quoted.single.nelua'));
  assert(!scopeAt(result, s.indexOf('--'), 'comment.line.double-dash.nelua'));
  result = line('##[=[ local lua = true');
  result = line(']=] local amount = 1', result.ruleStack);
  assert(scopeAt(result, 4, 'storage.modifier.nelua'));
  result = line('local bytes = [==[ text');
  result = line(']=] not closed', result.ruleStack);
  assert(scopeAt(result, 0, 'string.quoted.other.long.nelua'));
  result = line(']==] global done = true', result.ruleStack);
  assert(scopeAt(result, 5, 'storage.modifier.nelua'));
  registry.dispose();
  console.log('Native TextMate: declarations, annotations, contextual names, typed numbers, exact long delimiters and opaque strings PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
