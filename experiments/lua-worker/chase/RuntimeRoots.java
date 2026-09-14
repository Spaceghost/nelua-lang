// SPDX-License-Identifier: MIT
// Build-only, pinned GraalVM 25.0.1 experiment. No guest state is precreated.
import java.lang.reflect.*;
import java.util.*;
import java.util.jar.JarFile;
import java.io.File;
import org.graalvm.nativeimage.hosted.Feature;
public final class RuntimeRoots implements Feature {
  @SuppressWarnings("unchecked")
  public List<Class<? extends Feature>> getRequiredFeatures(){
    try{return List.of((Class<? extends Feature>)Class.forName("com.oracle.svm.truffle.TruffleFeature"));}
    catch(Exception e){throw new IllegalStateException("pinned TruffleFeature unavailable",e);}
  }
  static List<Method> entryMethods() throws Exception {
    Class<?> anchor=Class.forName("com.zhhz.truffle.lua.nodes.LuaAstRootNode",false,RuntimeRoots.class.getClassLoader());
    File file=new File(anchor.getProtectionDomain().getCodeSource().getLocation().toURI());
    List<Method> methods=new ArrayList<>();
    try(JarFile jar=new JarFile(file)){
      for(var entries=jar.entries();entries.hasMoreElements();){
        String name=entries.nextElement().getName();
        if(!name.startsWith("com/zhhz/truffle/lua/nodes/")||!name.endsWith(".class"))continue;
        Class<?> type=Class.forName(name.substring(0,name.length()-6).replace('/','.'),false,anchor.getClassLoader());
        for(Method m:type.getDeclaredMethods()){
          int modifiers=m.getModifiers();
          if(!m.getName().startsWith("execute")||Modifier.isAbstract(modifiers)||Modifier.isNative(modifiers)||m.isBridge())continue;
          boolean frame=Arrays.stream(m.getParameterTypes()).anyMatch(p->p.getName().equals("com.oracle.truffle.api.frame.VirtualFrame"));
          boolean boundary=Arrays.stream(m.getDeclaredAnnotations()).anyMatch(a->a.annotationType().getName().endsWith("CompilerDirectives$TruffleBoundary"));
          if(frame&&!boundary)methods.add(m);
        }
      }
    }
    // The broader AST graph reaches boolean boxing during deoptimization.
    // Register the generic static target explicitly so its deopt version is
    // parsed as a root as well; never disable the compiler's consistency check.
    methods.add(Class.forName("com.zhhz.truffle.lua.runtime.LuaBoolean",false,anchor.getClassLoader()).getDeclaredMethod("valueOf",boolean.class));
    methods.sort(Comparator.comparing(Method::toGenericString));
    if(methods.isEmpty())throw new IllegalStateException("no generic AST execution methods discovered");
    return methods;
  }
  public void beforeAnalysis(BeforeAnalysisAccess access){
    try{
      Class<?> runtime=Class.forName("com.oracle.svm.graal.hosted.runtimecompilation.RuntimeCompilationFeature");
      Object feature=runtime.getMethod("singleton").invoke(null);
      Object meta=Class.forName("com.oracle.svm.hosted.FeatureImpl$BeforeAnalysisAccessImpl").getMethod("getMetaAccess").invoke(access);
      Method lookup=Class.forName("jdk.vm.ci.meta.MetaAccessProvider").getMethod("lookupJavaMethod",Executable.class);
      // Select the documented pinned signature, not reflection iteration order:
      // the builder exposes another overload with two parameters.
      Method prepare=runtime.getMethod("prepareMethodForRuntimeCompilation",
          Class.forName("jdk.vm.ci.meta.ResolvedJavaMethod"),
          Class.forName("com.oracle.svm.hosted.FeatureImpl$BeforeAnalysisAccessImpl"));
      List<Method> methods=entryMethods();
      for(Method guest:methods){prepare.invoke(feature,lookup.invoke(meta,guest),access);System.out.println("PEER_RUNTIME_ROOT "+guest.toGenericString());}
      System.out.println("PEER_RUNTIME_ROOT_COUNT "+methods.size());
    }catch(Exception e){throw new IllegalStateException("native AST graph registration failed",e);}
  }
  public void afterAnalysis(AfterAnalysisAccess access){
    try{
      Class<?> runtime=Class.forName("com.oracle.svm.graal.hosted.runtimecompilation.RuntimeCompilationFeature");
      Object feature=runtime.getMethod("singleton").invoke(null);
      Field field=runtime.getDeclaredField("invalidForRuntimeCompilation");field.setAccessible(true);
      Map<?,?> rejected=(Map<?,?>)field.get(feature);
      Method format=Class.forName("jdk.vm.ci.meta.ResolvedJavaMethod").getMethod("format",String.class);
      List<String> messages=new ArrayList<>();
      for(var entry:rejected.entrySet()){
        String method=(String)format.invoke(entry.getKey(),"%H.%n(%p)");
        if(method.startsWith("com.zhhz."))messages.add(method+" => "+entry.getValue());
      }
      Collections.sort(messages);for(String message:messages)System.out.println("PEER_RUNTIME_REJECT "+message);
      System.out.println("PEER_RUNTIME_REJECT_TOTAL "+rejected.size());
    }catch(Exception e){throw new IllegalStateException("pinned compiler rejection diagnostics unavailable",e);}
  }
  public static void main(String[] args) throws Exception {
    for(Method m:entryMethods())System.out.println(m.toGenericString());
  }
}
