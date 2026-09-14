// SPDX-License-Identifier: MIT
// Same bounded functional reference; bodyless synchronous routes stay synchronous.
import {readBounded} from './bounded.mjs';
const EMPTY=new Uint8Array(),enc=new TextEncoder(),dec=new TextDecoder();let counter=0,requests=0;
const response=(request,body,status=200)=>{requests++;return new Response(request.method==='HEAD'?null:body,{status,headers:{'content-type':'text/plain; charset=utf-8'}});};
async function get(env,signal,key){
 const r=await env.CONFIG.fetch('http://config.invalid/'+encodeURIComponent(key),{redirect:'manual'});
 if(r.status===404){await r.body?.cancel();return null;}if(r.status!==200)throw Error('CONFIG');
 return readBounded(r.body,signal);
}
async function capability(request,env,path,text){
 let result;const signal=request.signal;
 if(path==='/get')result=await get(env,signal,text||'greeting')??enc.encode('missing');
 else if(path==='/chain'){
  const greeting=await get(env,signal,'greeting'),r=await env.UPSTREAM.fetch('http://upstream.invalid/'+(text||'echo'),{redirect:'manual'});
  result=dec.decode(greeting)+':'+dec.decode(await readBounded(r.body,signal));
 }else for(let i=0;i<16;i++)result=await get(env,signal,'greeting');
 return response(request,result);
}
function dispatch(request,env,path,body){
 if(path==='/hello')return response(request,'ok');
 if(path==='/echo')return response(request,body);
 if(path==='/info')return response(request,request.method+'|'+request.url);
 if(path==='/counter')return response(request,String(++counter));
 if(path==='/cpu'){
  const n=Number(dec.decode(body));if(!Number.isSafeInteger(n)||n<1||n>20000)throw Error('invalid loop count');
  let sum=0;for(let i=1;i<=n;i++)sum+=i%97;return response(request,String(sum));
 }
 if(path==='/get'||path==='/chain'||path==='/ops16')return capability(request,env,path,path==='/ops16'?'':dec.decode(body));
 return response(request,'not found',404);
}
export default{fetch(request,env){
 const path=new URL(request.url).pathname;
 if(path==='/_peer/stats')return Response.json({active:0,admitted:0,luaBytes:0,traces:0,requests});
 request.signal.throwIfAborted();
 return request.body?readBounded(request.body,request.signal).then(body=>dispatch(request,env,path,body)):dispatch(request,env,path,EMPTY);
}};
