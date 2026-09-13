// SPDX-License-Identifier: MIT
// Trusted, fixed-source synchronous qualification host, not the async worker ABI.
import com.sun.net.httpserver.*;
import org.graalvm.polyglot.*;
import org.graalvm.polyglot.io.IOAccess;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;

public final class TrufflePeer {
  static final int LIMIT=65536;
  static final Map<String,String> PROGRAMS=new LinkedHashMap<>();
  static {
    PROGRAMS.put("hello", "return function() return 'ok' end");
    PROGRAMS.put("cpu", "return function(n) local sum=0; for i=1,n do sum=sum+i%97 end; return sum end");
    PROGRAMS.put("echo", "return function(s) return s end");
    PROGRAMS.put("counter", "local n=0; return function() n=n+1; return n end");
  }
  static Context context(){
    return Context.newBuilder("lua").allowAllAccess(false).allowIO(IOAccess.NONE)
      .allowHostAccess(HostAccess.NONE).allowHostClassLookup(name->false)
      .allowCreateProcess(false).allowCreateThread(false).build();
  }
  static Value eval(Context c,String name,String s)throws Exception{
    return c.eval(Source.newBuilder("lua",s,name+".lua").build());
  }
  static String json(String s){StringBuilder b=new StringBuilder("\"");for(char c:s.toCharArray()){switch(c){case '\\':b.append("\\\\");break;case '"':b.append("\\\"");break;case '\n':b.append("\\n");break;case '\r':b.append("\\r");break;case '\t':b.append("\\t");break;default:if(c<32)b.append(String.format("\\u%04x",(int)c));else b.append(c);}}return b.append('"').toString();}
  static String value(Value v){if(v.isString())return v.asString();if(v.fitsInLong())return Long.toString(v.asLong());if(v.isBoolean())return Boolean.toString(v.asBoolean());if(v.isNull())return "nil";return v.toString();}
  static void probe(Path output)throws Exception{
    String[][] cases={
      {"arithmetic","return 6*7","42"},
      {"closure","local n=0;local f=function() n=n+1;return n end;f();return f()","2"},
      {"multi-return","local function f()return 3,4 end;local a,b=f();return a+b","7"},
      {"nil-false","return (nil or false)==false","true"},
      {"integer-division","return 7//2","3"},
      {"utf8-byte-length","return #'é'","2"},
      {"coroutine-required","return type(coroutine)","table"}
    };
    List<String> rows=new ArrayList<>();boolean core=true;String engine;
    try(Context c=context()){
      engine=c.getEngine().getImplementationName()+" "+c.getEngine().getVersion();
      for(String[] q:cases){String actual="",error="";try{actual=value(eval(c,q[0],q[1]));}catch(Exception e){error=e.toString();}
        boolean pass=error.isEmpty()&&actual.equals(q[2]);if(q[0].equals("arithmetic")||q[0].equals("closure"))core&=pass;
        rows.add("{\"case\":"+json(q[0])+",\"source\":"+json(q[1])+",\"expected\":"+json(q[2])+",\"actual\":"+json(actual)+",\"error\":"+json(error)+",\"pass\":"+pass+"}");
      }
      Value cpu=eval(c,"cpu-handler",PROGRAMS.get("cpu"));
      for(int n=10000;n<10200;n++){long sum=0;for(int i=1;i<=n;i++)sum+=i%97;if(cpu.execute(n).asLong()!=sum)throw new AssertionError("input-dependent CPU mismatch");}
    }
    String result="{\"engine\":"+json(engine)+",\"coreQualified\":"+core+",\"asyncWorkerQualified\":false,\"binaryStringQualified\":false,\"cpuCheckedCalls\":200,\"cases\":["+String.join(",",rows)+"]}";
    Files.writeString(output,result+"\n");System.out.println(result);if(!core)throw new AssertionError("synchronous core qualification failed");
  }
  static void respond(HttpExchange x,int status,byte[] body)throws Exception{
    x.getResponseHeaders().set("Content-Type","text/plain; charset=utf-8");
    if(x.getRequestMethod().equals("HEAD")){x.sendResponseHeaders(status,-1);x.close();return;}
    x.sendResponseHeaders(status,body.length==0?-1:body.length);if(body.length>0)x.getResponseBody().write(body);x.close();
  }
  public static void main(String[] args)throws Exception{
    if(args.length==2&&args[0].equals("--probe")){probe(Path.of(args[1]));return;}
    if(args.length!=1)throw new IllegalArgumentException("usage: TrufflePeer PORT | --probe OUTPUT");
    Context c=context();Map<String,Value> functions=new HashMap<>();
    for(var e:PROGRAMS.entrySet())functions.put(e.getKey(),eval(c,e.getKey()+"-handler",e.getValue()));
    long[] requests={0};HttpServer server=HttpServer.create(new InetSocketAddress("127.0.0.1",Integer.parseInt(args[0])),16);
    // Only one thread enters this context; a bounded host queue is not guest coroutine support.
    server.setExecutor(new ThreadPoolExecutor(1,1,0,TimeUnit.SECONDS,new ArrayBlockingQueue<>(8),new ThreadPoolExecutor.AbortPolicy()));
    server.createContext("/",x->{try{
      String path=x.getRequestURI().getPath();
      if(path.equals("/_peer/stats")){respond(x,200,("{\"active\":0,\"admitted\":0,\"requests\":"+requests[0]+",\"asyncSupported\":false,\"binaryStrings\":false}").getBytes(StandardCharsets.UTF_8));return;}
      if(!Set.of("/hello","/cpu","/echo","/counter").contains(path)){respond(x,501,"UNSUPPORTED: asynchronous worker capability".getBytes(StandardCharsets.UTF_8));return;}
      byte[] bytes=x.getRequestBody().readNBytes(LIMIT+1);if(bytes.length>LIMIT){respond(x,413,new byte[0]);return;}
      // This implementation represents strings as Java strings. Do not silently
      // substitute UTF-8 replacement characters for arbitrary guest byte strings.
      if(path.equals("/echo"))for(byte b:bytes)if(b<0){respond(x,501,"UNSUPPORTED: binary string fidelity".getBytes(StandardCharsets.UTF_8));return;}
      String s=new String(bytes,StandardCharsets.UTF_8),answer;
      synchronized(c){
        if(path.equals("/cpu")){int n;try{n=Integer.parseInt(s);}catch(NumberFormatException e){respond(x,400,new byte[0]);return;}if(n<1||n>20000){respond(x,400,new byte[0]);return;}answer=value(functions.get("cpu").execute(n));}
        else if(path.equals("/echo"))answer=value(functions.get("echo").execute(s));
        else answer=value(functions.get(path.substring(1)).execute());
        requests[0]++;
      }
      byte[] result=answer.getBytes(StandardCharsets.UTF_8);if(result.length>LIMIT)throw new IllegalStateException("response bound");respond(x,200,result);
    }catch(Exception e){System.err.println(e);try{respond(x,500,"Truffle handler failed".getBytes(StandardCharsets.UTF_8));}catch(Exception ignored){x.close();}}});
    Runtime.getRuntime().addShutdownHook(new Thread(()->{server.stop(0);c.close(true);}));
    server.start();System.out.println("READY Truffle Lua "+c.getEngine().getImplementationName()+" "+c.getEngine().getVersion());
  }
}
