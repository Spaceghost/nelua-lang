# Measured optimization and build profiles

## Decision

Replace the fixed Lua bootstrap wrapper with compiled C continuation dispatch. Keep fresh Lua states, text-only guest compilation, the original Nelua ownership kernel, the original JavaScript adapter, instruction hooks, allocation/body/operation limits, cancellation and traceback handling. No slot/allocator/slab rewrite, SIMD requirement or GC-policy change is adopted.

The default remains **O2**, now with compiled dispatch. O3/LTO and Oz/LTO are explicit profiles because throughput, workload mix and binary size give different answers; there is no universal best flag. The profile names express an intended tradeoff, not a guarantee for every application.

```sh
npm run build                         # balanced: O2, compiled dispatch
WASM_PROFILE=cpu npm run build        # O3 + LTO
WASM_PROFILE=compact npm run build    # Oz + LTO
npm test
```

| Profile | Measured contender | Wasm bytes | SHA256 |
|---|---|---:|---|
| balanced (default) | entry-o2 | 259829 | 6ce174704937b0e82c5e059d599303f1e310bb8a9e16e6f142ce0e664298eb29 |
| cpu | entry-o3 | 338295 | 885da13f83ad36a249d50bd165a4959657de041e80f7c886590847cde0d7bd50 |
| compact | entry-oz | 187553 | 3255cf17ddfe9103e0a5caa49f95c3a21b6ec0682dfe6c56a040aab5b29a46b2 |

The original baseline was 259831 bytes. The balanced profile is effectively size-neutral; compact is about 28% smaller; cpu is about 30% larger. `perf/check-profiles.sh` requires the shipped source to match the entry-only change and each real build to be byte-identical to its fully gated shootout counterpart. It leaves the default balanced binary installed locally. Profile verification failures are CI failures.

## Independent runs, different hardware

Both runs use Node 22.16.0, Lua 5.5.1, Nelua a5845056, Emscripten 4.0.14 and workerd 1.20260911.1. Exact full source revisions, flags, hashes and raw samples are in the artifacts. Server and driver use separate pinned CPUs. Each run contains seven fresh-process rounds, six checked batched handler workloads, four actual HTTP cases and a 50,000-invocation memory pass per contender.

1. Run **34721102160**, AMD EPYC 9V74: compiled dispatch + O3/LTO improved the equal-weight geometric mean of the six batched cases by **9.1%** over the frozen baseline. The combined slot/reset/slab rewrite regressed the 64 KiB and sixteen-operation cases and was rejected as a bundle.
2. Run **34721712461**, Intel Xeon Platinum 8573C: the same compiled dispatch + O3/LTO improved that metric by **6.9%**. Compiled dispatch + O2 improved it by **8.7%**, while retaining baseline binary size. These are within-run comparisons. Do not compare AMD's absolute baseline time to Intel's optimized time and call the difference a software speedup.

The Intel run's batch medians follow. Units are externally timed **microseconds per complete invocation**, amortized across the batch. They are not per-request network latency.

| Workload | Baseline O2 | Compiled dispatch O2 | Compiled dispatch O3/LTO | Plain JavaScript |
|---|---:|---:|---:|---:|
| Hello | 95.94 | 83.36 | 84.08 | 14.03 |
| Integer loop | 339.75 | 337.49 | 324.05 | 68.45 |
| 64 KiB body | 442.65 | 429.38 | 433.03 | 292.29 |
| One resolved CONFIG read | 129.31 | 112.72 | 117.43 | 14.55 |
| CONFIG + UPSTREAM service chain, c4 | 356.85 | 329.66 | 353.05 | 154.85 |
| Sixteen resolved CONFIG reads | 199.99 | 173.23 | 177.77 | 20.08 |

The profile differences are small and workload-dependent. The paired aggregate O2/O3 speedup interval in the Intel run spans 1; this does not establish O2 as universally faster. SIMD and a trusted-bootstrap GC pause had small apparent gains, but no compelling independently replicated benefit sufficient to add them to the default. O3's interpreter-loop gain and Oz's binary-size saving justify optional profiles rather than forcing one tradeoff on every handler.

Plain JavaScript is faster in every measured batched case. It is a functional floor, not a security-equivalent dynamic-script runtime: it does not pay for a fresh sandboxed Lua VM, text compilation or Lua instruction metering. The async service-chain test uses actual workerd bindings with **no artificial fixture delay**. The HTTP results, closed-loop latency samples, startup data and confidence intervals are retained separately in each artifact, not conflated with these batch medians.

## Correctness and memory

Every Lua candidate passed native ASan/UBSan, the original 17 Node/Wasm contracts, four performance-specific regressions, normal workerd HTTP, ten in-workerd contract groups and the real TCP reset/quiet-close deadline tests. The four extra regressions now run with the normal source's `npm test` and CI. The original quota constants, allocator, slot zeroing and adapter are retained.

All measured invocations clean up to zero live Lua bytes and zero active/admitted/outstanding counters. Wasm linear memory stays at 4 MiB in these workloads. **Process RSS did not plateau** in either first or second memory pass; it rose even in the JavaScript floor. Zero Lua accounting is not a whole-process memory measurement or proof against leaks.

`perf/memory-diagnostic.mjs` is an additional, separate inspector-enabled probe. It records V8 heap usage and process RSS before and after forced collection at 50,000 and 100,000 hello invocations. Inspector and forced-GC behavior are intentionally excluded from all speed measurements and normal configurations. Its generated report, not the existence of the script, determines what this probe actually demonstrates.

## Evidence and reproducibility

- Original baseline: `4404fcbb48d2692274df8864616c399986c1fb8a`.
- Round-one head: `7512f2e7a34faf1591a066e9e4c5b3a13e593163`; run `34721102160`; artifact `10306845221`; ZIP SHA256 `77abae254ff5b2b36832415f2725d5bace3517ae3e2b2cde33ff510818d66cd7`.
- Round-two head: `1fa3c7b216e0ad8f71272b938250c56ab06f7f10`; run `34721712461`; artifact `10306990360`; ZIP SHA256 `9df68e19f7656fc6604c03fb1809d3a3b88051054326ded7e22a34470515b2dc`.
- Retained experiment history and rejected hypotheses: [EXPERIMENTS.md](EXPERIMENTS.md).
- Full harness methodology: [README.md](README.md).
- Post-promotion runs repeat the same baseline/contender matrix and require the shipped profile binaries to match. Consult the current workflow's retained test and measurement reports for that verification.

This remains a local prototype, not a Cloudflare hosted benchmark, a V8-free runtime, or a hostile-tenant sandbox. No performance measurement changes the original outer-isolation requirements.
