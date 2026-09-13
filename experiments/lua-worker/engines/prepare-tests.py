#!/usr/bin/env python3
"""Keep the existing controls intact; extend exact-match copies for this experiment."""
from pathlib import Path
import json
p=Path('.')
def once(s,old,new):
    if s.count(old)!=1:raise ValueError('harness drift: '+old[:100])
    return s.replace(old,new,1)
s=(p/'peer/harness.mjs').read_text()
s=s.replace("variant==='proxy-lua55'", "variant.startsWith('proxy-')")
s=once(s,"const vm=variant.includes('luajit')?'luajit':'lua55';", "const vm=variant.includes('luau')?'luau':variant.includes('luajit')?'luajit':'lua55';")
s=once(s,'(name="kernel.wasm",wasm=embed "kernel.wasm")','(name="kernel.wasm",wasm=embed "${variant===\'wasm-luau\'?\'kernel-luau.wasm\':\'kernel.wasm\'}")')
(p/'peer/engine-harness.mjs').write_text(s)
s=(p/'peer/http-tests.mjs').read_text().replace("'./harness.mjs'","'./engine-harness.mjs'")
s=once(s,"['javascript','wasm','native-lua55','native-luajit','native-luajit-trusted','proxy-lua55']", "['javascript','wasm','native-lua55','native-luau','wasm-luau','proxy-luau']")
a=s.index(" const child=spawn('python3'");b=s.index("}finally{await f.close();}",a)
s=s[:a]+s[b:]
s=s.replace('reports/peer/http-tests.json','reports/engines/luau-http.json')
(p/'peer/engine-http.mjs').write_text(s)
s=(p/'peer/bench.mjs').read_text().replace("'./harness.mjs'","'./engine-harness.mjs'")
s=once(s,"['javascript','wasm','native-lua55','native-luajit','native-luajit-trusted','proxy-lua55']", "['javascript','wasm','native-lua55','native-luau','wasm-luau','proxy-luau']")
s=s.replace('reports/peer/benchmark-','reports/engines/benchmark-').replace('reports/peer/RESULTS.md','reports/engines/RESULTS.md')
s=s.replace('Native peer HTTP shootout','Luau / workerd HTTP shootout').replace('LuaJIT metered | LuaJIT trusted | workerd -> native','Native Luau | Luau/Wasm | workerd -> Luau')
s=s.replace("'LuaJIT trusted enables trace compilation and omits instruction hooks. It is NOT the safety-equivalent winner; LuaJIT metered has JIT off.',", "'Luau is interpreter-only here with interrupt safepoint metering. Its budget is not equivalent to Lua opcode counting; compiler allocations are outside the 2 MiB VM heap.',")
s=s.replace('JIT trusted is not instruction-metered.','Luau uses interrupt-point metering, not Lua opcode counting.')
s=once(s,'median:a[Math.floor(a.length/2)]','median:(a[Math.floor((a.length-1)/2)]+a[Math.floor(a.length/2)])/2')
(p/'peer/engine-bench.mjs').write_text(s)
cases=json.loads((p/'peer/cases.json').read_text())
common=[c for c in cases if c['feature']=='common']
(p/'engines/luau-common.json').write_text(json.dumps(common,ensure_ascii=False,indent=2)+'\n')
s=(p/'peer/parity-native.py').read_text().replace("Path('peer/cases.json')","Path('engines/luau-common.json')").replace("['lua55','luajit']","['luau']").replace('reports/peer/parity-native.json','reports/engines/luau-native.json')
(p/'peer/engine-native.py').write_text(s)
