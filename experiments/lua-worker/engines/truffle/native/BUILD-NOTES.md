# Native image compatibility work

The original native image attempt did not build. Failed logs are retained; no
fallback JVM process is accepted as a native executable.

The pinned GraalVM 25.0.1 builder first required explicit initialization of the
generated language provider, generated interop dispatch registrations, and the
fixed LuaType descriptors plus their capture-free predicate interface. The
exact generated-class list and javap declarations are checked and retained.
LuaContext, LuaLanguage and application/host state are not explicitly initialized
at build time. No package-wide initialization option is used.

Run 34780038112 then reached native compilation but failed because seven interop
inspection methods had deoptimization-target entries without parsed graphs.
The experimental compatibility patch places those seven method bodies behind
TruffleBoundary, so the host-facing inspection still executes but is not copied
into optimized guest code. It neither disables guest runtime compilation nor
replaces Lua application work with Java. The same patch is applied to both JVM
and native-image contenders before the block-dispatch ablation is made.

This changes the new control's optimization boundary compared with PR #18. Do
not interpret cross-run timing differences as a pure native-image gain. Paired
new JVM/native builds use the same language JARs, and the linear-vs-boundary
comparison changes only the fixed-block dispatch patch. New interop regressions
exercise multiple returns, array/key access, function identity, Boolean display
and iterator progression. Existing source gaps remain explicit.
