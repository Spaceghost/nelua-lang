#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .deps reports dist
get() { node -e "console.log(JSON.parse(require('fs').readFileSync('toolchain.json')).$1)"; }
checkout() {
  local dir=$1 remote=$2 sha=$3
  if [[ ! -d "$dir/.git" ]]; then
    git init -q "$dir"
    git -C "$dir" remote add origin "$remote"
  fi
  git -C "$dir" fetch --depth=1 origin "$sha"
  git -C "$dir" checkout --detach "$sha"
  [[ $(git -C "$dir" rev-parse HEAD) == "$sha" ]]
}
version=$(get lua.version)
if [[ ! -f .deps/lua.tar.gz ]]; then curl --fail --location --retry 3 "$(get lua.url)" -o .deps/lua.tar.gz; fi
printf '%s  %s\n' "$(get lua.sha256)" .deps/lua.tar.gz | sha256sum --check --strict
tar -xzf .deps/lua.tar.gz -C .deps
checkout .deps/nelua "$(get nelua.repository)" "$(get nelua.commit)"
make -C .deps/nelua -j2 NO_RPMALLOC=1
checkout .deps/emsdk "$(get emsdk.repository)" "$(get emsdk.commit)"
.deps/emsdk/emsdk install "$(get emsdk.version)"
.deps/emsdk/emsdk activate "$(get emsdk.version)"
if [[ -f package-lock.json ]]; then npm ci --no-audit --no-fund; else npm install --no-audit --no-fund; fi
.deps/nelua/nelua --version | tee reports/nelua-version.txt
node_modules/.bin/workerd --version | tee reports/workerd-version.txt
node --version | tee reports/node-version.txt
printf '%s\n' "Lua source $version" "Nelua $(git -C .deps/nelua rev-parse HEAD)" "emsdk $(git -C .deps/emsdk rev-parse HEAD)" | tee reports/sources.txt
