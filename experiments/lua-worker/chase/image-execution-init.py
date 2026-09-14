#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Audit class-only initialization needed by GraalVM 25.0.1 guest graphs.

No language context, source AST or worker is constructed here. Unknown static
state is rejected/excluded, not covered by a package-wide initialization rule.
"""
from pathlib import Path
import hashlib, json, re, subprocess, sys, zipfile
profile = sys.argv[1] if len(sys.argv) > 1 else 'linear-lib'
jar = Path('dist/engines/truffle') / profile / 'language.jar'
exclude = {
    'com.zhhz.truffle.lua.nodes.controlflow.LuaNopNode': 'mutable Node singleton',
    'com.zhhz.truffle.lua.nodes.interop.NodeObjectDescriptor$ReadDescriptor': 'descriptor singleton not needed for this execution candidate',
    'com.zhhz.truffle.lua.nodes.interop.NodeObjectDescriptor$WriteDescriptor': 'descriptor singleton not needed for this execution candidate',
}
with zipfile.ZipFile(jar) as z:
    names = sorted(n[:-6].replace('/', '.') for n in z.namelist()
        if n.startswith('com/zhhz/truffle/lua/') and n.endswith('.class')
        and not re.search(r'Gen(?:\$[^/]*)?\.class$', n)
        and ('/nodes/' in n or '/runtime/' in n or n.endswith('/builtins/BuiltinRootNode.class'))
        and 'LuaContext' not in n and 'ReferenceMetadata' not in n)
    class_hashes = {n: hashlib.sha256(z.read(n.replace('.', '/') + '.class')).hexdigest() for n in names}
assert len(names) == 118, 'pinned execution class set changed; review before use'
output = subprocess.check_output(['javap', '-private', '-c', '-classpath', str(jar), *names], text=True)
parts = re.split(r'(?m)^Compiled from ', output)[1:]
rows, admitted = [], []
for chunk in parts:
    header = chunk.splitlines()[1]
    match = re.search(r'(?:class|interface) ([\w.$]+)', header)
    assert match, header
    name = match.group(1)
    fields = [l.strip() for l in chunk.splitlines() if 'static ' in l and ';' in l and '(' not in l and 'static {}' not in l and not re.match(r'\s*\d+:', l)]
    has_init = 'static {};' in chunk
    row = {'class': name, 'staticFields': fields, 'hasInitializer': has_init,
           'classSha256': class_hashes[name], 'bytecode': 'Compiled from ' + chunk}
    if name in exclude:
        row['excluded'] = exclude[name]
    else:
        for field in fields:
            # Existing boolean wrappers have mutable lazy fields, but no class
            # initializer. Only JVM-default nulls are captured, never a context's
            # boolean instances. Their broader semantics remain a known research
            # runtime concern; this experiment does not create or rewrite them.
            if name.endswith('.LuaBoolean'):
                assert not has_init and field in {
                    'public static com.zhhz.truffle.lua.runtime.LuaBoolean TRUE;',
                    'public static com.zhhz.truffle.lua.runtime.LuaBoolean FALSE;'}, field
                continue
            assert 'final ' in field, (name, field)
            allowed = any(t in field for t in (
                ' int ', ' long ', ' boolean ', 'java.lang.String ',
                'com.oracle.truffle.api.strings.TruffleString '))
            allowed |= name.endswith('.LuaNil') and any(t in field for t in (
                'com.oracle.truffle.api.object.Shape NIL_SHAPE;',
                'com.zhhz.truffle.lua.runtime.LuaNil SINGLETON;'))
            allowed |= name.endswith(('.LuaBreakException', '.LuaContinueException')) and field.endswith(' SINGLETON;')
            allowed |= name.endswith('.LuaCloseSlotNode$1') and 'int[] $SwitchMap$' in field
            allowed |= name.endswith('.LuaType') and 'com.zhhz.truffle.lua.runtime.LuaType' in field
            assert allowed, (name, field)
        admitted.append(name)
        row['admitted'] = True
    rows.append(row)
assert len(rows) == len(names) and {r['class'] for r in rows} == set(names)
assert 'com.zhhz.truffle.lua.nodes.LuaAstRootNode' in admitted
assert 'com.zhhz.truffle.lua.runtime.LuaNil' in admitted
assert all('ReferenceMetadata' not in n and 'LuaContext' not in n and n != 'com.zhhz.truffle.lua.LuaLanguage' for n in admitted)
out = Path('reports/chase-truffle'); out.mkdir(parents=True, exist_ok=True)
(out / 'execution-init-audit.json').write_text(json.dumps({
    'languageJarSha256': hashlib.sha256(jar.read_bytes()).hexdigest(),
    'classes': rows, 'admittedCount': len(admitted),
    'policy': 'Explicit class list only; preserve runtime language-index holders. No precreated worker, application context, source AST, socket or thread.'
}, indent=2) + '\n')
print(','.join(admitted))
