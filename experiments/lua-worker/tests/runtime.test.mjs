// SPDX-License-Identifier: MIT
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { LuaRuntime } from '../host/runtime.mjs';
const module = await WebAssembly.compile(await readFile(new URL('../dist/kernel.wasm', import.meta.url)));
const source = `local http=require'worker.http'
return {fetch=function(request,env,ctx)
  local greeting=env.CONFIG:get('greeting')
  local r=env.UPSTREAM:fetch('/echo')
  ctx.log('served')
  return http.text((greeting or 'absent')..':'..r.body..':'..request.body)
end}`;
const storageOnly = "local h=require'worker.http';return{fetch=function(r,e,c)return h.text(e.CONFIG:get('greeting') or 'missing')end}";
const request = (name='x') => new Request(`https://worker.invalid/${name}`, {method:'POST',body:name});
const delay = ms => new Promise(resolve => setTimeout(resolve,ms));
const host = value => ({get:async()=>value,fetch:async()=>new Response('upstream'),log() {}});
function clean(runtime) { assert.equal(runtime.stats().active,0); assert.equal(runtime.stats().luaBytes,0); assert.equal(runtime.stats().admitted,0); }

test('actual Lua VM, async CONFIG, subrequest, logging, and binary-safe request body', async()=>{
  const rt=new LuaRuntime(module); const logs=[]; const h=host('hello'); h.log=m=>logs.push(m);
  assert.equal(await (await rt.run(source,request('a\0b'),h)).text(),'hello:upstream:a\0b');
  assert.deepEqual(logs,['served']); clean(rt);
});
test('overlapping invocations have different bindings and finish in reverse order', async()=>{
  const rt=new LuaRuntime(module), order=[];
  const h=host('slow'); h.get=async()=>{await delay(40); return 'slow';};
  const a=rt.run(source,request('one'),h).then(async r=>{order.push('a');return r.text();});
  const b=rt.run(source,request('two'),host('fast')).then(async r=>{order.push('b');return r.text();});
  assert.deepEqual(await Promise.all([a,b]),['slow:upstream:one','fast:upstream:two']);
  assert.deepEqual(order,['b','a']); clean(rt);
});
test('Lua globals do not leak between invocations',async()=>{
  const rt=new LuaRuntime(module), s="counter=(counter or 0)+1;return{fetch=function()return{status=200,body=tostring(counter)}end}";
  for(let i=0;i<5;i++) assert.equal(await(await rt.run(s,request(),host(''))).text(),'1'); clean(rt);
});
test('missing storage is nil rather than an empty value',async()=>{
  const rt=new LuaRuntime(module);
  assert.equal(await(await rt.run(storageOnly,request(),host(null))).text(),'missing');
  assert.equal(await(await rt.run(storageOnly,request(),host(''))).text(),''); clean(rt);
});
test('Lua error retains application filename, message, and traceback',async()=>{
  const rt=new LuaRuntime(module);
  await assert.rejects(rt.run("return{fetch=function() local function broken() error('trace-needle') end; broken() end}",request(),host('')),
    e=>/app.lua/.test(e.message)&&/trace-needle/.test(e.message)&&/stack traceback/.test(e.message)); clean(rt);
});
test('runaway Lua instructions are stopped',async()=>{
  const rt=new LuaRuntime(module);
  await assert.rejects(rt.run('return{fetch=function() while true do end end}',request(),host('')),/instruction budget exhausted/); clean(rt);
});
test('initialization code is also instruction-budgeted',async()=>{
  const rt=new LuaRuntime(module);
  await assert.rejects(rt.run('while true do end',request(),host('')),/instruction budget exhausted/); clean(rt);
});
test('allocation limit fails without panicking or retaining Lua memory',async()=>{
  const rt=new LuaRuntime(module);
  await assert.rejects(rt.run("return{fetch=function()return{status=200,body=string.rep('x',4000000)}end}",request(),host('')),/memory|allocation/i); clean(rt);
});
test('binary chunks and ambient libraries are unavailable',async()=>{
  const rt=new LuaRuntime(module);
  await assert.rejects(rt.run(new Uint8Array([27,76,117,97,85,0]),request(),host('')),/binary|chunk/i);
  const s="assert(io==nil and os==nil and debug==nil and package==nil and coroutine==nil and load==nil and pcall==nil and setmetatable==nil);return{fetch=function()return{status=200,body=_VERSION}end}";
  assert.equal(await(await rt.run(s,request(),host(''))).text(),'Lua 5.5'); clean(rt);
});
test('cancellation releases state and a late backend result cannot resume a new invocation',async()=>{
  const rt=new LuaRuntime(module), c=new AbortController(); let resolve, started;
  const begin=new Promise(r=>started=r); const h=host(''); h.get=()=>{started();return new Promise(r=>resolve=r);};
  const task=rt.run(storageOnly,request(),h,{signal:c.signal}); const rejected=assert.rejects(task);
  await begin; c.abort(); await rejected; clean(rt);
  assert.equal(rt.stats().outstanding,1); // Uncancellable I/O remains charged until it actually settles.
  assert.equal(await(await rt.run(storageOnly,request(),host('fresh'))).text(),'fresh');
  resolve('late'); await delay(5); clean(rt); assert.equal(rt.stats().outstanding,0);
});
test('deadline and pre-aborted invocation clean up',async()=>{
  const rt=new LuaRuntime(module); let resolve;
  const h=host(''); h.get=()=>new Promise(r=>resolve=r);
  await assert.rejects(rt.run(storageOnly,request(),h,{timeoutMs:10}),e=>e.code==='TIMEOUT');
  clean(rt); resolve('late'); await delay(1);
  const c=new AbortController();c.abort();await assert.rejects(rt.run(source,request(),host(''),{signal:c.signal}));clean(rt);
});
test('request, response, storage value, and operation limits are enforced',async()=>{
  const rt=new LuaRuntime(module);
  await assert.rejects(rt.run(source,new Request('https://test.invalid',{method:'POST',body:'x'.repeat(65537)}),host('')),/body limit/);
  await assert.rejects(rt.run("return{fetch=function()return{status=200,body=string.rep('x',65537)}end}",request(),host('')),/body limit/);
  await assert.rejects(rt.run(storageOnly,request(),host('x'.repeat(65537))),/BODY_LIMIT/);
  await assert.rejects(rt.run("return{fetch=function(r,e)e.UPSTREAM:fetch('/a');e.UPSTREAM:fetch('/b')end}",request(),host('')),/operation rejected/);
  await assert.rejects(rt.run("return{fetch=function(r,e)for i=1,17 do e.CONFIG:get('a')end end}",request(),host('')),/operation rejected/);clean(rt);
});
test('host exceptions cannot disclose credentials to Lua',async()=>{
  const rt=new LuaRuntime(module), h=host('');h.get=()=>{throw new Error('SECRET=do-not-copy');};
  await assert.rejects(rt.run(storageOnly,request(),h),e=>/HOST_ERROR/.test(e.message)&&!e.message.includes('do-not-copy'));clean(rt);
});
test('outbound authority cannot be widened to arbitrary URLs',async()=>{
  const rt=new LuaRuntime(module);
  await assert.rejects(rt.run("return{fetch=function(r,e)return e.UPSTREAM:fetch('https://not-authorized.invalid/')end}",request(),host('')),/CAPABILITY/);clean(rt);
});
test('wrong operation sequence and released handle are rejected by the kernel',()=>{
  const rt=new LuaRuntime(module), e=rt.e, id=e.lw_open();
  const enc=new TextEncoder();
  assert.equal(rt.withBytes([enc.encode(storageOnly),enc.encode('GET'),enc.encode('https://test.invalid'),new Uint8Array()],(...args)=>e.lw_start(id,...args,123)),3);
  assert.equal(e.lw_complete(id,e.lw_sequence(id)+1,1,200,0,0),-1);
  const seq=e.lw_sequence(id);assert.equal(e.lw_release(id),0);
  const newer=e.lw_open();assert.notEqual(newer,id);
  assert.equal(e.lw_complete(id,seq,1,200,0,0),-1);assert.equal(e.lw_state(newer),1);assert.equal(e.lw_release(newer),0);clean(rt);
});
test('Wasm linear memory has a fixed maximum',()=>{
  const rt=new LuaRuntime(module);assert.throws(()=>rt.e.memory.grow(1024),RangeError);clean(rt);
});
test('external supervisor kills a process whose event loop cannot service timers',async()=>{
  await assert.rejects(promisify(execFile)(process.execPath,['scripts/supervise.mjs','100',process.execPath,'-e','while(true){}']),e=>e.code===124);
});
