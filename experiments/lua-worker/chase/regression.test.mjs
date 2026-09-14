// SPDX-License-Identifier: MIT
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PeerModule} from '../peer/wasm.mjs';
const host={get:async()=>new Uint8Array([104,105]),fetch:async()=>new Response('ok'),log(){}};
const req=()=>new Request('https://worker.invalid/');
const pause=ms=>new Promise(r=>setTimeout(r,ms));
for(const name of ['kernel.wasm','kernel-luau.wasm']){
 const module=await WebAssembly.compile(await readFile('dist/peer/'+name));
 const app=source=>new PeerModule(module).app(source);
 const echo="return{fetch=function(r)return{status=200,body=r.body}end}";
 const get="return{fetch=function(r,e)return{status=200,body=e.CONFIG:get('x')}end}";
 function clean(a){for(const k of ['active','admitted','outstanding'])assert.equal(a.stats()[k],0,k);}
 test(name+': all slots hide previous 64 KiB results after reuse',async()=>{
  const a=app(echo),secret='S'.repeat(65536);
  for(let round=0;round<4;round++){
   const ids=Array.from({length:8},()=>a.start('POST','https://worker.invalid/',secret));assert(ids.every(Boolean));
   for(const id of ids){assert.equal(a.info(id).body.length,65536);assert.equal(a.close(id),0);}
   const empty=Array.from({length:8},()=>a.start('GET','https://worker.invalid/',''));
   for(const id of empty){assert.equal(a.info(id).body.length,0);assert.equal(a.close(id),0);}
   for(const id of ids)assert.equal(a.complete(id,1,1,200,'late'),-1);
  }
  clean(a);a.dispose();
 });
 test(name+': preabort, pending input and deadline retain cleanup',async()=>{
  const a=app(get),c=new AbortController();c.abort();await assert.rejects(a.run(req(),host,{signal:c.signal}));clean(a);
  let cancelled=false;const input=new ReadableStream({pull(){},cancel(){cancelled=true;}});
  await assert.rejects(a.run(new Request('https://worker.invalid/',{method:'POST',body:input,duplex:'half'}),host,{timeoutMs:10}));
  assert(cancelled);clean(a);a.dispose();
 });
 test(name+': late backend rejection stays charged but never resumes freed Lua',async()=>{
  const a=app(get),c=new AbortController();let reject,entered;
  const started=new Promise(r=>entered=r),h={...host,get(){entered();return new Promise((_,r)=>reject=r);}};
  const pending=assert.rejects(a.run(req(),h,{signal:c.signal}));await started;c.abort();await pending;
  assert.equal(a.stats().active,0);assert.equal(a.stats().outstanding,1);
  assert.equal(await(await a.run(req(),host)).text(),'hi');reject(Error('late secret'));await pause(1);clean(a);a.dispose();
 });
 test(name+': binary input and over-limit host result remain bounded',async()=>{
  const a=app(echo),b=Uint8Array.from({length:65536},(_,i)=>i%256);
  assert.deepEqual(new Uint8Array(await(await a.run(new Request('https://worker.invalid/',{method:'POST',body:b}),host)).arrayBuffer()),b);clean(a);a.dispose();
  const g=app(get);await assert.rejects(g.run(req(),{...host,get:async()=>new Uint8Array(65537)}),/HOST_ERROR/);clean(g);g.dispose();
 });
}
