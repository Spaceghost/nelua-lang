#!/usr/bin/env python3
"""Rebuild a frozen fresh-worker control and resident-app lifecycle variants."""
import hashlib, json, os, pathlib, shutil, subprocess
from dispatch import optimize
ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE = 'b73f74cae2a228768d482b2c0640e9decc619e8b'
OUT = ROOT / 'dist/lifecycle'

def once(text, old, new):
    if text.count(old) != 1: raise ValueError(f'frozen source drift: {old[:90]!r}')
    return text.replace(old, new, 1)

def resident_bridge(source):
    start = source.index('  luaL_requiref(L, "_G"')
    end = source.index('  vm->co = lua_newthread(L);', start)
    sandbox = source[start:end]
    source = source[:start] + '  open_sandbox(L);\n' + source[end:]
    start = source.index('  lua_createtable(L, 0, 3);', source.index('static int prepare('))
    end = source.index('  lua_xmove(L, vm->co, 5);', start)
    values = source[start:end]
    source = source[:start] + '  request_values(L, vm);\n' + source[end:]
    helper = 'static void open_sandbox(lua_State *L) {\n' + sandbox + '}\n'
    helper += 'static void request_values(lua_State *L, Vm *vm) {\n' + values + '}\n'
    source = once(source, 'static int prepare(lua_State *L) {', helper + 'static int prepare(lua_State *L) {')
    source = once(source, '#include "kernel.h"', '#include "kernel.h"\n#include "lifecycle.h"')
    source = once(source, 'void bridge_close(void *p) {', 'static void legacy_bridge_close(void *p) {')
    return source + '\n' + (ROOT/'lifecycle/resident.c').read_text()

def resident_js(source):
    source = once(source, '  stats() {', (ROOT/'lifecycle/runtime-methods.mjs').read_text() + '  stats() {')
    source = once(source, 'wasmBytes: this.e.memory.buffer.byteLength, admitted:',
        'residentLuaBytes: this.e.wa_bytes(), requestRefs: this.e.wa_pending(), apps: this.e.wa_app_count(), appLoads: this.e.wa_load_count(),\n    wasmBytes: this.e.memory.buffer.byteLength, admitted:')
    source = once(source, "      const code = bounded(source, LIMIT, 'source');", '      const app = this.loadApplication(source);')
    source = once(source, '''      const seed = crypto.getRandomValues(new Uint32Array(1))[0];
      let state = this.withBytes([code, method, url, body], (...args) => this.e.lw_start(id, ...args, seed));''',
        '      let state = this.withBytes([method, url, body], (...args) => this.e.wa_start(id, app, ...args));')
    return source

def run(args, cwd, path):
    with path.open('w') as f:
        result = subprocess.run(args, cwd=cwd, stdout=f, stderr=subprocess.STDOUT, timeout=240)
    if result.returncode:
        print(path.read_text()[-20000:], flush=True)
        raise SystemExit(f'{path}: {result.returncode}')

