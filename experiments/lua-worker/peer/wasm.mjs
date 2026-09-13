// SPDX-License-Identifier: MIT
const enc=new TextEncoder(),dec=new TextDecoder();
export const bytes=v=>typeof v==='string'?enc.encode(v):v;
const FINISHED=Object.freeze(new Error('invocation finished'));
export class PeerModule {
  constructor(module){
    const bad=()=>8;
    const imports={env:{emscripten_notify_memory_growth(){},__syscall_dup3:()=>-8},wasi_snapshot_preview1:{fd_close:bad,fd_read:bad,fd_write:bad,fd_seek:bad,clock_time_get:()=>52}};
    for(const i of WebAssembly.Module.imports(module))if(i.kind!=='function'||!Object.hasOwn(imports[i.module]??{},i.name))throw Error('unapproved import '+i.module+'.'+i.name);
    this.e=new WebAssembly.Instance(module,imports).exports;this.e._initialize?.();
  }
  withBytes(values,fn){const e=this.e,ptrs=[];try{const args=[];for(const value of values){const b=bytes(value),p=e.malloc(Math.max(b.length,1));if(!p)throw Error('Wasm allocation');ptrs.push(p);new Uint8Array(e.memory.buffer,p,b.length).set(b);args.push(p,b.length);}return fn(...args);}finally{for(const p of ptrs)e.free(p);}}
  cstr(p){const heap=new Uint8Array(this.e.memory.buffer);let end=p;while(end<heap.length&&heap[end])end++;return dec.decode(heap.slice(p,end));}
  app(source){return new PeerApp(this,source);}
}
export class PeerApp {
  constructor(module,source){
    this.module=module;this.e=module.e;this.orphans=0;this.admitted=0;
    const seed=crypto.getRandomValues(new Uint32Array(1))[0];
    this.ptr=this.e.np_new(2097152,0);if(!this.ptr)throw Error('app allocation');
    try{if(module.withBytes([source],(p,n)=>this.e.np_load(this.ptr,p,n,seed))!==0)throw Error(module.cstr(this.e.np_error(this.ptr)));}
    catch(e){this.e.np_delete(this.ptr);this.ptr=0;throw e;}
  }
  state(id){return this.e.np_state(this.ptr,id);}
  info(id){const e=this.e,p=this.ptr,n=e.np_size(p,id);return{state:e.np_state(p,id),kind:e.np_kind(p,id),seq:e.np_sequence(p,id),status:e.np_status(p,id),body:new Uint8Array(e.memory.buffer,e.np_data(p,id),n).slice()};}
  start(method,url,body){return this.module.withBytes([method,url,body],(...args)=>this.e.np_start(this.ptr,...args));}
  complete(id,seq,ok,status,body){return this.module.withBytes([body],(p,n)=>this.e.np_complete(this.ptr,id,seq,ok,status,p,n));}
  close(id){return this.e.np_close(this.ptr,id);}
  stats(){return{active:this.e.np_active(this.ptr),luaBytes:this.e.np_bytes(this.ptr),admitted:this.admitted,outstanding:this.orphans,wasmBytes:this.e.memory.buffer.byteLength};}
  dispose(){if(this.admitted||this.orphans)throw Error('app has live host work');if(this.ptr&&this.e.np_delete(this.ptr))throw Error('app is active');this.ptr=0;}
  async run(request,host,{signal=request.signal,timeoutMs=2500}={}){
    if(!this.ptr)throw Error('app released');if(this.admitted>=8||this.orphans>=8)throw Error('capacity');
    if(!Number.isFinite(timeoutMs)||timeoutMs<=0||timeoutMs>60000)throw Error('invalid timeout');
    const c=new AbortController();const cancel=()=>c.abort(signal?.reason??Error('cancelled'));
    signal?.addEventListener('abort',cancel,{once:true});if(signal?.aborted)cancel();
    const timer=setTimeout(()=>c.abort(Error('deadline exceeded')),timeoutMs);this.admitted++;let id=0;
    try{
      c.signal.throwIfAborted();const body=await readBounded(request.body,c.signal);c.signal.throwIfAborted();
      id=this.start(request.method,request.url,body);if(!id)throw Error('admission or request bound');
      while(this.state(id)===3){
        const op=this.info(id);this.orphans++;
        const operation=(async()=>{try{
          const arg=new TextDecoder('utf-8',{fatal:true}).decode(op.body);
          if(op.kind===1){const b=await host.get(arg,{signal:c.signal});return{status:b===null?404:200,body:b===null?new Uint8Array():bytes(b)};}
          if(op.kind===2){const r=await host.fetch(arg,{signal:c.signal});return{status:r.status,body:await readBounded(r.body,c.signal)};}
          await host.log(arg);return{status:200,body:new Uint8Array()};
        }finally{this.orphans--;}})();
        // Keep settlement accounting alive after the HTTP caller disconnects.
        host.retain?.(operation.then(()=>{},()=>{}));
        let result,ok=1;
        try{result=await raceAbort(operation,c.signal);if(result.body.length>65536)throw Error('host result bound');}
        catch(error){c.signal.throwIfAborted();ok=0;result={status:502,body:enc.encode('host operation failed (HOST_ERROR)')};}
        c.signal.throwIfAborted();if(this.complete(id,op.seq,ok,result.status,result.body)<3)throw Error('stale completion');
      }
      const result=this.info(id);if(result.state!==4)throw Error(dec.decode(result.body));
      return new Response([204,205,304].includes(result.status)||request.method==='HEAD'?null:result.body,{status:result.status,headers:{'content-type':'text/plain; charset=utf-8'}});
    }finally{clearTimeout(timer);signal?.removeEventListener('abort',cancel);c.abort(FINISHED);this.admitted--;if(id&&this.close(id))throw Error('cleanup failed');}
  }
}
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
