// SPDX-License-Identifier: MIT
// External-clock, output-checked, balanced-order workerd performance shootout.
import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {spawn,spawnSync} from 'node:child_process';
import {once} from 'node:events';
import {resolve,relative} from 'node:path';
import {cpus,platform,arch} from 'node:os';
import {performance} from 'node:perf_hooks';
import {createHash} from 'node:crypto';
import {expected,operationCounts} from './workloads.mjs';
const out=resolve('reports/shootout');
await mkdir(out,{recursive:true});
const manifest=JSON.parse(await readFile('dist/shootout/manifest.json','utf8'));
assert(manifest.variants.every(v=>v.contract==='PASS'));
const variants=['javascript',...manifest.variants.map(v=>v.name)];
const rounds=Number(process.env.SHOOTOUT_ROUNDS||7);
assert(Number.isSafeInteger(rounds)&&rounds>=3&&rounds<=30);
const pause=ms=>new Promise(r=>setTimeout(r,ms));
const summarize=values=>{const s=[...values].sort((a,b)=>a-b);return{n:s.length,min:s[0],median:s[Math.floor(s.length/2)],p95:s[Math.min(s.length-1,Math.floor(s.length*.95))],max:s.at(-1)};};
const statusText=await readFile('/proc/self/status','utf8');
const allowed=statusText.match(/^Cpus_allowed_list:\s+(.+)$/m)[1].split(',').flatMap(part=>{
  const [a,b=a]=part.split('-').map(Number);return Array.from({length:b-a+1},(_,i)=>a+i);
});
const serverCpu=allowed[0],clientCpu=allowed[1]??allowed[0];
const affinity=spawnSync('taskset',['-pc',String(clientCpu),String(process.pid)],{encoding:'utf8'});
assert.equal(affinity.status,0,affinity.stderr);
const report={schema:1,manifest,environment:{node:process.version,platform:platform(),arch:arch(),cpu:cpus()[0]?.model,
  allowedCpus:allowed,serverCpu,clientCpu,runner:process.env.RUNNER_NAME??null},rounds,order:[],raw:[],cold:[],memory:[],
  caveats:[
    'Local Linux workerd only, not Cloudflare hosted performance or hosted cold starts.',
    'Bare JavaScript is a functional floor, not an equally sandboxed dynamic-script runtime.',
    'All Lua contenders preserve fresh per-invocation Lua states, text-only guest loading, hooks, limits and cancellation.',
    'Batch microseconds/invocation are externally timed amortized full-handler costs, not individual HTTP latency.',
    'HTTP uses closed-loop load; per-request percentiles do not correct coordinated omission.',
    'Balanced fresh-process rounds share one machine; confidence intervals describe these rounds, not all hardware.',
    'Cold samples include launch, compile, polling and first handler, with warm OS filesystem caches possible.',
    'Process RSS includes V8, all fixture services, code and allocator retention; zero Lua bytes is not zero RSS.',
    'No subtraction of unrelated benchmark medians is used to estimate marginal boundary cost.'
  ]};
