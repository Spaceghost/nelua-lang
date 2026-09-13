# JIT qualification and the failed first HTTP gate

Run 34769897210 passed native builds, sanitizer checks, the 35-case source corpus,
Wasm/workerd parity and metered HTTP contracts. It stopped at the trusted-JIT
HTTP assertion: the four variable CPU requests had not produced a compiled trace.
The performance step did not run; there was no result to claim.

The standalone 200-call probe passed, so the next check exercised the exact
`peer/worker.lua` application through the same native ABI. On the downloaded
build, the sequence 31, 997, 10000, 10999 followed by 10000+i produced the first
trace on total call six. All 204 outputs matched. This is evidence that the
functional test was not sufficient warmup, not a fixed warmup requirement for
all LuaJIT versions or inputs.

The revised HTTP gate runs 200 input-dependent requests against that same routed
application and still requires compiled traces. No interpreter quotas, failure
checks or trace assertions were removed. The performance harness gives every
contender the same fixed 200 CPU calls and 32 calls for each other case, and
checks the trusted-JIT trace counter before any timed samples. Counts are
retained in `benchmark-raw.json` under `warmup`.

Expected CPU results are now computed before the measurement clock starts. The
load driver no longer executes its own reference arithmetic loop inside the
throughput measurement. Output validation and actual HTTP transfer still remain
in the timed path. This prevents interpreting load-driver arithmetic as guest
execution cost but does not remove all driver or fixture bottlenecks.

The trusted-JIT profile remains explicitly different from the metered profile.
Its compiled code is not subject to the Lua debug-hook instruction budget; an
independent process-kill test is required. This is not hostile-tenant parity.
