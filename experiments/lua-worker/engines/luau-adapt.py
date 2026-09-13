#!/usr/bin/env python3
"""Derive the Luau adapter from the reviewed explicit-context peer implementation."""
from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parents[1]
s=(root/'peer/runtime.c').read_text()
def once(old,new):
    global s
    if s.count(old)!=1:raise ValueError('adapter baseline drift: '+old[:80])
    s=s.replace(old,new,1)
once('#include "lauxlib.h"','#include "luau-shim.h"')
once('#else\n#if LUA_VERSION_NUM != 505','#elif !defined(PEER_LUAU)\n#if LUA_VERSION_NUM != 505')
once('typedef struct {lua_State *co;uint32_t id;} Frame;', 'typedef struct {lua_State *co;uint32_t id,interrupts;} Frame;')
once('int handler,frames,log_factory,ready,jit;uint32_t traces;', 'int handler,frames,log_factory,ready,jit;uint32_t traces,init_interrupts;')
once('static void hook(lua_State *L,lua_Debug *ar){(void)ar;np_app *a=app_for(L);if(!nk_tick(a->kernel,owner(a,L)))luaL_error(L,"instruction budget exhausted");}', '''static void hook(lua_State *L,int gc){
  /* GC callbacks must not raise errors. Execution safepoints use gc < 0. */
  if(gc>=0)return;
  np_app *a=app_for(L);if(!a)return;
  uint32_t id=owner(a,L);int index=nk_index(a->kernel,id);
  uint32_t *count=index<0?&a->init_interrupts:&a->requests[index].interrupts;
  if(++*count>=1024){*count=0;if(!nk_tick(a->kernel,id))luaL_error(L,"instruction budget exhausted (Luau safepoint budget)");}
}''')
once('#ifdef PEER_LUAJIT\n  /* LuaJIT open functions', '#if defined(PEER_LUAJIT) || defined(PEER_LUAU)\n  /* LuaJIT/Luau open functions')
once('(void)seed;a->root=lua_newstate(nk_alloc,a->kernel);', '(void)seed;a->root=lua_newstate(nk_alloc,a->kernel);')
s=s.replace('#ifdef PEER_LUAJIT\n  (void)seed;', '#if defined(PEER_LUAJIT) || defined(PEER_LUAU)\n  (void)seed;')
once('if(!a->jit)lua_sethook(L,hook,LUA_MASKCOUNT,1000);','lua_callbacks(L)->interrupt=hook;')
once('lua_sethook(L,NULL,0,0);a->source=NULL;', 'a->source=NULL;')
once('if(!a->jit)lua_sethook(r->co,hook,LUA_MASKCOUNT,1000);','r->interrupts=0;')
once('#ifdef PEER_LUAJIT\n  Capability *c=lua_newuserdata', '#if defined(PEER_LUAJIT) || defined(PEER_LUAU)\n  Capability *c=lua_newuserdata')
once('#ifdef PEER_LUAJIT\n  int result=lua_resume(co,nargs);nresults=lua_gettop(co);', '#ifdef PEER_LUAU\n  int result=lua_resume(co,NULL,nargs);nresults=lua_gettop(co);\n#elif defined(PEER_LUAJIT)\n  int result=lua_resume(co,nargs);nresults=lua_gettop(co);')
once('#ifndef PEER_LUAJIT\n    lua_closethread(r->co,a->root);', '#if !defined(PEER_LUAJIT) && !defined(PEER_LUAU)\n    lua_closethread(r->co,a->root);')
once('    lua_sethook(r->co,NULL,0,0);', '    lua_resetthread(r->co);')
once('return LUA_RELEASE;', 'return "Luau 0.738 (interrupt-metered)";')
once('  lua_createtable(L,8,0);a->frames=luaL_ref(L,LUA_REGISTRYINDEX);', '''  lua_createtable(L,8,0);a->frames=luaL_ref(L,LUA_REGISTRYINDEX);
  luaL_sandbox(L);luaL_sandboxthread(L); /* Readonly builtins, app-local writable globals. */''')
(root/'dist/engines').mkdir(parents=True,exist_ok=True)
(root/'dist/engines/luau-runtime.c').write_text(s)
(root/'reports/engines').mkdir(parents=True,exist_ok=True)
(root/'reports/engines/adapter.json').write_text(json.dumps({'baseSha256':hashlib.sha256((root/'peer/runtime.c').read_bytes()).hexdigest(),'generatedSha256':hashlib.sha256(s.encode()).hexdigest(),'budget':'1024 interrupt callbacks per kernel tick; not Lua opcode counting','userBinaryChunks':False},indent=2)+'\n')
