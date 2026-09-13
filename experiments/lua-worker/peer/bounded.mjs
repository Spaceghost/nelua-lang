// SPDX-License-Identifier: MIT
// Shared bounded reader only; the JavaScript reference imports no Lua adapter.
export function raceAbort(promise,signal){return new Promise((resolve,reject)=>{
 const abort=()=>{signal.removeEventListener('abort',abort);reject(signal.reason);};
 if(signal.aborted){Promise.resolve(promise).catch(()=>{});reject(signal.reason);return;}
 signal.addEventListener('abort',abort,{once:true});Promise.resolve(promise).then(v=>{signal.removeEventListener('abort',abort);resolve(v);},e=>{signal.removeEventListener('abort',abort);reject(e);});
});}
export async function readBounded(stream,signal){
 signal.throwIfAborted();if(!stream)return new Uint8Array();const reader=stream.getReader();let n=0;const chunks=[];
 const cancel=()=>{void reader.cancel().catch(()=>{});};signal.addEventListener('abort',cancel,{once:true});
 try{for(;;){const {done,value}=await raceAbort(reader.read(),signal);if(done)break;n+=value.length;if(n>65536)throw Error('body limit exceeded');chunks.push(value);}const b=new Uint8Array(n);let i=0;for(const c of chunks){b.set(c,i);i+=c.length;}return b;}
 catch(e){cancel();throw e;}finally{signal.removeEventListener('abort',cancel);reader.releaseLock();}
}
