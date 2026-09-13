// SPDX-License-Identifier: MIT
// External timing. Each contender uses workerd's actual Dynamic Worker Loader.
import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {spawn,spawnSync} from 'node:child_process';
import {once} from 'node:events';
import {resolve,relative} from 'node:path';
import {cpus} from 'node:os';
import {performance} from 'node:perf_hooks';
const out=resolve('reports/lifecycle');await mkdir(out,{recursive:true});
const manifest=JSON.parse(await readFile('dist/lifecycle/manifest.json','utf8'));
assert.equal(manifest.variants.length,3);assert(manifest.variants.every(x=>x.contract==='PASS'));
const variants=['javascript',...manifest.variants.map(x=>x.name)],rounds=8;
const payload='X'.repeat(65536);let sum=0;for(let i=1;i<=10000;i++)sum+=i%97;
const expected={hello:'ok',cpu:String(sum),echo64k:payload,get:'hello',chain:'hello:upstream',ops16:'hello'};
const pause=ms=>new Promise(r=>setTimeout(r,ms));
const status=await readFile('/proc/self/status','utf8');
const allowed=status.match(/^Cpus_allowed_list:\s+(.+)$/m)[1].split(',').flatMap(s=>{const[a,b=a]=s.split('-').map(Number);return Array.from({length:b-a+1},(_,i)=>a+i);});
const serverCpu=allowed[0],clientCpu=allowed[1]??allowed[0];
assert.equal(spawnSync('taskset',['-pc',String(clientCpu),String(process.pid)]).status,0);
const report={manifest,rounds,environment:{node:process.version,cpu:cpus()[0]?.model,serverCpu,clientCpu},raw:[],cold:[],memory:[],orders:[],cacheChecks:[],
 caveats:[
 'Same actual workerd Worker Loader for JavaScript, fresh Lua and resident Lua. Lua VMs still execute in V8-hosted Wasm.',
 'Resident applications deliberately preserve Lua globals until eviction. This is not the fresh-state-per-invocation contract.',
 'Resident app aggregate Lua heap cap is 2 MiB including all requests, versus 2 MiB for each isolated request in the fresh control.',
 'New-worker measurements include unique-ID loader creation and TWO checked requests, not only isolate creation. Compiled module/code caches may remain warm.',
 'Batch timings are amortized full-handler time measured by the external Node clock, not individual HTTP latencies.',
 'Closed-loop HTTP is not an open-loop overload test. All response bodies and operation counts are checked.',
 'Wasm module is compiled by the parent and passed to child loaders for immutable code sharing; linear memories are separate.',
 'JavaScript does not implement equivalent Lua instruction metering or embedded heap quotas; it is a functional lifecycle reference.',
 'No inspector or forced GC in headline timings. RSS includes parent, fixture, child isolates, V8 and retained garbage.',
 'Self-hosted experimental Worker Loader, pinned version; not Cloudflare hosted start-up or security guarantees.'
 ]};
