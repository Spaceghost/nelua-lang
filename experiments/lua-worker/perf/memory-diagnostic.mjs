// SPDX-License-Identifier: MIT
// Separate diagnostic, never included in performance timings or production configuration.
import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {resolve,dirname} from 'node:path';
const pause=ms=>new Promise(r=>setTimeout(r,ms));
const out=resolve('reports/shootout/memory-diagnostic.json');
const report={purpose:'Distinguish retained JS heap from uncollected garbage under an inspector-enabled diagnostic host.',
  manifest:JSON.parse(await readFile('dist/shootout/manifest.json','utf8')),
  caveats:['Inspector mode and forced collections change runtime behavior. These are not speed results or production memory guarantees.',
    'RSS includes native allocations and allocator retention; V8 used heap and Lua live-byte counters do not account for the whole process.',
    'The probe is a finite hello workload, not a proof against every leak or untrusted-tenant resource attack.'],cases:[]};
function clean(stats){for(const k of ['active','luaBytes','admitted','outstanding'])assert.equal(stats[k],0,k);}
async function connect(url){
  const ws=new WebSocket(url),pending=new Map();let sequence=0;
  const timeout=setTimeout(()=>ws.close(),10000);
  try {
    await new Promise((resolve,reject)=>{ws.addEventListener('open',resolve,{once:true});ws.addEventListener('error',()=>reject(new Error('inspector websocket failed')),{once:true});ws.addEventListener('close',()=>reject(new Error('inspector closed before open')),{once:true});});
  } finally { clearTimeout(timeout); }
  ws.addEventListener('message',event=>{const message=JSON.parse(event.data);if(!message.id)return;const p=pending.get(message.id);if(!p)return;pending.delete(message.id);clearTimeout(p.timer);message.error?p.reject(new Error(JSON.stringify(message.error))):p.resolve(message.result);});
  ws.addEventListener('close',()=>{for(const p of pending.values()){clearTimeout(p.timer);p.reject(new Error('inspector disconnected'));}pending.clear();});
  return {close:()=>ws.close(),call(method){return new Promise((resolve,reject)=>{const id=++sequence,timer=setTimeout(()=>{pending.delete(id);reject(new Error(`inspector timeout: ${method}`));},10000);pending.set(id,{resolve,reject,timer});ws.send(JSON.stringify({id,method}));});}};
}
for(const variant of ['javascript','baseline','entry-o3']){
  const original=resolve(`dist/shootout/${variant}/bench.capnp`);
  const config=(await readFile(original,'utf8')).replace(/127\.0\.0\.1:\d+/g,'127.0.0.1:9829');
  const file=resolve(dirname(original),'memory.capnp');await writeFile(file,config);
  const child=spawn(resolve('node_modules/.bin/workerd'),['serve',file,'--inspector-addr=127.0.0.1:9329'],{stdio:['ignore','pipe','pipe']});
  let logs='';child.stdout.on('data',x=>logs+=x);child.stderr.on('data',x=>logs+=x);
  const sessions=[];const record={variant,samples:[]};report.cases.push(record);
  try{
    for(let i=0;;i++){
      if(child.exitCode!==null||child.signalCode!==null)throw new Error(logs);
      try{const r=await fetch('http://127.0.0.1:9829/stats');assert.equal(r.status,200);clean(await r.json());break;}
      catch(error){if(i===500)throw error;await pause(10);}
    }
    const targets=await(await fetch('http://127.0.0.1:9329/json/list')).json();
    assert(Array.isArray(targets)&&targets.length>0&&targets.length<=4);
    for(const target of targets){assert(target.webSocketDebuggerUrl);const url=new URL(target.webSocketDebuggerUrl);url.hostname='127.0.0.1';url.port='9329';sessions.push({name:target.title??target.id,session:await connect(url.href)});}
    const snapshot=async(label,requests)=>{
      const text=await readFile(`/proc/${child.pid}/status`,'utf8');
      const stats=await(await fetch('http://127.0.0.1:9829/stats')).json();clean(stats);
      const heaps=[];for(const {name,session} of sessions)heaps.push({name,...await session.call('Runtime.getHeapUsage')});
      record.samples.push({label,requests,rssKiB:Number(text.match(/^VmRSS:\s+(\d+) kB$/m)[1]),stats,heaps});
    };
    const collect=async()=>{for(const {session} of sessions)await session.call('HeapProfiler.collectGarbage');await pause(50);};
    const load=async(n)=>{for(let i=0;i<n;i+=1000){const r=await fetch('http://127.0.0.1:9829/batch/hello?n=1000&c=4&mode=mock');const text=await r.text();assert.equal(r.status,200,text);const b=JSON.parse(text);assert.equal(b.completed,1000);assert.equal(b.bytes,2000);assert.equal(b.counts.get,0);assert.equal(b.counts.fetch,0);clean(b.stats);}};
    await load(1000);await collect();await snapshot('warm-post-gc',1000);
    await load(49000);await snapshot('50k-before-gc',50000);await collect();await snapshot('50k-post-gc',50000);
    await load(50000);await snapshot('100k-before-gc',100000);await collect();await snapshot('100k-post-gc',100000);
    record.status='PASS';console.log(JSON.stringify(record));
  }catch(error){record.status='FAIL';record.error=error.message;throw error;}
  finally{
    for(const {session} of sessions)session.close();
    if(child.exitCode===null&&child.signalCode===null){const timer=setTimeout(()=>child.kill('SIGKILL'),2000);child.kill('SIGTERM');await once(child,'exit');clearTimeout(timer);}
    await mkdir(dirname(out),{recursive:true});await writeFile(out,JSON.stringify(report,null,2)+'\n');await writeFile(resolve(dirname(out),`${variant}-inspector.log`),logs);
  }
}
