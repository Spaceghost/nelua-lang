# Code generation versus safepoint bookkeeping

The first complete CodeGen run, 34890406809 at b9dd0ebaa0353e4d50a4fb2542ddc1a7d85cb6d6, passed both sanitizer suites, the common-source corpus, native-execution observation with a disable/reenable control, runaway recovery and the real HTTP/disconnect gates. Code generation alone did not establish a broad HTTP improvement. Its observations must not be relabelled as a compute-engine win.

This second experiment is a 2x2 comparison:

| Profile | Interpreter or native code | Safepoint bookkeeping |
|---|---|---|
| interp | Interpreter | Original |
| compiled | CodeGen | Original |
| interp-fastmeter | Interpreter | Cached counter location |
| compiled-fastmeter | CodeGen | Cached counter location |

The old callback looked up its coroutine owner and request-slot index on every non-GC safepoint, although the kernel only debits a budget tick every 1024 callbacks. The experimental callback stores a host-owned pointer to that coroutine's Frame in Luau's thread-data field. Each callback increments the exact same request-local counter. On every budget debit the complete owner is checked again; the kernel validates the complete invocation ID. Root initialization has its separate original counter. The pointer is cleared before coroutine reset. The thread-data field is not exposed to application Lua.

No callback is skipped, the threshold is still 1024 callbacks per tick, and the 1000-tick budgets are unchanged. Capability calls, result completion and stale IDs retain their original full checks. There is no process-global current request, shared counter across coroutines, reduced hook frequency or admission-limit change. The experiment does not claim safepoints are the same units as Lua opcode hooks or CPU time.

`fastmeter.py` derives explicitly retained prepare/check/configure scripts from the original CodeGen lane. Four release and four sanitizer profiles must pass before ten rotated HTTP rounds. Lua 5.5, metered/trusted LuaJIT, Lua/Wasm and optimized JavaScript remain controls. The proxy routes stock workerd to the compiled cached-meter host. The original two-profile experiment is reproducible from its original scripts and recorded commit.

Run after pinned baseline setup:

```sh
python3 chase/codegen/fastmeter.py
python3 chase/codegen/prepare-fast.py
python3 chase/codegen/checks-fast.py
python3 chase/codegen/configure-fast.py
node peer/codegen-http.mjs
node peer/codegen-bench.mjs
```

The first attempt's diagnostic bug is retained in run 34889378108: it read optional `CallInfo.p` cache storage without the LuauCIProto flag. All 31 compiled source cases completed before observation triggered the fault. The repaired diagnostic reads the current Lua closure instead, following the pinned upstream fallback path; it does not change VM flags. Both the execution-off control and compilation-count requirement remain. The independent native-code observation is disabled during timings.

Native machine code is not ASan-instrumented. Its 4 MiB code-allocation limit is separate from the 2 MiB VM-heap cap; compiler/host metadata require outer limits. The host still is not a hardened hostile-tenant or complete Workers implementation. No runtime default switch or performance improvement is implied by this experiment's presence.
