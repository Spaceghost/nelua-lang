# Cancellation contract

The normal workerd configuration explicitly enables `enable_request_signal`. A compatibility date alone does not turn it on in the inspected upstream source. Without it, a manual AbortController test can pass while a real client disconnect fails to signal the invocation.

The test configuration is separate from the normal example. Its wire probe holds one CONFIG operation pending, confirms that the invocation is active, destroys the client's actual TCP connection, and inspects retained test evidence from another request. It requires the incoming request's abort event, completed invocation cleanup, and zero live Lua allocations / invocations / host operations. The test's timeout fallback is not accepted as proof of a network abort.

Ordinary explicit cancellation, timeouts, cancelled input readers, overlapping invocation ownership, and deliberately late non-cancellable backend callbacks are also tested inside the actual stock workerd runtime. The host rejects old invocation/operation identifiers, and work that ignores cancellation remains charged until it settles.

A synchronous Wasm/C call cannot be interrupted by a JavaScript timer on the same event loop. Lua instruction hooks terminate the tested interpreter loops, but do not meter arbitrary native work. `scripts/supervise.mjs` supplies a coarse external process-lifetime termination path; it does not promise per-tenant containment, graceful service restart or a production watchdog.

Relevant upstream sources:
- https://developers.cloudflare.com/workers/runtime-apis/request/#properties
- https://github.com/cloudflare/workerd/blob/17e4f5a73014286398fcf4e14f22c9caaffec42d/src/workerd/io/compatibility-date.capnp (enableRequestSignal)

Tests are assertions, not evidence of execution by themselves. The workflow logs and `network-disconnect.json` artifact record what actually ran.
