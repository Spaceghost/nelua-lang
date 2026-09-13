/* SPDX-License-Identifier: MIT
 * Luau 0.738 C ABI adaptation. Only host-produced bytecode enters luau_load.
 * Compilation allocations are outside the Lua heap counter; the source bound
 * and outer process memory/CPU limits must also cover the compiler.
 */
#include "lua.h"
#include "lualib.h"
#include "luacode.h"
#include <stdlib.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#undef lua_pushcfunction
#undef lua_pushcclosure
#define lua_pushcfunction(L,f) lua_pushcclosurek(L,f,#f,0,NULL)
#define lua_pushcclosure(L,f,n) lua_pushcclosurek(L,f,#f,n,NULL)
static int peer_luau_error(lua_State *L,const char *fmt,...){
  char buf[8192];va_list ap;va_start(ap,fmt);vsnprintf(buf,sizeof(buf),fmt,ap);va_end(ap);
  luaL_errorL(L,"%s",buf);return 0;
}
#undef luaL_error
#define luaL_error peer_luau_error
static int peer_luau_throw(lua_State *L){lua_error(L);return 0;}
#define lua_error peer_luau_throw
static int luaL_ref(lua_State *L,int index){
  if(index!=LUA_REGISTRYINDEX)return luaL_error(L,"invalid registry");
  int r=lua_ref(L,-1);lua_pop(L,1);return r;
}
static int luaL_loadbufferx(lua_State *L,const char *source,size_t n,const char *name,const char *mode){
  (void)mode;
  if(n==0||n>65536||(unsigned char)source[0]==27){lua_pushliteral(L,"text-only source required; binary chunks are not allowed");return LUA_ERRSYNTAX;}
  struct lua_CompileOptions options={0};options.optimizationLevel=2;options.debugLevel=1;
  size_t length=0;char *code=luau_compile(source,n,&options,&length);
  if(!code){lua_pushliteral(L,"source compilation allocation failed");return LUA_ERRMEM;}
  /* luau_load protects parsing/loading errors and returns a status. */
  int result=luau_load(L,name,code,length,0);free(code);return result;
}
