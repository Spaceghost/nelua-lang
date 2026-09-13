#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist/peer reports/peer .deps
lj=c6ffc141a8762b41703f9287d63d93622a13dd8f
if [[ ! -d .deps/luajit/.git ]]; then git init -q .deps/luajit; git -C .deps/luajit remote add origin https://github.com/LuaJIT/LuaJIT.git; fi
git -C .deps/luajit fetch --depth=1 origin "$lj"
git -C .deps/luajit checkout --detach "$lj"
make -C .deps/luajit -j2 BUILDMODE=static XCFLAGS=-fPIC
python3 - <<'PY'
from pathlib import Path
b=Path('peer/bootstrap.lua').read_bytes()
Path('dist/peer/bootstrap.h').write_text('static const char peer_bootstrap[] = {'+','.join(map(str,b))+',0};\n')
PY
.deps/nelua/nelua --no-cache --cc gcc --code -P "unitname=''" -o dist/peer/kernel-native.c peer/kernel.nelua
lua_src="$PWD/.deps/lua-5.5.1/src"
mapfile -t sources < <(find "$lua_src" -maxdepth 1 -name '*.c' ! -name lua.c ! -name luac.c ! -name linit.c ! -name ldblib.c ! -name liolib.c ! -name loslib.c ! -name loadlib.c | sort)
common=(-std=c11 -Wall -Wextra -Ipeer -Idist/peer)
gcc "${common[@]}" -I"$lua_src" -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer dist/peer/kernel-native.c peer/runtime.c "${sources[@]}" peer/core-test.c -lm -o dist/peer/core-lua55-asan
gcc "${common[@]}" -I"$lua_src" -O2 -fPIC -shared dist/peer/kernel-native.c peer/runtime.c "${sources[@]}" -lm -o dist/peer/libpeer-lua55.so
gcc "${common[@]}" -I.deps/luajit/src -DPEER_LUAJIT -O2 -fPIC -shared dist/peer/kernel-native.c peer/runtime.c .deps/luajit/src/libluajit.a -lm -ldl -o dist/peer/libpeer-luajit.so
gcc "${common[@]}" -I.deps/luajit/src -DPEER_LUAJIT -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer dist/peer/kernel-native.c peer/runtime.c .deps/luajit/src/libluajit.a peer/core-test.c -lm -ldl -o dist/peer/core-luajit-asan
# Same explicit-context kernel and C adapter compiled for Wasm, not a separate VM implementation.
set +u; source .deps/emsdk/emsdk_env.sh; set -u
.deps/nelua/nelua --no-cache --cc emcc --code -P "unitname=''" -o dist/peer/kernel-wasm.c peer/kernel.nelua
exports='["_malloc","_free","_np_new","_np_load","_np_start","_np_complete","_np_close","_np_delete","_np_state","_np_kind","_np_status","_np_sequence","_np_active","_np_traces","_np_data","_np_error","_np_version","_np_size","_np_bytes","_np_collect"]'
emcc "${common[@]}" -I"$lua_src" -O2 -fwasm-exceptions -sSUPPORT_LONGJMP=wasm dist/peer/kernel-wasm.c peer/runtime.c "${sources[@]}" --no-entry -sSTANDALONE_WASM=1 -sFILESYSTEM=0 -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=4194304 -sMAXIMUM_MEMORY=33554432 -sSTACK_SIZE=1048576 -sABORTING_MALLOC=0 -sEXPORTED_FUNCTIONS="$exports" -o dist/peer/kernel.wasm
{ gcc --version; emcc --version; .deps/luajit/src/luajit -v; git -C .deps/luajit rev-parse HEAD; } > reports/peer/toolchains.txt
sha256sum peer/* dist/peer/kernel* dist/peer/*.so > reports/peer/sha256.txt
