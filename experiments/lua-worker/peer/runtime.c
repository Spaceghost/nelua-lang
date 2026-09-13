/* SPDX-License-Identifier: MIT
 * One explicitly owned application, identical worker contract on Lua 5.5 and
 * LuaJIT. All fallible Lua operations stay behind protected C entry points.
 * C++ host frames never survive a Lua yield or error longjmp.
 */
#include "api.h"
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "bootstrap.h"
#include <stdlib.h>
#include <string.h>
#ifdef PEER_LUAJIT
#include "luajit.h"
#else
#if LUA_VERSION_NUM != 505
#error Expected the pinned Lua 5.5 C API
#endif
#endif
#ifndef LUA_OK
#define LUA_OK 0
#endif
static const char CAP[] = "peer.capability.v1";
typedef struct { lua_State *co; uint32_t id; } Frame;
struct np_app {
  void *kernel;
  lua_State *root;
  int handler, frames, log_factory, ready, jit;
  uint32_t traces;
  Frame requests[8];
  const char *source, *method, *url, *body;
  size_t source_n, method_n, url_n, body_n;
  uint32_t preparing;
  int result_ok, result_status;
  char error[8193];
};
typedef struct { np_app *app; uint32_t id; int kind; } Capability;
static void error_text(np_app *a, const char *s) {
  size_t n=strlen(s); if(n>8192)n=8192; memcpy(a->error,s,n); a->error[n]=0;
}
static uint32_t owner(np_app *a, lua_State *L) {
  for(int i=0;i<8;i++)if(a->requests[i].co==L)return a->requests[i].id;
  return 0;
}
static np_app *app_for(lua_State *L) {
  void *ud=NULL; lua_getallocf(L,&ud); return nk_vm(ud);
}
static void hook(lua_State *L, lua_Debug *ar) {
  (void)ar; np_app *a=app_for(L);
  if(!nk_tick(a->kernel,owner(a,L)))luaL_error(L,"instruction budget exhausted");
}
static int fail(np_app *a,uint32_t id,const char *s) {
  size_t n=strlen(s); if(n>8192)n=8192;
  return nk_result(a->kernel,id,5,500,(void *)s,n);
}
static const char *string(lua_State *L,int index,size_t *n) {
  luaL_checktype(L,index,LUA_TSTRING); return lua_tolstring(L,index,n);
}
static int issue(lua_State *L) {
  Capability *c=luaL_checkudata(L,1,CAP);
  np_app *a=lua_touserdata(L,lua_upvalueindex(1));
  int kind=(int)luaL_checkinteger(L,2); size_t n; const char *p=string(L,3,&n);
  if(c->app!=a || c->id==0 || owner(a,L)!=c->id || c->kind!=kind)
    return luaL_error(L,"capability owner or type mismatch");
  if(kind==2) {
    if(n==0 || p[0]!='/' || (n>1 && p[1]=='/'))return luaL_error(L,"CAPABILITY: relative upstream path required");
    for(size_t i=0;i<n;i++)if((unsigned char)p[i]<32 || p[i]=='\\' || p[i]==127)
      return luaL_error(L,"CAPABILITY: invalid upstream path");
  }
  if(nk_issue(a->kernel,c->id,kind,(void *)p,n))return luaL_error(L,"operation rejected: size, count or state limit");
  return 0;
}
static int text_response(lua_State *L) {
  size_t n; string(L,1,&n); if(n>65536)return luaL_error(L,"response body limit exceeded");
  lua_Integer status=luaL_optinteger(L,2,200);
  if(status<200 || status>599)return luaL_error(L,"invalid response status");
  lua_createtable(L,0,2);lua_pushvalue(L,1);lua_setfield(L,-2,"body");
  lua_pushinteger(L,status);lua_setfield(L,-2,"status");return 1;
}
static int require_http(lua_State *L) {
  size_t n;const char *s=string(L,1,&n);
  if(n!=11 || memcmp(s,"worker.http",11))return luaL_error(L,"module not allowed");
  lua_createtable(L,0,1);lua_pushcfunction(L,text_response);lua_setfield(L,-2,"text");return 1;
}
static void library(lua_State *L,const char *name,lua_CFunction fn) {
#ifdef PEER_LUAJIT
  lua_pushcfunction(L,fn);lua_pushstring(L,name);lua_call(L,1,1);lua_setglobal(L,name);
#else
  luaL_requiref(L,name,fn,1);lua_pop(L,1);
#endif
}
#ifdef PEER_LUAJIT
static int trace_event(lua_State *L) {
  np_app *a=lua_touserdata(L,lua_upvalueindex(1));
  const char *event=lua_tostring(L,1);
  if(event && strcmp(event,"stop")==0)++a->traces;
  return 0;
}
#endif
static int prepare_app(lua_State *L) {
  np_app *a=lua_touserdata(L,1);
  library(L,"_G",luaopen_base);
  library(L,"string",luaopen_string);library(L,"table",luaopen_table);library(L,"math",luaopen_math);
#ifndef PEER_LUAJIT
  library(L,"utf8",luaopen_utf8);library(L,"coroutine",luaopen_coroutine);
#else
  luaJIT_setmode(L,0,LUAJIT_MODE_ENGINE | (a->jit?LUAJIT_MODE_ON:LUAJIT_MODE_OFF));
  if(a->jit) {
    library(L,"jit",luaopen_jit);lua_getglobal(L,"jit");lua_getfield(L,-1,"attach");
    lua_pushlightuserdata(L,a);lua_pushcclosure(L,trace_event,1);lua_pushliteral(L,"trace");lua_call(L,2,0);lua_pop(L,1);
  }
#endif
  if(luaL_loadbuffer(L,peer_bootstrap,sizeof(peer_bootstrap)-1,"@peer-bootstrap.lua"))return lua_error(L);
  lua_pushlightuserdata(L,a);lua_pushcclosure(L,issue,1);
  lua_getglobal(L,"coroutine");lua_getfield(L,-1,"yield");lua_remove(L,-2);
  lua_call(L,2,2);a->log_factory=luaL_ref(L,LUA_REGISTRYINDEX);
  luaL_newmetatable(L,CAP);lua_pushliteral(L,"sealed capability");lua_setfield(L,-2,"__metatable");
  lua_pushvalue(L,-2);lua_setfield(L,-2,"__index");lua_pop(L,2);
  const char *deny[]={"dofile","loadfile","load","loadstring","collectgarbage","print","warn","pcall","xpcall",
    "getmetatable","setmetatable","newproxy","getfenv","setfenv","module","coroutine","jit","io","os","debug","package",NULL};
  for(int i=0;deny[i];i++){lua_pushnil(L);lua_setglobal(L,deny[i]);}
  lua_getglobal(L,"string");lua_pushnil(L);lua_setfield(L,-2,"dump");lua_pop(L,1);
  lua_pushcfunction(L,require_http);lua_setglobal(L,"require");
  lua_createtable(L,8,0);a->frames=luaL_ref(L,LUA_REGISTRYINDEX);
  /* Explicit bytecode refusal even when a VM's loader accepts binary chunks. */
  if(a->source_n && (unsigned char)a->source[0]==27)return luaL_error(L,"binary chunks are not allowed");
  if(luaL_loadbuffer(L,a->source,a->source_n,"@app.lua"))return lua_error(L);
  lua_call(L,0,1);luaL_checktype(L,-1,LUA_TTABLE);
  lua_pushliteral(L,"fetch");lua_rawget(L,-2);
  if(!lua_isfunction(L,-1))return luaL_error(L,"application must return a fetch handler");
  a->handler=luaL_ref(L,LUA_REGISTRYINDEX);return 0;
}
np_app *np_new(size_t limit,int jit) {
#ifndef PEER_LUAJIT
  if(jit)return NULL;
#endif
  np_app *a=calloc(1,sizeof(*a));if(!a)return NULL;
  a->kernel=nk_new(limit);if(!a->kernel){free(a);return NULL;}
  nk_setvm(a->kernel,a);a->jit=jit;return a;
}
int np_load(np_app *a,const char *source,size_t n,uint32_t seed) {
  if(a->root || !n || n>65536){error_text(a,"source limit or already loaded");return -1;}
  a->source=source;a->source_n=n;
#ifdef PEER_LUAJIT
  (void)seed;a->root=lua_newstate(nk_alloc,a->kernel);
#else
  a->root=lua_newstate(nk_alloc,a->kernel,seed);
#endif
  if(!a->root){error_text(a,"Lua allocation failed");return -1;}
  lua_State *L=a->root;
  if(!a->jit)lua_sethook(L,hook,LUA_MASKCOUNT,1000);
  lua_pushcfunction(L,prepare_app);lua_pushlightuserdata(L,a);
  int result=lua_pcall(L,1,0,0);lua_sethook(L,NULL,0,0);
  a->source=NULL;a->source_n=0;
  if(result){error_text(a,lua_type(L,-1)==LUA_TSTRING?lua_tostring(L,-1):"application initialization failed");lua_settop(L,0);return -1;}
  a->ready=1;return 0;
}
static void cap(lua_State *L,np_app *a,uint32_t id,int kind) {
#ifdef PEER_LUAJIT
  Capability *c=lua_newuserdata(L,sizeof(*c));
#else
  Capability *c=lua_newuserdatauv(L,sizeof(*c),0);
#endif
  c->app=a;c->id=id;c->kind=kind;luaL_getmetatable(L,CAP);lua_setmetatable(L,-2);
}
static int prepare_request(lua_State *L) {
  np_app *a=lua_touserdata(L,1);uint32_t id=a->preparing;int index=nk_index(a->kernel,id);
  Frame *r=&a->requests[index];r->id=id;
  lua_rawgeti(L,LUA_REGISTRYINDEX,a->frames);r->co=lua_newthread(L);
  lua_rawseti(L,-2,index+1);lua_pop(L,1);
  if(!lua_checkstack(r->co,32))return luaL_error(L,"coroutine stack allocation failed");
  if(!a->jit)lua_sethook(r->co,hook,LUA_MASKCOUNT,1000);
  lua_rawgeti(L,LUA_REGISTRYINDEX,a->handler);
  lua_createtable(L,0,3);
  lua_pushlstring(L,a->method,a->method_n);lua_setfield(L,-2,"method");
  lua_pushlstring(L,a->url,a->url_n);lua_setfield(L,-2,"url");
  lua_pushlstring(L,a->body,a->body_n);lua_setfield(L,-2,"body");
  lua_createtable(L,0,2);cap(L,a,id,1);lua_setfield(L,-2,"CONFIG");cap(L,a,id,2);lua_setfield(L,-2,"UPSTREAM");
  lua_createtable(L,0,1);lua_rawgeti(L,LUA_REGISTRYINDEX,a->log_factory);cap(L,a,id,3);lua_call(L,1,1);lua_setfield(L,-2,"log");
  lua_xmove(L,r->co,4);return 0;
}
static int save_response(lua_State *L) {
  np_app *a=lua_touserdata(L,1);uint32_t id=(uint32_t)lua_tointeger(L,2);
  luaL_checktype(L,3,LUA_TTABLE);lua_pushliteral(L,"status");lua_rawget(L,3);
  if(!lua_isnumber(L,-1))return luaL_error(L,"invalid response status");
  lua_Number status=lua_tonumber(L,-1);lua_pop(L,1);
  if(status<200 || status>599 || status!=(int)status)return luaL_error(L,"invalid response status");
  lua_pushliteral(L,"body");lua_rawget(L,3);size_t n;const char *p=string(L,-1,&n);
  if(n>65536)return luaL_error(L,"response body limit exceeded");
  if(n && (status==204 || status==205 || status==304))return luaL_error(L,"body forbidden for response status");
  nk_result(a->kernel,id,4,(int)status,(void *)p,n);return 0;
}
static int traceback(lua_State *L) {
  np_app *a=lua_touserdata(L,1);uint32_t id=(uint32_t)lua_tointeger(L,2);
  lua_State *co=a->requests[nk_index(a->kernel,id)].co;
  const char *message=lua_type(co,-1)==LUA_TSTRING?lua_tostring(co,-1):"non-string Lua error";
  luaL_traceback(L,co,message,0);fail(a,id,lua_tostring(L,-1));return 0;
}
static int step(np_app *a,uint32_t id,int nargs) {
  lua_State *co=a->requests[nk_index(a->kernel,id)].co;int nresults=0;
#ifdef PEER_LUAJIT
  int result=lua_resume(co,nargs);nresults=lua_gettop(co);
#else
  int result=lua_resume(co,NULL,nargs,&nresults);
#endif
  if(result==LUA_YIELD) {
    if(nresults || nk_state(a->kernel,id)!=3)return fail(a,id,"unexpected coroutine yield");
    return 3;
  }
  lua_State *L=a->root;lua_settop(L,0);
  if(result!=LUA_OK) {
    lua_pushcfunction(L,traceback);lua_pushlightuserdata(L,a);lua_pushinteger(L,id);
    if(lua_pcall(L,2,0,0))fail(a,id,"Lua allocation/error limit; traceback unavailable");
  } else if(nresults!=1)fail(a,id,"fetch must return exactly one response");
  else {
    lua_pushcfunction(L,save_response);lua_pushlightuserdata(L,a);lua_pushinteger(L,id);lua_xmove(co,L,1);
    if(lua_pcall(L,3,0,0))fail(a,id,lua_type(L,-1)==LUA_TSTRING?lua_tostring(L,-1):"invalid response");
  }
  lua_settop(L,0);return nk_state(a->kernel,id);
}
uint32_t np_start(np_app *a,const char *method,size_t mn,const char *url,size_t un,const char *body,size_t bn) {
  if(!a->ready || !mn || mn>16 || un>4096 || bn>65536)return 0;
  uint32_t id=nk_open(a->kernel);if(!id)return 0;
  /* These pointers are used only by a synchronous protected preparation call.
   * They are cleared before guest execution or return to the host. */
  a->preparing=id;a->method=method;a->method_n=mn;a->url=url;a->url_n=un;a->body=body;a->body_n=bn;
  lua_State *L=a->root;lua_settop(L,0);lua_pushcfunction(L,prepare_request);lua_pushlightuserdata(L,a);
  int result=lua_pcall(L,1,0,0);
  a->preparing=0;a->method=a->url=a->body=NULL;
  if(result){fail(a,id,lua_type(L,-1)==LUA_TSTRING?lua_tostring(L,-1):"request allocation failed");lua_settop(L,0);return id;}
  step(a,id,3);return id;
}
static int supply(lua_State *L) {
  np_app *a=lua_touserdata(L,1);uint32_t id=(uint32_t)lua_tointeger(L,2);
  lua_State *co=a->requests[nk_index(a->kernel,id)].co;
  if(!lua_checkstack(co,3))return luaL_error(L,"result stack allocation failed");
  lua_pushboolean(L,a->result_ok);lua_pushinteger(L,a->result_status);
  lua_pushlstring(L,nk_data(a->kernel,id),nk_size(a->kernel,id));lua_xmove(L,co,3);return 0;
}
int np_complete(np_app *a,uint32_t id,uint32_t seq,int ok,int status,const char *p,size_t n) {
  int resolved=nk_resolve(a->kernel,id,seq,ok,status,(void *)p,n);if(resolved)return resolved;
  a->result_ok=ok;a->result_status=status;lua_State *L=a->root;
  lua_settop(L,0);lua_pushcfunction(L,supply);lua_pushlightuserdata(L,a);lua_pushinteger(L,id);
  if(lua_pcall(L,2,0,0)){fail(a,id,"result allocation failed");lua_settop(L,0);return 5;}
  return step(a,id,3);
}
int np_close(np_app *a,uint32_t id) {
  int index=nk_index(a->kernel,id);if(index<0)return -1;
  Frame *r=&a->requests[index];
  if(r->co) {
#ifndef PEER_LUAJIT
    lua_closethread(r->co,a->root);
#endif
    lua_sethook(r->co,NULL,0,0);
    /* LuaJIT has no closethread: unroot rather than pool a suspended frame. */
    lua_rawgeti(a->root,LUA_REGISTRYINDEX,a->frames);lua_pushnil(a->root);lua_rawseti(a->root,-2,index+1);lua_pop(a->root,1);
  }
  r->co=NULL;r->id=0;return nk_close(a->kernel,id);
}
int np_delete(np_app *a) {
  if(!a || nk_active(a->kernel))return -1;
  if(a->root){lua_close(a->root);a->root=NULL;}
  if(nk_delete(a->kernel))return -2;free(a);return 0;
}
int np_collect(np_app *a) {if(np_active(a))return -1;lua_gc(a->root,LUA_GCCOLLECT,0);return 0;}
int np_state(np_app *a,uint32_t id){return nk_state(a->kernel,id);}
int np_kind(np_app *a,uint32_t id){return nk_kind(a->kernel,id);}
int np_status(np_app *a,uint32_t id){return nk_status(a->kernel,id);}
uint32_t np_sequence(np_app *a,uint32_t id){return nk_sequence(a->kernel,id);}
uint32_t np_active(np_app *a){return nk_active(a->kernel);}
uint32_t np_traces(np_app *a){return a->traces;}
const char *np_data(np_app *a,uint32_t id){return nk_data(a->kernel,id);}
const char *np_error(np_app *a){return a->error;}
size_t np_size(np_app *a,uint32_t id){return nk_size(a->kernel,id);}
size_t np_bytes(np_app *a){return nk_bytes(a->kernel);}
const char *np_version(void){
#ifdef PEER_LUAJIT
return LUAJIT_VERSION;
#else
return LUA_RELEASE;
#endif
}
