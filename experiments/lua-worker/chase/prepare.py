#!/usr/bin/env python3
"""Frozen lifecycle controls, output-checked contenders, no production changes."""
import hashlib, importlib.util, json, os, pathlib, shutil, subprocess
from changes import completion, lazy, pool, slab, once
ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE = 'abf9213181e95feaede032532b268203f4751feb'
OUT = ROOT/'dist/chase'

def run(args, cwd, log):
    with log.open('w') as output:
        result = subprocess.run(args, cwd=cwd, stdout=output, stderr=subprocess.STDOUT, timeout=240)
    if result.returncode:
        print(log.read_text()[-20000:], flush=True)
        raise SystemExit(f'{log}: exit {result.returncode}')

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

if __name__ == '__main__':
    os.chdir(ROOT); OUT.mkdir(parents=True, exist_ok=True)
    repo = subprocess.check_output(['git','rev-parse','--show-toplevel'], text=True).strip()
    frozen = ROOT/'.deps/chase-frozen'
    if frozen.exists(): shutil.rmtree(frozen)
    frozen.mkdir()
    archive = subprocess.check_output(['git','archive',f'{BASE}:experiments/lua-worker'], cwd=repo)
    subprocess.run(['tar','-x','-C',str(frozen)],input=archive,check=True)
    spec = importlib.util.spec_from_file_location('frozen_lifecycle',frozen/'lifecycle/prepare.py')
    lifecycle = importlib.util.module_from_spec(spec); spec.loader.exec_module(lifecycle)
    fresh = ROOT/'.deps/chase-fresh'
    if fresh.exists(): shutil.rmtree(fresh)
    fresh.mkdir()
    archive = subprocess.check_output(['git','archive',f'{lifecycle.BASE}:experiments/lua-worker'],cwd=repo)
    subprocess.run(['tar','-x','-C',str(fresh)],input=archive,check=True)
    manifest={'baseline':BASE,'freshSource':lifecycle.BASE,'head':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
      'experimentSet':os.environ.get('CHASE_SET','dispatch'),'toolchain':json.loads((frozen/'toolchain.json').read_text()),'variants':[]}
    names = ['resident','lazy','slab','packed'] if os.environ.get('CHASE_SET') == 'loading' else ['resident','completion','lazy','pooled']
    for name in names:
        target=OUT/name
        if target.exists(): shutil.rmtree(target)
        shutil.copytree(fresh,target)
        shutil.copytree(frozen/'lifecycle',target/'lifecycle')
        (target/'.deps').symlink_to(ROOT/'.deps',target_is_directory=True)
        (target/'node_modules').symlink_to(ROOT/'node_modules',target_is_directory=True)
        (target/'reports').mkdir(exist_ok=True)
        p=target/'core/kernel.nelua';p.write_text(p.read_text()+'\n'+(frozen/'lifecycle/application.nelua').read_text())
        p=target/'core/lua_bridge.c';p.write_text(lifecycle.resident_bridge(p.read_text()))
        shutil.copyfile(frozen/'lifecycle/api.h',target/'core/lifecycle.h')
        p=target/'host/runtime.mjs';p.write_text(lifecycle.resident_js(p.read_text()))
        if name=='resident':
            assert digest(p)=='492a01af033f74ff80741e3eafa6a67a01a4aeabaa8cdfdabb1d45e145256336'
            assert digest(target/'core/lua_bridge.c')=='a97ea36a978b16a9054dbcc5dc7efea65e1c774eb10381b20ec6b27878f34600'
        if name=='completion':p.write_text(completion(p.read_text()))
        if name in ['lazy','pooled','slab','packed']:p.write_text(lazy(p.read_text()))
        if name=='slab':p.write_text(slab(p.read_text()))
        extras=['wa_open','wa_load','wa_start','wa_release','wa_bytes','wa_pending','wa_app_count','wa_error_data','wa_error_size','wa_load_count','wa_collect']
        if name=='pooled':
            p=target/'core/lua_bridge.c';p.write_text(pool(p.read_text()))
            extras.append('wa_cached_coroutines')
            p=target/'host/runtime.mjs';p.write_text(once(p.read_text(),'residentLuaBytes: this.e.wa_bytes(),',
                'cachedCoroutines: this.e.wa_cached_coroutines(this.appId || 0), residentLuaBytes: this.e.wa_bytes(),'))
        p=target/'scripts/build.sh'
        s=once(p.read_text(),'"_lw_bytes"]','"_lw_bytes",'+','.join('"_'+x+'"'for x in extras)+']')
        native=s[s.index('cc -std=c11'):s.index('emcc --version')]
        s+='\n'+native.replace('tests/native.c','lifecycle/native.c').replace('dist/native-contract','dist/lifecycle-native')
        p.write_text(s)
        p=target/'lifecycle/contracts.mjs'
        p.write_text("import {extraSuite} from './chase-contracts.mjs';\n"+once(p.read_text(),'  return {warm,passed};',
            '  passed.push(...await extraSuite(make));\n  return {warm,passed};'))
        shutil.copyfile(ROOT/'chase/contracts.mjs',target/'lifecycle/chase-contracts.mjs')
        p=target/'lifecycle/workerd-tests.mjs';p.write_text(once(p.read_text(),'(name="contracts.mjs",esModule=embed "contracts.mjs"),',
            '(name="contracts.mjs",esModule=embed "contracts.mjs"),(name="chase-contracts.mjs",esModule=embed "chase-contracts.mjs"),'))
        print('BUILD AND GATE',name,flush=True)
        run(['env','WASM_PROFILE=balanced','bash','scripts/build.sh'],target,target/'reports/build.log')
        run(['timeout','60','./dist/native-contract'],target,target/'reports/native.txt')
        run(['timeout','60','./dist/lifecycle-native'],target,target/'reports/lifecycle-native.txt')
        run(['timeout','90','node','lifecycle/node-tests.mjs'],target,target/'reports/node.txt')
        run(['timeout','90','node','lifecycle/workerd-tests.mjs'],target,target/'reports/workerd.txt')
        files=['core/kernel.nelua','core/lua_bridge.c','host/runtime.mjs','dist/kernel.wasm','lifecycle/contracts.mjs','lifecycle/chase-contracts.mjs']
        manifest['variants'].append({'name':name,'warm':True,'profile':'balanced','contract':'PASS',
            'wasmBytes':(target/'dist/kernel.wasm').stat().st_size,'sha256':{x:digest(target/x)for x in files}})
        (OUT/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        print('PASS',name,'native ASan/UBSan, frozen + new lifecycle contracts in Node/workerd, real TCP cleanup',flush=True)
