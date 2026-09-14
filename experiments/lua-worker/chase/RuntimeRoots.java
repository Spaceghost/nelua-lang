// SPDX-License-Identifier: MIT
// Build-only, pinned GraalVM 25.0.1 experiment. No guest state is precreated.
import java.lang.reflect.*;
import java.util.List;
import org.graalvm.nativeimage.hosted.Feature;
public final class RuntimeRoots implements Feature {
  @SuppressWarnings("unchecked")
  public List<Class<? extends Feature>> getRequiredFeatures(){
    try{return List.of((Class<? extends Feature>)Class.forName("com.oracle.svm.truffle.TruffleFeature"));}
    catch(Exception e){throw new IllegalStateException("pinned TruffleFeature unavailable",e);}
  }
  public void beforeAnalysis(BeforeAnalysisAccess access){
    try{
      Class<?> runtime=Class.forName("com.oracle.svm.graal.hosted.runtimecompilation.RuntimeCompilationFeature");
      Object feature=runtime.getMethod("singleton").invoke(null);
      Object meta=Class.forName("com.oracle.svm.hosted.FeatureImpl$BeforeAnalysisAccessImpl").getMethod("getMetaAccess").invoke(access);
      Class<?> metaApi=Class.forName("jdk.vm.ci.meta.MetaAccessProvider");
      Method guest=Class.forName("com.zhhz.truffle.lua.nodes.LuaAstRootNode").getMethod("execute",Class.forName("com.oracle.truffle.api.frame.VirtualFrame"));
      Object resolved=metaApi.getMethod("lookupJavaMethod",Executable.class).invoke(meta,guest);
      Method prepare=null;for(Method m:runtime.getMethods())if(m.getName().equals("prepareMethodForRuntimeCompilation")&&m.getParameterCount()==2)prepare=m;
      if(prepare==null)throw new NoSuchMethodException("prepareMethodForRuntimeCompilation");
      prepare.invoke(feature,resolved,access);
      System.out.println("PEER_RUNTIME_ROOT "+guest.toGenericString());
    }catch(Exception e){throw new IllegalStateException("native guest-root registration failed",e);}
  }
}
