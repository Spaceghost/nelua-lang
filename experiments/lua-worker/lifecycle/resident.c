/* SPDX-License-Identifier: MIT
 * App-resident variant. App globals intentionally persist; request frames do not.
 * Included after the frozen bridge so its validation, capabilities, tracebacks
 * and resume path are reused, rather than replaced with a benchmark-only API.
 */
typedef struct {
  lua_State *root;
  uint32_t id;
  int handler, coroutines;
  const char *source;
  size_t source_n;
} Application;
typedef struct {
  Vm vm;
  uint32_t app_id;
  int slot;
  int occupied;
} WarmRequest;
static WarmRequest requests[8];
static uint32_t loads;
static void init_budget(lua_State *L, lua_Debug *ar) {
  (void)ar;
  if (!wa_tick(owner(L))) luaL_error(L, "application initialization instruction budget exhausted");
}
static int init_traceback(lua_State *L) {
  const char *message = lua_type(L, 1) == LUA_TSTRING ? lua_tostring(L, 1) : "application initialization failed";
  luaL_traceback(L, L, message, 1);
  return 1;
}
static int load_application(lua_State *L) {
  Application *a = lua_touserdata(L, 1);
  open_sandbox(L);
  lua_createtable(L, 8, 0);
  a->coroutines = luaL_ref(L, LUA_REGISTRYINDEX);
  if (luaL_loadbufferx(L, a->source, a->source_n, "@app.lua", "t")) return lua_error(L);
  lua_call(L, 0, 1); /* Initialization has no external capability and cannot yield. */
  luaL_checktype(L, -1, LUA_TTABLE);
  lua_pushliteral(L, "fetch"); lua_rawget(L, -2);
  if (!lua_isfunction(L, -1)) return luaL_error(L, "application must return a fetch handler");
  a->handler = luaL_ref(L, LUA_REGISTRYINDEX);
  return 0;
}
static int app_fail(const char *message) { return wa_error((void *)message, strlen(message)); }
int wa_load(uint32_t id, const char *source, size_t n, uint32_t seed) {
  if (!n || n > 65536) return app_fail("application source limit exceeded");
  Application *a = calloc(1, sizeof(*a));
  if (!a) return app_fail("application descriptor allocation failed");
  a->id = id; a->handler = LUA_NOREF; a->source = source; a->source_n = n;
  if (wa_attach(id, a)) { free(a); return app_fail("invalid application load state"); }
  a->root = lua_newstate(wa_alloc, (void *)(uintptr_t)id, seed);
  if (!a->root) return app_fail("application allocation limit exceeded");
  lua_State *L = a->root;
  *(uint32_t *)lua_getextraspace(L) = id;
  lua_sethook(L, init_budget, LUA_MASKCOUNT, 1000);
  lua_pushcfunction(L, init_traceback);
  lua_pushcfunction(L, load_application); lua_pushlightuserdata(L, a);
  int status = lua_pcall(L, 1, 0, 1);
  lua_sethook(L, NULL, 0, 0);
  a->source = NULL; a->source_n = 0;
  if (status != LUA_OK) {
    const char *message = lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1) : "application initialization failed";
    app_fail(message); lua_settop(L, 0); return -1;
  }
  lua_settop(L, 0);
  if (wa_ready(id)) return app_fail("application state transition failed");
  ++loads;
  return 0;
}
static int prepare_warm_request(lua_State *L) {
  WarmRequest *r = lua_touserdata(L, 1);
  Application *a = wa_ptr(r->app_id);
  if (!a) return luaL_error(L, "application was released");
  Vm *vm = &r->vm;
  lua_rawgeti(L, LUA_REGISTRYINDEX, a->coroutines);
  vm->co = lua_newthread(L);
  lua_rawseti(L, -2, r->slot); /* Preallocated array: anchor before any further allocation. */
  lua_pop(L, 1);
  if (!lua_checkstack(vm->co, 32)) return luaL_error(L, "coroutine stack allocation failed");
  *(uint32_t *)lua_getextraspace(vm->co) = vm->id;
  lua_sethook(vm->co, budget, LUA_MASKCOUNT, 1000);
  lua_rawgeti(L, LUA_REGISTRYINDEX, a->handler);
  request_values(L, vm);
  lua_xmove(L, vm->co, 4); /* Loaded handler plus three fresh invocation records. */
  return 0;
}
int wa_start(uint32_t id, uint32_t app_id, const char *method, size_t method_n,
             const char *url, size_t url_n, const char *body, size_t body_n) {
  if (lw_state(id) != 1) return -1;
  if (!method_n || method_n > 16 || url_n > 4096 || body_n > 65536)
    return fail(id, "request limit exceeded");
  Application *a = wa_ptr(app_id);
  if (!a || wa_pin(app_id)) return fail(id, "application not ready or at capacity");
  WarmRequest *r = NULL;
  for (int i = 0; i < 8; ++i) if (!requests[i].occupied) { r = &requests[i]; break; }
  if (!r) { wa_unpin(app_id); return fail(id, "request descriptor capacity"); }
  memset(r, 0, sizeof(*r));
  r->occupied = 1; r->app_id = app_id; r->slot = (int)(r - requests) + 1;
  Vm *vm = &r->vm;
  vm->id = id; vm->root = a->root;
  vm->method = method; vm->method_n = method_n;
  vm->url = url; vm->url_n = url_n; vm->body = body; vm->body_n = body_n;
  if (lw_attach(id, vm)) { r->occupied = 0; wa_unpin(app_id); return -1; }
  lua_State *L = a->root;
  lua_settop(L, 0);
  lua_pushcfunction(L, prepare_warm_request); lua_pushlightuserdata(L, r);
  if (lua_pcall(L, 1, 0, 0)) {
    const char *message = lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1) : "request preparation failed";
    fail(id, message); lua_settop(L, 0); return 5;
  }
  vm->method = vm->url = vm->body = NULL;
  return step(vm, 3);
}
void bridge_close(void *p) {
  for (int i = 0; i < 8; ++i) {
    WarmRequest *r = &requests[i];
    if (!r->occupied || p != &r->vm) continue;
    if (r->vm.co) {
      /* No guest-created finalizers/metatables in this library profile. */
      lua_closethread(r->vm.co, r->vm.root);
      lua_settop(r->vm.co, 0);
      lua_sethook(r->vm.co, NULL, 0, 0);
      *(uint32_t *)lua_getextraspace(r->vm.co) = 0;
    }
    Application *a = wa_ptr(r->app_id);
    lua_rawgeti(r->vm.root, LUA_REGISTRYINDEX, a->coroutines);
    lua_pushnil(r->vm.root); lua_rawseti(r->vm.root, -2, r->slot); lua_pop(r->vm.root, 1);
    lua_settop(r->vm.root, 0);
    uint32_t app_id = r->app_id;
    memset(r, 0, sizeof(*r));
    wa_unpin(app_id);
    return;
  }
  legacy_bridge_close(p);
}
void warm_destroy(void *p) {
  Application *a = p;
  if (a->root) lua_close(a->root);
  free(a);
}
int wa_collect(uint32_t id) {
  Application *a = wa_ptr(id);
  if (!a || wa_pending()) return -1;
  lua_gc(a->root, LUA_GCCOLLECT); /* Explicit diagnostic only; never in warm dispatch. */
  return 0;
}
uint32_t wa_load_count(void) { return loads; }
