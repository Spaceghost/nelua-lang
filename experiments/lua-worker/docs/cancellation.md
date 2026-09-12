# Cancellation contract

The normal workerd configuration explicitly enables `enable_request_signal`. A compatibility date alone does not turn it on in the inspected upstream source. Without it, a manual AbortController test can pass while a real client disconnect fails to signal the invocation.

The host adapter retains the bounded invocation task with `ctx.waitUntil` so cleanup remains live when the HTTP caller disappears. This is host-owned lifecycle management, not an application-visible waitUntil API. Cancellation releases ordinary Lua state; the independent asynchronous deadline remains necessary when a transport cannot immediately detect disconnection. It still cannot preempt synchronous native work.

## Real network tests

The first network probe incorrectly assumed a quiet TCP close must immediately notify the server that no response can be delivered. Run 34711245916 retained the failure: the manual cancellation contract passed, while the quiet-close probe had not observed a request abort. The lower-level KJ API explicitly documents limits to write-disconnect detection. Do not turn a deadline into evidence of a transport event.

The test configuration is separate from the normal example. Two wire probes each hold one CONFIG operation pending, confirm that the invocation is active, tear down the client's actual TCP connection, and inspect retained evidence from another request:

1. **Reset:** `socket.resetAndDestroy()` sends TCP RST. The test requires the incoming request's abort event, a non-timeout termination, completed invocation cleanup, and zero live Lua allocations / invocations / host operations.
2. **Quiet close:** `client.destroy()` closes without demanding a reset. Either an actual abort or the independent deadline must clean up completely. Its evidence records which happened; timeout cleanup is not called an immediate disconnect signal.

Ordinary explicit cancellation, deadlines, cancelled input readers, overlapping invocation ownership, and deliberately late non-cancellable backend callbacks are also tested inside stock workerd. The host rejects old invocation/operation identifiers, and work that ignores cancellation remains charged until it settles.

A synchronous Wasm/C call cannot be interrupted by a JavaScript timer on the same event loop. Lua instruction hooks terminate the tested interpreter loops, but do not meter arbitrary native work. `scripts/supervise.mjs` supplies a coarse external process-lifetime termination path; it does not promise per-tenant containment, graceful service restart or a production watchdog.

Relevant upstream sources:
- https://developers.cloudflare.com/workers/runtime-apis/request/#properties
- https://github.com/cloudflare/workerd/blob/17e4f5a73014286398fcf4e14f22c9caaffec42d/src/workerd/io/compatibility-date.capnp (enableRequestSignal)
- https://github.com/capnproto/capnproto/blob/master/c%2B%2B/src/kj/async-io.h (whenWriteDisconnected)
- https://nodejs.org/docs/latest-v22.x/api/net.html#socketresetanddestroy

Tests are assertions, not evidence of execution by themselves. Workflow logs plus `network-reset.json` and `network-close.json` record what actually ran.
