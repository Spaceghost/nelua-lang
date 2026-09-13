#!/usr/bin/env bash
# Preserve licenses and the complete built dependency footprint with evidence.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist/peer/licenses reports/peer
cp .deps/luajit/COPYRIGHT dist/peer/licenses/LuaJIT-COPYRIGHT
cp .deps/lua-5.5.1/doc/readme.html dist/peer/licenses/Lua-README.html
cp /usr/share/doc/libcapnp-dev/copyright dist/peer/licenses/CapnProto-copyright
if test -f .deps/nelua/LICENSE; then cp .deps/nelua/LICENSE dist/peer/licenses/Nelua-LICENSE; fi
ldd dist/peer/host-lua55 > reports/peer/ldd-lua55.txt
ldd dist/peer/host-luajit > reports/peer/ldd-luajit.txt
sha256sum dist/peer/libpeer-*.so dist/peer/host-* dist/peer/kernel.wasm > reports/peer/binary-sha256.txt
find peer -type f -not -path '*/__pycache__/*' -print0 | sort -z | xargs -0 sha256sum > reports/peer/source-sha256.txt
