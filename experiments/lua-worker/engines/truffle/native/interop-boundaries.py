#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Keep seven interop inspection helpers out of guest partial evaluation.

GraalVM 25.0.1 otherwise creates deoptimization targets without parsed graphs.
Bodies and exposed operations are preserved. Applied to both JVM/native controls.
"""
from pathlib import Path
import hashlib,json
root=Path('.deps/trufflelua/language/src/main/java/com/zhhz/truffle/lua/runtime')
changes={
 'LuaBoolean.java':['    public String asString() {'],
 'LuaFunction.java':['        static TriState doLuaFunction(LuaFunction receiver, LuaFunction other) {'],
 'LuaMultiValue.java':['    boolean isArrayElementReadable(long index) {'],
 'LuaTable.java':['    Object getMembers(boolean includeInternal, @CachedLibrary("this") DynamicObjectLibrary objLib) {','    boolean isArrayElementReadable(long index) {'],
 'LuaTableIterator.java':['    boolean hasIteratorNextElement() {'],
 'LuaTableKeys.java':['    public boolean isArrayElementReadable(long index) {'],
}
rows=[]
for file,needles in changes.items():
 p=root/file;s=p.read_text();before=hashlib.sha256(s.encode()).hexdigest()
 for old in needles:
  assert s.count(old)==1,(file,old)
  indent=old[:len(old)-len(old.lstrip())]
  s=s.replace(old,indent+'@com.oracle.truffle.api.CompilerDirectives.TruffleBoundary\n'+old,1)
 p.write_text(s)
 rows.append({'file':str(p),'beforeSha256':before,'afterSha256':hashlib.sha256(s.encode()).hexdigest(),'methods':[n.strip() for n in needles]})
Path('reports/truffle-native/interop-boundaries.json').write_text(json.dumps({'reason':'GraalVM 25.0.1 missing parsed graphs for interop deoptimization targets','methodBodiesChanged':False,'guestExecutionOrCompilerDisabled':False,'files':rows},indent=2)+'\n')
