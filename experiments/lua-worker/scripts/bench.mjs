// SPDX-License-Identifier: MIT
// Descriptive samples, not comparative performance claims or hosted cold-start numbers.
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { cpus, platform, arch } from 'node:os';
import { performance } from 'node:perf_hooks';
import { LuaRuntime } from '../host/runtime.mjs';
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const wasm = await readFile('dist/kernel.wasm');
const module = await WebAssembly.compile(wasm);
const summarize = values => {
  const sorted = [...values].sort((a,b)=>a-b);
  return { n: sorted.length, min: sorted[0], median: sorted[Math.floor(sorted.length/2)],
    p95: sorted[Math.min(sorted.length-1, Math.floor(sorted.length*0.95))], max: sorted.at(-1), samples: values };
};
const result = {
  provenance: { node: process.version, platform: platform(), arch: arch(), cpu: cpus()[0]?.model,
    toolchain: JSON.parse(await readFile('toolchain.json','utf8')), wasmBytes: wasm.byteLength },
  caveats: [
    'One shared CI machine; descriptive samples only; no competing runtime baseline.',
    'Module-instantiation measurements reuse a compiled module and are not hosted cold starts.',
    'Local workerd cold samples include process launch, compilation, fixture delay, HTTP, and polling.',
    'RSS includes all workerd services and V8; Wasm linear memory is not total resident memory.',
    'JS/Wasm ping is a synchronous ABI call; it does not measure an asynchronous capability round trip.'
  ]
};
const instantiate=[];
for(let i=0;i<30;i++) { const t=performance.now();new LuaRuntime(module);instantiate.push(performance.now()-t); }
result.compiledModuleInstantiationMs=summarize(instantiate);
const rt=new LuaRuntime(module), ping=[]; let sum=0;
for(let j=0;j<10;j++) {
  const count=100000, t=performance.now();
  for(let i=0;i<count;i++)sum=(sum+rt.e.lw_ping(i))>>>0;
  ping.push((performance.now()-t)*1e6/count);
}
result.synchronousJsWasmPingNs=summarize(ping);result.pingChecksum=sum;
const plain="return{fetch=function()return{status=200,body='ok'}end}";
const binding="local h=require'worker.http';return{fetch=function(r,e)return h.text(e.CONFIG:get('x'))end}";
const host={get:async()=> 'ok',fetch:async()=>new Response('ok'),log(){}};
for(const [name,source] of [['plain',plain],['oneResolvedStorageOperation',binding]]) {
  for(let i=0;i<25;i++)await rt.run(source,new Request('https://bench.invalid'),host);
  const samples=[];
  for(let i=0;i<200;i++) {
    const t=performance.now();const response=await rt.run(source,new Request('https://bench.invalid'),host);
    assert.equal(await response.text(),'ok');samples.push(performance.now()-t);
  }
  result[`${name}NodeInvocationMs`]=summarize(samples);
}
assert.equal(rt.stats().active,0);assert.equal(rt.stats().luaBytes,0);result.quiescentKernel=rt.stats();
const cold=[];const rss=[];let steady=[];
for(let sample=0;sample<3;sample++) {
  const started=performance.now();
  const child=spawn('node_modules/.bin/workerd',['serve','workerd.capnp'],{stdio:['ignore','pipe','pipe']});
  let logs='';child.stderr.on('data',d=>logs+=d);child.stdout.resume();
  try {
    let connected=false;
    for(let retry=0;retry<200;retry++) {
      if(child.exitCode!==null)throw new Error(logs);
      try { const r=await fetch('http://127.0.0.1:8787/bench');assert.equal(r.status,200);await r.arrayBuffer();connected=true;break; }
      catch(error) { if(retry===199)throw error;await pause(5); }
    }
    assert(connected);cold.push(performance.now()-started);
    if(sample===0) {
      for(let i=0;i<100;i++) {
        const t=performance.now();const r=await fetch('http://127.0.0.1:8787/bench');assert.equal(r.status,200);await r.arrayBuffer();
        if(i>=20)steady.push(performance.now()-t);
        if(i===19||i===59||i===99) {
          const status=await readFile(`/proc/${child.pid}/status`,'utf8');
          rss.push({afterRequests:i+1,kib:Number(status.match(/^VmRSS:\s+(\d+) kB$/m)?.[1])});
        }
      }
    }
  } finally { child.kill('SIGTERM');if(child.exitCode===null)await once(child,'exit'); }
}
result.localWorkerdProcessToFirstResponseMs=summarize(cold);
result.localWorkerdSteadyHttpMs=summarize(steady);
result.localWorkerdRss=rss;
await mkdir('reports',{recursive:true});await writeFile('reports/benchmark.json',JSON.stringify(result,null,2)+'\n');
for(const [key,value] of Object.entries(result)) {
  if(value?.samples)console.log(key,JSON.stringify({...value,samples:undefined}));
  else if(['quiescentKernel','localWorkerdRss','caveats'].includes(key))console.log(key,JSON.stringify(value));
}
