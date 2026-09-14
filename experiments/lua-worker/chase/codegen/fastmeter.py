#!/usr/bin/env python3
"""Derive a 2x2 interpreter/CodeGen and ordinary/cached-meter experiment."""
from pathlib import Path
import hashlib, json, os
ROOT=Path(__file__).resolve().parents[2]
os.chdir(ROOT)
HERE=Path('chase/codegen'); REPORT=Path('reports/codegen')
REPORT.mkdir(parents=True,exist_ok=True)
def once(s,old,new):
    if s.count(old)!=1:raise ValueError('CodeGen experiment drift: '+old[:100])
    return s.replace(old,new,1)
old_hook='''  uint32_t id=owner(a,L);int index=nk_index(a->kernel,id);
  uint32_t *count=index<0?&a->init_interrupts:&a->requests[index].interrupts;
  if(++*count>=1024){*count=0;if(!nk_tick(a->kernel,id))luaL_error(L,"instruction budget exhausted (Luau safepoint budget)");}'''
new_hook='''#if PEER_DIRECT_METER
  /* Per-coroutine host metadata is a cache, not capability authority. */
  Frame *cached=(Frame *)lua_getthreaddata(L);
  uint32_t *count=cached?&cached->interrupts:&a->init_interrupts;
  if(++*count>=1024){
    *count=0;
    uint32_t id=owner(a,L);
    if(cached && (cached->co!=L || cached->id!=id))
      luaL_error(L,"meter owner mismatch");
    if(!nk_tick(a->kernel,id))
      luaL_error(L,"instruction budget exhausted (Luau safepoint budget)");
  }
#else
''' + old_hook + '''
#endif'''
prepare=(HERE/'prepare.py').read_text()
insert='source = once(source, '+repr(old_hook)+', '+repr(new_hook)+')\n'
insert+='source = once(source, '+repr('  r->interrupts=0;')+', '+repr('  r->interrupts=0;\n#if PEER_DIRECT_METER\n  lua_setthreaddata(r->co,r);\n#endif')+')\n'
insert+='source = once(source, '+repr('    lua_resetthread(r->co);')+', '+repr('''#if PEER_DIRECT_METER
    lua_setthreaddata(r->co,NULL);
#endif
    lua_resetthread(r->co);''')+')\n'
prepare=once(prepare,"(OUT/'runtime.c').write_text(source)",insert+"(OUT/'runtime.c').write_text(source)")
prepare=once(prepare,"for label,enabled in [('interp',0),('compiled',1)]:", "for label,enabled,direct in [('interp',0,0),('compiled',1,0),('interp-fastmeter',0,1),('compiled-fastmeter',1,1)]:")
prepare=once(prepare,"'-DPEER_LUAU',f'-DPEER_CODEGEN={enabled}','-c'", "'-DPEER_LUAU',f'-DPEER_CODEGEN={enabled}',f'-DPEER_DIRECT_METER={direct}','-c'")
prepare=once(prepare,"'nativeCodegen':bool(enabled),'sanitizers'", "'nativeCodegen':bool(enabled),'cachedMeter':bool(direct),'sanitizers'")
checks=(HERE/'checks.py').read_text()
checks=once(checks,"for name in ['interp','compiled']:","for name in ['interp','compiled','interp-fastmeter','compiled-fastmeter']:")
checks=checks.replace("name=='compiled'","name.startswith('compiled')")
configure=(HERE/'configure.py').read_text()
configure=once(configure,"for name in ['interp','compiled']:","for name in ['interp','compiled','interp-fastmeter','compiled-fastmeter']:")
configure=once(configure,"const vm=variant.includes('luau-compiled')?'compiled':", "const vm=variant.includes('luau-compiled-fastmeter')?'compiled-fastmeter':variant.includes('luau-interp-fastmeter')?'interp-fastmeter':variant.includes('luau-compiled')?'compiled':")
configure=once(configure,"['javascript','native-luau-interp','native-luau-compiled','proxy-luau-compiled']", "['javascript','native-luau-interp','native-luau-compiled','native-luau-interp-fastmeter','native-luau-compiled-fastmeter','proxy-luau-compiled-fastmeter']")
configure=once(configure,"['javascript','wasm','native-lua55','native-luajit','native-luajit-trusted','native-luau-interp','native-luau-compiled','proxy-luau-compiled']", "['javascript','wasm','native-lua55','native-luajit','native-luajit-trusted','native-luau-interp','native-luau-compiled','native-luau-interp-fastmeter','native-luau-compiled-fastmeter','proxy-luau-compiled-fastmeter']")
configure=once(configure,"'const rounds=8;'","'const rounds=10;'")
configure=configure.replace('eight rotated-order','ten rotated-order').replace('across eight fresh-process rounds','across ten fresh-process rounds')
outputs={'prepare-fast.py':prepare,'checks-fast.py':checks,'configure-fast.py':configure}
for name,source in outputs.items():
    compile(source,name,'exec')
    (HERE/name).write_text(source)
manifest={'design':'2x2: interpreter/CodeGen x original/cached safepoint bookkeeping',
 'unchanged':['1024 non-GC callbacks per kernel tick','1000 ticks per request/initialization','per-application VM budget','capability identity checks','application source','original reset and input handling'],
 'mechanism':'Host-owned coroutine data caches the Frame counter location; full owner checks occur before every kernel budget tick. Operations and resumes still validate their complete identities.',
 'sha256':{str(HERE/n):hashlib.sha256((HERE/n).read_bytes()).hexdigest() for n in ['fastmeter.py','prepare.py','checks.py','configure.py',*outputs]}}
(REPORT/'factorial-source.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Generated four-profile CodeGen/meter experiment; no measurements claimed')
