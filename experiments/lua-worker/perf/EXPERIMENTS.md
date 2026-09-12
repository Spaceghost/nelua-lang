# Performance experiment ledger

Preserve both wins and failed hypotheses. Production promotion requires contract evidence and repeated measurement; candidate source is not a production default.

## Round 1: compiler profiles, dispatch and combined changes

Frozen baseline: `4404fcbb48d2692274df8864616c399986c1fb8a`.
Harness head: `7512f2e7a34faf1591a066e9e4c5b3a13e593163`.
Successful run: https://github.com/Spaceghost/nelua-lang/actions/runs/34721102160
Artifact: `lua-shootout-34721102160`, ID `10306845221`.
Downloaded ZIP SHA256: `77abae254ff5b2b36832415f2725d5bace3517ae3e2b2cde33ff510818d66cd7`.
Runner CPU: AMD EPYC 9V74; server and driver pinned to separate CPUs.

Every Lua contender passed native ASan/UBSan, 17 original Node/Wasm tests, four added regressions, normal workerd HTTP, ten in-workerd contract groups and real TCP reset/quiet-close cleanup. Seven fresh-process rounds measured six batched workloads and four actual-HTTP cases. All output and operation counts were checked. Artificial fixture delays were removed.

| Contender | Equal-weight geometric speedup across six batched cases | Wasm bytes | Decision after round 1 |
|---|---:|---:|---|
| baseline O2 | 1.000x | 259831 | Control |
| O3 LTO | 1.026x | 337574 | Small speed gain; substantial size cost |
| Oz LTO | 0.987x | 187526 | Smaller, not a throughput win |
| compiled entry + O3 LTO | 1.091x | 338295 | Promising; confirm and compare other profiles |
| combined entry/IDs/reset/slab + O3 | 1.061x | 333753 | Reject bundle: 64 KiB body and 16-operation regressions |
| plain JavaScript | 5.561x | none | Functional floor, not equally sandboxed dynamic-code execution |

The compiled-entry case improved each of the six workloads. Its paired speedup intervals were above 1 in this run. The combined variant's 64 KiB case was 0.957x [0.945, 0.968] and its sixteen-operation case was 0.950x [0.937, 0.964]. Do not select that bundle just because its best cases look attractive. Component-level attribution has not yet been established.

Compiled entry replaces parsing a fixed trusted Lua wrapper with C continuations. It does not cache guest bytecode or Lua states, change source-loading policy, remove hooks, weaken bounds or preserve an arbitrary C stack over await. Added tests check return cardinality before and after async yields, invalid handler exports, binary bodies, source changes, tracebacks and stale-ID churn.

### Memory is unresolved, not a win

At 50,000 hello invocations, all Lua counters were zero and linear memory remained 4 MiB, but RSS increased for every contender including JavaScript. JavaScript rose from 73,708 to 284,900 KiB between 1,000 and 50,000 invocations; baseline Lua from 91,772 to 308,300 KiB; compiled entry from 96,420 to 308,880 KiB. This is not a stable memory plateau, nor proof that Lua itself leaks. It requires a separate host/GC/retention investigation. Do not turn zero Lua accounting into a low-process-memory claim.

### Harness repair

Run `34720990577` stopped before timing because `git archive` inherited the project-subdirectory prefix. The corrected extraction runs from the repository root and asserts that the baseline build script is present. No runtime change or failing runtime test was hidden by that fix.

## Round 2: controlled refinement and independent confirmation

The default `SHOOTOUT_SET=refine` repeats the frozen baseline and compiled-entry O3 build in a fresh Actions run, and adds compiled-entry O2, Oz/LTO, O3/LTO SIMD, and an O3/LTO trusted-bootstrap GC-pause experiment. With JavaScript, seven contenders rotate across seven rounds so each occupies each order position once. The measurement harness and workload definitions are unchanged.

The GC experiment pauses collection only during trusted library/coroutine initialization, restarts it before guest source parsing, and asserts it is running on entry to guest execution. Allocation quotas and instruction hooks remain unchanged. No forced V8 collection is part of the performance measurements.

SIMD support is documented by Cloudflare, but this particular build must still pass the real pinned workerd contract. Allocator substitutions are not selected merely for speed: default dlmalloc retains its metadata-corruption detection. Disabling safeguards is not an optimization win.

Reproduce the first set with `SHOOTOUT_SET=initial python3 perf/prepare.py`; use `SHOOTOUT_SET=refine` for the second. Then run `node perf/run.mjs`. Source hashes, binaries, test logs and raw samples are retained by the workflow. No round-two result or production promotion is claimed before its evidence is inspected.

References:
- https://developers.cloudflare.com/workers/runtime-apis/webassembly/
- https://www.lua.org/manual/5.5/manual.html#lua_callk
- https://www.lua.org/manual/5.5/manual.html#lua_gc
- https://emscripten.org/docs/tools_reference/settings_reference.html#malloc
