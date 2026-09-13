// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict';
import {readFile,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {pack,boundedHelper} from './packing.mjs';
const root=resolve('dist/chase/packed');
const runtime=await readFile(root+'/host/runtime.mjs','utf8');
const common=await readFile('lifecycle/bench-common.mjs','utf8');
const application=await readFile('lifecycle/bench.lua','utf8');
let compiled=pack(runtime,common,application);
assert(compiled.startsWith("import module from './kernel.wasm';"));
compiled=compiled.replace("import module from './kernel.wasm';", "import {readFileSync} from 'node:fs';\nconst module=new WebAssembly.Module(readFileSync(new URL('../dist/kernel.wasm',import.meta.url)));\n");
compiled+='\nexport {adapter};\n';
const path=root+'/lifecycle/packed-node.mjs';await writeFile(path,compiled);
const packed=await import(pathToFileURL(path));
const {contractSuite}=await import(pathToFileURL(root+'/lifecycle/contracts.mjs'));
const wasm=new WebAssembly.Module(await readFile(root+'/dist/kernel.wasm'));
const contracts=await contractSuite(()=>new packed.adapter.LuaRuntime(wasm));
assert.equal(contracts.passed.length,27);
const helper=boundedHelper(runtime);
assert(!helper.includes('LuaRuntime')&&!helper.includes('wa_start')&&!helper.includes('wa_open'));
const pending=[];
const env={CONFIG:{fetch:async()=>new Response('hello')},UPSTREAM:{fetch:async()=>new Response('upstream')}};
const ctx={waitUntil:promise=>pending.push(promise)};
let sum=0;for(let i=1;i<=10000;i++)sum+=i%97;
const expected={hello:'ok',cpu:String(sum),get:'hello',chain:'hello:upstream',ops16:'hello',echo64k:'X'.repeat(65536)};
for(const [name,body] of Object.entries(expected)) {
  const request=new Request('https://bench.invalid/call/'+name,name==='echo64k'?{method:'POST',body}:undefined);
  const response=await packed.default.fetch(request,env,ctx);
  assert.equal(response.status,200);assert.equal(await response.text(),body);
}
for(let i=1;i<=3;i++)assert.equal(await(await packed.default.fetch(new Request('https://bench.invalid/call/lifetime'),env,ctx)).text(),String(i));
const stats=await(await packed.default.fetch(new Request('https://bench.invalid/stats'),env,ctx)).json();
assert.equal(stats.appLoads,1);assert.equal(stats.active,0);assert.equal(stats.requestRefs,0);
await packed.default.fetch(new Request('https://bench.invalid/evict'),env,ctx);await Promise.all(pending);
await writeFile('reports/packing-tests.json',JSON.stringify({contracts,benchmarkWorkloads:'PASS',javaScriptReferenceHasLuaCode:false,stats},null,2)+'\n');
console.log('PASS fixed-graph packing: 27 lifecycle contracts; six output-checked handlers; persistent counters; Lua-free JS helper');
