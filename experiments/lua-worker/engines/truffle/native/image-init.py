#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Allow generated interop metadata and fixed type descriptors in the image."""
from pathlib import Path
import json, subprocess, sys, zipfile
profile=sys.argv[1]
jar=Path('dist/engines/truffle')/profile/'language.jar'
metadata=['com.zhhz.truffle.lua.LuaLanguageProvider',
          'com.zhhz.truffle.lua.runtime.LuaType']
suffixes=('Gen$InteropLibraryExports.class','Gen$InteropLibraryExports$Cached.class','Gen$InteropLibraryExports$Uncached.class')
with zipfile.ZipFile(jar) as z:
    names=metadata+sorted(n[:-6].replace('/','.') for n in z.namelist() if n.startswith('com/zhhz/truffle/lua/') and n.endswith(suffixes))
assert len(names)==53, 'pinned metadata changed; review initialization list'
rows=[]
for name in names:
    declaration=subprocess.check_output(['javap','-private','-classpath',str(jar),name],text=True)
    fields=[line.strip() for line in declaration.splitlines() if 'static ' in line and ';' in line and '(' not in line and 'static {}' not in line]
    for field in fields:
        assert 'final ' in field, (name,field)
        if name.endswith('.LuaType'):
            # Fixed descriptors contain a name and a capture-free type predicate.
            # PRECEDENCE is a fixed descriptor array; no application values.
            assert 'com.zhhz.truffle.lua.runtime.LuaType' in field, (name,field)
        else:
            # Class metadata, stateless dispatch helpers and field descriptors.
            # Never a Lua context, application value, executor or I/O instance.
            assert any(token in field for token in ('$assertionsDisabled;', 'FinalBitSet ENABLED_MESSAGES;',
                '$Uncached UNCACHED;', '$Cached CACHE;', 'InlineSupport$StateField ',
                'InlineSupport$ReferenceField<', 'InlinedBranchProfile ')), (name,field)
    rows.append({'class':name,'staticFields':fields,'declaration':declaration})
out=Path('reports/truffle-native')
(out/(profile+'-image-init.json')).write_text(json.dumps({'classes':rows,'excluded':'LuaLanguage, LuaContext, application state, host globals; no package-wide initialization'},indent=2)+'\n')
print(','.join(names))
