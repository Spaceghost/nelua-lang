// SPDX-License-Identifier: MIT
// One entry point for the JVM control and the real native executable.
import org.graalvm.nativeimage.ImageInfo;
import org.graalvm.polyglot.Context;
import org.graalvm.polyglot.Value;

public final class NativeImagePeer {
  static String identity() {
    return "{\"nativeImage\":" + ImageInfo.inImageRuntimeCode()
      + ",\"vm\":" + TrufflePeer.json(System.getProperty("java.vm.name", "unknown"))
      + ",\"java\":" + TrufflePeer.json(System.getProperty("java.version", "unknown")) + "}";
  }
  static void jitProbe() throws Exception {
    // Diagnostic process only; performance processes do not log compilation.
    System.setProperty("polyglot.engine.TraceCompilation", "true");
    System.setProperty("polyglot.engine.BackgroundCompilation", "false");
    System.setProperty("polyglot.engine.CompilationFailureAction", "Print");
    try (Context c = TrufflePeer.context()) {
      Value cpu = TrufflePeer.eval(c, "cpu-handler", TrufflePeer.PROGRAMS.get("cpu"));
      for (int i = 0; i < 1600; ++i) {
        long n = 10000 + (i * 37) % 997, expected = 0;
        for (long j = 1; j <= n; ++j) expected += j % 97;
        if (cpu.execute(n).asLong() != expected) throw new AssertionError("CPU mismatch at " + i);
      }
    }
    System.out.println("JIT_PROBE {\"checkedCalls\":1600,\"identity\":" + identity() + "}");
  }
  public static void main(String[] args) throws Exception {
    if (args.length == 1 && args[0].equals("--identity")) { System.out.println(identity()); return; }
    if (args.length == 1 && args[0].equals("--jit-probe")) { jitProbe(); return; }
    if (args.length == 1 && args[0].equals("--regressions")) { NativeRegressions.main(new String[0]); return; }
    // Always disclose the actual mode, including at the HTTP launch site.
    System.err.println("RUNTIME_IDENTITY " + identity());
    TrufflePeer.main(args);
  }
}
