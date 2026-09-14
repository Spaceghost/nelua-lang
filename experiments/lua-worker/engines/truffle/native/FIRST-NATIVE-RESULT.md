# First completed Native Image run

Head `01bc8c059e20b0a5d4e092224fe972f156b280c5` completed the entire Native Image pipeline in run `34804808089`, job `103854471217`. Tested PR merge checkout: `c7cf64eed7720ccb8001553f2ca69754cff740c4`. Artifact `10333156843`, ZIP SHA256 `bc69f1477ca5e17e976b669bcc16bcce264070ccca0e90e0405051fbd6a2a478`.

The prior `-1` language-context index defect is fixed by runtime initialization of the two reference holders. Both actual ELF executables pass identity checks with Java absent from PATH, the 14 admitted control-flow regressions, close-on-exception checks, five interop groups, independent contexts and repeated qualification. Original missing coroutine/byte-string semantics and numeric-loop table-index behavior remain explicit. The new 200-case differential corpus is an additional gate for the follow-up run, not retroactively claimed as part of this one.

## Measured, not inferred

AMD EPYC 7763, six rotated fresh-process rounds. Conventional median checked HTTP requests per second:

| Path | Hello | Input-dependent CPU | Process to first response |
|---|---:|---:|---:|
| stock workerd JavaScript | 2589.32 | 1599.38 | 21.31 ms |
| JVM boundary control | 2417.90 | 958.95 | 1182.31 ms |
| Native Image boundary control | 2967.70 | 827.65 | 18.26 ms |
| JVM fixed-block experiment | 2420.89 | 1952.70 | 1184.92 ms |
| Native Image fixed-block experiment | 2884.10 | 811.61 | 19.40 ms |
| workerd to native fixed-block | 2277.03 | 738.62 | 34.04 ms |

These are full closed-loop HTTP hosts with different isolation and implementation costs, not isolated language execution. The JVM fixed-block CPU route has a within-round geometric-mean ratio of 1.229x versus JavaScript in this run, but Native Image's corresponding CPU ratio is 0.520x. Startup is process launch/readiness, not dynamic worker creation or hosted cold start. Six rounds are one CI-machine experiment, not six independent environments.

## Guest compilation, distinct from host AOT

In separate diagnostic processes, the JVM fixed-block implementation completes Tier 1 and Tier 2 compilation of the actual `cpu-handler.lua` function. The JVM boundary control fails virtual-frame escape. Both native images fail a different un-inlined invoke/frame-escape path; compiling the Polyglot wrapper is not counted as guest compilation.

A local compiler graph dump of the downloaded linear native executable retains an un-inlined `LuaAstRootNode.execute(VirtualFrame)` call after partial evaluation. This narrows the next investigation to availability/inlining of the native runtime compilation graph, not a license to force unsafe frame materialization or to count wrapper compilation as guest JIT. Root cause beyond that observed call has not been established.

The native executable is about 48.31 MiB and still contains an interpreter, runtime compiler and collector. After the separate 5000-request hello soak, RSS is 90.26 MiB for JavaScript, 277.19 MiB JVM control, 126.66 MiB native control, 272.23 MiB JVM fixed-block, 127.61 MiB native fixed-block and 164.00 MiB for the two-process proxy. Native startup and JVM-relative memory improve, but JavaScript memory parity and a stable long-run plateau are not established.

Both artifacts' source/binary hashes, all 72 raw rows and 12 summary rows were checked independently. The downloaded native binaries passed identity, source qualification, 200 variable-input CPU checks and 26 local HTTP assertions each. The JVM-only exploratory differential corpus also passed locally; native execution of that new corpus remains the follow-up gate.

No merge, default change, hosted deployment, asynchronous Truffle API or complete Lua conformance was performed. Keep native mode as a required contender and JVM as a labelled control; do not remove the native loss from the report.
