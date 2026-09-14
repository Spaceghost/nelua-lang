# Native Luau CodeGen shootout

An additional experimental lane, not a default change. Existing Lua, LuaJIT,
Luau, Wasm and Native Image controls remain. Stock workerd reaches compiled
native Luau through an external service, not an in-process language plugin.
Luau CodeGen is not enabled inside Wasm.

The two new peers use the same generated Nelua core, host, Lua source and Luau
0.738 libraries. The interpreter leaves native execution uninitialized; the
compiled peer creates a VM-local CodeGen context and compiles the loaded
application chunk and nested functions before initialization. Partial/failed
compilation is a gate failure. Bytecode options and safepoint metering stay the
same. The main HTTP suite uses identical worker.lua source; typed/untyped source
pairs have separate correctness checks. Compiled code may fall back for some
operations; no claim is made that all operations stay native.

## Gates

Both variants run the original ownership/error suite with VM, compiler, CodeGen,
adapter, kernel and harness instrumented with ASan/UBSan. Generated machine code
is not itself sanitizer-instrumented. Release libraries must match the 31-case
common-source corpus, pass 200 typed/untyped results, overlapping applications,
stale-result rejection, a 64 KiB binary body and runaway-loop recovery.

A version-pinned diagnostic observes the native CallInfo flag at application
interrupt safepoints. Disabling native execution must stop those observations;
reenabling it must resume them. Observation is disabled during timing. An
unrelated pending coroutine must survive a runaway request's budget failure.
Real TCP reset and quiet-close cleanup probes precede measurements.

The existing meter counts Luau safepoints, not Lua opcodes or CPU time. Machine
code allocation has a separate 4 MiB per-VM cap. The 2 MiB VM-heap cap excludes
compiler/host allocations and metadata outside that code allocation. External
CPU/memory limits remain necessary; this is not V8-equivalent tenant isolation.

## Measurements

Eight rotated fresh-process rounds cover optimized JavaScript, same-core
Lua/Wasm, native Lua 5.5, metered/trusted LuaJIT, matched Luau interpreter and
CodeGen, and stock workerd forwarding to the CodeGen peer. Warmup, sources,
inputs and backend-operation counts are matched. Startup includes application
compilation. Source/binary hashes, generated-code counts/bytes, raw latency
samples and finite RSS observations are retained.

Closed-loop HTTP is not isolated interpreter speed, open-loop capacity, dynamic
worker creation or hosted Cloudflare performance. Trusted LuaJIT has JIT on and
instruction hooks off, unlike the metered column. A full all-engine/Native Image
repeat is triggered separately by the same commit. No build/test result or
performance gain is claimed merely by committing this harness.

After pinned baseline/engine setup:

```sh
python3 chase/codegen/prepare.py
python3 chase/codegen/checks.py
python3 chase/codegen/configure.py
node peer/codegen-http.mjs
node peer/codegen-bench.mjs
```
