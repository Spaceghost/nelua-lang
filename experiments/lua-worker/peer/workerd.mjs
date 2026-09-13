// SPDX-License-Identifier: MIT
import compiled from './kernel.wasm';
import source from './worker.lua';
import {PeerModule,readBounded} from './wasm.mjs';
const module=new PeerModule(compiled);let app,requests=0;
export default {async fetch(request,env,ctx){
 app ??= module.app(source);
 if(new URL(request.url).pathname==='/_peer/stats')return Response.json({...app.stats(),requests});
 const host={
  async get(key,{signal}){const r=await env.CONFIG.fetch('http://config.invalid/'+encodeURIComponent(key),{signal,redirect:'manual'});if(r.status===404){await r.body?.cancel();return null;}if(r.status!==200){await r.body?.cancel();throw Error('CONFIG');}return readBounded(r.body,signal);},
  fetch(path,{signal}){return env.UPSTREAM.fetch('http://upstream.invalid'+path,{signal,redirect:'manual'});},
  log(message){console.log(JSON.stringify({source:'lua',message}));}
 };
 const task=app.run(request,host);ctx.waitUntil(task.then(()=>{},()=>{}));
 try{const r=await task;requests++;return r;}catch(error){console.error(error.message);const status=error.message==='body limit exceeded'?413:error.message==='deadline exceeded'?504:500;return new Response('Lua worker failed',{status});}
}};
