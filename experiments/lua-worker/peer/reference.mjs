// SPDX-License-Identifier: MIT
// Functional JavaScript reference. It does not emulate Lua's interpreter budget.
import {readBounded} from './bounded.mjs';
const enc=new TextEncoder(),dec=new TextDecoder();let counter=0,requests=0;
export default {async fetch(request,env){
 const path=new URL(request.url).pathname;
 if(path==='/_peer/stats')return Response.json({active:0,admitted:0,luaBytes:0,traces:0,requests});
 const body=await readBounded(request.body,request.signal);const text=dec.decode(body);let result,status=200;
 const get=async key=>{const r=await env.CONFIG.fetch('http://config.invalid/'+encodeURIComponent(key),{redirect:'manual'});if(r.status===404){await r.body?.cancel();return null;}if(r.status!==200)throw Error('CONFIG');return readBounded(r.body,request.signal);};
 if(path==='/hello')result='ok';
 else if(path==='/echo')result=body;
 else if(path==='/counter')result=String(++counter);
 else if(path==='/cpu'){const n=Number(text);if(!Number.isSafeInteger(n)||n<1||n>20000)throw Error('invalid loop count');let sum=0;for(let i=1;i<=n;i++)sum+=i%97;result=String(sum);}
 else if(path==='/get'){const value=await get(text||'greeting');result=value??enc.encode('missing');}
 else if(path==='/chain'){const greeting=await get('greeting'),r=await env.UPSTREAM.fetch('http://upstream.invalid/'+(text||'echo'),{redirect:'manual'});result=dec.decode(greeting)+':'+dec.decode(await readBounded(r.body,request.signal));}
 else if(path==='/ops16'){for(let i=0;i<16;i++)result=await get('greeting');}
 else{status=404;result='not found';}
 requests++;return new Response(request.method==='HEAD'?null:result,{status,headers:{'content-type':'text/plain; charset=utf-8'}});
}};