if __name__ == '__main__':
    os.chdir(ROOT); OUT.mkdir(parents=True, exist_ok=True)
    checkout = subprocess.check_output(['git','rev-parse','--show-toplevel'], text=True).strip()
    archive = subprocess.run(['git','archive',f'{BASE}:experiments/lua-worker'], cwd=checkout, capture_output=True, check=True).stdout
    frozen = ROOT/'.deps/lifecycle-frozen'
    if frozen.exists(): shutil.rmtree(frozen)
    frozen.mkdir()
    subprocess.run(['tar','-x','-C',str(frozen)], input=archive, check=True)
    assert (frozen/'scripts/build.sh').is_file()
    manifest = {'baseline':BASE, 'head':subprocess.check_output(['git','rev-parse','HEAD'], text=True).strip(),
                'toolchain':json.loads((ROOT/'toolchain.json').read_text()), 'variants':[]}
    for name, warm, profile in [('fresh',False,'balanced'),('resident',True,'balanced'),('resident-o3',True,'cpu')]:
        target = OUT/name
        if target.exists(): shutil.rmtree(target)
        shutil.copytree(frozen, target)
        shutil.copytree(ROOT/'lifecycle', target/'lifecycle')
        (target/'.deps').symlink_to(ROOT/'.deps', target_is_directory=True)
        (target/'node_modules').symlink_to(ROOT/'node_modules', target_is_directory=True)
        (target/'reports').mkdir(exist_ok=True)
        if warm:
            p=target/'core/kernel.nelua'; p.write_text(p.read_text()+'\n'+(ROOT/'lifecycle/application.nelua').read_text())
            p=target/'core/lua_bridge.c'; p.write_text(resident_bridge(p.read_text()))
            shutil.copyfile(ROOT/'lifecycle/api.h',target/'core/lifecycle.h')
            p=target/'host/runtime.mjs'; p.write_text(optimize(resident_js(p.read_text())))
            # The selected source must equal the measured lazy adapter, not merely resemble it.
            expected='fcdfa78e6725bd72ab83626f5af5774a9baa821c6119a86d6c1a3a88dbf0a98e'
            assert hashlib.sha256(p.read_bytes()).hexdigest()==expected
            shutil.copyfile(ROOT/'lifecycle/dispatch-contracts.mjs',target/'lifecycle/dispatch-contracts.mjs')
            p=target/'lifecycle/contracts.mjs'
            p.write_text("import {extraSuite} from './dispatch-contracts.mjs';\n"+once(p.read_text(),
                '  return {warm,passed};','  passed.push(...await extraSuite(make));\n  return {warm,passed};'))
            p=target/'lifecycle/workerd-tests.mjs'
            p.write_text(once(p.read_text(),'(name="contracts.mjs",esModule=embed "contracts.mjs"),',
                '(name="contracts.mjs",esModule=embed "contracts.mjs"),(name="dispatch-contracts.mjs",esModule=embed "dispatch-contracts.mjs"),'))
            p=target/'scripts/build.sh'
            extras=['wa_open','wa_load','wa_start','wa_release','wa_bytes','wa_pending','wa_app_count','wa_error_data','wa_error_size','wa_load_count','wa_collect']
            s=once(p.read_text(),'"_lw_bytes"]', '"_lw_bytes",'+','.join('"_'+n+'"' for n in extras)+']')
            native=s[s.index('cc -std=c11'):s.index('emcc --version')]
            s += '\n'+native.replace('tests/native.c','lifecycle/native.c').replace('dist/native-contract','dist/lifecycle-native')
            p.write_text(s)
        shutil.copyfile(ROOT/'perf/regression.test.mjs',target/'tests/performance-regression.test.mjs')
        print(f'BUILD {name} WASM_PROFILE={profile}',flush=True)
        run(['env',f'WASM_PROFILE={profile}','bash','scripts/build.sh'],target,target/'reports/build.log')
        run(['timeout','60','./dist/native-contract'],target,target/'reports/native.txt')
        if warm:
            run(['timeout','60','./dist/lifecycle-native'],target,target/'reports/lifecycle-native.txt')
        else:
            run(['timeout','60','node','--test','tests/runtime.test.mjs','tests/performance-regression.test.mjs'],target,target/'reports/original-tests.tap')
        run(['timeout','90','node','lifecycle/node-tests.mjs'],target,target/'reports/lifecycle-node.txt')
        run(['timeout','90','node','lifecycle/workerd-tests.mjs'],target,target/'reports/lifecycle-workerd.txt')
        if name == 'resident':
            assert hashlib.sha256((target/'dist/kernel.wasm').read_bytes()).hexdigest() == '8bef38601a1b10a04e6e5f25c324f7e09e1f8ee5313b1ea9b72a5eb2fce3337c'
        files=['core/kernel.nelua','core/lua_bridge.c','host/runtime.mjs','dist/kernel.wasm']
        manifest['variants'].append({'name':name,'warm':warm,'profile':profile,'contract':'PASS',
            'wasmBytes':(target/'dist/kernel.wasm').stat().st_size,
            'sha256':{p:hashlib.sha256((target/p).read_bytes()).hexdigest() for p in files}})
        (OUT/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        print(f'PASS {name}: original native, lifecycle contracts in Node and stock workerd',flush=True)
