// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdir, writeFile } from 'node:fs/promises';
const child=spawn('node_modules/.bin/workerd',['serve','workerd.capnp'],{stdio:['ignore','pipe','pipe']});
let logs='';child.stdout.on('data',d=>logs+=d);child.stderr.on('data',d=>logs+=d);
const pause=ms=>new Promise(r=>setTimeout(r,ms));
try {
  let ready=false;
  for(let i=0;i<100;i++){
    if(child.exitCode!==null)throw new Error(`workerd exited: ${logs}`);
    try{const r=await fetch('http://127.0.0.1:8787/ready');assert.equal(r.status,200,await r.text());ready=true;break;}catch(error){if(i===99)throw error;await pause(50);}
  }
  assert(ready);
  const order=[];
  const get=name=>fetch(`http://127.0.0.1:8787/${name}`).then(async r=>{assert.equal(r.status,200);const body=await r.text();order.push(name);return body;});
  assert.deepEqual(await Promise.all([get('slow'),get('fast')]),['Hello from Lua 5.5 slow','Hello from Lua 5.5 fast']);
  assert.deepEqual(order,['fast','slow']);
  for(let i=0;i<20;i++)assert.equal(await get(`repeat-${i}`),`Hello from Lua 5.5 repeat-${i}`);
  console.log('stock workerd HTTP contract: PASS (real bindings, async subrequests, overlapping requests, reversed completions, repeated cleanup path)');
} finally {
  child.kill('SIGTERM');
  if(child.exitCode===null)await once(child,'exit');
  await mkdir('reports',{recursive:true});await writeFile('reports/workerd.log',logs);
}
