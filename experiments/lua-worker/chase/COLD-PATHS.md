# Cold-path qualification after enabling execution graphs

Run 34879126447's Native Image experiment reached a different, explicit failure:
271 runtime-compiler blocklist violations. Of the retained traces, 266 went
through LuaPathSearcherNode.doSearch's unconstrained Object.toString call and
five through LuaBlockNode's exception-message conversion. The prior missing
execution graphs had hidden these paths from the runtime compiler.

The next candidate adds TruffleBoundary to exactly two existing methods:
LuaPathSearcherNode.doSearch(Object[]) and
LuaBlockNode.closeErrorObject(Throwable). Their bodies and observable operations
are unchanged. No VirtualFrame crosses either boundary. Module lookup and
exception-message formatting stay outside guest partial evaluation; block
execution and cleanup stay eligible. No compiler safety check is disabled.

The source-patched language is retained as eligible-lib, independently of the
old boundary and fixed-block controls. JVM and Native Image candidate lanes use
the identical eligible JAR. The native candidate also uses the explicit class
initialization audit. Eight rotated process rounds cover all eight contenders;
old controls are not overwritten. Compilation traces are parsed line-by-line,
with source-attributed guest events separated from Polyglot wrapper events.

As before, a successful image build does not by itself prove guest compilation
or a performance gain. Source/interop regressions, native identity, compilation
diagnostics and matched measured requests are separate gates. The missing
async/byte-string/table-key behaviors remain explicit. No default promotion.
