#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Emsdk's environment script is not nounset-safe across releases.
set +u
source .deps/emsdk/emsdk_env.sh
set -u
mkdir -p dist reports
lua_version=$(node -e "console.log(JSON.parse(require('fs').readFileSync('toolchain.json')).lua.version)")
lua_src="$PWD/.deps/lua-$lua_version/src"
mapfile -t sources < <(find "$lua_src" -maxdepth 1 -name '*.c' ! -name lua.c ! -name luac.c ! -name linit.c ! -name ldblib.c ! -name liolib.c ! -name loslib.c ! -name loadlib.c ! -name lcorolib.c | sort)
nelua="$PWD/.deps/nelua/nelua"
# Generate separately: size_t/pointer layouts must match each target's C compiler.
"$nelua" --no-cache --cc emcc --code -P "unitname=''" -o dist/kernel-wasm.c core/kernel.nelua
"$nelua" --no-cache --cc gcc --code -P "unitname=''" -o dist/kernel-native.c core/kernel.nelua
exports='["_malloc","_free","_lw_abi_version","_lw_ping","_lw_open","_lw_start","_lw_state","_lw_sequence","_lw_kind","_lw_status","_lw_data","_lw_size","_lw_complete","_lw_release","_lw_active","_lw_bytes"]'
emcc -O2 -std=c11 -fwasm-exceptions -sSUPPORT_LONGJMP=wasm \
  -I"$lua_src" -Icore dist/kernel-wasm.c core/lua_bridge.c "${sources[@]}" \
  --no-entry -sSTANDALONE_WASM=1 -sFILESYSTEM=0 -sALLOW_MEMORY_GROWTH=1 \
  -sINITIAL_MEMORY=4194304 -sMAXIMUM_MEMORY=33554432 -sSTACK_SIZE=1048576 \
  -sABORTING_MALLOC=0 -sEXPORTED_FUNCTIONS="$exports" -o dist/kernel.wasm
cc -std=c11 -O1 -g -Wall -Wextra -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I"$lua_src" -Icore dist/kernel-native.c core/lua_bridge.c "${sources[@]}" tests/native.c -lm -o dist/native-contract
emcc --version > reports/emcc-version.txt
cc --version > reports/cc-version.txt
sha256sum dist/kernel.wasm dist/kernel-wasm.c dist/kernel-native.c > reports/build-sha256.txt
node -e "const fs=require('fs'); const m=new WebAssembly.Module(fs.readFileSync('dist/kernel.wasm')); fs.writeFileSync('reports/wasm-abi.json',JSON.stringify({imports:WebAssembly.Module.imports(m),exports:WebAssembly.Module.exports(m)},null,2))"
cat reports/wasm-abi.json
