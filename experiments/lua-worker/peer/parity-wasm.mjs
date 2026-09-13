// SPDX-License-Identifier: MIT
const dec=new TextDecoder();const assert=(ok,message)=>{if(!ok)throw Error(message);};
export function sourceCorpus(module,cases){
  const rows=[];
  for(const c of cases){let app;const responses=[],operations=[];
    try{
      app=module.app(c.source);
      for(let k=0;k<c.count;k++){
        const id=app.start('POST','http://worker.invalid/case',c.body);assert(id,'admission');
        while(app.state(id)===3){const op=app.info(id),arg=dec.decode(op.body);operations.push([op.kind,arg]);let status=200,body='';if(op.kind===1){status=arg==='missing'?404:200;body=['empty','missing'].includes(arg)?'':'hello';}else if(op.kind===2){status=201;body='upstream';}assert(app.complete(id,op.seq,1,status,body)>=3,'completion');}
        const r=app.info(id),text=dec.decode(r.body),error=Array.isArray(c.error)?c.error[k]:c.error;
        if(r.state===5){assert(error&&(text.toLowerCase().includes(error.toLowerCase())||error==='memory'&&text.includes('allocation')),c.name+': '+text);if(error==='trace-needle')assert(text.includes('app.lua')&&text.includes('stack traceback'),'traceback');responses.push({error});}
        else{const expected=Array.isArray(c.expect)?c.expect[k]:c.expect;assert(!error&&text===expected,c.name+': '+text);responses.push({status:r.status,body:text});}assert(app.close(id)===0,'close');
      }
    }catch(e){if(app)throw e;assert(c.error&&e.message.toLowerCase().includes(c.error.toLowerCase()),c.name+': '+e.message);responses.push({error:c.error});}
    finally{app?.dispose();}rows.push({case:c.name,feature:c.feature,responses,operations});
  }return rows;
}
export async function runtimeContracts(module){
  const src="local h=require'worker.http';return{fetch=function(r,e)return h.text(e.CONFIG:get('greeting'))end}";
  const a=module.app(src),b=module.app(src);let x=a.start('GET','http://worker.invalid/a',''),y=a.start('GET','http://worker.invalid/b',''),z=b.start('GET','http://worker.invalid/c','');
  assert(a.complete(x,99,1,200,'bad')===-1,'wrong sequence');assert(b.complete(z,1,1,200,'other')===4,'second context');assert(dec.decode(b.info(z).body)==='other','second body');b.close(z);
  a.complete(y,1,1,200,'second');a.complete(x,1,1,200,'first');assert(dec.decode(a.info(x).body)==='first'&&dec.decode(a.info(y).body)==='second','out of order');a.close(x);a.close(y);
  x=a.start('GET','http://worker.invalid/a','');a.close(x);y=a.start('GET','http://worker.invalid/b','');assert(a.complete(x,1,1,200,'late')===-1&&a.state(y)===3,'stale callback');a.close(y);a.dispose();b.dispose();
  const c=module.app(src),controller=new AbortController();let release,started;const begin=new Promise(r=>started=r);
  const task=c.run(new Request('http://worker.invalid/a'),{get(){started();return new Promise(r=>release=r);},fetch(){},log(){}},{signal:controller.signal}).then(()=>{throw Error('expected cancellation');},()=>{});
  await begin;controller.abort();await task;assert(c.stats().active===0&&c.stats().outstanding===1,'cancel or orphan charge');release('late');await new Promise(r=>setTimeout(r,1));assert(c.stats().outstanding===0,'orphan settlement');c.dispose();
  const echo=module.app("return{fetch=function(r)return{status=200,body=r.body}end}");const input=Uint8Array.from({length:65536},(_,i)=>i%251);
  const response=await echo.run(new Request('http://worker.invalid/a',{method:'POST',body:input}),{});const actual=new Uint8Array(await response.arrayBuffer());assert(actual.length===input.length&&actual.every((v,i)=>v===input[i]),'binary body');echo.dispose();
  return ['two applications in one Wasm instance','out-of-order completion','stale sequence and closed IDs','cancellation and charged late callbacks','64 KiB binary-safe response'];
}
