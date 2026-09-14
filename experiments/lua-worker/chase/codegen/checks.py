#!/usr/bin/env python3
"""Source/ownership gates and evidence of native application safepoints."""
from pathlib import Path
import ctypes as C, json, sys
sys.path.insert(0, str(Path('peer').resolve()))
from native import Native
cases=[c for c in json.loads(Path('peer/cases.json').read_text()) if c['feature']!='lua55']
report={'commonCaseCount':len(cases),'profiles':[]}
def corpus(native):
    rows=[]
    for c in cases:
        app=None; responses=[]; operations=[]
        try:
            app=native.app(c['source'])
            for k in range(c['count']):
                id=app.start('POST','http://worker.invalid/case',c['body']); assert id
                try:
                    while app.info(id)['state']==3:
                        o=app.info(id);arg=o['body'].decode();operations.append([o['kind'],arg]);status=200;body=b''
                        if o['kind']==1:status=404 if arg=='missing' else 200;body=b'' if arg in ('missing','empty') else b'hello'
                        elif o['kind']==2:status=201;body=b'upstream'
                        assert app.complete(id,o['seq'],1,status,body)>=3
                    out=app.info(id);text=out['body'].decode(errors='replace')
                    error=c['error'][k] if isinstance(c['error'],list) else c['error']
                    if out['state']==5:
                        assert error and (error.lower() in text.lower() or error=='memory' and 'allocation' in text),(c['name'],text)
                        if error=='trace-needle': assert 'app.lua' in text and 'stack traceback' in text
                        responses.append({'error':error})
                    else:
                        want=c['expect'][k] if isinstance(c['expect'],list) else c['expect']
                        assert not error and text==want,(c['name'],text,want)
                        responses.append({'status':out['status'],'body':text})
                finally: assert app.close(id)==0
        except RuntimeError as e:
            assert c['error'] and c['error'].lower() in str(e).lower(),(c['name'],str(e))
            responses=[{'error':c['error']}]
        finally:
            if app: assert app.e.np_active(app.ptr)==0; app.delete()
        rows.append({'case':c['name'],'responses':responses,'operations':operations})
    return rows
baseline=corpus(Native('dist/peer/libpeer-luau.so'))
for name in ['interp','compiled']:
    native=Native(f'dist/codegen/libpeer-{name}.so'); e=native.lib
    for fn,restype in [('np_codegen_functions',C.c_uint32),('np_codegen_bytes',C.c_size_t),('np_codegen_safepoints',C.c_uint64)]:
        f=getattr(e,fn); f.argtypes=[C.c_void_p];f.restype=restype
    for fn in ['np_codegen_observe','np_codegen_enable']:
        f=getattr(e,fn);f.argtypes=[C.c_void_p,C.c_int];f.restype=None
    rows=corpus(native);assert rows==baseline
    item={'name':name,'commonCases':rows,'groups':[]};report['profiles'].append(item)
    src=Path('peer/worker.lua').read_text();a=native.app(src)
    try:
        e.np_codegen_observe(a.ptr,1)
        def cpu(n):
            id=a.start('POST','http://worker.invalid/cpu',str(n)); assert id
            out=a.info(id); assert out['state']==4,out
            assert out['body'].decode()==str(sum(i%97 for i in range(1,n+1)))
            assert a.close(id)==0
        for n in [31,997,10000,10999]:cpu(n)
        nativePoints=e.np_codegen_safepoints(a.ptr);functions=e.np_codegen_functions(a.ptr);codeBytes=e.np_codegen_bytes(a.ptr)
        if name=='compiled': assert nativePoints>0 and functions>0 and codeBytes>0,(nativePoints,functions,codeBytes)
        else:assert nativePoints==functions==codeBytes==0
        e.np_codegen_enable(a.ptr,0);cpu(10001);assert e.np_codegen_safepoints(a.ptr)==nativePoints
        if name=='compiled':
            e.np_codegen_enable(a.ptr,1);cpu(10002);assert e.np_codegen_safepoints(a.ptr)>nativePoints
        item['nativeEvidence']={'functions':functions,'codeBytes':codeBytes,'applicationNativeSafepoints':nativePoints,'executionTogglePassed':True}
        item['groups'].append('actual routed application native safepoints; interpreter toggle')
        pending=a.start('POST','http://worker.invalid/get','greeting');assert a.info(pending)['state']==3
        runaway=a.start('GET','http://worker.invalid/loop');out=a.info(runaway)
        assert out['state']==5 and b'budget exhausted' in out['body'],out
        assert a.close(runaway)==0 and a.info(pending)['state']==3
        assert a.complete(pending,1,1,200,b'kept')==4 and a.info(pending)['body']==b'kept'
        assert a.close(pending)==0;cpu(991)
        item['groups'].append('native/interpreter runaway budget, unrelated pending request, recovery')
        pending=a.start('POST','http://worker.invalid/get','greeting');assert a.info(pending)['state']==3
        assert a.close(pending)==0
        for i in range(1024):
            id=a.start('GET','http://worker.invalid/hello');assert a.info(id)['body']==b'ok';assert a.close(id)==0
        assert a.complete(pending,1,1,200,b'late')==-1
        item['groups'].append('1024 reuse cycles reject released completion')
        b=bytes(i%256 for i in range(65536));id=a.start('POST','http://worker.invalid/echo',b)
        assert a.info(id)['body']==b and a.close(id)==0
        item['groups'].append('64 KiB arbitrary binary bytes')
    finally:
        assert e.np_active(a.ptr)==0;a.delete()
    source="local n=0;return{fetch=function(r,e)n=n+1;local v=e.CONFIG:get('greeting');return{status=200,body=v..':'..n}end}"
    a=native.app(source);b=native.app(source)
    try:
        x=a.start();y=a.start();z=b.start()
        assert b.complete(z,1,1,200,b'other')==4 and b.info(z)['body']==b'other:1'
        assert a.complete(y,1,1,200,b'second')==4 and a.info(y)['body']==b'second:2'
        assert a.complete(x,1,1,200,b'first')==4 and a.info(x)['body']==b'first:2'
        assert a.close(x)==a.close(y)==b.close(z)==0
    finally:a.delete();b.delete()
    item['groups'].append('independent applications and reversed completions')
    for typed in [False,True]:
        source="local function add(n%s)%s local sum%s=0;for i=1,n do sum=sum+i%%97 end;return sum end;return{fetch=function(r)local n=tonumber(r.body);assert(n and n>=1 and n<=20000);return{status=200,body=tostring(add(n))}end}"%(':number' if typed else '',':number' if typed else '',':number' if typed else '')
        a=native.app(source)
        try:
            for n in range(1,101):
                id=a.start('POST','http://worker.invalid/',str(n));out=a.info(id)
                assert out['state']==4 and out['body'].decode()==str(sum(i%97 for i in range(1,n+1)));assert a.close(id)==0
        finally:a.delete()
    item['groups'].append('200 input-dependent typed/untyped results')
    print('PASS',name,len(rows),'common source cases;',len(item['groups']),'native qualification groups',item['nativeEvidence'],flush=True)
Path('reports/codegen/qualification.json').write_text(json.dumps(report,indent=2)+'\n')
