// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { get as httpGet } from 'node:http';
import { once } from 'node:events';
import { mkdir, writeFile } from 'node:fs/promises';
const pause=ms=>new Promise(r=>setTimeout(r,ms));
async function serve(config,port,body,logName) {
  const child=spawn('node_modules/.bin/workerd',['serve',config],{stdio:['ignore','pipe','pipe']});
  let logs='';child.stdout.on('data',d=>logs+=d);child.stderr.on('data',d=>logs+=d);
  try {
    let ready=false;
    for(let i=0;i<100;i++){
      if(child.exitCode!==null)throw new Error(`workerd exited: ${logs}`);
      try{const r=await fetch(`http://127.0.0.1:${port}/ready`);assert.equal(r.status,200,await r.text());ready=true;break;}
      catch(error){if(i===99)throw error;await pause(50);}
    }
    assert(ready);await body();
  } finally {
    child.kill('SIGTERM');
    if(child.exitCode===null)await once(child,'exit');
    await mkdir('reports',{recursive:true});await writeFile(`reports/${logName}`,logs);
  }
}
await serve('workerd.capnp',8787,async()=>{
  const order=[];
  const get=name=>fetch(`http://127.0.0.1:8787/${name}`).then(async r=>{assert.equal(r.status,200);const body=await r.text();order.push(name);return body;});
  assert.deepEqual(await Promise.all([get('slow'),get('fast')]),['Hello from Lua 5.5 slow','Hello from Lua 5.5 fast']);
  assert.deepEqual(order,['fast','slow']);
  for(let i=0;i<20;i++)assert.equal(await get(`repeat-${i}`),`Hello from Lua 5.5 repeat-${i}`);
  console.log('stock workerd HTTP contract: PASS (actual service bindings, asynchronous subrequests, separate overlapping HTTP invocations, reversed completions)');
},'workerd.log');
await serve('tests/in-workerd.capnp',8788,async()=>{
  const response=await fetch('http://127.0.0.1:8788/test');const result=await response.json();
  await writeFile('reports/in-workerd-tests.json',JSON.stringify(result,null,2)+'\n');
  assert.equal(response.status,200,JSON.stringify(result));assert.equal(result.passed.length,10);
  assert.equal(result.stats.active,0);assert.equal(result.stats.luaBytes,0);assert.equal(result.stats.admitted,0);assert.equal(result.stats.outstanding,0);
  console.log('inside stock workerd: '+result.passed.length+' contract groups passed');
  for(const name of result.passed)console.log('PASS '+name);
  console.log('quiescent accounting: '+JSON.stringify(result.stats));
  const status=async()=>{const r=await fetch('http://127.0.0.1:8788/wire/status');return r.json();};
  // TCP reset proves transport-triggered abort; a quiet close may only be detected
  // on a later write, so it must still release through the independent deadline.
  for(const name of ['reset','close']) {
    const client=httpGet(`http://127.0.0.1:8788/wire/start/${name}`,r=>r.resume());
    client.on('error',()=>{}); // The client intentionally tears down this connection.
    let snapshot,record;
    try {
      for(let i=0;i<100;i++){snapshot=await status();record=snapshot.cases.find(c=>c.name===name);if(record?.started)break;await pause(5);}
      assert.equal(record?.started,true);assert.equal(snapshot.stats.active,1);
      if(name==='reset') {assert(client.socket);client.socket.resetAndDestroy();}
      else client.destroy();
      for(let i=0;i<300;i++){snapshot=await status();record=snapshot.cases.find(c=>c.name===name);if(record?.finished)break;await pause(5);}
      await writeFile(`reports/network-${name}.json`,JSON.stringify(snapshot,null,2)+'\n');
      assert.equal(record?.finished,true,JSON.stringify(snapshot));
      if(name==='reset') {
        assert.equal(record.networkAbort,true,JSON.stringify(snapshot));
        assert.notEqual(record.errorCode,'TIMEOUT','a deadline is not proof of a transport abort');
      } else {
        assert(record.networkAbort||record.errorCode==='TIMEOUT','quiet closure must abort or reach its bounded deadline');
      }
      assert.equal(snapshot.stats.active,0);assert.equal(snapshot.stats.luaBytes,0);assert.equal(snapshot.stats.admitted,0);assert.equal(snapshot.stats.outstanding,0);
      console.log(`PASS TCP ${name}: networkAbort=${record.networkAbort}, error=${record.errorCode}, all invocation/operation accounting zero`);
    } finally {client.destroy();}
  }
},'in-workerd.log');
