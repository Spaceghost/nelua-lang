#!/usr/bin/env python3
"""Build immutable, correctness-gated contenders from the same pinned baseline."""
import hashlib, json, os, pathlib, shutil, subprocess
ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE = '4404fcbb48d2692274df8864616c399986c1fb8a'
OUT = ROOT / 'dist' / 'shootout'

def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f'baseline drift: expected one occurrence of {old[:70]!r}')
    return text.replace(old, new, 1)

def entry(source):
    start = source.index('  const char *entry = ')
    end = source.index('  if (luaL_loadbufferx(L, vm->source', start)
    source = source[:start] + '  lua_pushcfunction(L, worker_entry);\n' + source[end:]
    functions = '''/* Trusted dispatch compiled once, with explicit Lua continuations.
 * Keep all handler results: the outer contract rejects zero/multiple responses. */
static int handler_return(lua_State *L, int status, lua_KContext prefix) {
  (void)status;
  return lua_gettop(L) - (int)prefix;
}
static int enter_handler(lua_State *L, int status, lua_KContext context) {
  (void)status; (void)context;
  if (!lua_istable(L, 5)) return luaL_error(L, "application must return a fetch handler");
  lua_getfield(L, 5, "fetch");
  if (!lua_isfunction(L, -1)) return luaL_error(L, "application must return a fetch handler");
  lua_remove(L, 5);
  lua_pushvalue(L, 2); lua_pushvalue(L, 3); lua_pushvalue(L, 4);
  lua_callk(L, 3, LUA_MULTRET, 4, handler_return);
  return handler_return(L, LUA_OK, 4);
}
static int worker_entry(lua_State *L) {
  lua_pushvalue(L, 1);
  lua_callk(L, 0, 1, 0, enter_handler);
  return enter_handler(L, LUA_OK, 0);
}
'''
    return replace_once(source, 'static int prepare(lua_State *L) {', functions + 'static int prepare(lua_State *L) {')

def slots(source):
    source = replace_once(source, '''  for i=0,7 do
    if slots[i].id == id then return &slots[i] end
  end
  return nilptr''', '''  local r = &slots[(id - 1) % 8]
  if r.id ~= id then return nilptr end
  return r''')
    source = replace_once(source, 'if serial >= 2147483600 then', 'if serial >= 268435399 then')
    return replace_once(source, '''      $r = Invocation{}
      serial = serial + 1
      r.id = serial
      r.state = 1''', '''      -- Reset ownership/lengths, not 64 KiB of inaccessible buffer capacity.
      -- No previous payload is observable through the length-bounded guest API.
      r.sequence, r.kind, r.status, r.ok = 0, 0, 0, 0
      r.operations, r.fetches, r.used, r.n = 0, 0, 0, 0
      r.vm = nilptr
      serial = serial + 1
      r.id = serial * 8 + uint32(i) + 1
      r.state = 1''')

def bridge(source):
    start = source.index('  withBytes(values, fn) {')
    end = source.index('  async operation(', start)
    return source[:start] + '''  withBytes(values, fn) {
    // One call-scoped slab. No mutable memory view is retained across an await.
    const length = values.reduce((sum, value) => sum + value.length, 0);
    const base = this.e.malloc(Math.max(length, 1));
    if (!base) throw new WorkerError('Wasm allocation limit', 'MEMORY_LIMIT');
    try {
      const heap = new Uint8Array(this.e.memory.buffer);
      const args = [];
      let offset = 0;
      for (const value of values) {
        heap.set(value, base + offset);
        args.push(base + offset, value.length);
        offset += value.length;
      }
      return fn(...args);
    } finally { this.e.free(base); }
  }
''' + source[end:]

def run(args, cwd, log, timeout=300):
    with log.open('w') as f:
        p = subprocess.run(args, cwd=cwd, stdout=f, stderr=subprocess.STDOUT, timeout=timeout)
    if p.returncode:
        print(log.read_text()[-16000:], flush=True)
        raise SystemExit(f'{log}: exit {p.returncode}')

if __name__ == '__main__':
    os.chdir(ROOT)
    OUT.mkdir(parents=True, exist_ok=True)
    baseline = ROOT / '.deps' / 'shootout-baseline'
    if baseline.exists(): shutil.rmtree(baseline)
    baseline.mkdir()
    checkout = subprocess.check_output(['git','rev-parse','--show-toplevel'],text=True).strip()
    archive = subprocess.run(['git', 'archive', f'{BASE}:experiments/lua-worker'], cwd=checkout, capture_output=True, check=True).stdout
    subprocess.run(['tar', '-x', '-C', str(baseline)], input=archive, check=True)
    assert (baseline/'scripts/build.sh').is_file(), 'frozen baseline archive is incomplete'
    contenders = [('baseline','-O2',False,False), ('o3-lto','-O3 -flto',False,False),
                  ('oz-lto','-Oz -flto',False,False), ('entry-o3','-O3 -flto',True,False),
                  ('combined-o3','-O3 -flto',True,True)]
    manifest = {'baselineCommit': BASE, 'headCommit': subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
                'toolchain': json.loads((ROOT/'toolchain.json').read_text()), 'variants': []}
    for name, flags, dispatch, combined in contenders:
        target = OUT/name
        if target.exists(): shutil.rmtree(target)
        shutil.copytree(baseline,target)
        (target/'.deps').symlink_to(ROOT/'.deps',target_is_directory=True)
        (target/'node_modules').symlink_to(ROOT/'node_modules',target_is_directory=True)
        (target/'reports').mkdir(exist_ok=True)
        if dispatch:
            path=target/'core/lua_bridge.c';path.write_text(entry(path.read_text()))
        if combined:
            path=target/'core/kernel.nelua';path.write_text(slots(path.read_text()))
            path=target/'host/runtime.mjs';path.write_text(bridge(path.read_text()))
        path=target/'scripts/build.sh'
        path.write_text(replace_once(path.read_text(),'emcc -O2 -std=c11',f'emcc {flags} -std=c11'))
        print(f'BUILD {name}: {flags}',flush=True)
        run(['bash','scripts/build.sh'],target,target/'reports/build.log')
        run(['timeout','60','./dist/native-contract'],target,target/'reports/native-tests.txt')
        run(['timeout','60','node','--test','tests/runtime.test.mjs'],target,target/'reports/runtime-tests.tap')
        extra=ROOT/'perf/regression.test.mjs'
        shutil.copyfile(extra,target/'tests/performance-regression.test.mjs')
        run(['timeout','60','node','--test','tests/performance-regression.test.mjs'],target,target/'reports/performance-regression.tap')
        run(['timeout','60','node','tests/workerd.test.mjs'],target,target/'reports/workerd-tests.txt')
        paths=['core/kernel.nelua','core/lua_bridge.c','core/kernel.h','host/runtime.mjs','host/workerd.mjs','scripts/build.sh','dist/kernel.wasm']
        item={'name':name,'flags':flags,'dispatch':dispatch,'combined':combined,'contract':'PASS',
              'wasmBytes':(target/'dist/kernel.wasm').stat().st_size,
              'sha256':{p:hashlib.sha256((target/p).read_bytes()).hexdigest() for p in paths}}
        manifest['variants'].append(item)
        (OUT/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        print(f'PASS {name}: native sanitizers, Node, workerd and extra regressions',flush=True)
