// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict';import {readFile,writeFile} from 'node:fs/promises';
import {PeerModule} from './wasm.mjs';import {sourceCorpus,runtimeContracts} from './parity-wasm.mjs';
const module=new PeerModule(await WebAssembly.compile(await readFile('dist/peer/kernel.wasm'))),cases=JSON.parse(await readFile('peer/cases.json','utf8'));
const rows=sourceCorpus(module,cases),groups=await runtimeContracts(module),native=JSON.parse(await readFile('reports/peer/parity-native.json','utf8'));
assert.deepEqual(rows,native.find(r=>r.backend==='lua55').rows);
assert.deepEqual(rows.filter(r=>r.feature==='common'),native.find(r=>r.backend==='luajit').rows.filter(r=>r.feature==='common'));
await writeFile('reports/peer/parity-wasm.json',JSON.stringify({rows,groups,native55Exact:true,luajitCommonExact:true},null,2)+'\n');
console.log(`PASS ${rows.length} source cases: native Lua 5.5 matches Wasm; ${rows.filter(r=>r.feature==='common').length} common cases match LuaJIT; ${groups.length} ownership/async groups`);
