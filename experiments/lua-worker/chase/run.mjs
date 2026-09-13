// SPDX-License-Identifier: MIT
// Reuse the frozen, externally timed Worker Loader harness; fail on any drift.
import {readFile,writeFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {resolve} from 'node:path';
const baseline='abf9213181e95feaede032532b268203f4751feb';
const checkout=execFileSync('git',['rev-parse','--show-toplevel'],{encoding:'utf8'}).trim();
let source=execFileSync('git',['show',baseline+':experiments/lua-worker/lifecycle/run.mjs'],{cwd:checkout,encoding:'utf8'});
function once(old,value){if(source.split(old).length!==2)throw Error('frozen harness drift: '+old.slice(0,80));source=source.replace(old,value);}
source=source.replaceAll('dist/lifecycle','dist/chase').replaceAll('reports/lifecycle','reports/chase');
once('manifest.variants.length,3','manifest.variants.length,4');
once('rounds=8','rounds=10');
once("const warm=variant.startsWith('resident');","const warm=variant!=='javascript';");
source=source.replaceAll("variant==='javascript'?'fresh':variant","variant==='javascript'?'resident':variant");
once("readFile('lifecycle/loader.mjs'","readFile('chase/loader.mjs'");
if(source.split('round%4').length!==3)throw Error('rotation drift');
source=source.replaceAll('round%4','round%variants.length');
once('if(round>=4)','if(round>=variants.length)');
once("r.variant==='fresh'","r.variant==='resident'");
source=source.replaceAll('speedupVsFresh','speedupVsResident').replaceAll('Speedup vs fresh Lua','Speedup vs resident Lua').replaceAll('Frozen fresh baseline:','Frozen resident baseline:');
const old="   const t=performance.now(),spawned=await json(server,'/spawn?n=24');assert.equal(spawned.created,24);assert.equal(spawned.requests,48);report.raw.push({round,variant,kind:'creation',name:'new-worker-and-two-requests',n:24,us:(performance.now()-t)*1000/24});";
once(old,`   for(const lifetime of [1,2,8,32,128]){
     const n=8,t=performance.now(),created=await json(server,'/spawn?n='+n+'&k='+lifetime);
     assert.equal(created.created,n);assert.equal(created.requests,n*lifetime);
     report.raw.push({round,variant,kind:'creation',name:'lifetime-'+lifetime,n,requestsPerWorker:lifetime,us:(performance.now()-t)*1000/n});
   }`);
const begin=source.indexOf(' caveats:['),end=source.indexOf(' ]};',begin);
if(begin<0||end<0)throw Error('caveat boundaries drift');
source=source.slice(0,begin)+' caveats:'+JSON.stringify([
 'Every contender uses the same actual stock-workerd Worker Loader and blocked ambient egress. V8 remains.',
 'Frozen resident control and three ablations: shared immutable completion reason; lazy I/O machinery; lazy I/O plus empty-coroutine pool.',
 'All Lua candidates retain the same 2 MiB aggregate app cap, source pinning, per-invocation hooks, body/operation limits and exact capability ownership.',
 'Empty pooled coroutines are retained app allocations, not live requests; explicit eviction must release their storage.',
 'Lazy I/O allocates a deadline/controller when a request body or host operation requires it. Deadline origin is admission. Same-loop timers never preempt synchronous Wasm.',
 'Complete lifetimes use distinct worker IDs with identical source and checked counters. Code/OS caches may be warm; source uniqueness is not measured.',
 'Complete lifetime cost is measured directly, not by subtracting unrelated cold and warm medians.',
 'Batches are externally timed amortized full-handler costs; HTTP is closed-loop, not an open-loop overload or coordinated-omission-corrected latency test.',
 'JavaScript is a functional lifecycle reference, not equivalent instruction/embedded-heap metering.',
 'No inspector or forced GC in performance or 50,000-invocation soaks. RSS includes every isolate and retained host garbage.',
 'No hosted deployment, native server, JIT for guest Lua, or claim of superiority on unmeasured workloads.'
 ])+'};'+source.slice(end+4);

if(process.env.CHASE_SET==='loading') {
  source=source.replace('Frozen resident control and three ablations: shared immutable completion reason; lazy I/O machinery; lazy I/O plus empty-coroutine pool.',
    'Loading set: resident control, confirmed lazy I/O, lazy plus one call-scoped slab, and lazy plus fixed-graph module packing.');
  source=source.replace('Empty pooled coroutines are retained app allocations, not live requests; explicit eviction must release their storage.',
    'JavaScript reference imports only the shared bounded-reader helper, not any Lua-specific implementation. Packed Lua reduces child module count without changing application source, VM, memory, or authority.');
  once("import assert from 'node:assert/strict';", "import assert from 'node:assert/strict';\nimport {pack,boundedHelper} from './packing.mjs';");
  once(" const runtime=resolve('dist/chase',variant==='javascript'?'resident':variant,'host/runtime.mjs');",
       " let runtime=resolve('dist/chase',variant==='javascript'?'resident':variant,'host/runtime.mjs');");
  once(" const child=variant==='javascript'?", " let child=variant==='javascript'?");
  once(" await writeFile(resolve(dir,'child.mjs'),child);", `
 const packSource=await readFile(runtime,'utf8');
 const commonSource=await readFile('lifecycle/bench-common.mjs','utf8');
 if(variant==='javascript') {
   runtime=resolve(dir,'bounded-helper.mjs');
   await writeFile(runtime,boundedHelper(packSource));
 }
 if(variant==='packed') child=pack(packSource,commonSource,await readFile('lifecycle/bench.lua','utf8'));
 await writeFile(resolve(dir,'child.mjs'),child);`);
  once("await writeFile(resolve(dir,'parent.mjs'),variant==='javascript'?parentSource.replace(\"import kernel from './kernel.wasm';\",'const kernel=null;'):parentSource);",
       `await writeFile(resolve(dir,'parent.mjs'),variant==='javascript'?parentSource.replace("import kernel from './kernel.wasm';",'const kernel=null;'):variant==='packed'?parentSource.replace("const modules={'main.mjs':{js:child},'runtime.mjs':{js:runtime},'common.mjs':{js:common},'app.lua':{text:application}};", "const modules={'main.mjs':{js:child}};"):parentSource);`);
  once("for(const lifetime of [1,2,8,32,128])", "for(const lifetime of [...[1,2,8,32,128].slice(round%5),...[1,2,8,32,128].slice(0,round%5)])");
}
await writeFile('chase/run.generated.mjs',source);
await import('./run.generated.mjs');
