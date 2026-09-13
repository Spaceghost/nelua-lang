import assert from 'node:assert/strict';
import {writeFile,readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {get as httpGet} from 'node:http';
import {once} from 'node:events';
const config=`using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
 services=[(name="main",worker=(compatibilityDate="2026-09-01",compatibilityFlags=["enable_request_signal"],modules=[
 (name="worker.mjs",esModule=embed "contract-worker.mjs"),(name="contracts.mjs",esModule=embed "contracts.mjs"),
 (name="runtime.mjs",esModule=embed "../host/runtime.mjs"),(name="kernel.wasm",wasm=embed "../dist/kernel.wasm")],
 bindings=[(name="CONFIG",service="config"),(name="UPSTREAM",service="upstream")])),
 (name="config",worker=(compatibilityDate="2026-09-01",modules=[(name="config.mjs",esModule=embed "../examples/config.mjs")])),
 (name="upstream",worker=(compatibilityDate="2026-09-01",modules=[(name="upstream.mjs",esModule=embed "../examples/upstream.mjs")]))],
 sockets=[(name="http",address="127.0.0.1:8789",http=(),service="main")]);`;
await writeFile('lifecycle/contracts.capnp',config);
const child=spawn('node_modules/.bin/workerd',['serve','lifecycle/contracts.capnp'],{stdio:['ignore','pipe','pipe']});
let logs='';child.stdout.on('data',x=>logs+=x);child.stderr.on('data',x=>logs+=x);
const pause=ms=>new Promise(r=>setTimeout(r,ms)),base='http://127.0.0.1:8789';
const result={};
try{
  for(let i=0;;i++){if(child.exitCode!==null)throw Error(logs);try{const r=await fetch(base+'/ready');assert.equal(r.status,200);await r.text();break;}catch(e){if(i>100)throw e;await pause(20);}}
  const suite=await fetch(base+'/suite');const raw=await suite.text();assert.equal(suite.status,200,raw);result.suite=JSON.parse(raw);
  const order=[];
  const get=name=>fetch(base+'/actual/'+name).then(async r=>{const text=await r.text();assert.equal(r.status,200,text);order.push(name);return text;});
  assert.deepEqual(await Promise.all([get('slow'),get('fast')]),['Hello from Lua 5.5:slow','Hello from Lua 5.5:fast']);assert.deepEqual(order,['fast','slow']);
  result.actualBindings='PASS';
  const stats=async()=>{const r=await fetch(base+'/stats');return r.json();};
  for(const name of ['reset','close']){
    const client=httpGet(base+'/wire/'+name,r=>r.resume());client.on('error',()=>{});
    try{
      let record;
      for(let i=0;i<200;i++){record=(await stats()).probes.find(p=>p.name===name);if(record?.started)break;await pause(5);}assert.equal(record?.started,true);
      if(name==='reset')client.socket.resetAndDestroy();else client.destroy();
      for(let i=0;i<400;i++){record=(await stats()).probes.find(p=>p.name===name);if(record?.finished)break;await pause(5);}assert.equal(record?.finished,true,JSON.stringify(record));
      if(name==='reset'){assert.equal(record.networkAbort,true);assert.notEqual(record.code,'TIMEOUT');}else assert(record.networkAbort||record.code==='TIMEOUT');
      for(const k of ['active','luaBytes','admitted','outstanding'])assert.equal(record.stats[k],0);
      if(result.suite.warm){assert.equal(record.stats.residentLuaBytes,0);assert.equal(record.stats.apps,0);}
      result[name]=record;
    }finally{client.destroy();}
  }
  await writeFile('reports/lifecycle-workerd.json',JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify(result,null,2));
}finally{
  child.kill('SIGTERM');if(child.exitCode===null&&child.signalCode===null)await once(child,'exit');
  await writeFile('reports/lifecycle-workerd.log',logs);
}
