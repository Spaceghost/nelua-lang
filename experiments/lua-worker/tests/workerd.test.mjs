// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
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
},'in-workerd.log');
