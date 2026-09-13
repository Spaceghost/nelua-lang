#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist/engines reports/engines .deps
sha=$(node -p "require('./engines/pins.json').luau.commit")
if [[ ! -d .deps/luau/.git ]]; then git init -q .deps/luau; git -C .deps/luau remote add origin https://github.com/luau-lang/luau.git; fi
git -C .deps/luau fetch --depth=1 origin "$sha"
git -C .deps/luau checkout --detach "$sha"
[[ $(git -C .deps/luau rev-parse HEAD) == "$sha" ]]
python3 engines/luau-adapt.py
cmake -S .deps/luau -B .deps/luau-native -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DLUAU_EXTERN_C=ON -DLUAU_BUILD_CLI=OFF -DLUAU_BUILD_TESTS=OFF
cmake --build .deps/luau-native --target Luau.Compiler Luau.VM -j2
inc=(-Ipeer -Idist/peer -Iengines -I.deps/luau/VM/include -I.deps/luau/Compiler/include)
gcc -std=c11 -O2 -fPIC -c dist/peer/kernel-native.c -o dist/engines/luau-kernel.o
gcc -std=c11 -O2 -fPIC -DPEER_LUAU "${inc[@]}" -c dist/engines/luau-runtime.c -o dist/engines/luau-runtime.o
libs=(.deps/luau-native/libLuau.Compiler.a .deps/luau-native/libLuau.Ast.a .deps/luau-native/libLuau.Bytecode.a .deps/luau-native/libLuau.VM.a .deps/luau-native/libLuau.Common.a)
g++ -shared dist/engines/luau-kernel.o dist/engines/luau-runtime.o -Wl,--start-group "${libs[@]}" -Wl,--end-group -lm -o dist/peer/libpeer-luau.so
gcc -std=c11 -Ipeer -c peer/core-test.c -o dist/engines/core-test.o
g++ dist/engines/core-test.o -Ldist/peer -lpeer-luau -Wl,-rpath,'$ORIGIN/../peer' -o dist/engines/core-luau
g++ -std=c++17 -O2 -g -Ipeer peer/kj-host.c++ -Ldist/peer -lpeer-luau $(pkg-config --cflags --libs kj-http kj-async) -Wl,-rpath,'$ORIGIN' -o dist/peer/host-luau
# Fully instrument Luau VM/compiler as well as the adapter in a separate gate.
cmake -S .deps/luau -B .deps/luau-asan -DCMAKE_BUILD_TYPE=Debug -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DLUAU_EXTERN_C=ON -DLUAU_BUILD_CLI=OFF -DLUAU_BUILD_TESTS=OFF '-DCMAKE_CXX_FLAGS=-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer'
cmake --build .deps/luau-asan --target Luau.Compiler Luau.VM -j2
for unit in kernel-native luau-runtime; do
 source=dist/peer/kernel-native.c; [[ $unit != luau-runtime ]] || source=dist/engines/luau-runtime.c
 gcc -std=c11 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -DPEER_LUAU "${inc[@]}" -c "$source" -o "dist/engines/$unit-asan.o"
done
asanlibs=(); for lib in "${libs[@]}"; do asanlibs+=("${lib/luau-native/luau-asan}"); done
g++ -fsanitize=address,undefined dist/engines/kernel-native-asan.o dist/engines/luau-runtime-asan.o dist/engines/core-test.o -Wl,--start-group "${asanlibs[@]}" -Wl,--end-group -lm -o dist/engines/core-luau-asan
# Portable interpreter+compiler; no native code generation in the Wasm lane.
set +u; source .deps/emsdk/emsdk_env.sh; set -u
emcmake cmake -S .deps/luau -B .deps/luau-wasm -DCMAKE_BUILD_TYPE=Release -DLUAU_EXTERN_C=ON -DLUAU_BUILD_CLI=OFF -DLUAU_BUILD_TESTS=OFF '-DCMAKE_CXX_FLAGS=-fwasm-exceptions -sSUPPORT_LONGJMP=wasm'
cmake --build .deps/luau-wasm --target Luau.Compiler Luau.VM -j2
emcc -O2 -fwasm-exceptions -sSUPPORT_LONGJMP=wasm -c dist/peer/kernel-wasm.c -o dist/engines/luau-kernel-wasm.o
emcc -O2 -fwasm-exceptions -sSUPPORT_LONGJMP=wasm -DPEER_LUAU "${inc[@]}" -c dist/engines/luau-runtime.c -o dist/engines/luau-runtime-wasm.o
wasmlibs=();for lib in "${libs[@]}"; do wasmlibs+=("${lib/luau-native/luau-wasm}"); done
exports='["_malloc","_free","_np_new","_np_load","_np_start","_np_complete","_np_close","_np_delete","_np_state","_np_kind","_np_status","_np_sequence","_np_active","_np_traces","_np_data","_np_error","_np_version","_np_size","_np_bytes","_np_collect"]'
em++ -O2 -fwasm-exceptions -sSUPPORT_LONGJMP=wasm dist/engines/luau-kernel-wasm.o dist/engines/luau-runtime-wasm.o -Wl,--start-group "${wasmlibs[@]}" -Wl,--end-group --no-entry -sSTANDALONE_WASM=1 -sFILESYSTEM=0 -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=4194304 -sMAXIMUM_MEMORY=33554432 -sSTACK_SIZE=1048576 -sABORTING_MALLOC=0 -sEXPORTED_FUNCTIONS="$exports" -o dist/peer/kernel-luau.wasm
sha256sum dist/peer/libpeer-luau.so dist/peer/kernel-luau.wasm dist/peer/host-luau dist/engines/luau-runtime.c > reports/engines/luau-build-sha256.txt
