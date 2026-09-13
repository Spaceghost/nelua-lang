#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Ubuntu CI installs libcapnp-dev; exact distro package/library versions are retained.
pkg-config --modversion kj-http kj-async > reports/peer/kj-versions.txt
pkg-config --cflags --libs kj-http kj-async > reports/peer/kj-flags.txt
for vm in lua55 luajit; do
  g++ -std=c++17 -O2 -g -Wall -Wextra -Ipeer peer/kj-host.c++ -Ldist/peer -lpeer-$vm \
    $(pkg-config --cflags --libs kj-http kj-async) -Wl,-rpath,'$ORIGIN' -o dist/peer/host-$vm
done
sha256sum dist/peer/host-* >> reports/peer/sha256.txt
