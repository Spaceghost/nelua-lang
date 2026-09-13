# JavaScript reference fairness

The first full native-peer shootout passed in run 34772691281 at head
fe35c7d4019700e279b4bc3b905f6617a356fd5f. Keep its evidence as the first completed
run, not a universal result or a source-compatibility guarantee.

The follow-up uses unchanged Lua/Nelua/Wasm/native code, with two avoidable costs
removed from the functional JavaScript reference:

- A request with no body does not await an empty-body reader.
- Binary echo does not decode a 64 KiB body to a JavaScript string that it never
  uses. Only computation, CONFIG key and upstream-path routes decode text.

These changes do not remove the bounded reader for actual input, change response
bytes, replace network fixture calls with constants, or modify Lua's workloads.
The reference still passes the same HTTP output and operation-count tests.
Local Node checks also exercised eight routes, 64 KiB arbitrary binary data and
oversized-body rejection before this source change was committed.

This is a stronger JavaScript reference, not a security-equivalent dynamic-script
sandbox. No per-request Lua instruction-hook or embedded Lua-heap quota is
emulated on JavaScript. Comparisons must state this difference and must not use
HTTP throughput as a proxy for isolated engine execution speed. The same-core
Wasm control is likewise not claimed to be the earlier fastest Wasm adapter.

Repeated within-run ratios are meaningful for the version actually tested.
Do not subtract absolute timings from different CI hosts, or attribute every
change between these runs to the JavaScript source optimization alone.
