#!/usr/bin/env python3
"""Keep cold label-map lookup outside Truffle partial evaluation; preserve semantics."""
from pathlib import Path
import hashlib,json
p=Path('.deps/trufflelua/language/src/main/java/com/zhhz/truffle/lua/nodes/controlflow/LuaBlockNode.java')
s=p.read_text();before=hashlib.sha256(s.encode()).hexdigest()
assert s.count('labelTargets.get(')==2
s=s.replace('labelTargets.get(e.getLabel())','lookupLabel(e.getLabel())').replace('labelTargets.get(nested.getLabel())','lookupLabel(nested.getLabel())')
needle='    private void close(VirtualFrame frame, Object errorObject) {'
assert s.count(needle)==1
s=s.replace(needle,'''    // Cold goto dispatch must not partially evaluate java.util.HashMap's
    // recursive tree-bin lookup into every compiled guest function.
    @com.oracle.truffle.api.CompilerDirectives.TruffleBoundary
    private Integer lookupLabel(TruffleString label) {
        return labelTargets.get(label);
    }

'''+needle)
p.write_text(s)
Path('reports/truffle/label-boundary.json').write_text(json.dumps({'source':str(p),'beforeSha256':before,'afterSha256':hashlib.sha256(s.encode()).hexdigest(),'change':'cold label lookup only; no Lua semantics or body loop changes'},indent=2)+'\n')
