#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
cd "$(dirname "$0")/.."
bash engines/truffle/native/build.sh
mkdir -p dist/chase/truffle/classes reports/chase-truffle
cp_path='dist/engines/truffle/classes:dist/engines/truffle/linear-lib/*:dist/chase/truffle/classes'
javac -cp "$cp_path" -d dist/chase/truffle/classes chase/RuntimeRoots.java
image_init=$(python3 engines/truffle/native/image-init.py linear-lib)
runtime_init='com.zhhz.truffle.lua.LuaLanguage$ReferenceMetadata,com.zhhz.truffle.lua.runtime.LuaContext$ReferenceMetadata'
/usr/bin/time -v native-image --no-fallback --parallelism=4 -J-Xmx10g -O2 -march=compatibility \
 -J--add-exports=org.graalvm.nativeimage.builder/com.oracle.svm.hosted=ALL-UNNAMED \
 -J--add-exports=org.graalvm.nativeimage.builder/com.oracle.svm.graal.hosted.runtimecompilation=ALL-UNNAMED \
 -J--add-exports=jdk.internal.vm.ci/jdk.vm.ci.meta=ALL-UNNAMED \
 --enable-native-access=ALL-UNNAMED -R:MaxHeapSize=268435456 \
 -H:+UnlockExperimentalVMOptions -H:+PrintRuntimeCompileMethods -H:-UnlockExperimentalVMOptions \
 "--initialize-at-build-time=$image_init" "--initialize-at-run-time=$runtime_init" \
 --features=RuntimeRoots -cp "$cp_path" NativeImagePeer -o dist/chase/truffle/native-roots \
 2>&1 | tee reports/chase-truffle/roots-build.log
file dist/chase/truffle/native-roots > reports/chase-truffle/roots-file.txt
ldd dist/chase/truffle/native-roots > reports/chase-truffle/roots-ldd.txt
! grep -qi libjvm reports/chase-truffle/roots-ldd.txt
env -u JAVA_HOME -u CLASSPATH PATH=/no-java "$PWD/dist/chase/truffle/native-roots" --identity > reports/chase-truffle/identity.json
python3 -c "import json; assert json.load(open('reports/chase-truffle/identity.json'))['nativeImage'] is True"
dist/chase/truffle/native-roots --regressions > reports/chase-truffle/regressions.json
cmp reports/chase-truffle/regressions.json reports/truffle-native/linear-lib-native-regressions.json
dist/chase/truffle/native-roots --probe reports/chase-truffle/qualification.json > reports/chase-truffle/qualification.log 2>&1
dist/chase/truffle/native-roots --jit-probe > reports/chase-truffle/jit.log 2>&1
python3 - <<'PY'
from pathlib import Path
p=Path('engines/truffle/native/run.mjs');s=p.read_text()
s=s.replace("'proxy-native-linear'];","'native-roots','proxy-native-linear'];")
s=s.replace("const rounds=6,", "const rounds=4,")
s=s.replace("function command(v){const profile", "function command(v){if(v==='native-roots')return{exe:resolve('dist/chase/truffle/native-roots'),args:['-Dsun.net.httpserver.nodelay=true','-Xms32m','-Xmx256m']};const profile")
s=s.replace("const dir='reports/truffle-native';", "const dir='reports/chase-truffle';")
s=s.replace('const file=`${dir}/${profile}${native?', 'const file=`reports/truffle-native/${profile}${native?')
p.with_name('chase-run.mjs').write_text(s)
PY
node engines/truffle/native/chase-run.mjs
sha256sum dist/chase/truffle/native-roots chase/RuntimeRoots.java > reports/chase-truffle/sha256.txt
