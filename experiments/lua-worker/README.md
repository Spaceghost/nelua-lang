# Lua / Nelua workers in stock workerd

A narrow runtime experiment, not a Workers compatibility layer. The original discussion produced no code; this directory is its first implementation. It is temporarily isolated in a branch of the user's Nelua fork; the upstream compiler is not modified. Bak Flow is unrelated.

```
application.lua
  -> stock Lua 5.5.1 VM + Nelua-generated ownership / operation kernel
     -> Wasm + explicit JS adapter -> unmodified workerd (V8 still present)
     -> native C build -> contract test executable
```

**Validation is recorded by the `Lua workerd prototype` workflow and its retained artifacts, not by this README's existence.** Do not equate a written test with a passing test. A native HTTP server and an authorized Cloudflare deployment have not been implemented or verified. There is no performance advantage claim.

## Run locally

Prerequisites: Linux, Git, curl, tar, make, a native C compiler, Python 3, and Node 22.16.0. Tool downloads require network access. No Docker, QEMU, workerd fork, Wasmoon dependency, Asyncify, or custom Lua VM patch is used.

```sh
git clone --branch lua-workerd-prototype https://github.com/Spaceghost/nelua-lang.git
cd nelua-lang/experiments/lua-worker
npm run bootstrap
npm run build
./dist/native-contract
npm test
npm start
# In another terminal:
curl http://127.0.0.1:8787/world
```

`npm run start:bounded` instead runs workerd under an external 60-second process-lifetime limit. This intentionally stops the entire demonstration service; it is not a production supervisor or per-request deadline.

Pinned source identities and versions live in `toolchain.json`. The Nelua compiler uses its own bundled interpreter, separately from the guest Lua 5.5.1 VM. The build generates C separately for wasm32 and native pointer/size_t layouts. Emscripten's native Wasm exception support implements Lua's setjmp/longjmp; it does not suspend a C stack across JavaScript await. CI retains compiler versions, source SHAs, generated C, Wasm imports/exports, hashes, test logs, the npm lockfile, and a source archive.

## Application contract

```lua
local http = require 'worker.http'
return {
  fetch = function(request, env, ctx)
    local greeting = env.CONFIG:get('greeting') or 'Hello'
    local upstream = env.UPSTREAM:fetch('/echo/world')
    ctx.log('request complete')
    return http.text(greeting .. ' ' .. upstream.body)
  end
}
```

`request` has `method`, `url`, and a buffered byte-string `body`. A response is `{status = 200, body = 'bytes'}`; `http.text` is a checked constructor. The host currently sets a fixed text content type. There is no general headers API, streaming, WebSocket, `waitUntil`, dynamic module loading, or ambient `fetch`.

`CONFIG` and `UPSTREAM` are sealed Lua userdata carrying invocation-specific capability identities, not arbitrary JavaScript objects. The host retains actual service bindings and credentials. `UPSTREAM:fetch` admits only same-origin paths within that configured capability, makes one GET, and returns `{status, body}`. Redirects are not automatically followed. There is no arbitrary public-network escape path in this adapter.

### Storage semantics actually provided

The host's read-only CONFIG protocol is `GET /<encoded-key>`: status 200 supplies bytes, 404 means absent and becomes Lua nil; other statuses are errors. Empty bytes and absence are distinct. `examples/config.mjs` is an explicitly configured **read-only in-memory fixture**, not durable application storage, Workers KV, a consistency emulator, or a transactional database. Replacing that fixture requires documenting and testing the chosen backend's real semantics. No write or persistence operation is promised by this slice.

## Ownership and asynchronous execution

Eight slots share one Wasm instance. Each invocation owns a separate Lua state, coroutine, request values, capability userdata, accounting allocator, operation sequence and buffer. No mutable current-request/current-env variable exists. Application source is loaded and executed afresh for each invocation; mutable Lua globals are not cached across requests.

A C binding copies a bounded operation record into the Nelua kernel and calls `lua_yieldk`. `lua_resume` returns to the host. Only then does JavaScript await I/O. Completion validates both the live invocation ID and operation sequence before resuming the matching coroutine's continuation. No arbitrary Nelua/C frame survives the await. IDs never wrap into reusable identities: exhaustion refuses new invocations.

Pointers passed over the C ABI are borrowed for that synchronous call only. No live Wasm memory view crosses await. Lua owns the copies of request/source data needed after initialization. Hosts must serialize entry to an instance; the native kernel is not thread-safe.

Cancellation/deadline/failure closes the invocation's entire Lua state. Late completions cannot enter a freed or replacement invocation. A backend operation that ignores cancellation remains counted against the host's outstanding-operation cap until it actually settles; cancelling eight stuck operations does not admit an unbounded ninth. This is resource accounting, not a promise that every backend can physically stop work.

## Limits and trust

