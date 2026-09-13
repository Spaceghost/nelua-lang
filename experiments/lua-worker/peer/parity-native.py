#!/usr/bin/env python3
import json
from pathlib import Path
from native import Native
cases=json.loads(Path('peer/cases.json').read_text());results=[]
for name in ['lua55','luajit']:
    native=Native('dist/peer/libpeer-'+name+'.so');rows=[]
    for case in cases:
        app=None;responses=[];ops=[]
        try:
            app=native.app(case['source'])
            for k in range(case['count']):
                id=app.start('POST','http://worker.invalid/case',case['body']);assert id
                while app.info(id)['state']==3:
                    op=app.info(id);arg=op['body'].decode();ops.append([op['kind'],arg]);status=200;body=b''
                    if op['kind']==1:status=404 if arg=='missing' else 200;body=b'' if arg in ('missing','empty') else b'hello'
                    elif op['kind']==2:status=201;body=b'upstream'
                    assert app.complete(id,op['seq'],1,status,body)>=3
                result=app.info(id);text=result['body'].decode(errors='replace');expected_error=case['error'][k] if isinstance(case['error'],list) else case['error']
                if result['state']==5:
                    if case['feature']=='lua55' and name=='luajit':responses.append({'unsupported':True})
                    else:
                        assert expected_error and (expected_error.lower() in text.lower() or expected_error=='memory' and 'allocation' in text),(case['name'],text)
                        if expected_error=='trace-needle':assert 'app.lua' in text and 'stack traceback' in text
                        responses.append({'error':expected_error})
                else:
                    expect=case['expect'][k] if isinstance(case['expect'],list) else case['expect'];assert not expected_error and text==expect,(case['name'],text,expect);responses.append({'status':result['status'],'body':text})
                assert app.close(id)==0
        except RuntimeError as e:
            if case['feature']=='lua55' and name=='luajit':responses=[{'unsupported':True}]
            else:assert case['error'] and case['error'].lower() in str(e).lower(),(case['name'],str(e));responses=[{'error':case['error']}]
        finally:
            if app:assert app.e.np_active(app.ptr)==0;app.delete()
        rows.append({'case':case['name'],'feature':case['feature'],'responses':responses,'operations':ops})
    results.append({'backend':name,'rows':rows})
Path('reports/peer/parity-native.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
print('PASS native source corpus:',len(cases),'cases per engine; LuaJIT language differences explicit')