const paths={};let port=8790;
for(const name of variants){
  const dir=resolve('dist/shootout',name);await mkdir(dir,{recursive:true});
  const runtime=name==='javascript'?resolve('host/runtime.mjs'):resolve(dir,'host/runtime.mjs');
  const wrapper=name==='javascript'
    ?"import {makeWorker,javascript} from './perf/workloads.mjs';export default makeWorker(javascript);\n"
    :"import module from './kernel.wasm';import {LuaRuntime} from './host/runtime.mjs';import {makeWorker} from './perf/workloads.mjs';const rt=new LuaRuntime(module);export default makeWorker({call:(name,source,request,host)=>rt.run(source,request,host),stats:()=>rt.stats()});\n";
  await writeFile(resolve(dir,'bench.mjs'),wrapper);
  await writeFile(resolve(dir,'fixture.mjs'),"export default{fetch(r){const u=new URL(r.url);return new Response(u.hostname==='config.invalid'?'hello':'upstream');}};\n");
  paths[name]={dir,runtime};
}
function jsonQuote(s){return JSON.stringify(s);}
async function start(name){
  const {dir,runtime}=paths[name],p=++port;
  const embed=file=>jsonQuote(relative(dir,file));
  const wasm=name==='javascript'?'':`,(name="kernel.wasm",wasm=embed ${embed(resolve(dir,'dist/kernel.wasm'))})`;
  const config=`using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
services=[(name="main",worker=(compatibilityDate="2026-09-01",compatibilityFlags=["enable_request_signal"],
 modules=[(name="main.mjs",esModule=embed "bench.mjs"),(name="perf/workloads.mjs",esModule=embed ${embed(resolve('perf/workloads.mjs'))}),
 (name="host/runtime.mjs",esModule=embed ${embed(runtime)})${wasm}],
 bindings=[(name="CONFIG",service="fixture"),(name="UPSTREAM",service="fixture")])),
 (name="fixture",worker=(compatibilityDate="2026-09-01",modules=[(name="fixture.mjs",esModule=embed "fixture.mjs")]))],
 sockets=[(name="http",address="127.0.0.1:${p}",http=(),service="main")]);\n`;
  const file=resolve(dir,'bench.capnp');await writeFile(file,config);
  const beginning=performance.now();
  const child=spawn('taskset',['-c',String(serverCpu),resolve('node_modules/.bin/workerd'),'serve',file],{stdio:['ignore','pipe','pipe']});
  let logs='';child.stdout.on('data',d=>logs+=d);child.stderr.on('data',d=>logs+=d);
  const base=`http://127.0.0.1:${p}`;
  const stop=async()=>{
    if(child.exitCode===null&&child.signalCode===null){child.kill('SIGTERM');
      const timer=setTimeout(()=>child.kill('SIGKILL'),2000);
      await once(child,'exit');clearTimeout(timer);}
    await writeFile(resolve(out,`${name}-${p}.log`),logs);
  };
  try{
    for(let i=0;;i++){
      if(child.exitCode!==null||child.signalCode!==null)throw new Error(`workerd failed: ${logs}`);
      try{const r=await fetch(`${base}/call/hello`,{signal:AbortSignal.timeout(1000)});assert.equal(r.status,200);assert.equal(await r.text(),'ok');break;}
      catch(e){if(i>=1000)throw e;await pause(1);}
    }
    return{child,base,stop,coldMs:performance.now()-beginning};
  }catch(e){await stop();throw e;}
}
function quiescent(stats){for(const key of ['active','luaBytes','admitted','outstanding'])assert.equal(stats[key],0,key);}
async function batch(server,name,n,c=1,mode='mock'){
  const t=performance.now();
  const r=await fetch(`${server.base}/batch/${name}?n=${n}&c=${c}&mode=${mode}`,{signal:AbortSignal.timeout(60000)});
  const text=await r.text();assert.equal(r.status,200,text);const value=JSON.parse(text);
  const ms=performance.now()-t;
  assert.equal(value.completed,n);assert.equal(value.bytes,n*expected[name].length);
  assert.equal(value.counts.get,n*operationCounts[name][0]);assert.equal(value.counts.fetch,n*operationCounts[name][1]);quiescent(value.stats);
  return{ms,usPerInvocation:ms*1000/n,stats:value.stats};
}
async function http(server,name,n,c){
  let next=0;const latencies=[];const t=performance.now();
  await Promise.all(Array.from({length:c},async()=>{while(next++<n){
    const begin=performance.now(),r=await fetch(`${server.base}/call/${name}`,{signal:AbortSignal.timeout(30000)});
    const text=await r.text();assert.equal(r.status,200,text);assert.equal(text,expected[name]);latencies.push(performance.now()-begin);
  }}));
  const ms=performance.now()-t;assert.equal(latencies.length,n);
  const stats=await(await fetch(`${server.base}/stats`)).json();quiescent(stats);
  return{ms,rps:n*1000/ms,latencyMs:summarize(latencies),latencies};
}
const microCases=[['hello',1024,1,'mock'],['cpu',256,1,'mock'],['echo64k',128,1,'mock'],['get',512,1,'mock'],['chain',256,4,'service'],['ops16',128,1,'mock']];
const httpCases=[['hello',512,1],['cpu',256,1],['chain',512,4],['chain',1024,8]];
for(let round=0;round<rounds;round++){
  const rotation=round%variants.length;
  let order=[...variants.slice(rotation),...variants.slice(0,rotation)];
  if(Math.floor(round/variants.length)%2)order.reverse();
  report.order.push({round,variants:order});
  for(const variant of order){
    console.log(`MEASURE round=${round+1}/${rounds} variant=${variant}`);
    const server=await start(variant);report.cold.push({round,variant,ms:server.coldMs});
    try{
      // Same warmup work, fresh process, no artificial fixture delay.
      for(const [name,,c,mode] of microCases)await batch(server,name,256,c,mode);
      for(const [name,n,c,mode] of microCases){const value=await batch(server,name,n,c,mode);report.raw.push({round,variant,type:'batch',name,n,c,mode,...value});}
      for(const [name,n,c] of httpCases){await http(server,name,64,c);const value=await http(server,name,n,c);report.raw.push({round,variant,type:'http',name,n,c,...value});}
    }finally{await server.stop();}
    await writeFile(resolve(out,'raw.json'),JSON.stringify(report)+'\n');
  }
}
// A separate, longer memory pass. No forced workerd GC and no plateau assertion.
for(const variant of variants){
  console.log(`MEMORY ${variant}`);const server=await start(variant);
  try{
    let requests=0;
    for(const checkpoint of [1000,5000,10000,20000,50000]){
      let stats;
      while(requests<checkpoint){const n=Math.min(1000,checkpoint-requests);stats=(await batch(server,'hello',n,4)).stats;requests+=n;}
      const text=await readFile(`/proc/${server.child.pid}/status`,'utf8');
      report.memory.push({variant,requests,rssKiB:Number(text.match(/^VmRSS:\s+(\d+) kB$/m)[1]),stats});
    }
  }finally{await server.stop();}
}
const groupKey=r=>`${r.type}/${r.name}/c${r.c}${r.mode?'/'+r.mode:''}`;
let seed=0x53504f54;function random(){seed^=seed<<13;seed^=seed>>>17;seed^=seed<<5;return(seed>>>0)/4294967296;}
function pairedInterval(ratios){
  const logs=ratios.map(Math.log),samples=[];
  for(let n=0;n<4000;n++){let sum=0;for(let i=0;i<logs.length;i++)sum+=logs[Math.floor(random()*logs.length)];samples.push(Math.exp(sum/logs.length));}
  samples.sort((a,b)=>a-b);
  return{geomean:Math.exp(logs.reduce((a,b)=>a+b,0)/logs.length),low95:samples[100],high95:samples[3899],ratios};
}
report.summary=[];
for(const key of [...new Set(report.raw.map(groupKey))]){
  const base=report.raw.filter(r=>r.variant==='baseline'&&groupKey(r)===key);
  for(const variant of variants){
    const rows=report.raw.filter(r=>r.variant===variant&&groupKey(r)===key);
    const metric=rows[0].type==='http'?'rps':'usPerInvocation';
    const ratios=rows.map(r=>{const b=base.find(b=>b.round===r.round);return metric==='rps'?r[metric]/b[metric]:b[metric]/r[metric];});
    report.summary.push({key,variant,metric,...summarize(rows.map(r=>r[metric])),speedupVsBaseline:pairedInterval(ratios)});
  }
}
report.coldSummary=variants.map(variant=>({variant,...summarize(report.cold.filter(r=>r.variant===variant).map(r=>r.ms))}));
for(const file of ['perf/prepare.py','perf/run.mjs','perf/workloads.mjs','perf/regression.test.mjs'])
  (report.harnessSha256??={})[file]=createHash('sha256').update(await readFile(file)).digest('hex');
