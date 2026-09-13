// SPDX-License-Identifier: MIT
// Same HTTP workloads and fixture endpoints; independent process per round.
import assert from 'node:assert/strict';
import {writeFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {cpus} from 'node:os';
import {performance} from 'node:perf_hooks';
import {fixtures,start} from './harness.mjs';
const variants=['javascript','wasm','native-lua55','native-luajit','native-luajit-trusted','proxy-lua55'];
const rounds=6;const payload=Buffer.alloc(65536,88);let sequence=0;
const report={rounds,environment:{node:process.version,cpu:cpus()[0]?.model,cpus:cpus().length,commit:execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim()},raw:[],memory:[],cold:[],
 caveats:['One Linux CI machine; six balanced-order independent processes per contender, not independent hardware replication.',
 'Closed-loop external HTTP load; driver and fixture overhead may hide engine differences. No open-loop capacity or coordinated-omission correction.',
 'Native hosts use distro KJ; workerd uses its own bundled version. Libraries and HTTP paths are not byte-identical.',
 'Native Lua and Wasm compile the same context-owned core and run identical Lua source; JavaScript uses equivalent explicit handlers.',
 'The new Wasm adapter is a same-core control, not the previous fastest lazy-I/O prototype.',
 'LuaJIT trusted enables trace compilation and omits instruction hooks. It is NOT the safety-equivalent winner; LuaJIT metered has JIT off.',
 'Proxy RSS is the sum of both native and workerd processes. Fixture and client RSS are not included.',
 'Process-to-first-response includes launcher/readiness polling and may have warm OS caches. No hosted cold starts or worker-loader creation claim.',
 'No forced GC or inspector in measured paths. Finite-load RSS does not prove a plateau, leak freedom or tenant safety.']};
const f=await fixtures();
const summary=arr=>{const a=[...arr].sort((a,b)=>a-b);return{n:a.length,min:a[0],median:a[Math.floor(a.length/2)],p95:a[Math.min(a.length-1,Math.floor(a.length*.95))],max:a.at(-1)};};
const cases=[['hello',1,512],['cpu',1,256],['echo',4,128],['get',8,256],['chain',8,256],['ops16',4,128]];
async function workload(s,name,n,c){
 let next=0;const latencies=[];const before={...f.counts},t=performance.now();
 await Promise.all(Array.from({length:c},async()=>{while(next++<n){
  let body,expected;if(name==='hello')expected='ok';
  else if(name==='cpu'){const count=10000+(sequence++%1000);body=String(count);let sum=0;for(let i=1;i<=count;i++)sum+=i%97;expected=String(sum);}
  else if(name==='echo'){body=payload;expected=payload;}
  else expected=name==='chain'?'hello:upstream':'hello';
  const began=performance.now();const r=await fetch(s.base+'/'+name,{...(body!==undefined?{method:'POST',body}:{}),signal:AbortSignal.timeout(6000)});
  const b=Buffer.from(await r.arrayBuffer());assert.equal(r.status,200,b.toString());assert.deepEqual(b,Buffer.from(expected));latencies.push(performance.now()-began);
 }}));
 const ms=performance.now()-t;assert.equal(latencies.length,n);
 const gets=name==='get'||name==='chain'?n:name==='ops16'?16*n:0,fetches=name==='chain'?n:0;
 assert.equal(f.counts.get-before.get,gets);assert.equal(f.counts.fetch-before.fetch,fetches);
 return{ms,rps:n*1000/ms,latencyMs:summary(latencies),latencies};
}
try{
 for(let round=0;round<rounds;round++){
  const order=[...variants.slice(round),...variants.slice(0,round)];
  for(const variant of order){
   console.log('MEASURE',round+1,variant);const s=await start(variant,f);report.cold.push({round,variant,ms:s.coldMs});
   try{
    for(const [name,c] of cases)await workload(s,name,32,c);
    for(const [name,c,n] of cases){const value=await workload(s,name,n,c);report.raw.push({round,variant,name,c,n,...value});}
    const stats=await s.stats();assert.equal(stats.active,0);assert.equal(stats.admitted,0);
    if(variant==='native-luajit-trusted')assert(stats.traces>0);
   }finally{await s.stop();await writeFile('reports/peer/benchmark-raw.json',JSON.stringify(report)+'\n');}
  }
 }
 for(const variant of variants){
  console.log('MEMORY',variant);const s=await start(variant,f);let count=0;
  try{for(const checkpoint of [100,1000,5000]){
   await workload(s,'hello',checkpoint-count,4);count=checkpoint;const stats=await s.stats();assert.equal(stats.active,0);assert.equal(stats.admitted,0);
   report.memory.push({variant,requests:count,...await s.rss(),stats});
  }}finally{await s.stop();}
 }
 report.summary=[];
 for(const [name,c] of cases)for(const variant of variants){
  const rows=report.raw.filter(r=>r.name===name&&r.variant===variant),ratios=rows.map(r=>r.rps/report.raw.find(b=>b.round===r.round&&b.name===name&&b.variant==='javascript').rps);
  report.summary.push({name,c,variant,...summary(rows.map(r=>r.rps)),geomeanVsJs:Math.exp(ratios.reduce((s,r)=>s+Math.log(r),0)/ratios.length),roundRatios:ratios});
 }
 report.coldSummary=variants.map(variant=>({variant,...summary(report.cold.filter(r=>r.variant===variant).map(r=>r.ms))}));
 await writeFile('reports/peer/benchmark-raw.json',JSON.stringify(report)+'\n');await writeFile('reports/peer/benchmark-summary.json',JSON.stringify({...report,raw:undefined},null,2)+'\n');
 const lines=['# Native peer HTTP shootout','',`Commit: ${report.environment.commit}`,'','Median requests/second across six fresh-process rounds. JIT trusted is not instruction-metered.','',
 '| Case | JavaScript | Same-core Wasm | Native Lua 5.5 | LuaJIT metered | LuaJIT trusted | workerd → native |','|---|---:|---:|---:|---:|---:|---:|'];
 for(const [name,c] of cases)lines.push(`| ${name} c${c} | `+variants.map(v=>report.summary.find(r=>r.name===name&&r.variant===v).median.toFixed(1)).join(' | ')+' |');
 lines.push('','## Process startup','',...report.coldSummary.map(r=>`${r.variant}: ${r.median.toFixed(2)} ms`),'','## Qualifications','',...report.caveats.map(s=>'- '+s));
 await writeFile('reports/peer/RESULTS.md',lines.join('\n')+'\n');console.log(lines.join('\n'));
}finally{await f.close();}
