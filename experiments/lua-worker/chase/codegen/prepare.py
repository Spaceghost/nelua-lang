#!/usr/bin/env python3
"""Derive native Luau interpreter/CodeGen peers without altering frozen controls."""
from pathlib import Path
import hashlib, json, os, shutil, subprocess
ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
OUT = Path('dist/codegen'); OUT.mkdir(parents=True, exist_ok=True)
REPORT = Path('reports/codegen'); REPORT.mkdir(parents=True, exist_ok=True)
def once(s, old, new):
    if s.count(old) != 1: raise ValueError('baseline drift: ' + old[:120])
    return s.replace(old, new, 1)
def run(args):
    print('BUILD', *args, flush=True)
    subprocess.run(args, check=True)
source = Path('dist/engines/luau-runtime.c').read_text()
source = once(source, 'static const char CAP[]=', '''extern int cg_create(lua_State *);
extern int cg_compile(lua_State *,int,uint32_t *,size_t *);
extern int cg_in_application(lua_State *);
extern void cg_enable(lua_State *,int);
static const char CAP[]=''')
source = once(source, 'Frame requests[8];', '''Frame requests[8];
  uint32_t cg_functions, cg_observe; uint64_t cg_safepoints; size_t cg_bytes;''')
source = once(source, '  uint32_t id=owner(a,L);', '''  if(a->cg_observe && cg_in_application(L))++a->cg_safepoints;
  uint32_t id=owner(a,L);''')
source = once(source, '  np_app *a=lua_touserdata(L,1);library(L,"_G",luaopen_base);', '''  np_app *a=lua_touserdata(L,1);
#if PEER_CODEGEN
  if(cg_create(L))return luaL_error(L,"CodeGen initialization failed");
#endif
  library(L,"_G",luaopen_base);''')
source = once(source, '  if(luaL_loadbufferx(L,a->source,a->source_n,"@app.lua","t"))return lua_error(L);', '''  if(luaL_loadbufferx(L,a->source,a->source_n,"@app.lua","t"))return lua_error(L);
#if PEER_CODEGEN
  if(cg_compile(L,-1,&a->cg_functions,&a->cg_bytes))return luaL_error(L,"CodeGen compilation failed");
#endif''')
source += '''
uint32_t np_codegen_functions(np_app *a){return a->cg_functions;}
size_t np_codegen_bytes(np_app *a){return a->cg_bytes;}
uint64_t np_codegen_safepoints(np_app *a){return a->cg_safepoints;}
void np_codegen_observe(np_app *a,int enabled){a->cg_observe=enabled!=0;}
void np_codegen_enable(np_app *a,int enabled){if(a->cg_functions)cg_enable(a->root,enabled);}
'''
(OUT/'runtime.c').write_text(source)
host = Path('peer/kj-host.c++').read_text()
host = once(host, '#include "api.h"', '''#include "api.h"
extern "C" uint32_t np_codegen_functions(np_app *);
extern "C" size_t np_codegen_bytes(np_app *);''')
host = once(host, 'np_traces(app),",\\"requests\\":",completed,"}");',
    'np_traces(app),",\\"requests\\":",completed,",\\"codegenFunctions\\":",np_codegen_functions(app),",\\"nativeCodeBytes\\":",np_codegen_bytes(app),"}");')
(OUT/'host.cpp').write_text(host)
run(['cmake','--build','.deps/luau-native','--target','Luau.CodeGen','-j2'])
run(['cmake','--build','.deps/luau-asan','--target','Luau.CodeGen','-j2'])
inc=['-Ipeer','-Idist/peer','-Iengines','-I.deps/luau/VM/include','-I.deps/luau/VM/src','-I.deps/luau/Compiler/include','-I.deps/luau/CodeGen/include','-I.deps/luau/Common/include']
libs=['Luau.Compiler','Luau.Ast','Luau.Bytecode','Luau.CodeGen','Luau.VM','Luau.Common']
kj=subprocess.check_output(['pkg-config','--cflags','--libs','kj-http','kj-async'],text=True).split()
manifest={'checkout':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
 'luau':subprocess.check_output(['git','-C','.deps/luau','rev-parse','HEAD'],text=True).strip(),
 'nativeCodeAllocationCap':4194304,'profiles':[]}
for label,enabled in [('interp',0),('compiled',1)]:
    for sanitized in [False,True]:
        suffix=label+('-asan' if sanitized else '')
        flags=['-O1','-g','-fsanitize=address,undefined','-fno-omit-frame-pointer'] if sanitized else ['-O2','-g']
        linklibs=['.deps/luau-'+('asan' if sanitized else 'native')+'/lib'+x+'.a' for x in libs]
        run(['gcc','-std=c11','-fPIC',*flags,*inc,'-DPEER_LUAU',f'-DPEER_CODEGEN={enabled}','-c',str(OUT/'runtime.c'),'-o',str(OUT/(suffix+'-runtime.o'))])
        run(['g++','-std=c++17','-fPIC',*flags,*inc,'-DLUA_API=extern "C"','-c','chase/codegen/bridge.cpp','-o',str(OUT/(suffix+'-bridge.o'))])
        kernel='dist/engines/kernel-native-asan.o' if sanitized else 'dist/engines/luau-kernel.o'
        objects=[kernel,str(OUT/(suffix+'-runtime.o')),str(OUT/(suffix+'-bridge.o'))]
        if sanitized:
            run(['gcc',*flags,'-Ipeer','-c','peer/core-test.c','-o',str(OUT/'test-asan.o')])
            run(['g++',*flags,str(OUT/'test-asan.o'),*objects,'-Wl,--start-group',*linklibs,'-Wl,--end-group','-lm','-o',str(OUT/(suffix+'-test'))])
            run(['timeout','-s','KILL','60',str(OUT/(suffix+'-test'))])
        else:
            lib=OUT/('libpeer-'+label+'.so')
            run(['g++','-shared',*flags,*objects,'-Wl,--start-group',*linklibs,'-Wl,--end-group','-lm','-o',str(lib)])
            run(['g++','-std=c++17',*flags,'-Ipeer',str(OUT/'host.cpp'),'-L'+str(OUT),'-lpeer-'+label,*kj,'-Wl,-rpath,$ORIGIN','-o',str(OUT/('host-'+label))])
    manifest['profiles'].append({'name':label,'nativeCodegen':bool(enabled),'sanitizers':'PASS'})
manifest['sha256']={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [OUT/'runtime.c',OUT/'host.cpp',Path('peer/worker.lua'),Path('chase/codegen/bridge.cpp'),*OUT.glob('*.so'),*OUT.glob('host-*')] if p.is_file()}
(OUT/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
