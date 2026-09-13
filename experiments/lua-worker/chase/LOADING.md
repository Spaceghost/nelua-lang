# Second pass: loading and call-scoped allocation

The first pass completed in run 34763635026. The lazy-I/O variant reduced warm hello cost substantially without changing Lua instructions or removing limits. Creation remained far behind JavaScript. This second pass repeats resident/lazy controls and separates two additional hypotheses, not a bundle of unidentifiable changes.

- `slab`: lazy adapter plus a single call-scoped Wasm allocation for input arguments. Request/response values remain copied and cannot alias a later invocation. No live view crosses an await. Kernel, Lua VM and module loading are unchanged.
- `packed`: lazy adapter with its known runtime/common/application module graph placed in one static JS module plus the shared precompiled Wasm module. This is a deliberately strict fixed-graph packer, not a generic bundler or dynamic eval. Application Lua remains a text literal parsed by Lua, not translated JS. Kernel and adapter operation semantics are unchanged. A separate Node test executes all 27 lifecycle groups through the packed adapter plus output/counter tests; actual workerd benchmark responses and operation counts remain checked.

The JavaScript reference now receives only the common bounded-body reader, not the otherwise unused LuaRuntime class. The original benchmark imported the Lua module to share that reader. Removing the unused implementation makes this a stricter reference, not an excuse to slow JavaScript. Do not compare its absolute values against a different hardware run as a software delta.

The five complete lifetime cases are rotated across rounds instead of always measuring one-request workers first. Each still uses eight new loader IDs with identical source, preserving exactly checked counters. This balances a source of order/cache bias; it does not eliminate all caching or establish unique-source compilation costs.

```sh
npm run bootstrap
CHASE_SET=loading python3 chase/prepare.py
node chase/packing.test.mjs
CHASE_SET=loading node chase/run.mjs
```

The current CI selects this set. The original `resident/completion/lazy/pooled` ablations remain reproducible by omitting CHASE_SET. All generated contract sources and build scripts are now included in artifacts as well as their hashes. No previous runtime default has been changed by adding this experiment.

Current official workerd source explicitly shares `GetCompiledModule()` when the loader receives a WebAssembly.Module. Our loader already does this; compilation sharing is not claimed as a new optimization. Lower-level startup attribution, native hosting and a guest Lua JIT have not been implemented by this pass.
