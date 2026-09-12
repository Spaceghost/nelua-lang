// SPDX-License-Identifier: MIT
// Test-only network probe. Never included in the normal worker configuration.
import contracts from './test.mjs';
import { runtime, runWithContext } from './workerd.mjs';
const evidence = new Map(); // Maximum two test records; no current-request authority.
const source = "local h=require'worker.http';return{fetch=function(r,e)return h.text(e.CONFIG:get('greeting'))end}";
export default { async fetch(request,env,ctx) {
  const path=new URL(request.url).pathname;
  if(path==='/wire/status')return Response.json({cases:[...evidence.values()],stats:runtime.stats()});
  if(!path.startsWith('/wire/start/'))return contracts.fetch(request,env,ctx);
  const name=path.slice('/wire/start/'.length);
  if(!['reset','close'].includes(name)||evidence.has(name)||evidence.size>=2)return new Response('invalid probe',{status:409});
  const record={name,started:false,networkAbort:false,finished:false,errorCode:null};
  evidence.set(name,record);
  const networkAbort=()=>{record.networkAbort=true;};
  request.signal.addEventListener('abort',networkAbort,{once:true});
  const host={
    get(key,{signal}) {
      record.started=true;
      return new Promise((resolve,reject)=>{
        if(signal.aborted){reject(signal.reason);return;}
        signal.addEventListener('abort',()=>reject(signal.reason),{once:true});
      });
    },
    fetch:async()=>new Response('unused'),log(){}
  };
  try{return await runWithContext(source,request,host,ctx,{timeoutMs:1000});}
  catch(error){record.errorCode=error.code??error.name;return new Response('cancelled',{status:499});}
  finally{request.signal.removeEventListener('abort',networkAbort);record.finished=true;}
}};
