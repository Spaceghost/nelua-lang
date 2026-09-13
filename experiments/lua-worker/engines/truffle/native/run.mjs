// SPDX-License-Identifier: MIT
// Real native executables, same application/host JARs on JVM, stock-workerd JS.
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {readFile,writeFile,mkdir,readlink} from 'node:fs/promises';
import {once} from 'node:events';
import {resolve} from 'node:path';
import {performance} from 'node:perf_hooks';
import {cpus} from 'node:os';
import {fixtures,start as peerStart} from '../../../peer/harness.mjs';
const dir='reports/truffle-native';await mkdir(dir,{recursive:true});
const pause=ms=>new Promise(r=>setTimeout(r,ms));
const variants=['javascript','jvm-boundary','native-boundary','jvm-linear','native-linear','proxy-native-linear'];
const rounds=6,raw=[],cold=[],memory=[],contracts=[],commands=[];
const report={rounds,variants,raw,cold,memory,contracts,commands,environment:{node:process.version,cpu:cpus()[0]?.model,commit:execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim()},caveats:[
 'Real native-image executables have no Java launcher fallback; ImageInfo and /proc process identity are checked.',
 'Boundary and linear builds differ only by the recorded AST block-dispatch patch. JVM/native use the corresponding identical language JAR and host classes.',
 'Native Image compiles the Java implementation ahead of time; successful runtime compilation of guest Lua is separately checked in retained diagnostic processes.',
 'Timed processes have compilation logging disabled and use default background compilation; every contender receives identical checked warmup.',
 'Synchronous fixed-source trusted lane only. Coroutine, arbitrary byte-string, and numeric-loop table-key gaps remain explicit. No async substitutes.',
 'The JDK HTTP host is not workerd. Closed-loop client/HTTP overhead is included; results are not engine-only throughput or maximum load capacity.',
 'Six balanced fresh-process rounds on one host. Repeat across hosts before promotion; no CPU-affinity claim.',
 'Native and JVM heaps are capped at 256 MiB, not total RSS. Serial native GC differs from JVM GC. Proxy RSS includes both processes.',
 'No forced GC or inspector; 5000-request hello soaks are finite, not proof of stable process memory.',
 'Whole-process launch is not new worker identity creation, unique-source compilation or hosted Cloudflare cold starts.'
]};
const median=v=>{const a=[...v].sort((a,b)=>a-b);return(a[Math.floor((a.length-1)/2)]+a[Math.floor(a.length/2)])/2;};
const f=await fixtures();let serial=0;
function command(v){const profile=v.endsWith('boundary')?'lib':'linear-lib';
 const options=['-Dsun.net.httpserver.nodelay=true','-Xms32m','-Xmx256m'];
 return v.startsWith('jvm-')?{exe:'java',args:[...options,'--enable-native-access=ALL-UNNAMED','-cp',`dist/engines/truffle/classes:dist/engines/truffle/${profile}/*`,'NativeImagePeer']}:
 {exe:resolve(`dist/engines/truffle-native/truffle-${profile}`),args:options};
}
async function start(v){
 if(v==='javascript')return peerStart('javascript',f);
 const id=++serial,port=22500+id*2,procs=[],logs=[],cmd=command(v),t=performance.now();
 const p=spawn(cmd.exe,[...cmd.args,String(port)],{stdio:['ignore','pipe','pipe']});procs.push(p);
 p.stdout.on('data',b=>logs.push(b.toString()));p.stderr.on('data',b=>logs.push(b.toString()));
 const timer=setTimeout(()=>{for(const child of procs)child.kill('SIGKILL');},90000);
 const stop=async()=>{clearTimeout(timer);for(const child of [...procs].reverse()){
  if(child.exitCode===null&&child.signalCode===null){child.kill('SIGTERM');const killer=setTimeout(()=>child.kill('SIGKILL'),1000);await once(child,'exit');clearTimeout(killer);}}
  await writeFile(`${dir}/${v}-${id}.log`,logs.join(''));};
 async function ready(base,child){for(let i=0;;i++){
   if(child.exitCode!==null||child.signalCode!==null)throw Error(logs.join(''));
   try{const r=await fetch(base+'/hello',{signal:AbortSignal.timeout(2000)});assert.equal(r.status,200);assert.equal(await r.text(),'ok');return;}
   catch(e){if(i>600)throw e;await pause(5);}
 }}
 try{
  let base=`http://127.0.0.1:${port}`;await ready(base,p);
  const identityLine=logs.join('').split('\n').find(x=>x.startsWith('RUNTIME_IDENTITY '));assert(identityLine,'missing runtime identity');
  const identity=JSON.parse(identityLine.slice('RUNTIME_IDENTITY '.length));const native=!v.startsWith('jvm-');assert.equal(identity.nativeImage,native);
  const executable=await readlink(`/proc/${p.pid}/exe`);if(native)assert.equal(executable,cmd.exe);
  commands.push({variant:v,id,...cmd,executable,identity});
  if(v.startsWith('proxy-')){
   const config=`using W=import "/workerd/workerd.capnp";const config:W.Config=(services=[(name="main",external=(address="127.0.0.1:${port}",http=()))],sockets=[(name="http",address="127.0.0.1:${port+1}",http=(),service="main")]);`;
   const path=`dist/engines/truffle-native/proxy-${id}.capnp`;await writeFile(path,config);
   const proxy=spawn(resolve('node_modules/.bin/workerd'),['serve',path],{stdio:['ignore','pipe','pipe']});procs.push(proxy);
   proxy.stdout.on('data',b=>logs.push(b.toString()));proxy.stderr.on('data',b=>logs.push(b.toString()));
   base=`http://127.0.0.1:${port+1}`;await ready(base,proxy);
  }
  return{base,coldMs:performance.now()-t,stop,async rss(){const processes=[];for(const child of procs){
   const s=await readFile(`/proc/${child.pid}/status`,'utf8');processes.push({pid:child.pid,rssKiB:Number(s.match(/^VmRSS:\s+(\d+) kB$/m)[1])});}
   return{sumKiB:processes.reduce((sum,p)=>sum+p.rssKiB,0),processes};}};
 }catch(e){await stop();throw e;}
}
async function invoke(s,path,body,status=200){const r=await fetch(s.base+path,{...(body!==undefined?{method:'POST',body}:{}),signal:AbortSignal.timeout(6000)});const bytes=await r.text();assert.equal(r.status,status,bytes);return bytes;}
async function workload(s,name,n){
 const vectors=Array.from({length:n},(_,i)=>{if(name==='hello')return[undefined,'ok'];const count=10000+(i*37)%997;let sum=0;for(let j=1;j<=count;j++)sum+=j%97;return[String(count),String(sum)];});
 const latencies=[],t=performance.now();for(const [input,expected] of vectors){const begin=performance.now();assert.equal(await invoke(s,'/'+name,input),expected);latencies.push(performance.now()-begin);}
 const ms=performance.now()-t;return{ms,rps:n*1000/ms,latencies};
}
try{
 for(let round=0;round<rounds;round++)for(const variant of [...variants.slice(round),...variants.slice(0,round)]){
  console.log('MEASURE',round,variant);const s=await start(variant);cold.push({round,variant,ms:s.coldMs});
  try{
   for(let i=1;i<=3;i++)assert.equal(await invoke(s,'/counter'),String(i));
   if(variant!=='javascript'){
    await invoke(s,'/get','greeting',501);await invoke(s,'/chain',undefined,501);await invoke(s,'/echo',new Uint8Array([255,128,0]),501);
    await invoke(s,'/echo','x'.repeat(65537),413);assert.equal(await invoke(s,'/echo','A'.repeat(65536)),'A'.repeat(65536));
    await invoke(s,'/cpu','garbage',400);await invoke(s,'/cpu','20001',400);
   }
   contracts.push({round,variant,counter:true,bounds:variant!=='javascript',unsupportedExplicit:variant!=='javascript'});
   await workload(s,'cpu',1600);await workload(s,'hello',100);
   for(const name of (round%2?['cpu','hello']:['hello','cpu']))raw.push({round,variant,name,n:512,...await workload(s,name,512)});
   memory.push({round,variant,stage:'warm-and-measured',...await s.rss()});
  }finally{await s.stop();await writeFile(`${dir}/raw.json`,JSON.stringify(report)+'\n');}
 }
 for(const variant of variants){
  const s=await start(variant);let count=0;
  try{for(const checkpoint of [100,1000,5000]){await workload(s,'hello',checkpoint-count);count=checkpoint;memory.push({variant,stage:'hello-soak',requests:count,...await s.rss()});}}
  finally{await s.stop();}
 }
 report.jit=[];
 for(const profile of ['lib','linear-lib'])for(const native of [false,true]){
  const file=`${dir}/${profile}${native?'-native':''}-jit.log`,text=await readFile(file,'utf8');
  assert(text.includes('JIT_PROBE {"checkedCalls":1600'),'JIT diagnostic did not finish');
  const completed=text.split('\n').filter(l=>l.includes('opt done')&&l.includes('Src cpu-handler.lua'));
  const failed=text.split('\n').filter(l=>l.includes('opt failed')&&l.includes('Src cpu-handler.lua'));
  report.jit.push({profile,native,file,guestCompiled:completed.length>0,completions:completed,failures:failed});
 }
 report.summary=[];for(const name of ['hello','cpu'])for(const variant of variants){const rows=raw.filter(r=>r.name===name&&r.variant===variant);
  const ratios=rows.map(r=>r.rps/raw.find(b=>b.name===name&&b.round===r.round&&b.variant==='javascript').rps);
  report.summary.push({name,variant,medianRps:median(rows.map(r=>r.rps)),geomeanVsJs:Math.exp(ratios.reduce((a,b)=>a+Math.log(b),0)/ratios.length),ratios});}
 report.coldSummary=variants.map(variant=>({variant,medianMs:median(cold.filter(r=>r.variant===variant).map(r=>r.ms))}));
 await writeFile(`${dir}/raw.json`,JSON.stringify(report)+'\n');
 await writeFile(`${dir}/summary.json`,JSON.stringify({...report,raw:undefined},null,2)+'\n');
 const lines=['# Truffle Native Image shootout','',`Commit: ${report.environment.commit}`,'','## HTTP median requests/second','',
 '| Case | '+variants.join(' | ')+' |','|---|'+variants.map(()=> '---:').join('|')+'|'];
 for(const name of ['hello','cpu'])lines.push('| '+name+' | '+variants.map(v=>report.summary.find(r=>r.name===name&&r.variant===v).medianRps.toFixed(1)).join(' | ')+' |');
 lines.push('','## Native/JVM guest compilation evidence','',...report.jit.map(j=>`${j.profile} ${j.native?'native':'JVM'}: guestCompiled=${j.guestCompiled}; successful=${j.completions.length}, failed=${j.failures.length}`),
 '','## Process launch to first response','',...report.coldSummary.map(x=>`${x.variant}: ${x.medianMs.toFixed(2)} ms`),'','## Limits','',...report.caveats.map(x=>'- '+x));
 await writeFile(`${dir}/RESULTS.md`,lines.join('\n')+'\n');console.log(lines.join('\n'));
}finally{await f.close();}
