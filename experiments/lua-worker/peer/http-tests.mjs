// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict';
import {request as httpRequest} from 'node:http';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {readFile,writeFile} from 'node:fs/promises';
import {performance} from 'node:perf_hooks';
import {fixtures,start,call,pause} from './harness.mjs';
const f=await fixtures();const evidence={source:[],hosts:[],externalTermination:null};
try {
 const contracts=await start('wasm',f,{contracts:true});
 try {
  const response=await fetch(contracts.base+'/test'),result=await response.json();assert.equal(response.status,200,JSON.stringify(result));
  const expected=JSON.parse(await readFile('reports/peer/parity-wasm.json','utf8'));
  assert.deepEqual(result.rows,expected.rows);assert.deepEqual(result.groups,expected.groups);evidence.source=result;
  console.log('PASS stock workerd: 35 identical source cases and five ownership/async groups');
 }finally{await contracts.stop();}
 for(const variant of ['javascript','wasm','native-lua55','native-luajit','native-luajit-trusted','proxy-lua55']) {
  const s=await start(variant,f);const record={variant,passed:[],disconnects:[]};evidence.hosts.push(record);
  const check=async(name,fn)=>{await fn();record.passed.push(name);};
  try {
   await check('hello and persistent app state',async()=>{await call(s,'/hello',undefined,'ok');for(let i=1;i<=3;i++)await call(s,'/counter',undefined,String(i));});
   await check('method and absolute request URL',()=>call(s,'/info','','POST|'+s.base+'/info'));
   await check('64 KiB binary body',async()=>{const b=Buffer.from(Uint8Array.from({length:65536},(_,i)=>i%251));await call(s,'/echo',b,b);});
   await check('input-dependent computation',async()=>{for(const n of [31,997,10000,10999]){let sum=0;for(let i=1;i<=n;i++)sum+=i%97;await call(s,'/cpu',String(n),String(sum));}});
   await check('CONFIG value empty absence and operation count',async()=>{const before=f.counts.get;await call(s,'/get','greeting','hello');await call(s,'/get','missing','missing');await call(s,'/get','empty','');await call(s,'/ops16',undefined,'hello');assert.equal(f.counts.get-before,19);});
   await check('actual async subrequests complete out of order',async()=>{const order=[],before=f.counts.fetch;const get=name=>call(s,'/chain',name,'hello:'+name).then(()=>order.push(name));await Promise.all([get('slow'),get('fast')]);assert.deepEqual(order,['fast','slow']);assert.equal(f.counts.fetch-before,2);});
   await check('HEAD suppresses body',async()=>{const r=await fetch(s.base+'/hello',{method:'HEAD'});assert.equal(r.status,200);assert.equal((await r.arrayBuffer()).byteLength,0);});
   if(variant!=='javascript') {
    await check('bounded request and host result failure',async()=>{const r=await fetch(s.base+'/echo',{method:'POST',body:'x'.repeat(65537)});await r.text();assert.equal(r.status,413);await call(s,'/get','large',undefined,500);await call(s,'/get','backend-error',undefined,500);});
    await check('traceback after host completion',async()=>{await call(s,'/fail',undefined,undefined,500);assert(s.logs.join('').includes('http-trace-needle')&&s.logs.join('').includes('app.lua'),'missing host traceback');});
    if(variant!=='native-luajit-trusted')await check('runaway interpreter loop terminates',()=>call(s,'/loop',undefined,undefined,500));
    for(const reset of [true,false]) {
     const client=httpRequest(s.base+'/get',{method:'POST'},r=>r.resume());client.on('error',()=>{});client.end('hang');
     try{
      let stats;for(let i=0;i<200;i++){stats=await s.stats();if(stats.active===1)break;await pause(5);}assert.equal(stats.active,1);
      const t=performance.now();if(reset){assert(client.socket);client.socket.resetAndDestroy();}else client.destroy();
      for(let i=0;i<650;i++){stats=await s.stats();if(stats.active===0&&stats.admitted===0&&(stats.outstanding??0)===0)break;await pause(5);}
      const elapsed=performance.now()-t;assert.equal(stats.active,0);assert.equal(stats.admitted,0);
      if(stats.outstanding!==undefined)assert.equal(stats.outstanding,0);
      if(reset)assert(elapsed<1500,'TCP reset cleanup fell back to the 2500 ms deadline');
      record.disconnects.push({reset,cleanupMs:elapsed,stats});
     }finally{client.destroy();}
    }
   }
   if(variant==='native-luajit-trusted')await check('trusted JIT compiles the actual routed application',async()=>{
    // Four functional CPU cases are not a JIT warmup contract. Exercise the
    // actual HTTP app with variable inputs; never count a JIT-on flag as proof.
    const before=(await s.stats()).traces;
    for(let i=0;i<200;i++){
     const n=10000+i;let sum=0;for(let j=1;j<=n;j++)sum+=j%97;
     await call(s,'/cpu',String(n),String(sum));
    }
    const after=(await s.stats()).traces;assert(after>0,'no compiled JIT traces after checked warmup');
    record.jitQualification={checkedCalls:200,tracesBefore:before,tracesAfter:after};
   });
   const stats=await s.stats();assert.equal(stats.active,0);assert.equal(stats.admitted,0);record.stats=stats;
   if(variant==='native-luajit-trusted')assert(stats.traces>0,'no compiled JIT traces');
   console.log(`PASS ${variant}: ${record.passed.length} HTTP groups; ${record.disconnects.length} real disconnect checks`);
  }finally{await s.stop();await writeFile('reports/peer/http-tests.json',JSON.stringify(evidence,null,2)+'\n');}
 }
 const child=spawn('python3',['peer/jit-probe.py','--runaway'],{stdio:['ignore','pipe','pipe']});let text='';child.stdout.on('data',b=>text+=b);child.stderr.on('data',b=>text+=b);
 const timeout=setTimeout(()=>child.kill('SIGKILL'),1000);const [code,signal]=await once(child,'exit');clearTimeout(timeout);
 assert(text.includes('READY-RUNAWAY'),text);assert.equal(signal,'SIGKILL');evidence.externalTermination={code,signal,readyObserved:true};
 await writeFile('reports/peer/http-tests.json',JSON.stringify(evidence,null,2)+'\n');
}finally{await f.close();}
