# Dispatch architecture chase

Frozen control: PR #16 at `abf9213181e95feaede032532b268203f4751feb`. This experiment does not replace the fresh-state default or the earlier resident implementation. Written candidates are not performance results. Successful workflows retain exact source/binary hashes and measurements.

## Hypotheses

A local Node CPU diagnostic found `WorkerError` construction in routine successful cleanup consuming samples. The Lua handler itself was only part of full adapter time. These observations are not workerd speed results. Three cumulative ablations are measured against the unchanged resident control:

1. `completion`: one immutable host-owned completion reason rather than a newly captured error stack per successful request. Code and message are preserved. Real failures still have useful tracebacks. Reason identity and its stack are not a per-request identity contract.
2. `lazy`: completion plus asynchronous signal/timer allocation only when a request body or host operation requires it. Synchronous bodyless handlers do not enqueue an unnecessary initial microtask. Deadline origin is admission, and existing Lua hooks remain enabled. In-process timers did not and still do not preempt synchronous Wasm. The host clock's workerd-specific precision/advancement limitations remain.
3. `pooled`: lazy plus up to eight app-owned empty coroutines. Every coroutine is closed, stack-cleared, unhooked and stripped of its owner before reuse. New request values, immutable capability owner IDs and operation sequences are still created for each invocation. Pool capacity is counted in the aggregate app heap and exposed in statistics; app eviction frees it.

Every Lua contender retains native ASan/UBSan and all 21 frozen lifecycle contract groups, plus six additional groups, in both Node and actual stock workerd. The actual service-binding and TCP reset/quiet-close cleanup tests remain. Baseline generated source hashes are checked against the prior artifact. No disabled validation, instruction hooks, quotas or authority checks are allowed in a measured winner.

## Measurement

The frozen Worker Loader harness is reused with ten balanced-order fresh-process rounds for JavaScript, resident control and three candidates. Existing six workloads and separate HTTP checks are retained. Complete lifetimes now measure 1, 2, 8, 32 and 128 checked requests per unique worker ID directly. All use the same source per variant, so this is not a unique-source compilation benchmark. The separate inspector-free soak runs 50,000 checked invocations and records process RSS, app allocations and request ownership. No forced GC is used to improve headline results.

V8's reusable initialized contexts and shared compiled code motivate amortizing setup; they do not grant Lua snapshots or JIT compilation automatically. The stock Lua VM remains an interpreter inside V8-hosted Wasm. Do not describe a warmed HTTP result as engine parity, and do not infer a lifetime break-even point by mixing timings from different paths.

Relevant upstream references:
- https://developers.cloudflare.com/workers/reference/how-workers-works/
- https://developers.cloudflare.com/dynamic-workers/api-reference/
- https://developers.cloudflare.com/workers/runtime-apis/performance/
- https://www.lua.org/manual/5.5/manual.html (lua_closethread, coroutine ownership and collection)
- https://v8.dev/blog/custom-startup-snapshots (architectural precedent, not this implementation)

```sh
npm run bootstrap
python3 chase/prepare.py
node chase/run.mjs
```

Output: `reports/chase/RESULTS.md`, `raw.json`, `summary.json`, plus `dist/chase/manifest.json` and per-contender tests. The required next decision is based on the measured Pareto tradeoff among startup, warm dispatch, tail latency, memory and code size, not the best isolated sample. Universal superiority is not established by any finite workload set.
