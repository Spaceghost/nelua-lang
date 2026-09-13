#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Isolate immutable Truffle reference registrations from runtime app state."""
from pathlib import Path
import hashlib,json
root=Path('.deps/trufflelua/language/src/main/java/com/zhhz/truffle/lua')
rows=[]
for file,kind,target in [('LuaLanguage.java','LanguageReference','LuaLanguage'),('runtime/LuaContext.java','ContextReference','LuaContext')]:
    p=root/file;s=p.read_text();before=hashlib.sha256(s.encode()).hexdigest()
    old=f'    private static final {kind}<{target}> REFERENCE = {kind}.create(LuaLanguage.class);'
    new=f'''    // Registration metadata only. The nested holder can be initialized by
    // Native Image without creating a LuaLanguage or application LuaContext.
    private static final class ReferenceMetadata {{
        static final {kind}<{target}> REFERENCE = {kind}.create(LuaLanguage.class);
    }}'''
    assert s.count(old)==1,(file,'reference declaration')
    s=s.replace(old,new)
    assert s.count('return REFERENCE.get(node);')==1,(file,'reference use')
    s=s.replace('return REFERENCE.get(node);','return ReferenceMetadata.REFERENCE.get(node);')
    p.write_text(s)
    rows.append({'file':str(p),'beforeSha256':before,'afterSha256':hashlib.sha256(s.encode()).hexdigest(),'registration':kind})
Path('reports/truffle-native/reference-metadata.json').write_text(json.dumps({'scope':'Truffle language/context reference registrations; no application context construction','files':rows},indent=2)+'\n')
