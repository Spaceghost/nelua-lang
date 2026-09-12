// SPDX-License-Identifier: MIT
// Separate inspector diagnostic. Never used for headline performance timings.
// A GC command acknowledgement can lag its effect in stock workerd; record both
// independently rather than equating a protocol timeout with collection failure.
import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {resolve,dirname} from 'node:path';
const pause=ms=>new Promise(r=>setTimeout(r,ms));
const out=resolve('reports/shootout/memory-diagnostic.json');
const report={purpose:'Observe heap and RSS effects of explicitly requested GC without assuming immediate CDP acknowledgement.',
  manifest:JSON.parse(await readFile('dist/shootout/manifest.json','utf8')),
  caveats:['Inspector mode and requested collections change runtime behavior. These are not speed results or production memory guarantees.',
    'after-gc-request means the request was sent, not necessarily acknowledged. Requests and replies are retained separately.',
    'A decrease after a GC request is evidence consistent with collection, not a proof of a stable long-run memory plateau.',
    'RSS includes native allocations and allocator retention. V8 and Lua counters do not account for the whole process.',
    'See https://github.com/cloudflare/workerd/issues/6824 for an upstream report of delayed GC acknowledgements and standalone GC scheduling.'],cases:[]};
function clean(stats){for(const k of ['active','luaBytes','admitted','outstanding'])assert.equal(stats[k],0,k);}
async function connect(url){
  const ws=new WebSocket(url),pending=new Map();let sequence=0;
  const timeout=setTimeout(()=>ws.close(),10000);
  try {
    await new Promise((resolve,reject)=>{ws.addEventListener('open',resolve,{once:true});ws.addEventListener('error',()=>reject(new Error('inspector websocket failed')),{once:true});ws.addEventListener('close',()=>reject(new Error('inspector closed before open')),{once:true});});
  } finally { clearTimeout(timeout); }
  ws.addEventListener('message',event=>{
    const message=JSON.parse(event.data);if(!message.id)return;
    const p=pending.get(message.id);if(!p)return;pending.delete(message.id);
    if(p.observation){p.observation.acknowledged=true;p.observation.error=message.error??null;return;}
    clearTimeout(p.timer);message.error?p.reject(new Error(JSON.stringify(message.error))):p.resolve(message.result);
  });
  ws.addEventListener('close',()=>{
    for(const p of pending.values()){
      if(p.observation){p.observation.connectionClosedBeforeReply=true;continue;}
      clearTimeout(p.timer);p.reject(new Error('inspector disconnected'));
    }
    pending.clear();
  });
  return {
    close:()=>ws.close(),
    call(method){return new Promise((resolve,reject)=>{
      const id=++sequence,timer=setTimeout(()=>{pending.delete(id);reject(new Error(`inspector timeout: ${method}`));},10000);
      pending.set(id,{resolve,reject,timer});ws.send(JSON.stringify({id,method}));
    });},
    requestCollection(){
      const id=++sequence,observation={id,acknowledged:false,error:null,connectionClosedBeforeReply:false};
      pending.set(id,{observation});ws.send(JSON.stringify({id,method:'HeapProfiler.collectGarbage'}));return observation;
    }
  };
}
for(const variant of ['javascript','baseline','entry-o2','entry-o3']){
  const original=resolve(`dist/shootout/${variant}/bench.capnp`);
  const config=(await readFile(original,'utf8')).replace(/127\.0\.0\.1:\d+/g,'127.0.0.1:9829');
  const file=resolve(dirname(original),'memory.capnp');await writeFile(file,config);
  const child=spawn(resolve('node_modules/.bin/workerd'),['serve',file,'--inspector-addr=127.0.0.1:9329'],{stdio:['ignore','pipe','pipe']});
  let logs='';child.stdout.on('data',x=>logs+=x);child.stderr.on('data',x=>logs+=x);
  const sessions=[];const record={variant,samples:[],collectionRequests:[]};report.cases.push(record);
  try{
    for(let i=0;;i++){
      if(child.exitCode!==null||child.signalCode!==null)throw new Error(logs);
      try{const r=await fetch('http://127.0.0.1:9829/stats');assert.equal(r.status,200);clean(await r.json());break;}
      catch(error){if(i===500)throw error;await pause(10);}
    }
    const targets=await(await fetch('http://127.0.0.1:9329/json/list')).json();
    assert(Array.isArray(targets)&&targets.length>0&&targets.length<=4);
    for(const target of targets){
      assert(target.webSocketDebuggerUrl);const url=new URL(target.webSocketDebuggerUrl);url.hostname='127.0.0.1';url.port='9329';
      sessions.push({name:target.title??target.id,session:await connect(url.href)});
    }
    const snapshot=async(label,requests)=>{
      const text=await readFile(`/proc/${child.pid}/status`,'utf8');
      const stats=await(await fetch('http://127.0.0.1:9829/stats')).json();clean(stats);
      const heaps=[];for(const {name,session} of sessions)heaps.push({name,...await session.call('Runtime.getHeapUsage')});
      assert(heaps.every(h=>Number.isFinite(h.usedSize)&&Number.isFinite(h.totalSize)));
      record.samples.push({label,requests,rssKiB:Number(text.match(/^VmRSS:\s+(\d+) kB$/m)[1]),stats,heaps});
      await writeFile(out,JSON.stringify(report,null,2)+'\n');
    };
    const requestCollection=async(requests)=>{
      for(const {name,session} of sessions)record.collectionRequests.push({name,requests,reply:session.requestCollection()});
      // OS and Runtime statistics are independent observations; a late GC reply
      // remains explicitly pending rather than being forged into success.
      await pause(1000);
      await snapshot('after-gc-request-1s',requests);
      await pause(1000);
      await snapshot('after-gc-request-2s',requests);
      for(const item of record.collectionRequests)assert.equal(item.reply.error,null,'GC request returned a protocol error');
    };
    const load=async(n)=>{for(let i=0;i<n;i+=1000){
      const r=await fetch('http://127.0.0.1:9829/batch/hello?n=1000&c=4&mode=mock');const text=await r.text();assert.equal(r.status,200,text);
      const b=JSON.parse(text);assert.equal(b.completed,1000);assert.equal(b.bytes,2000);assert.equal(b.counts.get,0);assert.equal(b.counts.fetch,0);clean(b.stats);
    }};
    await mkdir(dirname(out),{recursive:true});
    await load(1000);await snapshot('warm-no-forced-gc',1000);
    await load(49000);await snapshot('50k-before-gc-request',50000);await requestCollection(50000);
    await load(50000);await snapshot('100k-before-gc-request',100000);await requestCollection(100000);
    record.status='MEASURED';console.log(JSON.stringify(record));
  }catch(error){record.status='FAIL';record.error=error.message;throw error;}
  finally{
    for(const {session} of sessions)session.close();
    if(child.exitCode===null&&child.signalCode===null){const timer=setTimeout(()=>child.kill('SIGKILL'),2000);child.kill('SIGTERM');await once(child,'exit');clearTimeout(timer);}
    await mkdir(dirname(out),{recursive:true});await writeFile(out,JSON.stringify(report,null,2)+'\n');await writeFile(resolve(dirname(out),`${variant}-inspector.log`),logs);
  }
}
