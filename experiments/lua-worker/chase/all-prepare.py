#!/usr/bin/env python3
"""Freeze controls, derive small optimizations, gate profiles before timing."""
from pathlib import Path
import hashlib,json,shutil,subprocess,os
ROOT=Path(__file__).resolve().parents[1]
BASE='b5be21812242b33a6f566f3d73cd86efe929d54e'
OUT=ROOT/'dist/chase'
def once(s,old,new):
    if s.count(old)!=1: raise ValueError('frozen source drift: '+old[:90])
    return s.replace(old,new,1)
def run(args,target,name):
    log=target/'reports/chase'/name
    with log.open('w') as f:p=subprocess.run(args,cwd=target,stdout=f,stderr=subprocess.STDOUT,timeout=900)
    if p.returncode:
        print(log.read_text()[-18000:],flush=True);raise SystemExit(f'{log}: exit {p.returncode}')
def short_socket_paths(target):
    # Native UNIX socket paths have a platform length limit. All profiles use
    # the same private short directory, allocated before the startup clock.
    p=target/'peer/harness.mjs';s=p.read_text()
    s=once(s,'readFile,writeFile,mkdir,unlink','readFile,writeFile,mkdir,unlink,mkdtemp,rm')
    s=once(s,'const socket=resolve(dir,`peer-${index}.sock`);',
           "const socketDir=await mkdtemp('/tmp/lw-peer-');const socket=resolve(socketDir,'peer.sock');")
    s=once(s,'  await unlink(socket).catch(()=>{});',
           '  await unlink(socket).catch(()=>{});await rm(socketDir,{recursive:true,force:true});')
    p.write_text(s)
def patch(target, conservative=False):
    # Retain the frozen full-buffer reset. Only add a verified cache hint:
    # collisions fall back to the original scan and IDs/limits never change.
    if not conservative:
        p=target/'peer/kernel.nelua';s=p.read_text()
        s=once(s,'vm: pointer, slots: [8]Slot}', 'vm: pointer, slots: [8]Slot, hints: [256]uint8}')
        s=once(s,'  local e = engine(p)\n  for i=0,7 do if e.slots[i].id == id',
          '  local e = engine(p)\n  local hint = e.hints[id % 256]\n  if e.slots[hint].id == id then return &e.slots[hint] end\n  for i=0,7 do if e.slots[i].id == id')
        s=once(s,'      s.id, s.state, s.ticks = e.serial, 2, 1000',
          '      s.id, s.state, s.ticks = e.serial, 2, 1000\n      e.hints[s.id % 256] = uint8(i)')
        s=once(s, "local function nk_index(p: pointer, id: uint32): cint <cexport, codename 'nk_index'>\n",
          "local function nk_index(p: pointer, id: uint32): cint <cexport, codename 'nk_index'>\n  if p == nilptr or id == 0 then return -1 end\n  local e = engine(p)\n  local hint = e.hints[id % 256]\n  if e.slots[hint].id == id then return cint(hint) end\n")
        p.write_text(s)
    p=target/'peer/wasm.mjs';s=p.read_text()
    s=once(s,"const enc=new TextEncoder(),dec=new TextDecoder();","const enc=new TextEncoder(),dec=new TextDecoder();\nconst strictDecoder=new TextDecoder('utf-8',{fatal:true}),EMPTY=new Uint8Array();")
    start=s.index('  async run(');end=s.index('\n}\nexport function raceAbort',start)
    buffered=s[start:end].replace('  async run(', '  async _runBuffered(', 1)
    bodyless=(ROOT/'chase/wasm-run.mjs').read_text().rstrip().replace('  async run(', '  async _runBodyless(', 1)
    wrapper='  run(request,host,options){return request.body?this._runBuffered(request,host,options):this._runBodyless(request,host,options);}'
    s=s[:start]+wrapper+'\n'+bodyless+'\n'+buffered+s[end:]
    p.write_text(s)
    shutil.copyfile(ROOT/'chase/reference.mjs',target/'peer/reference.mjs')
if __name__=='__main__':
    os.chdir(ROOT);OUT.mkdir(parents=True,exist_ok=True)
    repo=subprocess.check_output(['git','rev-parse','--show-toplevel'],text=True).strip()
    archive=subprocess.check_output(['git','archive',f'{BASE}:experiments/lua-worker'],cwd=repo)
    manifest={'baseline':BASE,'checkout':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'profiles':[]}
    for profile in ['control','candidate','conservative']:
        target=OUT/profile
        if target.exists():shutil.rmtree(target)
        target.mkdir();subprocess.run(['tar','-x','-C',str(target)],input=archive,check=True)
        shutil.copytree(ROOT/'chase',target/'chase',dirs_exist_ok=True)
        (target/'.deps').symlink_to(ROOT/'.deps',target_is_directory=True)
        (target/'node_modules').symlink_to(ROOT/'node_modules',target_is_directory=True)
        (target/'reports/chase').mkdir(parents=True)
        short_socket_paths(target)
        if profile!='control':patch(target,conservative=profile=='conservative')
        commands=[(['bash','peer/build.sh'],'build.log'),(['bash','peer/build-host.sh'],'host.log'),
          (['timeout','60','dist/peer/core-lua55-asan'],'lua55-asan.log'),(['timeout','60','dist/peer/core-luajit-asan'],'luajit-asan.log'),
          (['python3','peer/make-cases.py'],'cases.log'),(['python3','peer/parity-native.py'],'parity-native.log'),
          (['node','peer/node-tests.mjs'],'parity-node.log'),(['python3','peer/jit-probe.py'],'jit.log'),
          (['bash','engines/build-luau.sh'],'luau-build.log'),(['timeout','60','dist/engines/core-luau-asan'],'luau-asan.log'),
          (['python3','engines/prepare-tests.py'],'harness.log'),(['python3','peer/engine-native.py'],'luau-native.log'),
          (['node','engines/luau-tests.mjs'],'luau-wasm.log'),(['timeout','180','node','peer/http-tests.mjs'],'http.log'),
          (['timeout','180','node','peer/engine-http.mjs'],'luau-http.log'),(['node','--test','chase/regression.test.mjs'],'regression.tap')]
        for args,name in commands:
            print('GATE',profile,name,flush=True);run(args,target,name)
        files=['peer/harness.mjs','peer/engine-harness.mjs','peer/kernel.nelua','peer/runtime.c','peer/wasm.mjs','peer/reference.mjs','peer/worker.lua','dist/peer/kernel.wasm','dist/peer/kernel-luau.wasm','dist/peer/libpeer-lua55.so','dist/peer/libpeer-luajit.so','dist/peer/libpeer-luau.so']
        manifest['profiles'].append({'profile':profile,'gate':'PASS','sha256':{p:hashlib.sha256((target/p).read_bytes()).hexdigest() for p in files}})
        (OUT/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
