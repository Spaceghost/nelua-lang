#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
cd "$(dirname "$0")/../../.."
mkdir -p reports/truffle-native dist/engines/truffle-native
command -v native-image >/dev/null
native-image --version | tee reports/truffle-native/native-image-version.txt
java -version 2>reports/truffle-native/java-version.txt
# Preserve the previous boundary-only experiment as a real same-run control.
bash engines/truffle/build.sh
javac -cp 'dist/engines/truffle/classes:dist/engines/truffle/lib/*' \
  -d dist/engines/truffle/classes engines/truffle/native/*.java
python3 engines/truffle/native/linear-blocks.py
mvn -B -f .deps/trufflelua/pom.xml -pl language -am -Dmaven.test.skip=true package
mkdir -p dist/engines/truffle/linear-lib
cp dist/engines/truffle/lib/*.jar dist/engines/truffle/linear-lib/
cp .deps/trufflelua/language/target/language.jar dist/engines/truffle/linear-lib/language.jar
git -C .deps/trufflelua diff > reports/truffle-native/upstream-full.patch
for profile in lib linear-lib; do
  cp="dist/engines/truffle/classes:dist/engines/truffle/$profile/*"
  java --enable-native-access=ALL-UNNAMED -cp "$cp" NativeImagePeer --regressions \
    > "reports/truffle-native/$profile-regressions.json" 2> "reports/truffle-native/$profile-regressions.log"
  java --enable-native-access=ALL-UNNAMED -cp "$cp" NativeImagePeer --probe "reports/truffle-native/$profile-qualification.json" \
    > "reports/truffle-native/$profile-qualification.log" 2>&1
  java --enable-native-access=ALL-UNNAMED -cp "$cp" NativeImagePeer --jit-probe \
    > "reports/truffle-native/$profile-jit.log" 2>&1
  # Truffle caches generated registration and interop metadata in its image.
  # Derive and inspect an exact generated-class list, never a package wildcard.
  image_init=$(python3 engines/truffle/native/image-init.py "$profile")
  # Build failures remain failures. No Java launcher fallback is accepted.
  /usr/bin/time -v native-image --no-fallback --parallelism=4 \
    -J-Xmx${NATIVE_BUILD_HEAP:-10g} -O2 -march=compatibility \
    --enable-native-access=ALL-UNNAMED -R:MaxHeapSize=268435456 \
    "--initialize-at-build-time=$image_init" \
    -cp "$cp" NativeImagePeer -o "dist/engines/truffle-native/truffle-$profile" \
    2>&1 | tee "reports/truffle-native/$profile-build.log"
  file "dist/engines/truffle-native/truffle-$profile" | tee "reports/truffle-native/$profile-file.txt"
  readelf -h "dist/engines/truffle-native/truffle-$profile" > "reports/truffle-native/$profile-elf.txt"
  ldd "dist/engines/truffle-native/truffle-$profile" > "reports/truffle-native/$profile-ldd.txt"
  if grep -qi 'libjvm' "reports/truffle-native/$profile-ldd.txt"; then exit 1; fi
  "dist/engines/truffle-native/truffle-$profile" --identity > "reports/truffle-native/$profile-native-identity.json"
  python3 - "$profile" <<'PY'
import json,sys
p=sys.argv[1]
assert json.load(open('reports/truffle-native/'+p+'-native-identity.json'))['nativeImage'] is True
PY
  "dist/engines/truffle-native/truffle-$profile" --regressions \
    > "reports/truffle-native/$profile-native-regressions.json" 2> "reports/truffle-native/$profile-native-regressions.log"
  "dist/engines/truffle-native/truffle-$profile" --probe "reports/truffle-native/$profile-native-qualification.json" \
    > "reports/truffle-native/$profile-native-qualification.log" 2>&1
  "dist/engines/truffle-native/truffle-$profile" --jit-probe \
    > "reports/truffle-native/$profile-native-jit.log" 2>&1
  cmp "reports/truffle-native/$profile-regressions.json" "reports/truffle-native/$profile-native-regressions.json"
done
cmp reports/truffle-native/lib-regressions.json reports/truffle-native/linear-lib-regressions.json
python3 - <<'PY'
import json
from pathlib import Path
base=json.loads(Path('reports/truffle-native/lib-qualification.json').read_text())
for p in Path('reports/truffle-native').glob('*qualification.json'):
  report=json.loads(p.read_text());assert report['cases']==base['cases'],str(p)
  assert report['cpuCheckedCalls']==200 and report['filesystemDenyChecks']==2,str(p)
PY
find dist/engines/truffle dist/engines/truffle-native -type f -print0 | sort -z | xargs -0 sha256sum > reports/truffle-native/binaries-sha256.txt
