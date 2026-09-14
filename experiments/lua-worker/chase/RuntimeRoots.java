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
      Method prepare=null;for(Method m:runtime.getMethods())if(m.getName().equals("prepareMethodForRuntimeCompilation")&&m.getParameterCount()==2)prepare=m;
      if(prepare==null)throw new NoSuchMethodException("prepareMethodForRuntimeCompilation");
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
      rejected.entrySet().stream().filter(e->e.getKey().toString().contains("com.zhhz.")).map(Object::toString).sorted().forEach(s->System.out.println("PEER_RUNTIME_REJECT "+s));
      System.out.println("PEER_RUNTIME_REJECT_TOTAL "+rejected.size());
    }catch(Exception e){throw new IllegalStateException("pinned compiler rejection diagnostics unavailable",e);}
  }
  public static void main(String[] args) throws Exception {
    for(Method m:entryMethods())System.out.println(m.toGenericString());
  }
}
