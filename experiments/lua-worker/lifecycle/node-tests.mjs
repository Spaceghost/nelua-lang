import {readFile,writeFile} from 'node:fs/promises';
import {LuaRuntime} from '../host/runtime.mjs';
import {contractSuite} from './contracts.mjs';
const module=await WebAssembly.compile(await readFile('dist/kernel.wasm'));
const result=await contractSuite(()=>new LuaRuntime(module));
await writeFile('reports/lifecycle-contracts.json',JSON.stringify(result,null,2)+'\n');
console.log(JSON.stringify(result,null,2));
