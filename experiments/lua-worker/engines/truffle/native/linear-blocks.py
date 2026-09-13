#!/usr/bin/env python3
"""Separate optimizer experiment: statically dispatch label-free blocks only."""
from pathlib import Path
import hashlib, json
p=Path('.deps/trufflelua/language/src/main/java/com/zhhz/truffle/lua/nodes/controlflow/LuaBlockNode.java')
s=p.read_text();before=hashlib.sha256(s.encode()).hexdigest()
def once(old,new):
    global s
    if s.count(old)!=1: raise ValueError('upstream source drift: '+old)
    s=s.replace(old,new,1)
once('    private final int[] blockPath;', '    private final int[] blockPath;\n    private final boolean hasLabels;')
once('        this.labelTargets = buildLabelTargets(bodyNodes);', '        this.labelTargets = buildLabelTargets(bodyNodes);\n        this.hasLabels = !this.labelTargets.isEmpty();')
once('    public void executeVoid(VirtualFrame frame) {', '''    public void executeVoid(VirtualFrame frame) {
        if (!hasLabels) {
            executeLinear(frame);
            return;
        }''')
once('    private void close(VirtualFrame frame, Object errorObject) {', '''    // Only the fixed AST statement list is unrolled, never a guest loop or
    // the dynamically jumping goto dispatcher. Preserve error/close semantics.
    @com.oracle.truffle.api.nodes.ExplodeLoop
    private void executeLinear(VirtualFrame frame) {
        try {
            for (int i = 0; i < statements.length; i++) {
                statements[i].executeVoid(frame);
            }
        } catch (Throwable t) {
            close(frame, closeErrorObject(t));
            throw t;
        }
        close(frame, LuaNil.SINGLETON);
    }

    @com.oracle.truffle.api.nodes.ExplodeLoop
    private void close(VirtualFrame frame, Object errorObject) {''')
p.write_text(s)
Path('reports/truffle-native/linear-blocks.json').write_text(json.dumps({'file':str(p),'beforeSha256':before,'afterSha256':hashlib.sha256(s.encode()).hexdigest(),'scope':'label-free AST statement dispatch; no guest-loop unrolling or source special casing'},indent=2)+'\n')
