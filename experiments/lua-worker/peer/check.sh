#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/bootstrap.sh
bash peer/build.sh
bash peer/build-host.sh
timeout --signal=KILL 60s dist/peer/core-lua55-asan
timeout --signal=KILL 60s dist/peer/core-luajit-asan
python3 peer/make-cases.py
timeout --signal=KILL 60s python3 peer/parity-native.py
timeout --signal=KILL 60s node peer/node-tests.mjs
timeout --signal=KILL 60s python3 peer/jit-probe.py
timeout --signal=KILL 180s node peer/http-tests.mjs
timeout --signal=KILL 600s node peer/bench.mjs
