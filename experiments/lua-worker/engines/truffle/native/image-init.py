#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Initialize audited generated Truffle DSL/interop metadata, never app state."""
from pathlib import Path
import json, re, subprocess, sys, zipfile
profile=sys.argv[1]
jar=Path('dist/engines/truffle')/profile/'language.jar'
metadata=['com.zhhz.truffle.lua.LuaLanguageProvider',
          'com.zhhz.truffle.lua.runtime.LuaType',
          'com.zhhz.truffle.lua.runtime.LuaType$TypeCheck']
# Language/ContextReference holders are intentionally NOT image-initialized.
# In GraalVM 25.0.1, their final index can become RESERVED_NULL (-1) before
# language discovery. Resolve them in the launched runtime, not the builder.
# Generated DSL nodes still need their immutable InlineSupport registrations.
with zipfile.ZipFile(jar) as z:
    names=metadata+sorted(n[:-6].replace('/','.') for n in z.namelist() if n.startswith('com/zhhz/truffle/lua/') and re.search(r'Gen(?:\$[^/]*)?\.class$', n))
assert len(names)==178, 'pinned metadata changed; review initialization list'
output=subprocess.check_output(['javap','-private','-classpath',str(jar),*names],text=True)
declarations={}
for chunk in re.split(r'(?m)^Compiled from ',output)[1:]:
    header=chunk.splitlines()[1]
    match=re.search(r'(?:class|interface) ([\w.$]+)',header)
    assert match, header
    declarations[match.group(1)]='Compiled from '+chunk
assert set(declarations)==set(names), 'incomplete javap declarations'
rows=[]
for name in names:
    declaration=declarations[name]
    fields=[line.strip() for line in declaration.splitlines() if 'static ' in line and ';' in line and '(' not in line and 'static {}' not in line]
    if name.endswith('$TypeCheck'):
        assert not fields, 'type-predicate interface unexpectedly has state'
    for field in fields:
        assert 'final ' in field, (name,field)
        if name.endswith('.LuaType'):
            assert 'com.zhhz.truffle.lua.runtime.LuaType' in field, (name,field)
        else:
            assert any(token in field for token in ('$assertionsDisabled;', 'FinalBitSet ENABLED_MESSAGES;',
                '$Uncached UNCACHED;', '$Cached CACHE;', 'InlineSupport$StateField ',
                'InlineSupport$ReferenceField<', 'InlinedBranchProfile ',
                'LibraryFactory<com.oracle.truffle.api.interop.InteropLibrary> ',
                'LibraryFactory<com.oracle.truffle.api.library.DynamicDispatchLibrary> ',
                'LibraryFactory<com.oracle.truffle.api.object.DynamicObjectLibrary> ',
                'LuaToMemberNode INLINED_', 'LuaToTruffleStringNode INLINED_')), (name,field)
    rows.append({'class':name,'staticFields':fields,'declaration':declaration})
out=Path('reports/truffle-native')
(out/(profile+'-image-init.json')).write_text(json.dumps({'classes':rows,'excluded':'Language/ContextReference holders, LuaLanguage, LuaContext, application state, host globals; no package-wide initialization'},indent=2)+'\n')
print(','.join(names))
