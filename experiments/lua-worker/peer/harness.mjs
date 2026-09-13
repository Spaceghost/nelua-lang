// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {readFile,writeFile,mkdir,unlink} from 'node:fs/promises';
import {resolve,relative} from 'node:path';
import {performance} from 'node:perf_hooks';
export const pause=ms=>new Promise(r=>setTimeout(r,ms));
let serial=0;
export async function fixtures(){
 const counts={get:0,fetch:0},connections=new Set();
 const configure=createServer((req,res)=>{
  counts.get++;const key=decodeURIComponent(new URL(req.url,'http://fixture.invalid').pathname.slice(1));
  if(key==='hang')return;
  if(key==='missing'){res.writeHead(404);res.end();return;}
  if(key==='backend-error'){res.writeHead(500);res.end('SECRET=do-not-copy');return;}
  res.end(key==='empty'?'':key==='large'?'x'.repeat(65537):'hello');
 });
 const upstream=createServer((req,res)=>{
  counts.fetch++;const path=new URL(req.url,'http://fixture.invalid').pathname;
  const finish=()=>res.end(path==='/echo'?'upstream':path.slice(1));
  if(path==='/slow')setTimeout(finish,80);else finish();
 });
 for(const s of [configure,upstream]){s.on('connection',socket=>{connections.add(socket);socket.on('close',()=>connections.delete(socket));});s.listen(0,'127.0.0.1');await once(s,'listening');}
 return{config:`127.0.0.1:${configure.address().port}`,upstream:`127.0.0.1:${upstream.address().port}`,counts,
  async close(){for(const s of connections)s.destroy();await Promise.all([configure,upstream].map(s=>new Promise(r=>s.close(r))));}};
}
export async function start(variant,fixture,{contracts=false}={}){
 const index=++serial,port=19000+index,dir=resolve('dist/peer');await mkdir(dir,{recursive:true});
 const processes=[],logs=[];let deadline;
 const launch=(command,args)=>{
  const proc=spawn(command,args,{stdio:['ignore','pipe','pipe']});processes.push(proc);
  proc.stdout.on('data',x=>logs.push(x.toString()));proc.stderr.on('data',x=>logs.push(x.toString()));
  proc.on('error',e=>logs.push(e.message));return proc;
 };
 const embed=path=>JSON.stringify(relative(dir,resolve(path)));
 const socket=resolve(dir,`peer-${index}.sock`);const isNative=variant.startsWith('native')||variant==='proxy-lua55';
 const began=performance.now();
 if(isNative){
  const vm=variant.includes('luajit')?'luajit':'lua55';
  const args=['peer/worker.lua',variant==='proxy-lua55'?'unix:'+socket:`127.0.0.1:${port}`,fixture.config,fixture.upstream];
  if(variant==='native-luajit-trusted')args.push('trusted-jit');
  launch(resolve(dir,'host-'+vm),args);
 }
 if(!isNative||variant==='proxy-lua55'){
  let services;
  if(variant==='proxy-lua55')services=`(name="main",external=(address=${JSON.stringify('unix:'+socket)},http=()))`;
  else {
   const main=contracts?'peer/contract-workerd.mjs':variant==='javascript'?'peer/reference.mjs':'peer/workerd.mjs';
   const modules=[`(name="main.mjs",esModule=embed ${embed(main)})`];
   if(variant==='javascript')modules.push(`(name="bounded.mjs",esModule=embed ${embed('peer/bounded.mjs')})`);
   else {
    modules.push(`(name="wasm.mjs",esModule=embed ${embed('peer/wasm.mjs')})`,`(name="kernel.wasm",wasm=embed "kernel.wasm")`);
    if(contracts)modules.push(`(name="cases.json",json=embed ${embed('peer/cases.json')})`,`(name="parity-wasm.mjs",esModule=embed ${embed('peer/parity-wasm.mjs')})`);
    else modules.push(`(name="worker.lua",text=embed ${embed('peer/worker.lua')})`);
   }
   services=`(name="main",worker=(compatibilityDate="2026-09-01",compatibilityFlags=["enable_request_signal"],modules=[${modules.join(',')}],bindings=[(name="CONFIG",service="config"),(name="UPSTREAM",service="upstream")])),
    (name="config",external=(address=${JSON.stringify(fixture.config)},http=())),(name="upstream",external=(address=${JSON.stringify(fixture.upstream)},http=()))`;
  }
  const file=resolve(dir,`host-${index}.capnp`);
  await writeFile(file,`using W=import "/workerd/workerd.capnp";const config:W.Config=(services=[${services}],sockets=[(name="http",address="127.0.0.1:${port}",http=(),service="main")]);\n`);
  launch(resolve('node_modules/.bin/workerd'),['serve',file]);
 }
 const base=`http://127.0.0.1:${port}`;
 const stop=async()=>{
  clearTimeout(deadline);
  for(const p of processes)if(p.exitCode===null&&p.signalCode===null)p.kill('SIGTERM');
  for(const p of processes)if(p.exitCode===null&&p.signalCode===null){const k=setTimeout(()=>p.kill('SIGKILL'),1000);await once(p,'exit');clearTimeout(k);}
  await mkdir('reports/peer/hosts',{recursive:true});await writeFile(`reports/peer/hosts/${variant}-${index}.log`,logs.join(''));
  await unlink(socket).catch(()=>{});
 };
 // Independent parent remains able to kill a blocked VM or native C call.
 deadline=setTimeout(()=>{for(const p of processes)p.kill('SIGKILL');},60000);
 try{
  for(let i=0;;i++){
   if(processes.find(p=>p.exitCode!==null||p.signalCode!==null))throw Error('host exited: '+logs.join(''));
   try{const r=await fetch(base+(contracts?'/ready':'/hello'),{signal:AbortSignal.timeout(1000)});const text=await r.text();assert.equal(r.status,200,text);assert.equal(text,contracts?'ready':'ok');break;}
   catch(e){if(i>300)throw Error(e.message+'\n'+logs.join(''));await pause(5);}
  }
  return{variant,base,processes,stop,coldMs:performance.now()-began,logs,
   async stats(){const r=await fetch(base+'/_peer/stats');assert.equal(r.status,200);return r.json();},
   async rss(){let sum=0;const items=[];for(const p of processes){const s=await readFile(`/proc/${p.pid}/status`,'utf8');const kib=Number(s.match(/^VmRSS:\s+(\d+) kB$/m)[1]);sum+=kib;items.push({pid:p.pid,kib});}return{sumKiB:sum,processes:items};}};
 }catch(e){await stop();throw e;}
}
export async function call(server,path,body,expected,status=200){
 const r=await fetch(server.base+path,{...(body!==undefined?{method:'POST',body}:{}),signal:AbortSignal.timeout(6000)});
 const data=new Uint8Array(await r.arrayBuffer());assert.equal(r.status,status,Buffer.from(data).toString());
 if(expected!==undefined)assert.deepEqual(Buffer.from(data),Buffer.from(expected));return r.status;
}
