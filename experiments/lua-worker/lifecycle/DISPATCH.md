# Selected resident dispatch optimization

The resident build now adopts the `lazy` adapter measured in dispatch runs 34763635026 and 34764387784. The generated JS SHA256 is `fcdfa78e6725bd72ab83626f5af5774a9baa821c6119a86d6c1a3a88dbf0a98e`; the O2 Wasm SHA256 is unchanged at `8bef38601a1b10a04e6e5f25c324f7e09e1f8ee5313b1ea9b72a5eb2fce3337c`. The build checks both identities. No pool, packed module graph, new instruction policy, reduced quota or typed substitute for Lua computation is selected.

## What changed

The host no longer constructs an unused error stack on every successful completion. Actual I/O signals retain their public completion code and message, but share an immutable completion-reason object. The reason's identity and stack are not an invocation identity API. Real failure tracebacks remain distinct and tested.

Synchronous, bodyless handlers no longer allocate asynchronous cancellation machinery or await an empty body. An input body or yielded host operation activates that machinery, with its deadline measured from admission. This changes scheduling: a synchronous handler can complete before control returns to its caller instead of crossing an unnecessary microtask boundary. Cancellation before admission remains checked. Input and host-I/O cancellation, late callbacks, exact capability ownership, and timeout cleanup remain checked. Same-loop timers still cannot preempt synchronous Wasm; Lua hooks and outer limits are not removed.

## Evidence and limits

The AMD EPYC 7763 pass measured resident hello 114.10 microseconds and selected lazy hello 54.12 microseconds, with within-round geometric mean speedup 2.100x. The independent Intel Xeon Platinum 8573C pass measured 43.21 and 27.99 microseconds, with within-round speedup 1.609x. Hardware and benchmark-reference differences mean absolute times must not be compared across those runs. The second pass removed unused Lua implementation code from the JavaScript reference.

The second pass did not show a compelling creation win from packing modules. The input slab and coroutine pool showed workload-dependent changes and remain experiments. They are not included in this selected runtime. The original fresh-state default is unchanged; resident globals and aggregate-app heap semantics still require an explicit mode choice.

JavaScript still leads the measured engine and creation paths. In the Intel pass, new identity plus one checked request was 5.45 ms JavaScript and 9.92 ms selected Lua; two requests were 5.17 and 10.21 ms. A 128-request complete lifetime was 11.82 and 21.53 ms. No engine parity, unique-source compilation advantage, hosted startup result or stable process-memory plateau is established.

## Run

Use a full clone so frozen source revisions are present:

```sh
cd experiments/lua-worker
npm run bootstrap
npm run build:resident
npm run start:resident
# In another terminal:
curl http://127.0.0.1:8787/world
```

`build:resident` builds and tests fresh control, resident O2 and resident O3 profiles, not just one unchecked executable. Each resident profile runs all 21 existing lifecycle groups plus six new dispatch groups in Node and workerd, as well as native sanitizer contracts and real network cleanup checks. Its build must complete successfully before using the output.

The frozen shootout controls remain untouched and reproducible. Their evidence artifacts record precise source revisions, raw samples, complete-lifetime cases, ownership/allocation counters and process RSS. This selection does not merge the PR or authorize a production deployment.