| Resource | Initial cap |
|---|---:|
| Concurrent admitted invocations | 8 |
| Outstanding host operations, including uncancelled orphans | 8 |
| Lua allocations per invocation | 2 MiB |
| Wasm linear memory | 32 MiB maximum, 4 MiB initial |
| Wasm C stack | 1 MiB |
| Source, request body, response body, host result | 64 KiB each |
| CONFIG key / upstream path / log message | 256 / 4096 / 2048 bytes |
| Host operations / outbound fetches per invocation | 16 / 1 |
| Lua VM instruction count | Approximately one million |
| Asynchronous deadline | 2500 ms by default |

These are deliberately small constants, not production defaults. Host/V8 memory, compiled Wasm code, descriptor allocations and OS overhead are not included in the Lua allocation counter or linear-memory size. Freed Lua allocations do not imply the Wasm heap or process RSS shrinks.

The initial library profile opens base, string, table, math and utf8, then removes dynamic/file loaders, pcall/xpcall, collectgarbage, metatable mutation/inspection, print/warn and string.dump. `require` resolves only `worker.http`. No io, os, debug, package or child-coroutine library is exposed. Guest chunks are text-only. The lack of pcall/xpcall is an explicit compatibility restriction so instruction-budget errors cannot be swallowed; a future recoverable-error API needs a non-bypassable budget design first.

**This is not a hardened hostile-tenant runtime.** Lua hooks do not meter parser or arbitrary native/C work. An in-process JavaScript timeout cannot preempt a blocked synchronous Wasm call. The external supervisor demonstrates termination from another process; hostile code additionally requires separately enforced CPU/wall-time/memory limits, process/container/VM isolation as appropriate, restricted filesystem/network authority, and an independently supervised host. Lua coroutines or separate Lua states inside shared Wasm memory are not tenant-security boundaries. Stock self-hosted workerd alone is not claimed to supply that entire boundary.

A Wasm trap retires the runtime rather than reusing possibly invalid state. The containing host/isolate must then be recycled; ordinary Lua errors and cancellations have the normal accounting-checked cleanup path. There is no stack persistence or suspended-frame serialization. Persist application records through a real configured backend when that backend is introduced.

Useful application tracebacks are propagated to the host. The HTTP adapter logs them and returns a generic failure body. Raw backend exceptions are deliberately not injected into Lua, because they may contain credentials.

## Evidence and measurements

`tests/native.c` exercises the native kernel with ASan/UBSan. `tests/runtime.test.mjs` exercises the actual Wasm build in Node, including out-of-order bindings, stale handles, cancellation, late callbacks, budgets, denied authority, limits and cleanup. `tests/workerd.test.mjs` starts the actual pinned workerd executable and sends HTTP requests through the configured services. Node tests are not by themselves proof of workerd or hosted Cloudflare behavior.

The benchmark script writes raw samples and explicitly separates module instantiation, end-to-end local HTTP, JS/Wasm call cost and process RSS. These quantities are not interchangeable, and none establishes an advantage over JavaScript or another runtime. Hosted cold starts remain unmeasured.

## Upstream review

- [Lua 5.5 C API and continuation rules](https://www.lua.org/manual/5.5/manual.html#4.5): use lua_yieldk/lua_resume and explicit continuation state; Lua 5.5 lua_newstate also takes a seed.
- [Official Lua downloads and checksums](https://www.lua.org/ftp/).
- [Nelua C interoperability](https://nelua.io/overview/#c-interoperability) and pinned [compiler source](https://github.com/edubart/nelua-lang/tree/a58450563e2d2ec49bff499865c8b5cfdf6ff81a): Nelua compiles the typed kernel, not arbitrary dynamic Lua.
- [Workers WebAssembly API](https://developers.cloudflare.com/workers/runtime-apis/webassembly/): import a precompiled Wasm module and instantiate it with explicit imports.
- [Emscripten setjmp/longjmp](https://emscripten.org/docs/porting/setjmp-longjmp.html): Wasm exception-based longjmp support, separate from Asyncify.
- [workerd JSG](https://github.com/cloudflare/workerd/blob/main/src/workerd/jsg/jsg.h) and [promise implementation](https://github.com/cloudflare/workerd/blob/main/src/workerd/jsg/promise.h): V8 values, isolates, promises and GC relationships remain integral to workerd. This experiment does not replace them.
- [Wasmoon thread implementation](https://github.com/ceifa/wasmoon/blob/main/src/thread.ts): inspected as an implementation reference for resume/yield/await loops and error reporting, not selected as a dependency or accepted as evidence of this prototype's Lua 5.5/Workers support.

Python Workers remain an architectural analogy only. Native hosting, an external-server workerd binding, broader API compatibility, streaming with actual backpressure, and hostile multitenancy are separate follow-on work, not implied by this prototype.
