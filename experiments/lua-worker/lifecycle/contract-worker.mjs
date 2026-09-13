import module from './kernel.wasm';
import {LuaRuntime,readBounded} from './runtime.mjs';
import {contractSuite,retire} from './contracts.mjs';
const actual=new LuaRuntime(module),probes=new Map();
const app="local h=require'worker.http';return{fetch=function(r,e,c)local g=e.CONFIG:get('greeting');local u=e.UPSTREAM:fetch('/echo/'..r.url:match('/([^/]+)$'));c.log('served');return h.text(g..':'..u.body)end}";
function host(env){return{
  async get(key,{signal}){const r=await env.CONFIG.fetch('https://config.invalid/'+encodeURIComponent(key),{signal,redirect:'manual'});if(r.status===404){await r.body?.cancel();return null;}if(r.status!==200)throw Error('CONFIG');return readBounded(r.body,signal);},
  fetch(path,{signal}){return env.UPSTREAM.fetch('https://upstream.invalid'+path,{signal,redirect:'manual'});},log(){}
};}
function retain(task,ctx){ctx.waitUntil(task.then(()=>{},()=>{}));return task;}
export default{async fetch(request,env,ctx){
  const path=new URL(request.url).pathname;
  if(path==='/ready')return new Response('ready');
  if(path==='/suite')return retain(contractSuite(()=>new LuaRuntime(module)).then(Response.json),ctx);
  if(path==='/stats')return Response.json({actual:actual.stats(),probes:[...probes.values()].map(p=>({...p.record,stats:p.rt.stats()}))});
  if(path.startsWith('/actual/'))return retain(actual.run(app,request,host(env)),ctx);
  if(path.startsWith('/wire/')){
    const name=path.slice(6);if(!['reset','close'].includes(name)||probes.has(name))return new Response('invalid',{status:409});
    const rt=new LuaRuntime(module),record={name,started:false,networkAbort:false,finished:false,code:null};probes.set(name,{rt,record});
    request.signal.addEventListener('abort',()=>record.networkAbort=true,{once:true});
    const h={get(key,{signal}){record.started=true;return new Promise((resolve,reject)=>{if(signal.aborted)reject(signal.reason);else signal.addEventListener('abort',()=>reject(signal.reason),{once:true});});},fetch:async()=>new Response('unused'),log(){}};
    const s="local h=require'worker.http';return{fetch=function(r,e)return h.text(e.CONFIG:get('greeting'))end}";
    const task=(async()=>{try{return await rt.run(s,request,h,{timeoutMs:1000});}catch(e){record.code=e.code??e.name;return new Response('cancelled',{status:499});}finally{await scheduler.wait(0);retire(rt);record.finished=true;}})();
    return retain(task,ctx);
  }
  return new Response('not found',{status:404});
}};
