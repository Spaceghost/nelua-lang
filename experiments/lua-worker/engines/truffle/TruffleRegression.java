// SPDX-License-Identifier: MIT
import org.graalvm.polyglot.Context;
public final class TruffleRegression {
  public static void main(String[] args)throws Exception{
    String[][] cases={
      {"local n=0; ::again:: n=n+1; if n<3 then goto again end; return n","3"},
      {"local n=0; do n=7; goto done end; ::done:: return n","7"},
      {"local n=0; local function f() ::again:: n=n+1; if n<4 then goto again end; return n end;return f()","4"}
    };
    try(Context c=TrufflePeer.context()){
      for(int i=0;i<cases.length;i++){
        String actual=TrufflePeer.value(TrufflePeer.eval(c,"label-regression-"+i,cases[i][0]));
        if(!actual.equals(cases[i][1]))throw new AssertionError("label regression "+i+": "+actual);
      }
    }
    System.out.println("{\"labelRegressions\":3,\"status\":\"PASS\"}");
  }
}
