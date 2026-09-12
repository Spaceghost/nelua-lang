// SPDX-License-Identifier: MIT
// Test-only network-disconnect probe. Never included in the normal worker config.
import contracts from './test.mjs';
import { runtime } from './workerd.mjs';
const evidence = new Map(); // Bounded test records, not invocation authority or a current-request global.
const source = "local h=require'worker.http';return{fetch=function(r,e)return h.text(e.CONFIG:get('greeting'))end}";
export default { async fetch(request,env,ctx) {
  const path=new URL(request.url).pathname;
  if(path==='/wire/status')return Response.json({cases:[...evidence.values()],stats:runtime.stats()});
  if(path!=='/wire/start')return contracts.fetch(request,env,ctx);
  if(evidence.size)return new Response('only one wire probe per test process',{status:409});
  const record={started:false,networkAbort:false,finished:false,errorCode:null};
  evidence.set('disconnect',record);
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
  try{return await runtime.run(source,request,host,{timeoutMs:2000});}
  catch(error){record.errorCode=error.code??error.name;return new Response('cancelled',{status:499});}
  finally{request.signal.removeEventListener('abort',networkAbort);record.finished=true;}
}};
