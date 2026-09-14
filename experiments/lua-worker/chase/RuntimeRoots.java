// SPDX-License-Identifier: MIT
// Read-only build diagnostic for pinned GraalVM 25.0.1. Earlier revisions
// forcibly registered execution roots; that experiment is no longer applied.
import java.lang.reflect.*;
import java.util.*;
import org.graalvm.nativeimage.hosted.Feature;
public final class RuntimeRoots implements Feature {
  @SuppressWarnings("unchecked")
  public List<Class<? extends Feature>> getRequiredFeatures() {
    try { return List.of((Class<? extends Feature>) Class.forName("com.oracle.svm.truffle.TruffleFeature")); }
    catch (Exception e) { throw new IllegalStateException("pinned TruffleFeature unavailable", e); }
  }
  public void afterAnalysis(AfterAnalysisAccess access) {
    try {
      Class<?> runtime = Class.forName("com.oracle.svm.graal.hosted.runtimecompilation.RuntimeCompilationFeature");
      Object feature = runtime.getMethod("singleton").invoke(null);
      Field field = runtime.getDeclaredField("invalidForRuntimeCompilation"); field.setAccessible(true);
      Map<?, ?> rejected = (Map<?, ?>) field.get(feature);
      Class<?> methodType = Class.forName("jdk.vm.ci.meta.ResolvedJavaMethod");
      Method format = methodType.getMethod("format", String.class);
      Method declaring = methodType.getMethod("getDeclaringClass");
      Method initialized = Class.forName("jdk.vm.ci.meta.ResolvedJavaType").getMethod("isInitialized");
      List<String> messages = new ArrayList<>();
      for (var entry : rejected.entrySet()) {
        String method = (String) format.invoke(entry.getKey(), "%H.%n(%p)");
        if (method.startsWith("com.zhhz.")) messages.add(method + " => " + entry.getValue()
            + "; declaringClassInitialized=" + initialized.invoke(declaring.invoke(entry.getKey())));
      }
      Collections.sort(messages);
      for (String message : messages) System.out.println("PEER_RUNTIME_REJECT " + message);
      System.out.println("PEER_RUNTIME_REJECT_TOTAL " + rejected.size());
      System.out.println("PEER_FORCED_RUNTIME_ROOTS 0");
    } catch (Exception e) { throw new IllegalStateException("pinned compiler rejection diagnostics unavailable", e); }
  }
}
