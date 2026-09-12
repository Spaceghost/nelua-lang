// SPDX-License-Identifier: MIT
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {LuaRuntime} from '../host/runtime.mjs';
const module=await WebAssembly.compile(await readFile(new URL('../dist/kernel.wasm',import.meta.url)));
const h={get:async()=> 'value',fetch:async()=>new Response('upstream'),log(){}};
const req=()=>new Request('https://test.invalid');
function clean(rt){for(const k of ['active','luaBytes','admitted','outstanding'])assert.equal(rt.stats()[k],0,k);}
test('compiled entry preserves response cardinality and app validation',async()=>{
  const rt=new LuaRuntime(module);
  for(const s of ["return{fetch=function()end}","return{fetch=function()return{status=200,body='x'},123 end}","return 1","return{fetch=42}"])
    await assert.rejects(rt.run(s,req(),h));
  for(const s of ["return{fetch=function(r,e)e.CONFIG:get('greeting');return{status=200,body='x'},123 end}","return{fetch=function(r,e)e.CONFIG:get('greeting')end}"])
    await assert.rejects(rt.run(s,req(),h),/exactly one response/);
  clean(rt);
});
test('mixed lifetime churn across all eight slots never aliases stale IDs',async()=>{
  const rt=new LuaRuntime(module),e=rt.e,stale=[];
  for(let round=0;round<100;round++){
    const ids=Array.from({length:8},()=>e.lw_open());
    assert(ids.every(Boolean));assert.equal(new Set(ids).size,8);assert.equal(e.lw_open(),0);
    for(const id of stale){assert.equal(e.lw_state(id),0);assert.equal(e.lw_complete(id,1,1,200,0,0),-1);}
    for(const id of ids){assert.equal(e.lw_size(id),0);assert.equal(e.lw_release(id),0);}
    stale.splice(0,stale.length,...ids);
  }
  clean(rt);
});
test('64 KiB binary body, empty buffers and source changes retain semantics',async()=>{
  const rt=new LuaRuntime(module),body=Uint8Array.from({length:65536},(_,i)=>i%256);
  const echo="return{fetch=function(r)return{status=200,body=r.body}end}";
  assert.deepEqual(new Uint8Array(await(await rt.run(echo,new Request('https://test.invalid',{method:'POST',body}),h)).arrayBuffer()),body);
  assert.equal(await(await rt.run(echo,req(),h)).text(),'');
  for(let i=0;i<20;i++)assert.equal(await(await rt.run(`return{fetch=function()return{status=200,body='${i}'}end}`,req(),h)).text(),String(i));
  clean(rt);
});
test('response validation and tracebacks remain after multiple host continuations',async()=>{
  const rt=new LuaRuntime(module);
  for(const s of ["return{fetch=function()return{status=204,body='bad'}end}","return{fetch=function()return{status=999,body='bad'}end}"])
    await assert.rejects(rt.run(s,req(),h));
  await assert.rejects(rt.run("return{fetch=function(r,e)e.CONFIG:get('x');e.UPSTREAM:fetch('/x');local function broken()error('after-two')end;broken()end}",req(),h),e=>/app.lua/.test(e.message)&&/after-two/.test(e.message)&&/stack traceback/.test(e.message));
  clean(rt);
});
