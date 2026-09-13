// SPDX-License-Identifier: MIT
import {readBounded} from './runtime.mjs';
const enc=new TextEncoder(),dec=new TextDecoder();
export const payload='X'.repeat(65536);
let sum=0;for(let i=1;i<=10000;i++)sum+=i%97;
export const expected={hello:'ok',cpu:String(sum),echo64k:payload,get:'hello',chain:'hello:upstream',ops16:'hello'};
const opCount={hello:[0,0],cpu:[0,0],echo64k:[0,0],get:[1,0],chain:[1,1],ops16:[16,0]};
export const requestFor=name=>new Request('https://bench.invalid/'+name,name==='echo64k'?{method:'POST',body:payload}:undefined);
function hostFor(env,mode,counts){return{
  async get(key,{signal}){counts.get++;if(mode==='mock')return enc.encode('hello');const r=await env.CONFIG.fetch('https://config.invalid/'+encodeURIComponent(key),{signal,redirect:'manual'});if(r.status!==200)throw Error('CONFIG');return readBounded(r.body,signal);},
  async fetch(path,{signal}){counts.fetch++;return mode==='mock'?new Response('upstream'):env.UPSTREAM.fetch('https://upstream.invalid'+path,{signal,redirect:'manual'});},log(){throw Error('unexpected log');}
};}
export function javascript(){let lifetime=0;return{
  stats(){return{active:0,luaBytes:0,admitted:0,outstanding:0,wasmBytes:0};},
  async run(name,request,host){
    let body;const signal=request.signal;
    if(name==='hello')body='ok';
    else if(name==='cpu'){let n=0;for(let i=1;i<=10000;i++)n+=i%97;body=String(n);}
    else if(name==='echo64k')body=await readBounded(request.body,signal);
    else if(name==='get')body=dec.decode(await host.get('greeting',{signal}));
    else if(name==='chain'){const g=dec.decode(await host.get('greeting',{signal}));const r=await host.fetch('/echo',{signal});body=g+':'+dec.decode(await readBounded(r.body,signal));}
    else if(name==='ops16'){for(let i=0;i<16;i++)body=dec.decode(await host.get('greeting',{signal}));}
    else if(name==='lifetime')body=String(++lifetime);
    else throw Error('unknown workload');
    return new Response(body,{headers:{'content-type':'text/plain; charset=utf-8'}});
  }
};}
function idle(stats){for(const k of ['active','luaBytes','admitted','outstanding'])if(stats[k]!==0)throw Error('nonzero '+k);if(stats.requestRefs)throw Error('live request coroutine');}
export function childWorker(backend){return{async fetch(request,env,ctx){
  const u=new URL(request.url),parts=u.pathname.split('/'),action=parts[1],name=parts[2];
  if(action==='stats'){const s=backend.stats();idle(s);return Response.json(s);}
  if(action==='evict'){backend.evict?.();const s=backend.stats();idle(s);return Response.json(s);}
  if(!Object.hasOwn(expected,name)&&name!=='lifetime')return new Response('invalid workload',{status:400});
  const mode=u.searchParams.get('mode')||'service';if(!['mock','service'].includes(mode))return new Response('invalid mode',{status:400});
  const counts={get:0,fetch:0},host=hostFor(env,mode,counts);
  if(action==='call'){
    const task=backend.run(name,request,host);ctx.waitUntil(task.then(()=>{},()=>{}));return task;
  }
  if(action!=='batch'||name==='lifetime')return new Response('invalid action',{status:400});
  const n=Number(u.searchParams.get('n')),c=Number(u.searchParams.get('c'));
  if(!Number.isSafeInteger(n)||n<1||n>4096||!Number.isSafeInteger(c)||c<1||c>8)return new Response('bad limits',{status:400});
  let next=0,complete=0,bytes=0;
  const task=Promise.all(Array.from({length:c},async()=>{while(next++<n){
    const r=await backend.run(name,requestFor(name),host),text=await r.text();if(r.status!==200||text!==expected[name])throw Error('incorrect output');complete++;bytes+=text.length;
  }}));
  ctx.waitUntil(task.then(()=>{},()=>{}));await task;
  const s=backend.stats();idle(s);if(complete!==n||counts.get!==n*opCount[name][0]||counts.fetch!==n*opCount[name][1])throw Error('operation count mismatch');
  return Response.json({complete,bytes,counts,stats:s});
}};}
