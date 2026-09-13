"""Exact-match architecture experiments; never edit the frozen control in place."""

def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f'candidate source drift: {old[:100]!r}')
    return text.replace(old, new, 1)


def completion(source):
    # Routine completion is not an error: preserve the public reason fields but
    # avoid capturing an otherwise unused request stack on every successful call.
    source = once(source, 'const aborted = signal =>',
        "const FINISHED = Object.freeze(new WorkerError('invocation finished', 'CANCELLED'));\nconst aborted = signal =>")
    return once(source, "controller.abort(new WorkerError('invocation finished', 'CANCELLED'));", 'controller.abort(FINISHED);')


def lazy(source):
    source = completion(source)
    source = once(source, '''    const controller = new AbortController();
    const cancel = () => controller.abort(signal?.reason ?? new WorkerError('invocation cancelled', 'CANCELLED'));
    signal?.addEventListener('abort', cancel, { once: true });
    if (signal?.aborted) cancel();
    const timer = setTimeout(() => controller.abort(new WorkerError('invocation deadline exceeded', 'TIMEOUT')), timeoutMs);
    const local = controller.signal;''', '''    // Allocate asynchronous cancellation machinery only when I/O is possible.
    // The deadline originates at admission, not at the first I/O operation.
    // Like the old timer, it cannot preempt synchronous Wasm; the VM hook and
    // external CPU/wall-time enforcement remain responsible for that work.
    const deadline = Date.now() + timeoutMs;
    let controller, timer, cancel, local = signal;
    const enableIO = () => {
      if (controller) return;
      controller = new AbortController();
      cancel = () => controller.abort(signal?.reason ?? new WorkerError('invocation cancelled', 'CANCELLED'));
      signal?.addEventListener('abort', cancel, { once: true });
      if (signal?.aborted) cancel();
      local = controller.signal;
      timer = setTimeout(() => controller.abort(new WorkerError('invocation deadline exceeded', 'TIMEOUT')),
        Math.max(0, deadline - Date.now()));
    };''')
    source = once(source, '      check(local);\n      const app = this.loadApplication(source);',
        '      if (local) check(local);\n      const app = this.loadApplication(source);')
    source = once(source, '''      const body = await readBounded(request.body, local);
      check(local);''', '''      let body;
      if (request.body) {
        enableIO();
        body = await readBounded(request.body, local);
      } else body = new Uint8Array();
      if (local) check(local);''')
    source = once(source, '      while (state === 3) {', '      while (state === 3) {\n        enableIO();')
    source = once(source, '''      clearTimeout(timer);
      signal?.removeEventListener('abort', cancel);
      controller.abort(FINISHED);''', '''      if (controller) {
        clearTimeout(timer);
        signal?.removeEventListener('abort', cancel);
        controller.abort(FINISHED);
      }''')
    return source


def pool(source):
    source = once(source, '  int handler, coroutines;', '  int handler, coroutines;\n  uint32_t cached_coroutines;')
    source = once(source, '''  vm->co = lua_newthread(L);
  lua_rawseti(L, -2, r->slot); /* Preallocated array: anchor before any further allocation. */
  lua_pop(L, 1);''', '''  lua_rawgeti(L, -1, r->slot);
  if (lua_isthread(L, -1)) {
    vm->co = lua_tothread(L, -1);
  } else {
    lua_pop(L, 1);
    vm->co = lua_newthread(L);
    lua_pushvalue(L, -1);
    lua_rawseti(L, -3, r->slot); /* Anchor before further allocation. */
    ++a->cached_coroutines;
  }
  lua_pop(L, 2);''')
    source = once(source, '''    Application *a = wa_ptr(r->app_id);
    lua_rawgeti(r->vm.root, LUA_REGISTRYINDEX, a->coroutines);
    lua_pushnil(r->vm.root); lua_rawseti(r->vm.root, -2, r->slot); lua_pop(r->vm.root, 1);''', '''    /* The closed, empty coroutine stays rooted in its app-owned slot. No
     * request values, hook, or invocation identity remain in this frame. */''')
    return source + '''
uint32_t wa_cached_coroutines(uint32_t id) {
  Application *a = wa_ptr(id);
  return a ? a->cached_coroutines : 0;
}
'''


def slab(source):
    begin = source.index('  withBytes(values, fn) {')
    end = source.index('  async operation(', begin)
    return source[:begin] + '''  withBytes(values, fn) {
    // Call-scoped storage: no pointer or live view survives an await.
    const size = values.reduce((total, value) => total + value.length, 0);
    const base = this.e.malloc(Math.max(size, 1));
    if (!base) throw new WorkerError('Wasm allocation limit', 'MEMORY_LIMIT');
    try {
      const heap = new Uint8Array(this.e.memory.buffer), args = [];
      let offset = 0;
      for (const value of values) {
        heap.set(value, base + offset);
        args.push(base + offset, value.length);
        offset += value.length;
      }
      return fn(...args);
    } finally { this.e.free(base); }
  }
''' + source[end:]
