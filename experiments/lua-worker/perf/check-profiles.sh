#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# The shipped core must be the measured entry-only change, not the rejected bundle.
cmp core/lua_bridge.c dist/shootout/entry-o2/core/lua_bridge.c
cmp core/kernel.nelua dist/shootout/baseline/core/kernel.nelua
cmp host/runtime.mjs dist/shootout/baseline/host/runtime.mjs
mkdir -p dist/profiles
: > reports/selected-profiles.txt
for profile in balanced cpu compact; do
  case "$profile" in
    balanced) candidate=entry-o2 ;;
    cpu) candidate=entry-o3 ;;
    compact) candidate=entry-oz ;;
  esac
  WASM_PROFILE="$profile" bash scripts/build.sh > "reports/profile-$profile-build.log" 2>&1
  cmp dist/kernel.wasm "dist/shootout/$candidate/dist/kernel.wasm"
  cp dist/kernel.wasm "dist/profiles/$profile.wasm"
  printf '%s matches %s: ' "$profile" "$candidate" | tee -a reports/selected-profiles.txt
  sha256sum "dist/profiles/$profile.wasm" | tee -a reports/selected-profiles.txt
done
# Leave the normal worker runnable with its documented default profile.
cp dist/profiles/balanced.wasm dist/kernel.wasm
printf '%s\n' 'WASM_PROFILE=balanced' 'WASM_FLAGS=-O2' > reports/build-profile.txt
sha256sum dist/kernel.wasm dist/kernel-wasm.c dist/kernel-native.c > reports/build-sha256.txt
