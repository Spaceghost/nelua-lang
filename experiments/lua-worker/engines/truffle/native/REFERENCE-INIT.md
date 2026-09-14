# Native context-index failure

Run 34781402564 generated a real native executable and verified its identity, then failed the first source-regression evaluation with `ArrayIndexOutOfBoundsException: Index -1`. The downloaded executable independently reproduced that failure. No shootout ran on that build.

The pinned GraalVM 25.0.1 `PolyglotFastThreadLocals.ContextReferenceImpl` stores a final language index at construction. `computeLanguageIndex` returns RESERVED_NULL (-1) if the language has not yet been discovered. Treating a LanguageReference/ContextReference as immutable registration-only metadata and initializing its holder in the image builder can preserve that invalid index in the executable.

The repair leaves the audited generated DSL/interop registration classes image-initialized but explicitly initializes the two reference holders in the launched runtime. No hard-coded language index, access-check bypass, swallowed exception, precreated application Context, or Java fallback is used. The same control-flow, interop, independent-context and qualification assertions remain mandatory before any performance sample. Both native-image identities are additionally checked with Java removed from PATH.

Primary source: https://github.com/oracle/graal/blob/vm-25.0.1/truffle/src/com.oracle.truffle.polyglot/src/com/oracle/truffle/polyglot/PolyglotFastThreadLocals.java

This note describes the diagnosis and proposed repair; the subsequent workflow's native regression results establish whether it succeeds.