await writeFile(resolve(out,'raw.json'),JSON.stringify(report)+'\n');
await writeFile(resolve(out,'summary.json'),JSON.stringify({...report,raw:undefined},null,2)+'\n');
const lines=['# Lua/workerd performance shootout','',`Baseline: ${manifest.baselineCommit}`,`Tested checkout: ${manifest.headCommit}`,'',
  'Each row is the median across fresh-process rounds. Speedup >1 is better; brackets show the paired bootstrap 95% interval. JavaScript is a functional floor, not a security-equivalent runtime.','',
  '| Case | Contender | Median | Speedup vs baseline |','|---|---|---:|---:|'];
for(const r of report.summary){const s=r.speedupVsBaseline;lines.push(`| ${r.key} | ${r.variant} | ${r.median.toFixed(2)} ${r.metric==='rps'?'req/s':'µs/inv'} | ${s.geomean.toFixed(3)}× [${s.low95.toFixed(3)}, ${s.high95.toFixed(3)}] |`);}
lines.push('','## Process startup','', '| Contender | Median launch to first response |','|---|---:|');
for(const r of report.coldSummary)lines.push(`| ${r.variant} | ${r.median.toFixed(2)} ms |`);
lines.push('','## Memory soak','', '| Contender | Requests | Process RSS (KiB) | Live Lua bytes | Wasm bytes |','|---|---:|---:|---:|---:|');
for(const r of report.memory)lines.push(`| ${r.variant} | ${r.requests} | ${r.rssKiB} | ${r.stats.luaBytes} | ${r.stats.wasmBytes} |`);
lines.push('','## Interpretation limits','',...report.caveats.map(s=>`- ${s}`));
await writeFile(resolve(out,'RESULTS.md'),lines.join('\n')+'\n');
console.log(lines.join('\n'));
