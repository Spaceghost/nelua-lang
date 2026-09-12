/* SPDX-License-Identifier: MIT
 * Deliberately small C shim for Lua's protected-call and continuation API.
 * No external I/O, no async C stack preservation, no current-request global.
 */
#include "kernel.h"
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#if LUA_VERSION_NUM != 505
#error This bridge is tested against Lua 5.5, not an assumed 5.4 ABI.
#endif

typedef struct {
  uint32_t id;
  lua_State *root, *co;
  const char *source, *method, *url, *body;
  size_t source_n, method_n, url_n, body_n;
} Vm;
typedef struct { uint32_t id; int kind; } Capability;
static const char *CAP = "lua-worker.capability.v1";
static uint32_t owner(lua_State *L) { return *(uint32_t *)lua_getextraspace(L); }
static int fail(uint32_t id, const char *message) {
  return lw_result(id, 5, 500, (void *)message, strlen(message));
}
static const char *bytes(lua_State *L, int index, size_t *n) {
  luaL_checktype(L, index, LUA_TSTRING);
  return lua_tolstring(L, index, n);
}
static void budget(lua_State *L, lua_Debug *ar) {
  (void)ar;
  if (!lw_tick(owner(L))) luaL_error(L, "instruction budget exhausted");
}
static int finish_operation(lua_State *L, int status, lua_KContext context) {
  (void)status;
  uint32_t id = (uint32_t)context;
  if (id != owner(L)) return luaL_error(L, "operation owner mismatch");
  if (!lw_ok(id)) {
    lua_pushlstring(L, lw_data(id), lw_size(id));
    return lua_error(L);
  }
  if (lw_kind(id) == 3) return 0;
  if (lw_kind(id) == 1) {
    if (lw_status(id) == 404) lua_pushnil(L);
    else lua_pushlstring(L, lw_data(id), lw_size(id));
    return 1;
  }
  lua_createtable(L, 0, 2);
  lua_pushinteger(L, lw_status(id)); lua_setfield(L, -2, "status");
  lua_pushlstring(L, lw_data(id), lw_size(id)); lua_setfield(L, -2, "body");
  return 1;
}
static int issue(lua_State *L, uint32_t id, int kind, int index) {
  size_t n;
  const char *p = bytes(L, index, &n);
  if (id != owner(L)) return luaL_error(L, "capability owner mismatch");
  if (lw_issue(id, kind, (void *)p, n))
    return luaL_error(L, "operation rejected: size, count, or state limit");
  lua_settop(L, 0);
  return lua_yieldk(L, 0, (lua_KContext)id, finish_operation);
}
static int storage_get(lua_State *L) {
  Capability *cap = luaL_checkudata(L, 1, CAP);
  if (cap->kind != 1) return luaL_error(L, "CONFIG capability required");
  return issue(L, cap->id, 1, 2);
}
static int upstream_fetch(lua_State *L) {
  Capability *cap = luaL_checkudata(L, 1, CAP);
  if (cap->kind != 2) return luaL_error(L, "UPSTREAM capability required");
  return issue(L, cap->id, 2, 2);
}
static int log_message(lua_State *L) {
  return issue(L, (uint32_t)lua_tointeger(L, lua_upvalueindex(1)), 3, 1);
}
static int http_text(lua_State *L) {
  size_t n;
  bytes(L, 1, &n);
  if (n > 65536) return luaL_error(L, "response body limit exceeded");
  lua_Integer status = luaL_optinteger(L, 2, 200);
  if (status < 200 || status > 599) return luaL_error(L, "invalid response status");
  lua_createtable(L, 0, 2);
  lua_pushvalue(L, 1); lua_setfield(L, -2, "body");
  lua_pushinteger(L, status); lua_setfield(L, -2, "status");
  return 1;
}
static int require_http(lua_State *L) {
  size_t n;
  const char *name = bytes(L, 1, &n);
  if (n != 11 || memcmp(name, "worker.http", 11))
    return luaL_error(L, "module not allowed");
  lua_createtable(L, 0, 1);
  lua_pushcfunction(L, http_text); lua_setfield(L, -2, "text");
  return 1;
}
static void capability(lua_State *L, uint32_t id, int kind) {
  Capability *cap = lua_newuserdatauv(L, sizeof(*cap), 0);
  cap->id = id; cap->kind = kind;
  luaL_setmetatable(L, CAP);
}
static int prepare(lua_State *L) {
  Vm *vm = lua_touserdata(L, 1);
  luaL_requiref(L, "_G", luaopen_base, 1); lua_pop(L, 1);
  /* No catchable budget errors, user-created finalizers, filesystem, debugger,
   * binary loader, dynamic modules, or child coroutines in the initial profile. */
  const char *deny[] = {"dofile", "loadfile", "load", "collectgarbage", "print", "warn",
    "pcall", "xpcall", "getmetatable", "setmetatable", NULL};
  for (int i = 0; deny[i]; ++i) { lua_pushnil(L); lua_setglobal(L, deny[i]); }
  luaL_requiref(L, "string", luaopen_string, 1);
  lua_pushnil(L); lua_setfield(L, -2, "dump"); lua_pop(L, 1);
  luaL_requiref(L, "table", luaopen_table, 1); lua_pop(L, 1);
  luaL_requiref(L, "math", luaopen_math, 1); lua_pop(L, 1);
  luaL_requiref(L, "utf8", luaopen_utf8, 1); lua_pop(L, 1);
  lua_pushcfunction(L, require_http); lua_setglobal(L, "require");
  luaL_newmetatable(L, CAP);
  lua_pushliteral(L, "sealed capability"); lua_setfield(L, -2, "__metatable");
  lua_createtable(L, 0, 2);
  lua_pushcfunction(L, storage_get); lua_setfield(L, -2, "get");
  lua_pushcfunction(L, upstream_fetch); lua_setfield(L, -2, "fetch");
  lua_setfield(L, -2, "__index"); lua_pop(L, 1);
  vm->co = lua_newthread(L);
  luaL_ref(L, LUA_REGISTRYINDEX); /* root owns this coroutine until close */
  if (!lua_checkstack(vm->co, 32)) return luaL_error(L, "coroutine stack allocation failed");
  lua_sethook(vm->co, budget, LUA_MASKCOUNT, 1000);
  const char *entry = "return function(app, request, env, ctx) "
    "local h=app(); assert(type(h)=='table' and type(h.fetch)=='function', "
    "'application must return a fetch handler'); return h.fetch(request,env,ctx) end";
  if (luaL_loadbufferx(L, entry, strlen(entry), "@worker-entry.lua", "t")) return lua_error(L);
  lua_call(L, 0, 1); /* only constructs the trusted wrapper; application runs on co */
  if (luaL_loadbufferx(L, vm->source, vm->source_n, "@app.lua", "t")) return lua_error(L);
  lua_createtable(L, 0, 3);
  lua_pushlstring(L, vm->method, vm->method_n); lua_setfield(L, -2, "method");
  lua_pushlstring(L, vm->url, vm->url_n); lua_setfield(L, -2, "url");
  lua_pushlstring(L, vm->body, vm->body_n); lua_setfield(L, -2, "body");
  lua_createtable(L, 0, 2);
  capability(L, vm->id, 1); lua_setfield(L, -2, "CONFIG");
  capability(L, vm->id, 2); lua_setfield(L, -2, "UPSTREAM");
  lua_createtable(L, 0, 1);
  lua_pushinteger(L, vm->id); lua_pushcclosure(L, log_message, 1); lua_setfield(L, -2, "log");
  lua_xmove(L, vm->co, 5);
  return 0;
}
static int save_traceback(lua_State *L) {
  Vm *vm = lua_touserdata(L, 1);
  const char *message = lua_type(vm->co, -1) == LUA_TSTRING ? lua_tostring(vm->co, -1) : "non-string Lua error";
  luaL_traceback(L, vm->co, message, 0);
  size_t n; const char *p = lua_tolstring(L, -1, &n);
  if (n > 8192) n = 8192;
  lw_result(vm->id, 5, 500, (void *)p, n);
  return 0;
}
static int save_response(lua_State *L) {
  uint32_t id = (uint32_t)lua_tointeger(L, 1);
  luaL_checktype(L, 2, LUA_TTABLE);
  lua_pushliteral(L, "status"); lua_rawget(L, 2);
  lua_Integer status = luaL_checkinteger(L, -1); lua_pop(L, 1);
  if (status < 200 || status > 599) return luaL_error(L, "invalid response status");
  lua_pushliteral(L, "body"); lua_rawget(L, 2);
  size_t n; const char *p = bytes(L, -1, &n);
  if (n > 65536) return luaL_error(L, "response body limit exceeded");
  if ((status == 204 || status == 205 || status == 304) && n)
    return luaL_error(L, "body forbidden for this response status");
  lw_result(id, 4, (int)status, (void *)p, n);
  return 0;
}
static int step(Vm *vm, int nargs) {
  int nresults = 0;
  int status = lua_resume(vm->co, NULL, nargs, &nresults);
  if (status == LUA_YIELD) {
    if (nresults != 0 || lw_state(vm->id) != 3) return fail(vm->id, "unexpected coroutine yield");
    return 3;
  }
  lua_State *L = vm->root;
  lua_settop(L, 0);
  if (status != LUA_OK) {
    lua_pushcfunction(L, save_traceback); lua_pushlightuserdata(L, vm);
    if (lua_pcall(L, 1, 0, 0)) {
      /* OOM can prevent traceback allocation; never panic while reporting it. */
      fail(vm->id, status == LUA_ERRMEM ? "Lua allocation limit exceeded (traceback unavailable)" : "Lua error (traceback unavailable)");
    }
  } else if (nresults != 1) {
    fail(vm->id, "fetch must return exactly one response");
  } else {
    lua_pushcfunction(L, save_response); lua_pushinteger(L, vm->id);
    lua_xmove(vm->co, L, 1);
    if (lua_pcall(L, 2, 0, 0)) {
      const char *message = lua_tostring(L, -1);
      fail(vm->id, message ? message : "invalid response");
    }
  }
  lua_settop(L, 0);
  return lw_state(vm->id);
}
int lw_start(uint32_t id, const char *source, size_t source_n, const char *method, size_t method_n,
             const char *url, size_t url_n, const char *body, size_t body_n, uint32_t seed) {
  if (lw_state(id) != 1) return -1;
  if (!source_n || source_n > 65536 || !method_n || method_n > 16 || url_n > 4096 || body_n > 65536)
    return fail(id, "request or source limit exceeded");
  Vm *vm = calloc(1, sizeof(*vm));
  if (!vm) return fail(id, "VM descriptor allocation failed");
  vm->id = id;
  vm->source = source; vm->source_n = source_n;
  vm->method = method; vm->method_n = method_n;
  vm->url = url; vm->url_n = url_n;
  vm->body = body; vm->body_n = body_n;
  if (lw_attach(id, vm)) { free(vm); return -1; }
  vm->root = lua_newstate(lw_lua_alloc, (void *)(uintptr_t)id, seed);
  if (!vm->root) return fail(id, "Lua state allocation failed");
  *(uint32_t *)lua_getextraspace(vm->root) = id;
  lua_pushcfunction(vm->root, prepare); lua_pushlightuserdata(vm->root, vm);
  if (lua_pcall(vm->root, 1, 0, 0)) {
    const char *message = lua_tostring(vm->root, -1);
    return fail(id, message ? message : "Lua preparation failed");
  }
  /* Source/request pointer lifetimes end here; only Lua-owned values survive. */
  vm->source = vm->method = vm->url = vm->body = NULL;
  return step(vm, 4);
}
int bridge_resume(uint32_t id) {
  Vm *vm = lw_vm(id);
  if (!vm || lw_state(id) != 2) return -1;
  return step(vm, 0);
}
void bridge_close(void *p) {
  Vm *vm = p;
  if (vm->root) lua_close(vm->root);
  free(vm);
}
