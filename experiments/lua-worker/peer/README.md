# Native peer and source/runtime parity

This is a working experiment branch, not a broad Workers implementation. Actual validation and timing live in the `Lua native peer shootout` workflow artifacts. A written test or candidate is not a passing result. Existing fresh and resident Wasm backends are unchanged.

## Implemented architecture

```
                              same application.lua
                                      |
                   explicit-context Nelua kernel + C adapter
                     /                              \
         stock native Lua 5.5 / LuaJIT        stock Lua 5.5 in Wasm
                    |                               |
           KJ HttpService host              explicit JavaScript adapter
                    |                               |
          direct HTTP or Unix socket              stock workerd
                    |
          optional stock-workerd external service
```

The native KJ host links no V8 or Wasm engine. The proxy topology still includes stock workerd/V8 and a local HTTP/Unix-socket hop. **A same-process native engine inside workerd has not been implemented here.** Native KJ currently comes from the Ubuntu development package, whose exact version is retained; workerd has its own bundled KJ. Do not call them identical server builds.

`kernel.nelua` owns all mutable state through an explicit pointer. Every app has its own allocation budget and eight request slots. This replaces the former implicit per-Wasm-instance global storage, rather than linking that storage once into a native process. Multiple app contexts are tested in one native process and in one Wasm instance.

`runtime.c` is shared by native Lua 5.5, LuaJIT and Wasm. It uses the public Lua C APIs. `bootstrap.lua` captures the trusted coroutine yield function: a binding validates and records an operation, its C frame returns normally, and only then a Lua frame yields. Host completion supplies results to exactly the owned coroutine. No C/C++ stack survives the asynchronous gap; no process-global current request exists.

The public API is in `api.h`. Calls into each app must be serialized. Request IDs are meaningful only together with their application pointer and operation sequence. Host pointers are trusted call-scoped references, not an untrusted wire protocol. Deleted application pointers must never be reused. Native and Wasm hosts copy response bytes before releasing request state.

## Scope and limits

The application contract has request method, URL, binary body; status and binary response body; read-only `CONFIG:get`; one configured `UPSTREAM:fetch`; and logging. CONFIG 200 is bytes and 404 is absent, distinct from empty. It is a fixture service in tests, not durable KV or a transaction system.

Each app's Lua heap is limited to 2 MiB, including globals/code/all active requests. Kernel slot buffers and host allocations are additional memory. The kernel has eight slots, 64 KiB source/body/result bounds, sixteen operations and one upstream fetch per invocation. Initialization and invocation loops are instruction-budgeted in metered profiles. Lua hooks do not account for arbitrary native C work or parsing. Resident globals persist and are not rolled back on request error.

The native host has a 2.5-second asynchronous deadline, fixed-address backend clients, loopback/Unix listeners, descriptor/CPU/address-space limits, and host-owned cancellation. The test runner supplies an independent hard process deadline. None constitutes complete hostile-tenant hardening. A production deployment still needs least-privilege process/container isolation, network/filesystem policy, independent supervision, and per-tenant resource enforcement. `/_peer/stats` is a local diagnostic endpoint, not an authenticated public management API.

Bytecode and ambient filesystem/debug/package/FFI authority are not exposed. The initial library profile intentionally omits pcall/xpcall and metatable mutation. Those restrictions are compatibility differences, not full Lua standard-library support. Bodies are buffered; streaming, arbitrary HTTP headers, WebSockets, scheduled events and Durable Objects are not implemented.

## LuaJIT lanes

- **Metered:** LuaJIT interpreter with JIT disabled, the same request/initialization hook budgets and operation contract. Language compatibility is not Lua 5.5.
- **Trusted JIT:** trace compilation enabled, instruction hooks omitted. A trace-event counter must show actual compiled traces and input-dependent outputs must match. This is a trusted-code performance lane under external process termination, not a security-equivalent winner. JIT code/cache memory is not fully represented by the Lua allocation counter.

LuaJIT's compiled code can ignore debug hooks. A dedicated child deliberately enters a runaway JIT loop; the parent must observe readiness and kill it with SIGKILL. This proves an external termination route, not request-local preemption or production recovery. The LuaJIT C adapter is sanitizer-instrumented, but its hand-written assembly/static VM build is not fully ASan-instrumented. Stock Lua 5.5 VM sources are compiled with sanitizers in the native correctness binary.

## Source parity

`make-cases.py` generates 35 deterministic source cases. Exactly those source bytes, request values, expected response bytes, normalized error categories and host-operation transcripts are consumed by native and Wasm drivers. Thirty-one are common to both engines; four explicitly exercise Lua 5.5 syntax/library features and currently differ on LuaJIT. This is corpus coverage, not a percentage of the Lua language implemented.

The stock-workerd test module repeats the same corpus and ownership/async tests inside actual workerd. Native C tests exercise simultaneous contexts, reversed completion, stale identifiers, budgets and cleanup. Real HTTP tests cover persistent state, input-dependent computation, 64 KiB binary bodies, configured I/O, exact operation counts, errors after I/O, TCP reset, quiet-close deadlines and cleanup. Backend exceptions are redacted before entering Lua.

## Performance methodology

Six contenders use the same fixture endpoints and equivalent HTTP workloads. Six fresh-process rounds rotate contender order; arithmetic input sequences restart for each contender. Raw latency samples, throughput, process-to-first-response and process RSS are retained. Proxy memory is the sum of both processes. A separate finite soak sends 5,000 real HTTP requests per contender, not the earlier 50,000 batched invocations.

These are closed-loop HTTP measurements and may be load-generator limited. Native/KJ and workerd have different object, transport and isolation costs. The same-core Wasm control is new and is not the prior fastest lazy adapter. No engine-parity claim follows from similar HTTP throughput. There is no unique-source worker-loader startup comparison in this slice, and no forced collection in timing/soak paths.

## Reproduce

Prerequisites: supported Linux/Ubuntu environment, Git, make, GCC/G++, Python 3, pkg-config and `libcapnp-dev`; Node 22.16.0. Initial toolchain downloads require network access. Alpine/musl and other host platforms have not been qualified.

```sh
cd experiments/lua-worker
bash peer/check.sh
```

The script bootstraps pinned Lua/Nelua/Emscripten/workerd tools, builds native and Wasm cores, runs correctness gates, and records the shootout. For an already built native host:

```sh
dist/peer/host-lua55 peer/worker.lua 127.0.0.1:8789 127.0.0.1:9001 127.0.0.1:9002
# CONFIG and UPSTREAM must actually be served at those explicitly configured addresses.
```

The native host is an experiment, not a production service manager. LuaJIT JIT mode is opt-in via the final `trusted-jit` argument. Other runtime candidates are screened in `ENGINES.md`.
