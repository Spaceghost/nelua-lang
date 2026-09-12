// SPDX-License-Identifier: MIT
import { readBounded } from '../host/runtime.mjs';
const enc = new TextEncoder(), dec = new TextDecoder();
export const payload = 'X'.repeat(65536);
export const sources = {
  hello: "return{fetch=function()return{status=200,body='ok'}end}",
  cpu: "return{fetch=function()local n=0;for i=1,10000 do n=n+i%97 end;return{status=200,body=tostring(n)}end}",
  echo64k: "return{fetch=function(r)return{status=200,body=r.body}end}",
  get: "local h=require'worker.http';return{fetch=function(r,e)return h.text(e.CONFIG:get('greeting'))end}",
  chain: "local h=require'worker.http';return{fetch=function(r,e)local g=e.CONFIG:get('greeting');local u=e.UPSTREAM:fetch('/echo');return h.text(g..':'..u.body)end}",
  ops16: "local h=require'worker.http';return{fetch=function(r,e)local g;for i=1,16 do g=e.CONFIG:get('greeting')end;return h.text(g)end}"
};
let sum=0;for(let i=1;i<=10000;i++)sum+=i%97;
export const expected = {hello:'ok',cpu:String(sum),echo64k:payload,get:'hello',chain:'hello:upstream',ops16:'hello'};
export const operationCounts = {hello:[0,0],cpu:[0,0],echo64k:[0,0],get:[1,0],chain:[1,1],ops16:[16,0]};
export const requestFor = name => new Request(`https://bench.invalid/${name}`,
  name==='echo64k'?{method:'POST',body:payload}:undefined);
export function hostFor(env, mode, counts) {
  const value=enc.encode('hello');
  return {
    async get(key,{signal}) {
      counts.get++;
      if(mode==='mock')return value;
      const r=await env.CONFIG.fetch(`https://config.invalid/${encodeURIComponent(key)}`,{signal,redirect:'manual'});
      if(r.status!==200)throw new Error('fixture CONFIG failure');
      return readBounded(r.body,signal);
    },
    async fetch(path,{signal}) {
      counts.fetch++;
      if(mode==='mock')return new Response('upstream');
      return env.UPSTREAM.fetch(`https://upstream.invalid${path}`,{signal,redirect:'manual'});
    }, log(){throw new Error('unexpected log operation in benchmark');}
  };
}
export const javascript = {
  // Functional floor, not an equally sandboxed dynamic-script runtime.
  stats:()=>({active:0,luaBytes:0,admitted:0,outstanding:0,wasmBytes:0}),
  async call(name,source,request,host) {
    let body;
    const signal=request.signal;
    if(name==='hello')body='ok';
    else if(name==='cpu'){let n=0;for(let i=1;i<=10000;i++)n+=i%97;body=String(n);}
    else if(name==='echo64k')body=await readBounded(request.body,signal);
    else if(name==='get')body=dec.decode(await host.get('greeting',{signal}));
    else if(name==='chain'){
      const greeting=dec.decode(await host.get('greeting',{signal}));
      const r=await host.fetch('/echo',{signal});
      body=greeting+':'+dec.decode(await readBounded(r.body,signal));
    }else if(name==='ops16'){
      for(let i=0;i<16;i++)body=dec.decode(await host.get('greeting',{signal}));
    }else throw new Error('unknown workload');
    return new Response(body,{headers:{'content-type':'text/plain; charset=utf-8'}});
  }
};
export function makeWorker(backend) {
  return {async fetch(request,env,ctx) {
    const url=new URL(request.url), [_,action,name]=url.pathname.split('/');
    if(action==='stats')return Response.json(backend.stats());
    if(!Object.hasOwn(sources,name))return new Response('unknown workload',{status:404});
    const mode=url.searchParams.get('mode')||'service';
    if(!['mock','service'].includes(mode))return new Response('bad mode',{status:400});
    const counts={get:0,fetch:0},host=hostFor(env,mode,counts);
    if(action==='call') {
      const task=backend.call(name,sources[name],request,host);
      ctx.waitUntil(task.then(()=>{},()=>{}));
      return task;
    }
    if(action!=='batch')return new Response('unknown action',{status:404});
    const n=Number(url.searchParams.get('n')||1), c=Number(url.searchParams.get('c')||1);
    if(!Number.isSafeInteger(n)||n<1||n>65536||!Number.isSafeInteger(c)||c<1||c>8)
      return new Response('invalid batch bounds',{status:400});
    let next=0,completed=0,bytes=0;
    const task=Promise.all(Array.from({length:c},async()=>{
      while(next++<n) {
        const r=await backend.call(name,sources[name],requestFor(name),host);
        const text=await r.text();
        if(r.status!==200||text!==expected[name])throw new Error('incorrect benchmark output');
        completed++;bytes+=text.length;
      }
    }));
    ctx.waitUntil(task.then(()=>{},()=>{}));await task;
    const [gets,fetches]=operationCounts[name],stats=backend.stats();
    if(completed!==n||counts.get!==n*gets||counts.fetch!==n*fetches)throw new Error('incorrect operation count');
    for(const key of ['active','luaBytes','admitted','outstanding'])if(stats[key]!==0)throw new Error(`not quiescent: ${key}`);
    return Response.json({completed,bytes,counts,stats});
  }};
}
