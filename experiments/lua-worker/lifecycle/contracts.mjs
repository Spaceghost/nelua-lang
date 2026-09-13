// SPDX-License-Identifier: MIT
const pause=ms=>new Promise(r=>setTimeout(r,ms));
const eq=(a,b)=>{if(a!==b)throw new Error(`expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);};
const ok=(value,message)=>{if(!value)throw new Error(message);};
async function rejects(task,pattern){try{await task;}catch(error){if(pattern&&!pattern.test(error.message))throw error;return error;}throw new Error('expected rejection');}
const req=(path='x',body)=>new Request('https://test.invalid/'+path,body===undefined?undefined:{method:'POST',body});
const basic=value=>({get:async()=>value,fetch:async()=>new Response('upstream'),log(){}});
const storage="local h=require'worker.http';return{fetch=function(r,e)return h.text(e.CONFIG:get('greeting') or 'missing')end}";
export function idle(rt){const s=rt.stats();for(const k of ['active','luaBytes','admitted','outstanding'])eq(s[k],0);if(s.requestRefs!==undefined)eq(s.requestRefs,0);return s;}
export function retire(rt){idle(rt);rt.unloadApplication?.();const s=rt.stats();if(s.residentLuaBytes!==undefined)eq(s.residentLuaBytes,0);if(s.apps!==undefined)eq(s.apps,0);}
export async function contractSuite(make){
  const passed=[];let warm=false;
  const test=async(name,fn)=>{const rt=make();warm=typeof rt.loadApplication==='function';try{await fn(rt);}finally{retire(rt);}passed.push(name);};
  await test('real VM, CONFIG, upstream, logging and binary request data',async rt=>{
    const logs=[],h=basic('hello');h.log=m=>logs.push(m);
    const s="local h=require'worker.http';return{fetch=function(r,e,c)local g=e.CONFIG:get('greeting');local u=e.UPSTREAM:fetch('/x');c.log('done');return h.text(g..':'..u.body..':'..r.body)end}";
    eq(await(await rt.run(s,req('x','a\0b'),h)).text(),'hello:upstream:a\0b');eq(logs.join(','),'done');
  });
  await test('overlap and reversed completions retain exact binding and request',async rt=>{
    const order=[],h=basic('');h.get=async()=>{await pause(30);return 'slow';};
    const s="local h=require'worker.http';return{fetch=function(r,e)local own=r.url;local g=e.CONFIG:get('greeting');return h.text(g..':'..own)end}";
    const a=rt.run(s,req('one'),h).then(async r=>{order.push('a');return r.text();});
    const b=rt.run(s,req('two'),basic('fast')).then(async r=>{order.push('b');return r.text();});
    eq((await Promise.all([a,b])).join('|'),'slow:https://test.invalid/one|fast:https://test.invalid/two');eq(order.join(','),'b,a');
  });
  await test('missing and empty CONFIG values remain distinct',async rt=>{
    eq(await(await rt.run(storage,req(),basic(null))).text(),'missing');eq(await(await rt.run(storage,req(),basic(''))).text(),'');
  });
  await test('traceback after two continuations survives',async rt=>{
    const s="return{fetch=function(r,e)e.CONFIG:get('x');e.UPSTREAM:fetch('/x');local function broken()error('trace-needle')end;broken()end}";
    const e=await rejects(rt.run(s,req(),basic('x')),/trace-needle/);ok(/app.lua/.test(e.message)&&/stack traceback/.test(e.message),'traceback lost');
  });
  await test('runaway request stops and the same worker can serve again',async rt=>{
    const s="return{fetch=function(r)if r.url:match('/loop$')then while true do end end;return{status=200,body='ok'}end}";
    await rejects(rt.run(s,req('loop'),basic('')),/instruction budget exhausted/);eq(await(await rt.run(s,req('next'),basic(''))).text(),'ok');
  });
  await test('top-level initialization is independently budgeted',async rt=>{
    await rejects(rt.run('while true do end',req(),basic('')),/instruction budget exhausted/);
  });
  await test('allocation limit, no panic, recovery after error',async rt=>{
    const s="return{fetch=function(r)if r.url:match('/oom$')then return{status=200,body=string.rep('x',4000000)}end;return{status=200,body='ok'}end}";
    await rejects(rt.run(s,req('oom'),basic('')),/memory|allocation/i);eq(await(await rt.run(s,req('next'),basic(''))).text(),'ok');
  });
  await test('untrusted binary chunks rejected',async rt=>{await rejects(rt.run('\x1bLua\x55\x00',req(),basic('')),/binary|chunk/);});
  await test('library allowlist unchanged',async rt=>{
    const s="assert(io==nil and os==nil and debug==nil and package==nil and coroutine==nil and load==nil and pcall==nil and setmetatable==nil);return{fetch=function()return{status=200,body=_VERSION}end}";
    eq(await(await rt.run(s,req(),basic(''))).text(),'Lua 5.5');
  });
  await test('response cardinality and validation survive yields',async rt=>{
    const s="return{fetch=function(r,e)e.CONFIG:get('x');if r.url:match('/zero$')then return elseif r.url:match('/two$')then return{status=200,body='x'},1 else return{status=204,body='bad'}end end}";
    await rejects(rt.run(s,req('zero'),basic('')),/exactly one response/);await rejects(rt.run(s,req('two'),basic('')),/exactly one response/);await rejects(rt.run(s,req('body'),basic('')),/body forbidden/);
  });
  await test('cancellation, late result and new invocation',async rt=>{
    const c=new AbortController();let resolve,started;const barrier=new Promise(r=>started=r),h=basic('');h.get=()=>{started();return new Promise(r=>resolve=r);};
    const failed=rejects(rt.run(storage,req(),h,{signal:c.signal}));await barrier;c.abort();await failed;
    eq(rt.stats().active,0);eq(rt.stats().outstanding,1);if(warm)eq(rt.stats().requestRefs,0);
    eq(await(await rt.run(storage,req(),basic('fresh'))).text(),'fresh');resolve('late');await pause(1);
  });
  await test('deadline and pre-aborted requests clean up',async rt=>{
    let resolve;const h=basic('');h.get=()=>new Promise(r=>resolve=r);
    eq((await rejects(rt.run(storage,req(),h,{timeoutMs:10}))).code,'TIMEOUT');resolve('late');await pause(1);
    const c=new AbortController();c.abort();await rejects(rt.run(storage,req(),basic(''),{signal:c.signal}));
  });
  await test('body and operation quotas unchanged',async rt=>{
    const s="return{fetch=function(r,e)if r.url:match('/ops$')then for i=1,17 do e.CONFIG:get('x')end elseif r.url:match('/fetches$')then e.UPSTREAM:fetch('/x');e.UPSTREAM:fetch('/y')elseif r.url:match('/response$')then return{status=200,body=string.rep('x',65537)}else return{status=200,body=r.body}end end}";
    await rejects(rt.run(s,req('request','x'.repeat(65537)),basic('')),/body limit/);await rejects(rt.run(s,req('response'),basic('')),/body limit/);
    await rejects(rt.run(s,req('ops'),basic('')),/operation rejected/);await rejects(rt.run(s,req('fetches'),basic('')),/operation rejected/);
  });
  await test('backend exception redaction and outbound authority',async rt=>{
    const s="return{fetch=function(r,e)if r.url:match('/host$')then return e.CONFIG:get('x')else return e.UPSTREAM:fetch('https://unbound.invalid')end end}";
    const h=basic('');h.get=()=>{throw new Error('SECRET=must-not-cross');};
    const e=await rejects(rt.run(s,req('host'),h),/HOST_ERROR/);ok(!e.message.includes('must-not-cross'),'secret crossed host boundary');
    await rejects(rt.run(s,req('url'),basic('')),/CAPABILITY/);
  });
  await test('eight overlaps and cancelled uncooperative I/O remain charged',async rt=>{
    const controllers=[],resolvers=[],tasks=[];let started=0,ready;const barrier=new Promise(r=>ready=r);
    for(let i=0;i<8;i++){const c=new AbortController(),h=basic('');controllers.push(c);h.get=()=>{if(++started===8)ready();return new Promise(r=>resolvers.push(r));};tasks.push(rejects(rt.run(storage,req(String(i)),h,{signal:c.signal})));}
    await barrier;eq((await rejects(rt.run(storage,req(),basic('')))).code,'CAPACITY');if(warm)await rejects(Promise.resolve().then(()=>rt.unloadApplication()),/active/);
    for(const c of controllers)c.abort();await Promise.all(tasks);eq(rt.stats().outstanding,8);
    await rejects(rt.run(storage,req(),basic('')),/CAPACITY/);for(const r of resolvers)r('late');await pause(1);
  });
  await test('64 KiB byte-for-byte echo and empty request',async rt=>{
    const s="return{fetch=function(r)return{status=200,body=r.body}end}",b=Uint8Array.from({length:65536},(_,i)=>i%256);
    const out=new Uint8Array(await(await rt.run(s,req('body',b),basic(''))).arrayBuffer());eq(out.length,b.length);ok(out.every((v,i)=>v===b[i]),'body corruption');eq(await(await rt.run(s,req(),basic(''))).text(),'');
  });
  await test('maximum Wasm memory remains enforced',async rt=>{let failed=false;try{rt.e.memory.grow(1024);}catch{failed=true;}ok(failed,'unbounded linear memory');});
  await test('application lifetime is explicit, not a hidden global-state reset',async rt=>{
    const s="local n=0;return{fetch=function()n=n+1;return{status=200,body=tostring(n)}end}";
    eq(await(await rt.run(s,req(),basic(''))).text(),'1');eq(await(await rt.run(s,req(),basic(''))).text(),warm?'2':'1');
    if(warm){eq(rt.stats().appLoads,1);rt.unloadApplication();eq(rt.stats().residentLuaBytes,0);eq(await(await rt.run(s,req(),basic(''))).text(),'1');eq(rt.stats().appLoads,2);}
  });
  if(warm){
    await test('stale CONFIG and log handles cannot attach to a later request',async rt=>{
      const s="local old,oldlog;return{fetch=function(r,e,c)if not old then old=e.CONFIG;oldlog=c.log;return{status=200,body='saved'}elseif r.url:match('/log$')then oldlog('wrong')else old:get('x')end end}";
      eq(await(await rt.run(s,req('save'),basic(''))).text(),'saved');await rejects(rt.run(s,req('get'),basic('')),/owner mismatch/);await rejects(rt.run(s,req('log'),basic('')),/owner mismatch/);
    });
    await test('application version and memory domain cannot silently change',async rt=>{
      await rt.run(storage,req(),basic('x'));await rejects(rt.run("return{}",req(),basic('')),/explicit eviction/);
      const other=make();try{ok(other.e.memory!==rt.e.memory,'applications share linear memory');await other.run(storage,req(),basic('other'));}finally{retire(other);}
    });
    await test('request GC and app eviction after repeated success and error',async rt=>{
      const s="return{fetch=function(r)if r.url:match('/bad$')then error('expected')end;return{status=200,body='ok'}end}";
      for(let i=0;i<1000;i++){if(i%7===0)await rejects(rt.run(s,req('bad'),basic('')),/expected/);else await rt.run(s,req(),basic(''));}
      idle(rt);rt.collectApplication();ok(rt.stats().residentLuaBytes<100000,'request memory retained after diagnostic GC');eq(rt.stats().appLoads,1);
    });
  }
  return {warm,passed};
}