let port=8900;
function statsOK(s){for(const k of ['active','luaBytes','admitted','outstanding'])assert.equal(s[k],0,k);if(s.requestRefs!==undefined)assert.equal(s.requestRefs,0);}
async function start(variant){
 const dir=resolve('dist/lifecycle',variant);await mkdir(dir,{recursive:true});
 const warm=variant.startsWith('resident');
 const runtime=resolve('dist/lifecycle',variant==='javascript'?'fresh':variant,'host/runtime.mjs');
 const wasm=resolve('dist/lifecycle',variant==='javascript'?'fresh':variant,'dist/kernel.wasm');
 const child=variant==='javascript'?"import{childWorker,javascript}from'./common.mjs';export default childWorker(javascript());\n":
  "import module from './kernel.wasm';import source from './app.lua';import{LuaRuntime}from'./runtime.mjs';import{childWorker}from'./common.mjs';const rt=new LuaRuntime(module);export default childWorker({run:(name,r,h)=>rt.run(source,r,h),stats:()=>rt.stats(),evict:()=>rt.unloadApplication?.()});\n";
 await writeFile(resolve(dir,'child.mjs'),child);await writeFile(resolve(dir,'variant.txt'),variant);
 const parentSource=await readFile('lifecycle/loader.mjs','utf8');
 await writeFile(resolve(dir,'parent.mjs'),variant==='javascript'?parentSource.replace("import kernel from './kernel.wasm';",'const kernel=null;'):parentSource);
 await writeFile(resolve(dir,'fixture.mjs'),"export default{fetch(r){return new Response(new URL(r.url).hostname==='config.invalid'?'hello':'upstream')}};\n");
 const embed=p=>JSON.stringify(relative(dir,resolve(p))),p=++port;
 const config=`using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (services=[
(name="parent",worker=(compatibilityDate="2026-09-01",compatibilityFlags=["experimental","enable_request_signal"],modules=[
(name="main.mjs",esModule=embed "parent.mjs"),
(name="child-source",text=embed "child.mjs"),(name="variant",text=embed "variant.txt"),
(name="runtime-source",text=embed ${embed(runtime)}),(name="common-source",text=embed ${embed('lifecycle/bench-common.mjs')}),
(name="application-source",text=embed ${embed('lifecycle/bench.lua')})${variant==='javascript'?'':`,(name="kernel.wasm",wasm=embed ${embed(wasm)})`}],
bindings=[(name="LOADER",workerLoader=()),(name="CONFIG",service="fixture"),(name="UPSTREAM",service="fixture")])),
(name="fixture",worker=(compatibilityDate="2026-09-01",modules=[(name="fixture.mjs",esModule=embed "fixture.mjs")]))],
sockets=[(name="http",address="127.0.0.1:${p}",http=(),service="parent")]);`;
 const file=resolve(dir,'bench.capnp');await writeFile(file,config);
 const t=performance.now(),proc=spawn('taskset',['-c',String(serverCpu),resolve('node_modules/.bin/workerd'),'serve','--experimental',file],{stdio:['ignore','pipe','pipe']});
 let logs='';proc.stdout.on('data',d=>logs+=d);proc.stderr.on('data',d=>logs+=d);
 const base='http://127.0.0.1:'+p;
 const stop=async()=>{if(proc.exitCode===null&&proc.signalCode===null){proc.kill('SIGTERM');const timer=setTimeout(()=>proc.kill('SIGKILL'),1000);await once(proc,'exit');clearTimeout(timer);}await writeFile(resolve(out,variant+'-'+p+'.log'),logs);};
 try{
  for(let i=0;;i++){if(proc.exitCode!==null||proc.signalCode!==null)throw Error(logs);try{const r=await fetch(base+'/call/hello');const text=await r.text();assert.equal(r.status,200,text);assert.equal(text,'ok');break;}catch(e){if(i>=200)throw Error(e.message+'\n'+logs);await pause(5);}}
  const coldMs=performance.now()-t;
  // Separate parent requests repeat loader.get(). A constant per-instance
  // appLoads=1 alone would not prove that the same isolate stayed resident.
  const values=[];
  for(let i=0;i<3;i++){
    const r=await fetch(base+'/call/lifetime');assert.equal(r.status,200);values.push(await r.text());
  }
  assert.deepEqual(values,variant==='fresh'?['1','1','1']:['1','2','3'],
    'loader did not retain application state across parent requests');
  report.cacheChecks.push({variant,port:p,values});
  return{base,proc,stop,coldMs,warm};
 }catch(e){await stop();throw e;}
}
async function json(server,path){const r=await fetch(server.base+path,{signal:AbortSignal.timeout(60000)});const text=await r.text();assert.equal(r.status,200,text);return JSON.parse(text);}
async function batch(server,name,n,c,mode){const t=performance.now(),v=await json(server,`/batch/${name}?n=${n}&c=${c}&mode=${mode}`);const ms=performance.now()-t;assert.equal(v.complete,n);assert.equal(v.bytes,n*expected[name].length);statsOK(v.stats);if(server.warm)assert.equal(v.stats.appLoads,1,'cached worker was rebuilt');return{ms,us:ms*1000/n,stats:v.stats};}
async function http(server,name,n,c){let next=0;const samples=[],t=performance.now();await Promise.all(Array.from({length:c},async()=>{while(next++<n){const s=performance.now(),r=await fetch(server.base+'/call/'+name);assert.equal(r.status,200);assert.equal(await r.text(),expected[name]);samples.push(performance.now()-s);}}));const ms=performance.now()-t;assert.equal(samples.length,n);statsOK(await json(server,'/stats'));return{ms,rps:n*1000/ms,samples};}
const cases=[['hello',1024,1,'mock'],['cpu',256,1,'mock'],['echo64k',128,1,'mock'],['get',512,1,'mock'],['chain',256,4,'service'],['ops16',128,1,'mock']];
for(let round=0;round<rounds;round++){
 let order=[...variants.slice(round%4),...variants.slice(0,round%4)];if(round>=4)order.reverse();report.orders.push(order);
 for(const variant of order){console.log('MEASURE',round+1,variant);const server=await start(variant);report.cold.push({round,variant,ms:server.coldMs});try{
   for(const[name,,c,mode]of cases)await batch(server,name,128,c,mode);
   for(const[name,n,c,mode]of cases)report.raw.push({round,variant,kind:'batch',name,c,mode,n,...await batch(server,name,n,c,mode)});
   for(const[name,n,c]of [['hello',256,1],['chain',512,8]]){await http(server,name,32,c);report.raw.push({round,variant,kind:'http',name,c,n,...await http(server,name,n,c)});}
   const t=performance.now(),spawned=await json(server,'/spawn?n=24');assert.equal(spawned.created,24);assert.equal(spawned.requests,48);report.raw.push({round,variant,kind:'creation',name:'new-worker-and-two-requests',n:24,us:(performance.now()-t)*1000/24});
  }finally{await server.stop();}await writeFile(resolve(out,'raw.json'),JSON.stringify(report)+'\n');
 }
}
for(const variant of variants){console.log('SOAK',variant);const server=await start(variant);try{
 let count=0;
 for(const checkpoint of [1000,10000,50000]){while(count<checkpoint){const n=Math.min(1000,checkpoint-count);await batch(server,'hello',n,4,'mock');count+=n;}
 const text=await readFile('/proc/'+server.proc.pid+'/status','utf8');report.memory.push({variant,invocations:count,rssKiB:Number(text.match(/^VmRSS:\s+(\d+) kB$/m)[1]),stats:await json(server,'/stats')});}
 if(server.warm){const s=await json(server,'/evict');assert.equal(s.residentLuaBytes,0);assert.equal(s.apps,0);report.memory.push({variant,phase:'application-evicted',stats:s});}
 }finally{await server.stop();}
}
const median=a=>{const s=[...a].sort((a,b)=>a-b),i=Math.floor(s.length/2);return s.length%2?s[i]:(s[i-1]+s[i])/2;};
const key=r=>r.kind+'/'+r.name+(r.c?'/c'+r.c:'');report.summary=[];
for(const k of [...new Set(report.raw.map(key))])for(const variant of variants){
 const rows=report.raw.filter(r=>key(r)===k&&r.variant===variant),metric=rows[0].kind==='http'?'rps':'us';
 const js=report.raw.filter(r=>key(r)===k&&r.variant==='javascript'),fresh=report.raw.filter(r=>key(r)===k&&r.variant==='fresh');
 const ratios=rows.map(r=>{const b=fresh.find(x=>x.round===r.round);return metric==='rps'?r[metric]/b[metric]:b[metric]/r[metric];});
 const geomean=Math.exp(ratios.reduce((s,r)=>s+Math.log(r),0)/ratios.length);
 report.summary.push({key:k,variant,metric,median:median(rows.map(r=>r[metric])),speedupVsFresh:geomean,roundRatios:ratios,relativeToJsMedian:median(rows.map(r=>r[metric]))/median(js.map(r=>r[metric]))});
}
report.coldSummary=variants.map(variant=>({variant,medianMs:median(report.cold.filter(x=>x.variant===variant).map(x=>x.ms))}));
await writeFile(resolve(out,'raw.json'),JSON.stringify(report)+'\n');await writeFile(resolve(out,'summary.json'),JSON.stringify({...report,raw:undefined},null,2)+'\n');
const lines=['# Worker lifecycle shootout','',`Frozen fresh baseline: ${manifest.baseline}`,`Tested checkout: ${manifest.head}`,'','| Case | Runtime | Median | Speedup vs fresh Lua |','|---|---|---:|---:|'];
for(const r of report.summary)lines.push(`| ${r.key} | ${r.variant} | ${r.median.toFixed(2)} ${r.metric==='us'?'us':'req/s'} | ${r.speedupVsFresh.toFixed(3)}x |`);
lines.push('','## Whole-process startup',JSON.stringify(report.coldSummary),'','## Memory',JSON.stringify(report.memory),'','## Limits',...report.caveats.map(x=>'- '+x));
await writeFile(resolve(out,'RESULTS.md'),lines.join('\n')+'\n');console.log(lines.join('\n'));
