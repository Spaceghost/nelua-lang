  async run(request,host,{signal=request.signal,timeoutMs=2500}={}){
    if(!this.ptr)throw Error('app released');if(this.admitted>=8||this.orphans>=8)throw Error('capacity');
    if(!Number.isFinite(timeoutMs)||timeoutMs<=0||timeoutMs>60000)throw Error('invalid timeout');
    const began=Date.now();let controller,timer,id=0;
    const cancel=()=>controller.abort(signal?.reason??Error('cancelled'));
    const check=()=>{signal?.throwIfAborted();controller?.signal.throwIfAborted();};
    const ioSignal=()=>{
      if(!controller){
        controller=new AbortController();signal?.addEventListener('abort',cancel,{once:true});
        if(signal?.aborted)cancel();
        timer=setTimeout(()=>controller.abort(Error('deadline exceeded')),Math.max(1,timeoutMs-(Date.now()-began)));
      }
      return controller.signal;
    };
    this.admitted++;
    try{
      check();const body=request.body?await readBounded(request.body,ioSignal()):EMPTY;check();
      id=this.start(request.method,request.url,body);if(!id)throw Error('admission or request bound');
      let op=this.info(id);
      while(op.state===3){
        const local=ioSignal();local.throwIfAborted();this.orphans++;
        const operation=(async()=>{try{
          const arg=strictDecoder.decode(op.body);
          if(op.kind===1){const b=await host.get(arg,{signal:local});return{status:b===null?404:200,body:b===null?EMPTY:bytes(b)};}
          if(op.kind===2){const r=await host.fetch(arg,{signal:local});return{status:r.status,body:await readBounded(r.body,local)};}
          await host.log(arg);return{status:200,body:EMPTY};
        }finally{this.orphans--;}})();
        host.retain?.(operation.then(()=>{},()=>{}));
        let result,ok=1;
        try{result=await raceAbort(operation,local);if(result.body.length>65536)throw Error('host result bound');}
        catch(error){check();ok=0;result={status:502,body:enc.encode('host operation failed (HOST_ERROR)')};}
        check();if(this.complete(id,op.seq,ok,result.status,result.body)<3)throw Error('stale completion');
        op=this.info(id);
      }
      if(op.state!==4)throw Error(dec.decode(op.body));
      return new Response([204,205,304].includes(op.status)||request.method==='HEAD'?null:op.body,{status:op.status,headers:{'content-type':'text/plain; charset=utf-8'}});
    }finally{
      if(controller){clearTimeout(timer);signal?.removeEventListener('abort',cancel);controller.abort(FINISHED);}
      this.admitted--;if(id&&this.close(id))throw Error('cleanup failed');
    }
  }
