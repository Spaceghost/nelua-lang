// SPDX-License-Identifier: MIT
const assert=(condition,message)=>{if(!condition)throw new Error(message);};
const request=(name,body)=>new Request('https://test.invalid/'+name,body===undefined?{}:{method:'POST',body});
const host=()=>({get:async()=> 'ok',fetch:async()=>new Response('ok'),log(){}});
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const source="return{fetch=function(r,e)if r.url:match('/get$')then return{status=200,body=e.CONFIG:get('x')}elseif r.url:match('/bad$')then error('reused-error')else return{status=200,body=r.body}end end}";
function idle(rt){for(const k of ['active','luaBytes','admitted','outstanding','requestRefs'])assert((rt.stats()[k]??0)===0,k+' not zero');}
async function rejects(task,pattern){try{await task;}catch(e){if(pattern&&!pattern.test(e.message))throw e;return;}throw Error('expected rejection');}
export async function extraSuite(make){
 const passed=[];
 const test=async(name,fn)=>{const rt=make();try{await fn(rt);idle(rt);}finally{rt.unloadApplication();assert(rt.stats().residentLuaBytes===0,'app allocations not released');}passed.push(name);};
 await test('completion signals keep public reason fields without leaking into later requests',async rt=>{
   const signals=[],h=host();h.get=async(_,{signal})=>{signals.push(signal);assert(!signal.aborted,'new signal already aborted');return 'ok';};
   for(let i=0;i<30;i++)await rt.run(source,request('get'),h);
   assert(new Set(signals).size===30,'signals shared across requests');
   for(const signal of signals){assert(signal.aborted,'completion not signalled');assert(signal.reason.code==='CANCELLED','reason code');assert(signal.reason.message==='invocation finished','reason message');}
 });
 await test('response bytes survive later requests and Wasm memory growth',async rt=>{
   const a=Uint8Array.from({length:65536},(_,i)=>i%251),b=new Uint8Array(65536).fill(123);
   const first=await rt.run(source,request('echo',a),host());
   for(let i=0;i<20;i++)await rt.run(source,request('echo',b),host());
   rt.e.memory.grow(1);
   const saved=new Uint8Array(await first.arrayBuffer());assert(saved.length===a.length&&saved.every((v,i)=>v===a[i]),'response retained mutable Wasm view');
 });
 await test('empty coroutine reuse resets errors hooks and ownership',async rt=>{
   for(let i=0;i<100;i++){
     await rejects(rt.run(source,request('bad'),host()),/reused-error/);
     assert(await(await rt.run(source,request('get'),host())).text()==='ok','reused coroutine failed');
   }
   const s=rt.stats();if(s.cachedCoroutines!==undefined)assert(s.cachedCoroutines===1,'sequential requests did not reuse one empty coroutine');
 });
 await test('pooled capacity is bounded and charged through app eviction',async rt=>{
   let release;const barrier=new Promise(r=>release=r),h=host();h.get=async()=>{await barrier;return'ok';};
   const tasks=Array.from({length:8},(_,i)=>rt.run(source,request('get'),h));
   await pause(1);assert(rt.stats().active===8,'overlap did not hold eight invocations');release();await Promise.all(tasks);
   const s=rt.stats();if(s.cachedCoroutines!==undefined)assert(s.cachedCoroutines===8,'pool capacity/accounting mismatch');
   rt.collectApplication();assert(rt.stats().residentLuaBytes<150000,'empty pool retains excessive request memory');
 });
 await test('bodyless requests still reject pre-aborted signals and invalid deadlines',async rt=>{
   const c=new AbortController();c.abort(new Error('caller cancelled'));
   await rejects(rt.run(source,request('echo'),host(),{signal:c.signal}),/caller cancelled/);
   for(const timeoutMs of [0,-1,Infinity,NaN,60001])await rejects(rt.run(source,request('echo'),host(),{timeoutMs}),/invalid timeout/);
 });
 await test('cancellation of stalled input still cancels the reader',async rt=>{
   const c=new AbortController();let cancelled=false;
   const stream=new ReadableStream({pull(){},cancel(){cancelled=true;}});
   const task=rejects(rt.run(source,new Request('https://test.invalid/echo',{method:'POST',body:stream,duplex:'half'}),host(),{signal:c.signal}));
   await pause(1);c.abort();await task;assert(cancelled,'input reader was not cancelled');
 });
 return passed;
}
