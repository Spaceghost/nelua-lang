// SPDX-License-Identifier: MIT
// A deterministic packer for this fixed adapter graph, not a JavaScript bundler.
// Unexpected module imports/exports fail instead of silently changing semantics.
function declarations(source, expected) {
  const names = [];
  const code = source.replace(/^export (?:async )?(?:const|class|function) (\w+)/gm, (match, name) => {
    names.push(name);
    return match.slice(7);
  });
  if (JSON.stringify(names.sort()) !== JSON.stringify([...expected].sort())) throw new Error('unexpected adapter exports');
  if (/^\s*(import|export)\s/m.test(code)) throw new Error('unexpected module syntax in fixed adapter');
  return code;
}
export function boundedHelper(runtime) {
  const end = runtime.indexOf('\nfunction bytes(value)');
  if (end < 0) throw new Error('bounded reader boundary changed');
  const helper = runtime.slice(0, end);
  if (helper.includes('class LuaRuntime')) throw new Error('JavaScript reference contains Lua code');
  return helper;
}
export function pack(runtime, common, application, javascript = false) {
  const sharedImport = "import {readBounded} from './runtime.mjs';";
  if (common.split(sharedImport).length !== 2) throw new Error('unexpected common helper imports');
  const api = javascript ? ['LIMIT', 'WorkerError', 'raceAbort', 'readBounded']
    : ['LIMIT', 'WorkerError', 'raceAbort', 'readBounded', 'LuaRuntime'];
  const runtimeSource = javascript ? boundedHelper(runtime) : runtime;
  const runtimeCode = declarations(runtimeSource, api);
  const commonCode = declarations(common.replace(sharedImport, ''), ['payload', 'expected', 'requestFor', 'javascript', 'childWorker']);
  const imports = javascript ? '' : "import module from './kernel.wasm';\n";
  const body = `${imports}const adapter = (() => {\n${runtimeCode}\nreturn {${api.join(',')}};\n})();\n` +
    `const harness = ((readBounded) => {\n${commonCode}\nreturn {childWorker,javascript};\n})(adapter.readBounded);\n`;
  return body + (javascript ? 'export default harness.childWorker(harness.javascript());\n'
    : `const source=${JSON.stringify(application)};\nconst rt=new adapter.LuaRuntime(module);\n` +
      'export default harness.childWorker({run:(name,r,h)=>rt.run(source,r,h),stats:()=>rt.stats(),evict:()=>rt.unloadApplication()});\n');
}
