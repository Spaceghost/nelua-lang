// SPDX-License-Identifier: MIT
// Paired, same-machine controls. Never compare unrelated runners' wall times.
import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
import {resolve} from 'node:path';
import {cpus} from 'node:os';
import {performance} from 'node:perf_hooks';
const ROOT=process.cwd(),OUT=resolve('reports/chase');await mkdir(OUT,{recursive:true});
const engines=['javascript','wasm','native-lua55','native-luajit','native-luajit-trusted','native-luau','wasm-luau'];
const profiles=['control','candidate','conservative'],harness={};
for(const p of profiles)harness[p]=await import(pathToFileURL(resolve('dist/chase',p,'peer/engine-harness.mjs')));
const fixture=await harness.control.fixtures(),rounds=6;
const report={rounds,manifest:JSON.parse(await readFile('dist/chase/manifest.json','utf8')),environment:{node:process.version,cpu:cpus()[0]?.model,cpus:cpus().length,checkout:execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim()},raw:[],cold:[],memory:[],order:[],warmup:[],caveats:[
 'Closed-loop checked HTTP, not isolated engine speed or open-loop capacity. The driver and backend fixtures can limit throughput.',
 'Each control/candidate pair runs in a new process. Pair order alternates; engine order rotates. The three Wasm profiles rotate positions over six rounds. No CPU-affinity or universal hardware claim.',
 'All engines receive identical variable-input arithmetic and identical warmup. Trusted LuaJIT requires actual traces and is not instruction-hook equivalent.',
 'Native/Wasm candidates add a 256-byte validated identity lookup hint with collision fallback. Full buffer resets and original buffered request handling are retained. Wasm bodyless dispatch uses lazy I/O; JavaScript preserves synchronous routes.',
 'The conservative Wasm profile optimizes only bodyless dispatch; candidate adds the checked lookup hint. Both retain original input allocation and buffered request handling. Native modes do not benchmark duplicate conservative builds.',
 'No application source, hook frequency, body limit, quota, supported capability, or backend operation count changes.',
 'Lookup hints never grant authority: full invocation IDs are compared before use, collisions scan live slots, and all stale-ID and buffer-clearing behavior is preserved.',
 'Native and workerd hosts have different HTTP, KJ and isolation overheads. Truffle is separately qualified in Native Image mode, not inserted as an async-compatible contestant.',
 'RSS includes engine process only; client/fixtures excluded. Finite hello-only soak is not a leak-free or indefinite plateau proof. No forced GC or inspector.',
 'Startup is process launch plus readiness, not dynamic worker identity creation or hosted cold start.'
]};
const cases=[['hello',1,512],['cpu',1,256],['echo',4,128],['get',8,256],['chain',8,256],['ops16',4,128]],payload=Buffer.alloc(65536,88);
const vectors=new Map();
function vector(name,n){const key=name+':'+n;if(vectors.has(key))return vectors.get(key);
 const list=Array.from({length:n},(_,i)=>{let body,expected;
 if(name==='hello')expected='ok';else if(name==='cpu'){const count=10000+(i*37)%997;body=String(count);let sum=0;for(let j=1;j<=count;j++)sum+=j%97;expected=String(sum);}
 else if(name==='echo'){body=payload;expected=payload;}else expected=name==='chain'?'hello:upstream':'hello';
 return{body,expected:Buffer.from(expected)};});vectors.set(key,list);return list;
}
async function workload(server,name,n,c){
 const list=vector(name,n),before={...fixture.counts},latencies=[];let next=0;const t=performance.now();
 await Promise.all(Array.from({length:c},async()=>{while(next<n){const {body,expected}=list[next++],began=performance.now();
  const r=await fetch(server.base+'/'+name,{...(body===undefined?{}:{method:'POST',body}),signal:AbortSignal.timeout(6000)}),b=Buffer.from(await r.arrayBuffer());
  assert.equal(r.status,200,b.toString());assert.deepEqual(b,expected);latencies.push(performance.now()-began);
 }}));const ms=performance.now()-t;assert.equal(latencies.length,n);
 assert.equal(fixture.counts.get-before.get,name==='ops16'?16*n:(name==='get'||name==='chain')?n:0);
 assert.equal(fixture.counts.fetch-before.fetch,name==='chain'?n:0);return{ms,rps:n*1000/ms,latencies};
}
function clean(stats){assert.equal(stats.active,0);assert.equal(stats.admitted,0);if(stats.outstanding!==undefined)assert.equal(stats.outstanding,0);}
async function launch(profile,engine){process.chdir(resolve(ROOT,'dist/chase',profile));return harness[profile].start(engine,fixture);}
async function save(){await writeFile(OUT+'/raw.json',JSON.stringify(report)+'\n');}
try{
 for(let round=0;round<rounds;round++)for(const engine of [...engines.slice(round),...engines.slice(0,round)]){
  const choices=engine.startsWith('wasm')?profiles:profiles.slice(0,2);
  const order=choices.length===3?[...choices.slice(round%3),...choices.slice(0,round%3)]:round%2?['candidate','control']:choices;report.order.push({round,engine,profiles:order});
  for(const profile of order){console.log('MEASURE',round,profile,engine);const s=await launch(profile,engine);report.cold.push({round,engine,profile,ms:s.coldMs,commands:s.processes.map(p=>({command:p.spawnfile,args:p.spawnargs,pid:p.pid}))});
   try{for(const [name,c] of cases)await workload(s,name,name==='cpu'?200:32,c);
    const warmup=await s.stats();clean(warmup);if(engine==='native-luajit-trusted')assert(warmup.traces>0);report.warmup.push({round,engine,profile,stats:warmup});
    for(const [name,c,n] of (round%2?[...cases].reverse():cases))report.raw.push({round,engine,profile,name,c,n,...await workload(s,name,n,c)});
    clean(await s.stats());
   }finally{await s.stop();await save();}
  }
 }
 for(const engine of engines)for(const profile of (engine.startsWith('wasm')?profiles:profiles.slice(0,2))){const s=await launch(profile,engine);let count=0;
  try{for(const checkpoint of [100,1000,5000]){await workload(s,'hello',checkpoint-count,4);count=checkpoint;const stats=await s.stats();clean(stats);report.memory.push({engine,profile,requests:count,...await s.rss(),stats});}}
  finally{await s.stop();}
 }
 const median=a=>{const s=[...a].sort((a,b)=>a-b);return(s[Math.floor((s.length-1)/2)]+s[Math.floor(s.length/2)])/2;};
 let seed=19283;const random=()=>{seed^=seed<<13;seed^=seed>>>17;seed^=seed<<5;return(seed>>>0)/4294967296;};
 function interval(values){const logs=values.map(Math.log),draw=[];for(let k=0;k<4000;k++){let sum=0;for(let i=0;i<logs.length;i++)sum+=logs[Math.floor(random()*logs.length)];draw.push(Math.exp(sum/logs.length));}draw.sort((a,b)=>a-b);return{geomean:Math.exp(logs.reduce((a,b)=>a+b,0)/logs.length),low95:draw[100],high95:draw[3899],ratios:values};}
 report.summary=[];
 for(const engine of engines)for(const [name] of cases)for(const candidateProfile of (engine.startsWith('wasm')?['candidate','conservative']:['candidate'])){
  const rows=p=>report.raw.filter(r=>r.profile===p&&r.engine===engine&&r.name===name),control=rows('control'),candidate=rows(candidateProfile);
  report.summary.push({engine,name,candidateProfile,controlRps:median(control.map(r=>r.rps)),candidateRps:median(candidate.map(r=>r.rps)),speedup:interval(candidate.map(r=>r.rps/control.find(x=>x.round===r.round).rps))});
 }
 report.coldSummary=[];for(const engine of engines)for(const profile of (engine.startsWith('wasm')?profiles:profiles.slice(0,2)))report.coldSummary.push({engine,profile,medianMs:median(report.cold.filter(r=>r.engine===engine&&r.profile===profile).map(r=>r.ms))});
 await save();await writeFile(OUT+'/summary.json',JSON.stringify({...report,raw:undefined},null,2)+'\n');
 const lines=['# All-engine optimization chase','',`Checkout: ${report.environment.checkout}`,'','Median checked HTTP requests/second; paired bootstrap intervals are exploratory, not corrected for multiple comparisons.','',
 '| Engine | Workload | Profile | Control | Candidate | Paired speedup [95% interval] |','|---|---|---|---:|---:|---:|'];
 for(const r of report.summary){const s=r.speedup;lines.push(`| ${r.engine} | ${r.name} | ${r.candidateProfile} | ${r.controlRps.toFixed(1)} | ${r.candidateRps.toFixed(1)} | ${s.geomean.toFixed(3)}x [${s.low95.toFixed(3)}, ${s.high95.toFixed(3)}] |`);}
 lines.push('','## Limits','',...report.caveats.map(s=>'- '+s));await writeFile(OUT+'/RESULTS.md',lines.join('\n')+'\n');console.log(lines.join('\n'));
}finally{process.chdir(ROOT);await fixture.close();}
