#!/usr/bin/env python3
"""Generate the existing checked HTTP suite with explicit CodeGen contenders."""
from pathlib import Path
import shutil
ROOT=Path(__file__).resolve().parents[2]
import os; os.chdir(ROOT)
def once(s,old,new):
    if s.count(old)!=1: raise ValueError('harness drift: '+old[:100])
    return s.replace(old,new,1)
for name in ['interp','compiled']:
    for file in ['host-'+name,'libpeer-'+name+'.so']:
        shutil.copyfile('dist/codegen/'+file,'dist/peer/'+file)
        if file.startswith('host'):Path('dist/peer/'+file).chmod(0o755)
h=Path('peer/engine-harness.mjs').read_text()
h=once(h,"const vm=variant.includes('luau')?'luau':", "const vm=variant.includes('luau-compiled')?'compiled':variant.includes('luau-interp')?'interp':variant.includes('luau')?'luau':")
if 'mkdtemp' not in h:
    h=once(h,'readFile,writeFile,mkdir,unlink','readFile,writeFile,mkdir,unlink,mkdtemp,rm')
    h=once(h,'const socket=resolve(dir,`peer-${index}.sock`);',"const socketDir=await mkdtemp('/tmp/lw-cg-');const socket=resolve(socketDir,'peer.sock');")
    h=once(h,'  await unlink(socket).catch(()=>{});','  await unlink(socket).catch(()=>{});await rm(socketDir,{recursive:true,force:true});')
Path('peer/codegen-harness.mjs').write_text(h)
s=Path('peer/engine-http.mjs').read_text().replace("'./engine-harness.mjs'","'./codegen-harness.mjs'")
s=once(s,"['javascript','wasm','native-lua55','native-luau','wasm-luau','proxy-luau']", "['javascript','native-luau-interp','native-luau-compiled','proxy-luau-compiled']")
s=once(s,'reports/engines/luau-http.json','reports/codegen/http-tests.json')
Path('peer/codegen-http.mjs').write_text(s)
s=Path('peer/bench.mjs').read_text()
s=once(s,"from './harness.mjs'", "from './codegen-harness.mjs'")
s=once(s,"['javascript','wasm','native-lua55','native-luajit','native-luajit-trusted','proxy-lua55']", "['javascript','wasm','native-lua55','native-luajit','native-luajit-trusted','native-luau-interp','native-luau-compiled','proxy-luau-compiled']")
s=once(s,'const rounds=6;','const rounds=8;')
s=once(s,"report.warmup.push({round,variant", "if(variant.includes('compiled'))assert(warmupStats.codegenFunctions>0&&warmupStats.nativeCodeBytes>0,'no native code in timed app');\n    report.warmup.push({round,variant")
s=s.replace('reports/peer/benchmark-', 'reports/codegen/benchmark-').replace('reports/peer/RESULTS.md','reports/codegen/RESULTS.md')
s=s.replace('six balanced-order','eight rotated-order').replace('across six fresh-process rounds','across eight fresh-process rounds')
s=once(s,"'| Case | JavaScript | Same-core Wasm | Native Lua 5.5 | LuaJIT metered | LuaJIT trusted | workerd → native |','|---|---:|---:|---:|---:|---:|---:|']", "'| Case | '+variants.join(' | ')+' |','|---|'+variants.map(()=>'---:|').join('')]")
s=s.replace("'Native hosts use distro KJ;", "'Luau interpreter/CodeGen peers share the exact same kernel, source, host and safepoint meter; generated machine code is not sanitizer-instrumented.',\n 'CodeGen has a 4 MiB executable allocation cap separate from the 2 MiB guest VM-heap cap; compiler/host allocations need outer limits.',\n 'Native execution is proven separately with application-attributed safepoint observation and an enable/disable control; observation is disabled while timing.',\n 'Native hosts use distro KJ;")
Path('peer/codegen-bench.mjs').write_text(s)
shutil.copyfile('chase/reference.mjs','peer/reference.mjs')
