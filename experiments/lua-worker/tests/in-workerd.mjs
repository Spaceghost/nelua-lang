// SPDX-License-Identifier: MIT
// Trusted contract harness. This module is absent from the normal workerd configuration.
import { runtime as rt, capabilities } from './workerd.mjs';
const storage = "local h=require'worker.http';return{fetch=function(r,e)return h.text(e.CONFIG:get('greeting') or 'missing')end}";
const req = (name='test') => new Request(`https://test.invalid/${name}`);
const host = value => ({get:async()=>value,fetch:async()=>new Response('ok'),log(){}});
const pause = ms => new Promise(resolve=>setTimeout(resolve,ms));
function eq(a,b) { if(a!==b)throw new Error(`expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }
function clean() { eq(rt.stats().active,0);eq(rt.stats().luaBytes,0);eq(rt.stats().admitted,0); }
async function rejects(promise, pattern) {
  try { await promise; } catch(error) {
    if(pattern && !pattern.test(error.message))throw error;
    return error;
  }
  throw new Error('expected rejection');
}
async function exercise(env) {
  const passed=[];
  const test=async(name,fn)=>{await fn();clean();passed.push(name);};
  await test('actual configured CONFIG and asynchronous UPSTREAM',async()=>{
    const s="local h=require'worker.http';return{fetch=function(r,e,c)local g=e.CONFIG:get('greeting');local u=e.UPSTREAM:fetch('/echo/proof');c.log('contract');return h.text(g..':'..u.body)end}";
    eq(await(await rt.run(s,req(),capabilities(env))).text(),'Hello from Lua 5.5:proof');
  });
  await test('distinct concurrent invocation bindings complete out of order',async()=>{
    const order=[],slow=host('');slow.get=async()=>{await pause(30);return 'slow';};
    const a=rt.run(storage,req('a'),slow).then(async r=>{order.push('a');return r.text();});
    const b=rt.run(storage,req('b'),host('fast')).then(async r=>{order.push('b');return r.text();});
    eq((await Promise.all([a,b])).join(','),'slow,fast');eq(order.join(','),'b,a');
  });
  await test('traceback survives an asynchronous continuation',async()=>{
    const e=await rejects(rt.run("return{fetch=function(r,e)e.CONFIG:get('greeting');local function broken()error('workerd-trace-needle')end;broken()end}",req(),capabilities(env)),/workerd-trace-needle/);
    if(!/app.lua/.test(e.message)||!/stack traceback/.test(e.message))throw e;
  });
  await test('runaway Lua loop and initialization loop stop',async()=>{
    await rejects(rt.run('return{fetch=function()while true do end end}',req(),host('')),/instruction budget exhausted/);
    await rejects(rt.run('while true do end',req(),host('')),/instruction budget exhausted/);
  });
  await test('allocation, text-only loading and response bounds',async()=>{
    await rejects(rt.run("return{fetch=function()return{status=200,body=string.rep('x',4000000)}end}",req(),host('')),/memory|allocation/i);
    await rejects(rt.run(new Uint8Array([27,76,117,97,85,0]),req(),host('')),/binary|chunk/i);
    await rejects(rt.run("return{fetch=function()return{status=200,body=string.rep('x',65537)}end}",req(),host('')),/body limit/);
  });
  await test('cancellation releases Lua and ignores a late callback after reuse',async()=>{
    let resolve,started;const begin=new Promise(r=>started=r),c=new AbortController(),h=host('');
    h.get=()=>{started();return new Promise(r=>resolve=r);};
    const failed=rejects(rt.run(storage,req(),h,{signal:c.signal}));
    await begin;c.abort();await failed;clean();eq(rt.stats().outstanding,1);
    eq(await(await rt.run(storage,req(),host('fresh'))).text(),'fresh');
    resolve('late');await pause(1);eq(rt.stats().outstanding,0);
  });
  await test('deadline cleanup and backend errors do not leak credentials',async()=>{
    let resolve;const h=host('');h.get=()=>new Promise(r=>resolve=r);
    const e=await rejects(rt.run(storage,req(),h,{timeoutMs:10}));eq(e.code,'TIMEOUT');clean();resolve('late');await pause(1);
    h.get=()=>{throw new Error('secret=never-copy-this');};
    const backend=await rejects(rt.run(storage,req(),h),/HOST_ERROR/);
    if(backend.message.includes('never-copy-this'))throw new Error('backend secret disclosure');
  });
  await test('cancelled input reader is cleaned up before Lua allocation',async()=>{
    const c=new AbortController();let cancelled=false;
    const body=new ReadableStream({pull(){},cancel(){cancelled=true;}});
    const request=new Request('https://test.invalid/input',{method:'POST',body});
    const task=rejects(rt.run(storage,request,host(''),{signal:c.signal}));
    await pause(1);c.abort();await task;eq(cancelled,true);
  });
  await test('invocation admission and uncancellable I/O remain bounded',async()=>{
    const resolvers=[],controllers=[],tasks=[];let started=0,allStarted;
    const barrier=new Promise(r=>allStarted=r);
    for(let i=0;i<8;i++) {
      const c=new AbortController(),h=host('');controllers.push(c);
      h.get=()=>{started++;if(started===8)allStarted();return new Promise(r=>resolvers.push(r));};
      tasks.push(rejects(rt.run(storage,req(String(i)),h,{signal:c.signal})));
    }
    await barrier;
    const full=await rejects(rt.run(storage,req('ninth'),host('')));eq(full.code,'CAPACITY');
    for(const c of controllers)c.abort();await Promise.all(tasks);clean();eq(rt.stats().outstanding,8);
    await rejects(rt.run(storage,req('orphan-cap'),host('')),/CAPACITY/);clean();eq(rt.stats().outstanding,8);
    for(const resolve of resolvers)resolve('late');await pause(1);eq(rt.stats().outstanding,0);
    eq(await(await rt.run(storage,req('recovered'),host('recovered'))).text(),'recovered');
  });
  await test('capability type and outward origin are enforced',async()=>{
    await rejects(rt.run("return{fetch=function(r,e)return e.CONFIG:fetch('/wrong')end}",req(),host('')),/UPSTREAM capability required/);
    await rejects(rt.run("return{fetch=function(r,e)return e.UPSTREAM:fetch('https://unconfigured.invalid/')end}",req(),host('')),/CAPABILITY/);
  });
  return {passed,stats:rt.stats()};
}
export default {async fetch(request,env) {
  if(new URL(request.url).pathname==='/ready')return new Response('ready');
  try{return Response.json(await exercise(env));}
  catch(error){return Response.json({error:error.message,stack:error.stack,stats:rt.stats()},{status:500});}
}};
