// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {PeerModule} from '../peer/wasm.mjs';
import {sourceCorpus,runtimeContracts} from '../peer/parity-wasm.mjs';
const module=new PeerModule(await WebAssembly.compile(await readFile('dist/peer/kernel-luau.wasm')));
const cases=JSON.parse(await readFile('engines/luau-common.json','utf8'));
const rows=sourceCorpus(module,cases),groups=await runtimeContracts(module);
const native=JSON.parse(await readFile('reports/engines/luau-native.json','utf8'))[0].rows;
assert.deepEqual(rows,native);
const reference=JSON.parse(await readFile('reports/peer/parity-native.json','utf8')).find(x=>x.backend==='lua55').rows.filter(x=>x.feature==='common');
assert.deepEqual(rows,reference);
const features=[];
for(const c of JSON.parse(await readFile('peer/cases.json','utf8')).filter(c=>c.feature!=='common')){
 let app;
 try{app=module.app(c.source);const id=app.start('GET','http://test.invalid','');const r=app.info(id);features.push({name:c.name,state:r.state,body:new TextDecoder().decode(r.body)});app.close(id);}catch(e){features.push({name:c.name,error:e.message});}finally{app?.dispose();}
}
const typed=module.app('local function twice(n: number): number return n*2 end; return {fetch=function() return {status=200,body=tostring(twice(21))} end}');
let id=typed.start('GET','http://test.invalid','');assert.equal(new TextDecoder().decode(typed.info(id).body),'42');typed.close(id);typed.dispose();
const code=`using W=import "/workerd/workerd.capnp";const config:W.Config=(services=[(name="main",worker=(compatibilityDate="2026-09-01",compatibilityFlags=["enable_request_signal"],modules=[
(name="main.mjs",esModule=embed "../../engines/luau-contract.mjs"),(name="kernel.wasm",wasm=embed "../peer/kernel-luau.wasm"),
(name="cases.json",json=embed "../../engines/luau-common.json"),(name="wasm.mjs",esModule=embed "../../peer/wasm.mjs"),
(name="parity-wasm.mjs",esModule=embed "../../peer/parity-wasm.mjs")]))],sockets=[(name="http",address="127.0.0.1:18878",http=(),service="main")]);`;
await mkdir('dist/engines',{recursive:true});await writeFile('dist/engines/luau-test.capnp',code);
const child=spawn('node_modules/.bin/workerd',['serve','dist/engines/luau-test.capnp'],{stdio:['ignore','pipe','pipe']});
let logs='';child.stdout.on('data',x=>logs+=x);child.stderr.on('data',x=>logs+=x);
try{
 for(let n=0;;n++){if(child.exitCode!==null)throw Error(logs);try{const r=await fetch('http://127.0.0.1:18878/ready');assert.equal(r.status,200);break;}catch(e){if(n>200)throw e;await new Promise(r=>setTimeout(r,10));}}
 const r=await fetch('http://127.0.0.1:18878/test');const actual=await r.json();assert.equal(r.status,200,JSON.stringify(actual));assert.deepEqual(actual,{rows,groups});
 await writeFile('reports/engines/luau-contracts.json',JSON.stringify({node:{rows,groups},workerd:actual,features,typedSource:true},null,2)+'\n');
 console.log(`PASS Luau: ${rows.length} source cases native/Wasm/Lua55; ${groups.length} async ownership groups in Node and stock workerd; typed Luau source`);
}finally{child.kill('SIGTERM');if(child.exitCode===null&&child.signalCode===null)await once(child,'exit');await writeFile('reports/engines/luau-workerd.log',logs);}
