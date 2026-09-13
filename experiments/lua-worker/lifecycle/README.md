# Worker lifecycle shootout

This experiment is separate from the parent runtime's fresh-state default. Its frozen control is commit `b73f74cae2a228768d482b2c0640e9decc619e8b`. The first experiment proved per-invocation safety and portability, but rebuilt the Lua state, libraries and application on each request. A normal warm JavaScript Worker does not rebuild its loaded application on every request. This shootout tests that architectural difference directly.

## Application lifetime versus invocation lifetime

| Lifetime | Resident Lua owns | Host owns |
|---|---|---|
| Worker application | One stock Lua VM, loaded text application, handler reference, globals and aggregate allocation budget | One Wasm instance and immutable code version, explicit bindings, admission and external isolation |
| Request | Fresh Lua coroutine, request values, capability userdata, instruction budget, operation IDs and response buffer | Request-specific binding references, I/O, deadline and cancellation |
| Eviction | Close the Lua state, release all app allocations | Refuse eviction until requests and outstanding I/O settle; retire the outer Worker/Wasm instance separately |

Application code is loaded once. The compiled Wasm module is passed through workerd's Worker Loader so immutable code can be shared, while each child gets a separate Wasm instance and linear memory. No Lua application AOT compiler, arbitrary guest bytecode, suspended native stack, generic JavaScript bridge or V8 fork is involved.

The existing Nelua request kernel remains in use. An additional Nelua application budget tracks residency, app identities and active request pins. A small C continuation adapter creates and anchors a new coroutine for each request, reuses the loaded handler, and removes that coroutine's roots on success, failure or cancellation. Caller-owned buffers and Wasm views never survive an await. Capability userdata still carries its original invocation ID, so an application that saves CONFIG or a log closure cannot exercise it from a later invocation.

## Deliberate contract changes

**Resident globals may persist.** The fresh control intentionally returns a new global environment on each request. The resident mode permits application-local caches and mutable globals until eviction, like a warm application. This is not durable persistence or a guarantee that a later request will reach the same Worker. Source/configuration versions must use distinct worker identities; a resident instance refuses a source change without explicit eviction.

**Memory accounting moves to the application.** Resident Lua uses a strict **2 MiB aggregate Lua heap limit**, covering loaded code, globals and all concurrent requests. The fresh control has 2 MiB per invocation. These scopes are not identical. A script may retain ordinary request data in globals within the app budget; removing coroutine roots cannot erase deliberate application references. Ordinary errors do not roll back mutations to application globals. An app exhausted by reachable allocations must be evicted or fixed.

Request instruction, operation, body, source and concurrency limits remain. Initialization is independently instruction-budgeted and has no external capabilities. The restricted library profile, text-only loading and useful tracebacks are retained. The host-only collection operation is a diagnostic used by correctness tests, not part of timed warm dispatch. Application Lua bytes remain nonzero while resident; zero live request counters are not reported as zero application memory.

One Wasm instance is a useful memory-ownership boundary, not a complete hostile-tenant sandbox. V8 and workerd remain present. Lua hooks do not meter arbitrary C/native execution or parsing. The outer host still requires independently enforced memory/CPU/time limits and termination. The parent runtime's process-memory growth issue is not assumed fixed by Lua residency.

## Contenders

- `javascript`: loaded JavaScript application in a dynamic workerd child. Functional lifecycle reference; it does not implement the Lua instruction hooks or embedded heap quota.
- `fresh`: frozen parent Lua implementation, O2, creating a Lua VM per invocation.
- `resident`: load-once application, O2, invocation-owned coroutines.
- `resident-o3`: identical resident lifecycle, O3 plus LTO.

All four use the **same actual stock-workerd Worker Loader** path. The parent blocks ambient outbound network access and passes only CONFIG and UPSTREAM fixture bindings to the child. Fixtures have no artificial delay. In-memory CONFIG remains a read-only fixture, not durable storage.

## What is measured

Eight fresh-process rounds rotate and reverse contender order. Server and external load-driver CPU affinity are recorded. The external Node clock measures all timings; frozen in-request clocks are not used.

1. **Warm dispatch:** checked full-handler batches for hello, an integer loop, a 64 KiB echo, one CONFIG operation, a real CONFIG-plus-UPSTREAM chain and sixteen operations. Separate closed-loop HTTP tests use concurrency one and eight.
2. **New dynamic workers:** distinct loader IDs, each receiving two checked requests. The first proves a fresh application; the second checks its intended lifetime semantics. The measured quantity is explicitly worker creation plus two requests, not isolated V8 isolate construction or hosted cold start. Immutable code and OS caches may already be warm.
3. **Whole-process startup:** process launch through first HTTP response, including startup and polling overhead, reported separately.
4. **Resident memory:** 50,000 checked handler invocations without forced collection, followed by explicit application eviction and a zero-allocation assertion. RSS includes V8, parent, fixtures, loaded children and retained host garbage.

Independent parent HTTP requests also check a resident counter sequence before timing: `1,2,3` for JavaScript/resident Lua, and `1,1,1` for fresh Lua. A per-instance load counter alone would not prove that the loader reused its isolate. This is an observation required for this cached-mode benchmark, not a claim that the platform always guarantees residency.

No prewarmed-state snapshots, coroutine pooling, native HTTP adapter, shared-tenant Lua VM or automatic eviction policy is included. Such candidates require separate gates rather than being silently mixed into this comparison.

## Correctness gates

Before measurement, build every Lua variant and run native ASan/UBSan. The fresh control also runs the original 17 Node tests plus four performance regressions. Portable lifecycle suites run against the actual Wasm in Node and inside stock workerd: 18 common groups and three additional resident groups. They cover async calls, reversed completion, cancellation, stale callbacks and handles, admission/orphan accounting, budgets, OOM recovery, tracebacks, response cardinality, binary bodies, source-version pinning and app eviction. Separate actual HTTP service-binding tests verify overlap, TCP reset and quiet-close deadline cleanup.

Generated source and Wasm SHA256 identities, exact toolchain versions, all test reports, raw timings, RSS samples and cache observations are retained. A green correctness run is not automatically a performance win. The benchmark has one machine per run and closed-loop HTTP load; do not infer cross-hardware or open-loop capacity guarantees.

## Reproduce

From a full clone of branch `lua-worker-lifecycle`:

```sh
cd experiments/lua-worker
npm run bootstrap
python3 lifecycle/prepare.py
node lifecycle/run.mjs
```

Requires the frozen control commit in Git history, Linux, native C compiler, Python 3, and the pinned Node/Emscripten toolchains. No Docker or QEMU is used. The ordinary parent `npm run build` remains the fresh-state implementation; lifecycle variants are under `dist/lifecycle/`. The workflow runs the experimental self-hosted Worker Loader, not an authorized Cloudflare deployment.

## Primary references

- https://developers.cloudflare.com/workers/reference/how-workers-works/
- https://developers.cloudflare.com/dynamic-workers/api-reference/
- https://www.lua.org/manual/5.5/manual.html#lua_newthread
- https://www.lua.org/manual/5.5/manual.html#lua_closethread
- https://github.com/cloudflare/workerd/blob/main/src/workerd/api/tests/worker-loader-wasm-test.js

Workers may reuse a loaded isolate across requests but do not guarantee that identity indefinitely. Lua coroutines share an application's globals while retaining independent stacks. The actual pinned-toolchain tests, rather than these general API descriptions, establish which paths this experiment exercised.
