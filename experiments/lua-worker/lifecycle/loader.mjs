// SPDX-License-Identifier: MIT
// Trusted benchmark parent. All contenders traverse this same Worker Loader API.
import child from './child-source';
import runtime from './runtime-source';
import common from './common-source';
import application from './application-source';
import kernel from './kernel.wasm';
import variant from './variant';
let serial=0;
function code(env){
  const modules={'main.mjs':{js:child},'runtime.mjs':{js:runtime},'common.mjs':{js:common},'app.lua':{text:application}};
  if(variant!=='javascript')modules['kernel.wasm']={wasm:kernel};
  return {compatibilityDate:'2026-09-01',compatibilityFlags:['enable_request_signal'],mainModule:'main.mjs',modules,
    globalOutbound:null,env:{CONFIG:env.CONFIG,UPSTREAM:env.UPSTREAM}};
}
export default{async fetch(request,env,ctx){
  const u=new URL(request.url);
  if(u.pathname==='/ready')return new Response('ready');
  const get=id=>env.LOADER.get(id,()=>code(env)).getEntrypoint();
  if(u.pathname==='/spawn'){
    const n=Number(u.searchParams.get('n'));if(!Number.isSafeInteger(n)||n<1||n>64)return new Response('bad count',{status:400});
    for(let i=0;i<n;i++){
      const worker=get('new:'+(++serial));
      const a=await worker.fetch('https://worker.invalid/call/lifetime');
      if(a.status!==200||await a.text()!=='1')throw Error('new worker was not fresh');
      const b=await worker.fetch('https://worker.invalid/call/lifetime');
      const wanted=variant==='fresh'?'1':'2';if(b.status!==200||await b.text()!==wanted)throw Error('worker lifetime not preserved');
    }
    return Response.json({created:n,requests:n*2,uniqueIds:true});
  }
  const worker=get('cached:v1');
  const task=worker.fetch(new Request('https://worker.invalid'+u.pathname+u.search,request));
  ctx.waitUntil(task.then(()=>{},()=>{}));return task;
}};
