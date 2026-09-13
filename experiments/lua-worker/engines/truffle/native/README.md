# Truffle Lua native-image shootout

This experiment adds actual GraalVM Native Image executables, not a JVM launcher labelled native. It preserves the prior JVM/boundary build as a control and makes one independently measured optimization experiment: fixed, label-free AST statement dispatch. The generic goto path is preserved. Guest loops are not unrolled or replaced by a benchmark-specific native implementation.

## Build and run

From `experiments/lua-worker`, on the pinned GraalVM Community 25.0.1 toolchain with `native-image`, Maven, Node 22.16.0, a C toolchain and Linux:

```sh
npm ci
bash engines/truffle/native/build.sh
node engines/truffle/native/run.mjs
```

The dedicated workflow records the exact toolchains and source/dependency hashes. Native binaries use `--no-fallback`, O2 and the compatibility CPU target. They embed the Truffle runtime compiler via the runtime's Native Image feature. No blanket build-time initialization of language contexts, credentials or application state is requested. Runtime heap cap is 256 MiB, not a process-RSS cap. Build memory is separately controlled with `NATIVE_BUILD_HEAP` (default 10g).

`ImageInfo.inImageRuntimeCode()`, ELF metadata, linked libraries and the live `/proc/PID/exe` path distinguish the native executable from JVM controls. A native image of an interpreter does not prove the guest Lua function compiled. Separate diagnostic processes check exact `cpu-handler.lua` compilation events and retain failures. The Polyglot calling wrapper is not counted as guest compilation. Timed processes disable compilation logging, retain normal background compilation, and use identical input-dependent warmup.

## Experiment matrix

- JavaScript in stock workerd.
- Prior label-boundary Truffle on the JVM and in native-image mode.
- Linear-block Truffle experiment on the JVM and in native-image mode.
- Stock workerd external service forwarding to the linear native executable.

Each contender receives the same HTTP inputs and checked outputs. Six fresh-process rounds rotate execution order, and hello/computation case order alternates. Whole-process startup, warm HTTP throughput, finite hello memory soak, native build time and artifact size are separate quantities. No full worker-creation, async parity, engine-only throughput, CPU affinity or hosted-cold-start claim.

## Correctness and limits

Control flow, goto, closures, multiple returns, nested loops and independent contexts are checked for both JVM and native images. The original qualification is repeated and compared across all builds. A newly observed pre-existing numeric-loop/table-key failure is retained as an explicit known gap, not removed from the corpus to make a patch pass. The missing coroutine and byte-string behavior remains visible.

This is still a trusted fixed-source synchronous host. CONFIG/fetch and non-ASCII binary echo are explicitly unsupported. There is no arbitrary-source HTTP endpoint, no assertion of hostile-tenant isolation, and no default backend switch. Native Image does not implement missing language features. Native/JVM compilation failures are qualification results, not automatically a failed build when the admitted interpreted subset still works.

Primary references:
- https://www.graalvm.org/latest/reference-manual/native-image/guides/build-polyglot-native-executable/
- https://www.graalvm.org/latest/reference-manual/native-image/overview/BuildOutput/
- https://www.graalvm.org/truffle/javadoc/com/oracle/truffle/api/nodes/ExplodeLoop.html
- https://www.graalvm.org/truffle/javadoc/com/oracle/truffle/api/frame/VirtualFrame.html
