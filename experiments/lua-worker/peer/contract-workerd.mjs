// SPDX-License-Identifier: MIT
// Test-only configuration. No public endpoint accepts arbitrary source.
import compiled from './kernel.wasm';
import cases from './cases.json';
import {PeerModule} from './wasm.mjs';
import {sourceCorpus,runtimeContracts} from './parity-wasm.mjs';
const module=new PeerModule(compiled);
export default {async fetch(request){if(new URL(request.url).pathname==='/ready')return new Response('ready');try{return Response.json({rows:sourceCorpus(module,cases),groups:await runtimeContracts(module)});}catch(e){return Response.json({error:e.message,stack:e.stack},{status:500});}}};
