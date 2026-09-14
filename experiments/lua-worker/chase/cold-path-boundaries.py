#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Separate module lookup and error formatting from guest partial evaluation.

No VirtualFrame crosses either boundary, no method body or capability changes,
and no compiler blocklist or graph validation rule is disabled.
"""
from pathlib import Path
import hashlib,json
root=Path('.deps/trufflelua/language/src/main/java/com/zhhz/truffle/lua')
changes={
 'nodes/controlflow/LuaBlockNode.java':'    private static Object closeErrorObject(Throwable throwable) {',
 'builtins/pack/LuaPathSearcherNode.java':'    public Object doSearch(Object[] args) {',
}
rows=[]
for relative,signature in changes.items():
 p=root/relative;s=p.read_text();assert s.count(signature)==1,(relative,signature)
 before=hashlib.sha256(s.encode()).hexdigest()
 changed=s.replace(signature,'    @com.oracle.truffle.api.CompilerDirectives.TruffleBoundary\n'+signature,1)
 p.write_text(changed)
 rows.append({'file':str(p),'method':signature.strip(),'beforeSha256':before,'afterSha256':hashlib.sha256(changed.encode()).hexdigest(),'methodBodyChanged':False})
out=Path('reports/chase-truffle');out.mkdir(parents=True,exist_ok=True)
(out/'cold-path-boundaries.json').write_text(json.dumps({'scope':'Cold module lookup and exception message conversion only; no frame argument, no code-path removal','files':rows},indent=2)+'\n')
