# Paired all-engine optimization chase

This experiment is additive. It does not change a shipping/default runtime or replace the older dispatch builder in `chase/prepare.py`.

## Controls and first completed trial

`all-prepare.py` freezes source at `b5be21812242b33a6f566f3d73cd86efe929d54e`, builds all profiles with the existing pinned toolchains, and records source/module hashes. It stops before timing on a failed build or contract. Native Lua 5.5 and metered LuaJIT retain instruction hooks; trusted LuaJIT remains a different trust/metering profile. Luau retains its safepoint budget. Original application Lua source is unchanged.

Run 34808175894 completed both jobs at head 75e2edc0c116b854be410d62977c5307f48a3ca5. The all-engine artifact SHA256 is `81627a3fc6a1e0ce0eba2048e9f9f521867415d7916304f2cfc3eec4187bd0e3`; the Truffle artifact is `8f24b790cacf842c363dc94a5a5e03732848c085bb86c50991449775b0d55888`. Both were downloaded and verified.

The first trial's bodyless Wasm hello gains were approximately 17-18% in paired within-round throughput, but 64 KiB echo regressed by approximately 13-14%. Native metadata-only reset was mixed/inconclusive overall. The single generic Truffle root-registration build passed its correctness gates but still failed optimized guest CPU compilation. It is not promoted as a fix. First-trial artifacts and raw measurements remain unchanged.

## Candidate profiles

The original aggressive candidate does four things:

1. The shared Nelua operation kernel resets every visible slot metadata field, not the entire 64 KiB payload capacity. New payloads are copied before exposing their length. This is not secure erasure. Separate application state in native/Wasm memory is not a hostile-tenant security boundary.
2. The Wasm adapter creates a cancellation controller and timer on first actual asynchronous work, preserving the original deadline origin. Bodyless synchronous handlers do not await an empty-body reader. Abort, failure, timeout, orphan-I/O accounting and late results remain tested. Synchronous C work still requires external preemption.
3. One call-scoped input slab replaces multiple host-to-Wasm allocations. No memory view or pointer crosses an await. The strict decoder is reused synchronously; byte-string bodies are not decoded.
4. JavaScript's functional reference retains synchronous returns for bodyless synchronous paths and uses module-level capability helpers instead of creating a closure per request. Bounded reads, response construction and backend calls remain. It is not a security-equivalent embedded-language sandbox.

The follow-up **conservative** profile targets the observed Wasm regressions. It retains the original kernel binary, original input allocation strategy and original buffered-request implementation, using the new path only for bodyless requests. Both Wasm engines test all three profiles. Native/JavaScript measurements omit the redundant conservative builds. Gates still run for every built profile.

## Measurements

JavaScript, native Lua 5.5, metered/trusted LuaJIT, native Luau, and Lua/Luau in stock workerd are measured in fresh processes. Native/JS pair order alternates; the three Wasm profiles rotate across all positions. Engine order rotates and workload order reverses on alternate rounds. Six rounds now produce 576 workload records and 54 paired summaries; the first trial had 504 and 42. Status/body and backend operation counts are assertions. Expected CPU sums are precomputed outside timing, inputs vary, and warmup is identical. Command identities and warmup counters are retained in the follow-up.

The workloads cover hello, arithmetic, 64 KiB echo, one storage read, a storage-plus-subrequest chain, and sixteen storage reads. Full response processing is timed. These are closed-loop HTTP results, not isolated language speed or open-loop capacity. Native and workerd have different networking/isolation costs. A finite 5,000-request hello soak records RSS without forced collection. Process launch is not dynamic Worker creation.

Bootstrap intervals are exploratory, paired within one run, and not adjusted for multiple comparisons. A favorable row does not justify promoting a complete profile. Preserve regressions and inconclusive changes.

## Truffle Native Image experiment

`truffle.sh` retains previous real Native Image and JVM controls and builds a third ELF using a pinned GraalVM 25.0.1 build feature. The follow-up broadens the failed single-root registration to generic concrete `execute*` methods accepting VirtualFrame in the language AST package, excluding explicit Truffle boundaries. This does not precreate an application or substitute a benchmark-specific function. Build-only rejection diagnostics are retained. A local classpath enumeration discovered 232 methods; this is not a successful native compilation result.

The new executable must pass identity/no-Java checks and the existing control-flow, differential, interop and qualification gates. Guest compilation diagnostics are separate from timed HTTP. A compiled Polyglot wrapper is not a compiled guest. The original byte-string/coroutine/table-key gaps and fixed-source synchronous trust model remain. The follow-up uses the stronger JavaScript reference and seven rotated rounds.

## Reproduce

On the pinned Linux environment with KJ headers and native/Wasm tools:

```sh
bash scripts/bootstrap.sh
python3 chase/all-prepare.py
node chase/bench.mjs
```

With pinned GraalVM Community 25.0.1 and Native Image:

```sh
npm ci
bash chase/truffle.sh
```

Evidence is retained by `.github/workflows/lua-all-engine-chase.yml`. A committed command/test does not imply a passing run. No merge, hosted deployment, native Luau CodeGen or in-process workerd native-engine integration is implied.
