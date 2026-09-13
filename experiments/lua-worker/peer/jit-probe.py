#!/usr/bin/env python3
"""JIT-enabled trusted-code lane. Run only under an external process deadline."""
import sys,json
from pathlib import Path
from native import Native
vm=Native('dist/peer/libpeer-luajit.so')
source="return{fetch=function(r)local s=0;for i=1,tonumber(r.body) do s=s+i%97 end;return{status=200,body=tostring(s)}end}"
if '--runaway' in sys.argv:
    app=vm.app('return{fetch=function()while true do end end}',jit=1)
    print('READY-RUNAWAY',flush=True);app.start();raise AssertionError('runaway returned')
app=vm.app(source,jit=1)
for i in range(200):
    n=10000+i;id=app.start('POST','http://worker.invalid/cpu',str(n));r=app.info(id)
    assert r['state']==4 and int(r['body'])==sum(j%97 for j in range(1,n+1));assert app.close(id)==0
traces=vm.lib.np_traces(app.ptr);assert traces>0,'JIT flag without compiled traces is not a JIT benchmark'
app.delete();Path('reports/peer/jit.json').write_text(json.dumps({'checkedCalls':200,'compiledTraces':traces,'profile':'trusted-code; no instruction-metering parity'})+'\n')
print('PASS trusted JIT:',traces,'compiled traces; 200 input-dependent checked calls')
