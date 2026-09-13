// SPDX-License-Identifier: MIT
// Synchronous-only, trusted fixed-source Truffle lane. Never ranked as async parity.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {once} from 'node:events';
import {resolve} from 'node:path';
import {performance} from 'node:perf_hooks';
import {fixtures,start as peerStart} from '../../peer/harness.mjs';
const pause=ms=>new Promise(r=>setTimeout(r,ms));
await mkdir('reports/truffle',{recursive:true});await mkdir('dist/engines/truffle',{recursive:true});
const javaArgs=['-Xms32m','-Xmx256m','--enable-native-access=ALL-UNNAMED','-Dpolyglot.engine.TraceCompilation=true','-Dpolyglot.engine.BackgroundCompilation=false','-cp','dist/engines/truffle/classes:dist/engines/truffle/lib/*','TrufflePeer'];
async function launch(args,log){
 const p=spawn('java',[...javaArgs,...args],{stdio:['ignore','pipe','pipe']});let logs='';p.stdout.on('data',d=>logs+=d);p.stderr.on('data',d=>logs+=d);
 const killer=setTimeout(()=>p.kill('SIGKILL'),60000);const [code,signal]=await once(p,'exit');clearTimeout(killer);await writeFile(log,logs);assert.equal(code,0,logs+' '+signal);return logs;
}
await launch(['--probe','reports/truffle/qualification.json'],'reports/truffle/qualification.log');
const qualification=JSON.parse(await readFile('reports/truffle/qualification.json','utf8'));assert(qualification.coreQualified);assert.equal(qualification.asyncWorkerQualified,false);
let serial=0;const f=await fixtures();
async function start(variant){
 if(variant==='javascript')return peerStart('javascript',f);
 const port=21100+(++serial)*2,procs=[],logs=[];const t=performance.now();
 const j=spawn('java',[...javaArgs,String(port)],{stdio:['ignore','pipe','pipe']});procs.push(j);j.stdout.on('data',d=>logs.push(d.toString()));j.stderr.on('data',d=>logs.push(d.toString()));
 const timer=setTimeout(()=>{for(const p of procs)p.kill('SIGKILL');},60000);
 const stop=async()=>{clearTimeout(timer);for(const p of procs)if(p.exitCode===null&&p.signalCode===null)p.kill('SIGTERM');for(const p of procs)if(p.exitCode===null&&p.signalCode===null){const k=setTimeout(()=>p.kill('SIGKILL'),1000);await once(p,'exit');clearTimeout(k);}await writeFile(`reports/truffle/${variant}-${serial}.log`,logs.join(''));};
 try{
  for(let n=0;;n++){if(j.exitCode!==null)throw Error(logs.join(''));try{const r=await fetch(`http://127.0.0.1:${port}/hello`);assert.equal(await r.text(),'ok');break;}catch(e){if(n>600)throw e;await pause(10);}}
  let base=`http://127.0.0.1:${port}`;
  if(variant==='proxy-truffle'){
   const config=`using W=import "/workerd/workerd.capnp";const config:W.Config=(services=[(name="main",external=(address="127.0.0.1:${port}",http=()))],sockets=[(name="http",address="127.0.0.1:${port+1}",http=(),service="main")]);`;
   const file=`dist/engines/truffle/proxy-${serial}.capnp`;await writeFile(file,config);
   const p=spawn(resolve('node_modules/.bin/workerd'),['serve',file],{stdio:['ignore','pipe','pipe']});procs.push(p);p.stdout.on('data',d=>logs.push(d.toString()));p.stderr.on('data',d=>logs.push(d.toString()));
   base=`http://127.0.0.1:${port+1}`;
   for(let n=0;;n++){if(p.exitCode!==null)throw Error(logs.join(''));try{const r=await fetch(base+'/hello');assert.equal(await r.text(),'ok');break;}catch(e){if(n>200)throw e;await pause(5);}}
  }
  return{base,coldMs:performance.now()-t,stop,logs,async rss(){let sum=0;for(const p of procs){const txt=await readFile(`/proc/${p.pid}/status`,'utf8');sum+=Number(txt.match(/^VmRSS:\s+(\d+) kB$/m)[1]);}return sum;}};
 }catch(e){await stop();throw e;}
}
const variants=['javascript','truffle','proxy-truffle'],rounds=3,raw=[],cold=[],memory=[],contracts=[];
const median=v=>{const a=[...v].sort((a,b)=>a-b);return(a[Math.floor((a.length-1)/2)]+a[Math.floor(a.length/2)])/2;};
async function invoke(s,path,body,status=200){const r=await fetch(s.base+path,{...(body!==undefined?{method:'POST',body}:{}),signal:AbortSignal.timeout(6000)});const b=await r.text();assert.equal(r.status,status,b);return b;}
async function workload(s,name,n){
 const vectors=Array.from({length:n},(_,i)=>{if(name==='hello')return[undefined,'ok'];const count=10000+i%200;let sum=0;for(let j=1;j<=count;j++)sum+=j%97;return[String(count),String(sum)];});
 const samples=[],t=performance.now();for(const [body,expected] of vectors){const begin=performance.now();assert.equal(await invoke(s,'/'+name,body),expected);samples.push(performance.now()-begin);}const ms=performance.now()-t;return{rps:n*1000/ms,ms,latencies:samples};
}
try{
 for(let round=0;round<rounds;round++)for(const variant of [...variants.slice(round),...variants.slice(0,round)]){
  const s=await start(variant);cold.push({round,variant,ms:s.coldMs});
  try{
   for(let i=1;i<=3;i++)assert.equal(await invoke(s,'/counter'),String(i));
   if(variant!=='javascript'){
    await invoke(s,'/get','greeting',501);await invoke(s,'/chain',undefined,501);
    await invoke(s,'/echo',new Uint8Array([255,128,0]),501);await invoke(s,'/echo','x'.repeat(65537),413);
    assert.equal(await invoke(s,'/echo','A'.repeat(65536)),'A'.repeat(65536));
   }
   contracts.push({round,variant,persistentCounter:true,unsupportedAsyncRejected:variant!=='javascript'});
   await workload(s,'cpu',1200);await workload(s,'hello',100);
   for(const name of ['hello','cpu'])raw.push({round,variant,name,n:256,...await workload(s,name,256)});
   memory.push({round,variant,rssKiB:variant==='javascript'?(await s.rss()).sumKiB:await s.rss()});
  }finally{await s.stop();}
 }
 const summary=[];for(const name of ['hello','cpu'])for(const variant of variants)summary.push({name,variant,medianRps:median(raw.filter(x=>x.name===name&&x.variant===variant).map(x=>x.rps))});
 const report={qualification,rounds,raw,summary,cold,memory,contracts,caveats:[
  'Synchronous trusted fixed-source qualification lane only: no coroutine/async capability or binary Lua-string parity.',
  'Truffle/JVM runs outside stock workerd; proxy-truffle is an actual external service, not a JVM embedded in workerd.',
  'The JDK HttpServer host differs from workerd. Every traced JVM runs with -Xmx256m; process RSS includes VM/JIT metadata too.',
  'TraceCompilation logs are retained. Compiler availability is not proof every measured handler compiled or reached steady state.',
  'Three fresh processes per contender; closed-loop one-client HTTP, not production capacity or engine-only execution speed.',
  'JavaScript receives the same inputs/warmup. No async case is replaced with synchronous I/O to fake admission.'
 ]};
 await writeFile('reports/truffle/shootout.json',JSON.stringify(report,null,2)+'\n');
 console.log(JSON.stringify({summary,qualification},null,2));
}finally{await f.close();}
