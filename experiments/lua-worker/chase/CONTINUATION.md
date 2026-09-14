# Continuation: checked lookup hints and isolated Wasm changes

## Publication and reconciliation

This commit publishes the pending non-Truffle portion of the locally prepared
continuation against PR #20 head `97cad6c75361238bd8901761ddf0554a419cf844`.
The saved patch was based on `39ec0040acf3dfd2f2c1b5aa17b005001c4ecb62`.
The three engine files were unchanged between those heads.

The branch acquired newer Truffle initialization and cold-path fixes meanwhile.
Those files are preserved, not overwritten by the older proposed Truffle patch.
See `EXECUTION-INIT.md`, `COLD-PATHS.md`, `image-execution-init.py`,
`cold-path-boundaries.py`, and `truffle.sh` for the current Native Image experiment.

The frozen runtime control remains
`b5be21812242b33a6f566f3d73cd86efe929d54e`.
Existing defaults, parent branches, application sources and limits are unchanged.

## Candidate being tested

Native Lua 5.5, LuaJIT and Luau candidates retain the full slot reset, complete
invocation IDs, exhaustion rules, quotas and existing execution metering.
A 256-byte per-kernel hint table suggests an active slot. The full live ID must
match before use; a collision falls back to the original eight-slot scan.
A hint never grants capability authority.

For both Wasm profiles, the original buffered-body handler and input allocation
path are retained. The conservative profile changes bodyless dispatch only;
the candidate additionally has the checked lookup hints. The prior metadata-only
reset and single-input-slab combination is not promoted. JavaScript retains its
stronger synchronous-path reference implementation.

The new regression keeps one old coroutine suspended while 1,024 subsequent
requests reuse another slot and overwrite its hint bucket. The live request must
remain resumable and stale completions must be rejected. The full workflow runs
this against regenerated control and candidate kernels, including Luau/Wasm.

## Evidence boundaries

Before publication, the selected patch passed `git apply --check` against the
verified unchanged files. Python/JavaScript syntax and exact-match source
transformations passed. Each transformed adapter passed ten Node regression
groups using the existing control Lua and Luau Wasm binaries.

Those twenty local regression groups validate the adapter and test harness,
not the new compiled hint kernel. The earlier generated-C-mirror hotspot
measurements are provisional and are not substituted for a pinned Nelua rebuild.

The all-engine CI workflow must regenerate every native/Wasm profile, run the
sanitizer/source/ownership/HTTP gates, and measure same-machine paired workloads
before any performance claim or default promotion. The separate Truffle job
still requires actual Native Image evidence and source-attributed guest
compilation diagnostics. A pushed commit is not a passing benchmark.
