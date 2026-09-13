# Additional engines: Luau and Truffle Lua

Both are explicit experimental lanes stacked on the native-peer baseline. Existing Lua 5.5, LuaJIT, Wasm and benchmark source files are not replaced. Pins are in `pins.json`. Written adapters and tests are not proof of successful execution; workflow artifacts retain results.

## Luau

Roblox's Luau 0.738 is embedded in the existing context-owned Nelua kernel. `luau-adapt.py` derives a narrow C API adapter from `peer/runtime.c`; exact-match checks fail on source drift. The same generated adapter and pinned VM/compiler are built natively and to Wasm. The native KJ HTTP host is unchanged. The Wasm variant runs inside unmodified workerd, and the native variant also has a workerd external-service/Unix-socket lane.

Source is limited to 64 KiB and compiled by the pinned host compiler. Caller-provided bytecode is never accepted. Compiler allocation is **outside** the 2 MiB per-app VM allocation quota, so outer memory/CPU limits remain necessary. Wasm linear memory remains capped at 32 MiB. Restricted libraries, readonly Luau builtins, app-local writable globals, immutable capability ownership, 8 request slots and operation/body caps are retained.

Execution uses Luau's interrupt callback, not Lua debug hooks. Every 1024 non-GC interrupt callbacks consumes one of 1000 kernel ticks, independently per invocation and initialization. This is a **safepoint budget**, not the same numerical instruction count as Lua 5.5. Both reject tested runaway loops, but the budget units are not security/performance-equivalent. Native C work and compilation require external supervision. Native code generation is not enabled in this initial Luau lane.

Gates: native fully instrumented Luau VM/compiler/adapter sanitizer executable; 31 common source cases against Lua 5.5; native/Wasm response and operation equality; five explicit async/ownership groups in Node and actual stock workerd; Luau typed-source proof; four Lua 5.5 feature probes; real HTTP/config/subrequest/cancellation tests before timing. Generated extensions of the existing harness are retained, rather than silently redefining the reference.

```sh
bash scripts/bootstrap.sh
bash peer/build.sh
bash peer/build-host.sh
python3 peer/make-cases.py
python3 peer/parity-native.py
node peer/node-tests.mjs
bash engines/build-luau.sh
timeout 60 dist/engines/core-luau-asan
python3 engines/prepare-tests.py
python3 peer/engine-native.py
node engines/luau-tests.mjs
node peer/engine-http.mjs
node peer/engine-bench.mjs
```

The workflow uses Ubuntu's pinned KJ package. No Alpine/musl, hosted Cloudflare, or same-process native workerd integration is claimed.

## Truffle Lua

The concrete implementation is `zhxzkhz/LuaTruffle`, pinned independently from its GraalVM Polyglot/Truffle version (25.0.1). This is not an official complete Lua backend supplied by GraalVM. Its published missing coroutine support and Java-string model require qualification rather than a full async ranking.

The first integration is a **trusted fixed-source synchronous qualification host** on GraalVM, reachable through stock workerd's external-service routing. It is not a JVM/Wasm interpreter inside workerd and does not use the Nelua allocation ABI. No arbitrary source upload endpoint exists. Polyglot host access, class lookup, I/O, process and thread access are denied, but those flags are not a proof of sandbox correctness for this language implementation.

Hello, input-dependent numeric computation, ASCII echo and resident counters are tested. Missing async capabilities and unsupported binary strings return 501 explicitly, rather than using blocking calls or lossy decoding. Common Lua source features are probed with exact source/result/error evidence. A failure of a required synchronous behavior stops measurement. Other semantic mismatches stay visible in the report; they do not become async parity by running a faster loop.

A dedicated three-round trusted/synchronous HTTP comparison runs JavaScript, direct Truffle and workerd-proxied Truffle with the same inputs and warmup. Cold process startup, RSS and compile traces are recorded separately. The compiler trace diagnostic affects behavior and is not a production performance guarantee. The JVM uses a 256 MiB Java heap cap; its total RSS includes additional native/JIT memory. An external parent can kill a wedged process. This lane does not claim request-local instruction metering, byte-string fidelity, coroutine cancellation or hostile-tenant containment.

```sh
# GraalVM Community JDK 25.0.1, Maven and pinned Node/workerd installed:
npm ci
bash engines/truffle/build.sh
node engines/truffle/run.mjs
```

Upstream test dependencies contain an unpinned TestNG RELEASE; the build changes only that declaration to 7.11.0 and retains the diff. Upstream tests are not claimed to have run; our qualification tests execute the built language. Root and source-level license notices, including UPL headers, are retained with the source archive.

## Primary references

- https://luau.org/sandbox/
- https://luau.org/performance/
- https://github.com/luau-lang/luau/tree/c54f558b4d5748ab0658610b8ce0c432053e41eb
- https://github.com/zhxzkhz/LuaTruffle/tree/001d3005e8045fe5c1d428790293b0a8525a6b09
- https://www.graalvm.org/latest/reference-manual/embed-languages/

Promote only after inspecting actual source/runtime gates and repeated measurements. Unsupported operations are excluded, not assigned fabricated timings. Faster HTTP on different hosts is not isolated engine-speed or full Workers parity.
