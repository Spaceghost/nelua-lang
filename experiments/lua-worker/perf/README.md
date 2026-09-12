# Performance shootout

Baseline is pinned to `4404fcbb48d2692274df8864616c399986c1fb8a`, not whatever the working branch happens to contain. All contenders are rebuilt with the existing pinned Lua/Nelua/Emscripten/workerd toolchain. Candidate source is derived with exact-match transformations; drift fails rather than silently applying a different experiment. No production defaults change just because a candidate exists.

## Contenders

| Name | Change from the frozen baseline | Hypothesis |
|---|---|---|
| javascript | Functionally equivalent handlers, no Lua VM | Establish a native-to-workerd JavaScript floor; not equivalent isolation |
| baseline | Original `-O2` build and source | Control |
| o3-lto | `-O3 -flto` | Cross-translation-unit optimization may improve interpreter/bridge code |
| oz-lto | `-Oz -flto` | Smaller Wasm may trade throughput for size/startup |
| entry-o3 | O3/LTO plus C continuation-based trusted dispatch | Stop parsing the fixed wrapper on every invocation, without caching guest state |
| combined-o3 | Compiled dispatch plus indexed IDs, metadata-only slot reset and one input slab | Remove table scans, unnecessary buffer clearing and repeated Wasm allocation crossings |

The compiled entry preserves all handler return values so zero/multiple-response errors remain errors. Every request still has a fresh Lua state, freshly loaded text source, its own coroutine and capability records. No guest bytecode cache, shared mutable Lua globals, reduced instruction hooks, fast-math, disabled validation, reduced security limits, or retained arbitrary C stack is permitted.

The combined buffer experiment does not securely erase freed capacity. Only initialized, length-bounded operation/response bytes are visible through the guest interface. The host was already trusted and can access all Wasm memory; shared linear memory remains unsuitable as a tenant-security boundary. Its monotonically generated, index-bearing IDs validate the full identity before every lookup and refuse exhaustion instead of wrapping.

## Gates and measurements

`python3 perf/prepare.py` first checks every Lua contender with native ASan/UBSan, the original 17 Node/Wasm contracts, four additional regressions, and all existing actual-workerd contracts including real TCP reset and quiet-close deadline cleanup. A failure stops the shootout. It retains exact per-contender source and Wasm hashes.

`node perf/run.mjs` uses a separate stock-workerd process per contender per round. Worker and load-driver CPUs are pinned separately where at least two CPUs are available. Seven rounds rotate contender order; each process receives identical warmup. Output bytes, operation counts and zero quiescent ownership/allocation counters are assertions, not optional benchmark metadata.

Six batched workloads cover hello, integer arithmetic, a 64 KiB body, one resolved storage operation, a real CONFIG-plus-UPSTREAM chain, and sixteen resolved storage operations. Timing is external to workerd, so frozen in-request clocks cannot invent results. The service fixture has no artificial delay. Actual HTTP measurements additionally cover concurrency 1, 4 and 8 with every response checked. HTTP load is closed-loop, not a coordinated-omission-corrected capacity test.

Raw per-request HTTP samples, per-round amortized handler costs, cold process-to-first-response samples, paired bootstrap intervals, compiler flags, hashes, CPU and runner identities are retained. The bootstrap intervals describe run-to-run variability on this machine, not a universal performance guarantee or multiple-comparison correction. A separate 50,000-invocation soak records RSS and live Lua/Wasm accounting without forcing GC or declaring a plateau automatically.

## Selection policy

Correctness is mandatory. Prioritize reproducible gains in the six batched full-handler workloads, with HTTP throughput as a separate practical check. Do not select by the single best sample. Examine per-workload regressions and intervals, code-size/startup costs, and another run before adopting a candidate. Keep rejected and inconclusive experiments in the ledger. Bare JavaScript is not expected to pay the Lua sandbox/VM setup cost, so functional equivalence does not establish security equivalence.

```sh
npm run bootstrap
# The frozen baseline commit must exist in this clone; CI uses a full checkout.
python3 perf/prepare.py
node perf/run.mjs
```

Outputs: `reports/shootout/RESULTS.md`, `summary.json`, `raw.json`, and `dist/shootout/manifest.json`. A dedicated workflow retains these plus every candidate's generated C, Wasm, source and test logs. Production promotion is a separate reviewed source change after the evidence is inspected.
