# Native guest graph eligibility

The previous all-engine run 34811296221 completed its separate shared-engine
measurements, but the Truffle experiment failed while building a deoptimization
variant of LuaBoolean.valueOf. It forcibly registered 233 runtime-compilation
roots. More roots did not fix graph eligibility; the compiler rejected many
of them with its generic graph-validation failure.

Pinned GraalVM 25.0.1 DeoptimizationUtils.createGraphChecker requires the
method's declaring class to be initialized. Runtime-compilation graphs must
also contain neither StackValueNode nor EnsureClassInitializedNode. The latter
restriction prevents partial evaluation from folding uninitialized fields.
This is distinct from an unreachable method or insufficient warmup.

The revised experiment adds an explicit audited execution-class initialization
list to the existing generated-metadata list. It retains bytecode and class
hashes for all 118 candidates, excludes three unaudited/mutable-node singleton
types, and rejects new static fields instead of widening to package-wide
initialization. No worker, application Context, source AST, socket or thread
is created at build time. LanguageReference and ContextReference holders stay
runtime-initialized so the earlier missing-language index cannot be captured.

LuaBoolean has two pre-existing lazy mutable static fields but no class
initializer. Only their default nulls are captured, not application-derived
boolean values. Its broader third-party semantics are not newly certified by
this experiment. The nil/type singletons and constant strings remain opaque
language constants; the audit does not claim arbitrary host mutation is safe.

RuntimeRoots now only records rejected graphs; it does not register roots,
change compiler blocklists, disable validation or force a virtual frame to
escape. Controls use the old initialization list and the exact same language
JAR. Native executables remain --no-fallback and are verified independently of
Java availability. Guest-source compilation events are counted separately from
Polyglot wrapper compilation. A successful native executable build alone is
not evidence of optimized guest execution.

Primary source:
https://github.com/oracle/graal/blob/vm-25.0.1/substratevm/src/com.oracle.svm.hosted/src/com/oracle/svm/hosted/code/DeoptimizationUtils.java
