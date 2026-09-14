#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
cd "$(dirname "$0")/.."
npm ci --no-audit --no-fund
bash engines/truffle/native/build.sh
mkdir -p dist/chase/truffle/classes reports/chase-truffle
# The original native/JVM controls above are retained without these boundaries.
python3 chase/cold-path-boundaries.py
mvn -B -f .deps/trufflelua/pom.xml -pl language -am -Dmaven.test.skip=true package
mkdir -p dist/engines/truffle/eligible-lib
cp dist/engines/truffle/linear-lib/*.jar dist/engines/truffle/eligible-lib/
cp .deps/trufflelua/language/target/language.jar dist/engines/truffle/eligible-lib/language.jar
git -C .deps/trufflelua diff > reports/chase-truffle/upstream-eligible.patch
cp_path='dist/engines/truffle/classes:dist/engines/truffle/eligible-lib/*:dist/chase/truffle/classes'
java --enable-native-access=ALL-UNNAMED -cp "$cp_path" NativeImagePeer --regressions > reports/chase-truffle/eligible-jvm-regressions.json
cmp reports/chase-truffle/eligible-jvm-regressions.json reports/truffle-native/linear-lib-regressions.json
java --enable-native-access=ALL-UNNAMED -cp "$cp_path" NativeImagePeer --jit-probe > reports/chase-truffle/eligible-jvm-jit.log 2>&1
javac -cp "$cp_path" -d dist/chase/truffle/classes chase/RuntimeRoots.java
image_init=$(python3 engines/truffle/native/image-init.py eligible-lib)
execution_init=$(python3 chase/image-execution-init.py eligible-lib)
image_init="$image_init,$execution_init"
runtime_init='com.zhhz.truffle.lua.LuaLanguage$ReferenceMetadata,com.zhhz.truffle.lua.runtime.LuaContext$ReferenceMetadata'
/usr/bin/time -v native-image --no-fallback --parallelism=4 -J-Xmx10g -O2 -march=compatibility \
 -J--add-exports=org.graalvm.nativeimage.builder/com.oracle.svm.hosted=ALL-UNNAMED \
 -J--add-exports=org.graalvm.nativeimage.builder/com.oracle.svm.graal.hosted.runtimecompilation=ALL-UNNAMED \
 -J--add-exports=jdk.internal.vm.ci/jdk.vm.ci.meta=ALL-UNNAMED \
 -J--add-opens=org.graalvm.nativeimage.builder/com.oracle.svm.graal.hosted.runtimecompilation=ALL-UNNAMED \
 --enable-native-access=ALL-UNNAMED -R:MaxHeapSize=268435456 \
 -H:+UnlockExperimentalVMOptions -H:+PrintRuntimeCompileMethods -H:-UnlockExperimentalVMOptions \
 "--initialize-at-build-time=$image_init" "--initialize-at-run-time=$runtime_init" \
 --features=RuntimeRoots -cp "$cp_path" NativeImagePeer -o dist/chase/truffle/native-exec-init \
 2>&1 | tee reports/chase-truffle/roots-build.log
file dist/chase/truffle/native-exec-init > reports/chase-truffle/roots-file.txt
ldd dist/chase/truffle/native-exec-init > reports/chase-truffle/roots-ldd.txt
! grep -qi libjvm reports/chase-truffle/roots-ldd.txt
env -u JAVA_HOME -u CLASSPATH PATH=/no-java "$PWD/dist/chase/truffle/native-exec-init" --identity > reports/chase-truffle/identity.json
python3 -c "import json; assert json.load(open('reports/chase-truffle/identity.json'))['nativeImage'] is True"
dist/chase/truffle/native-exec-init --regressions > reports/chase-truffle/regressions.json
cmp reports/chase-truffle/regressions.json reports/truffle-native/linear-lib-native-regressions.json
dist/chase/truffle/native-exec-init --probe reports/chase-truffle/qualification.json > reports/chase-truffle/qualification.log 2>&1
dist/chase/truffle/native-exec-init --jit-probe > reports/chase-truffle/jit.log 2>&1
python3 - <<'PY'
from pathlib import Path
p=Path('engines/truffle/native/run.mjs');s=p.read_text()
s=s.replace("'proxy-native-linear'];","'jvm-exec-init','native-exec-init','proxy-native-linear'];")
s=s.replace("const rounds=6,", "const rounds=8,")
s=s.replace('Six balanced fresh-process rounds', 'Eight rotated fresh-process rounds')
s=s.replace('The JavaScript baseline', 'The optimized JavaScript reference')
s=s.replace("function command(v){const profile", "function command(v){if(v==='jvm-exec-init')return{exe:'java',args:['--enable-native-access=ALL-UNNAMED','-Dsun.net.httpserver.nodelay=true','-Xms32m','-Xmx256m','-cp','dist/engines/truffle/classes:dist/engines/truffle/eligible-lib/*','NativeImagePeer']};if(v==='native-exec-init')return{exe:resolve('dist/chase/truffle/native-exec-init'),args:['-Dsun.net.httpserver.nodelay=true','-Xms32m','-Xmx256m']};const profile")
s=s.replace("const dir='reports/truffle-native';", "const dir='reports/chase-truffle';")
s=s.replace('const file=`${dir}/${profile}${native?', 'const file=`reports/truffle-native/${profile}${native?')
s=s.replace(' report.summary=[];', r''' const rootsText=await readFile('reports/chase-truffle/jit.log','utf8');
 assert(rootsText.includes('JIT_PROBE {"checkedCalls":1600'),'root diagnostic incomplete');
 const rootLines=rootsText.split('\n');assert(rootLines.some(l=>l.startsWith('JIT_PROBE ')),'unparsed native compilation log');
 report.jit.push({profile:'Audited execution class initialization; no forced roots',native:true,file:'reports/chase-truffle/jit.log',guestCompiled:rootLines.some(l=>l.includes('opt done')&&l.includes('Src cpu-handler.lua')),completions:rootLines.filter(l=>l.includes('opt done')&&l.includes('Src cpu-handler.lua')),failures:rootLines.filter(l=>l.includes('opt failed')&&l.includes('Src cpu-handler.lua'))});
 const eligibleJvmText=await readFile('reports/chase-truffle/eligible-jvm-jit.log','utf8');
 assert(eligibleJvmText.includes('JIT_PROBE {"checkedCalls":1600'),'eligible JVM diagnostic incomplete');
 const eligibleJvmLines=eligibleJvmText.split('\n');assert(eligibleJvmLines.some(l=>l.startsWith('JIT_PROBE ')),'unparsed JVM compilation log');
 report.jit.push({profile:'Matching cold-boundary language JAR',native:false,file:'reports/chase-truffle/eligible-jvm-jit.log',guestCompiled:eligibleJvmLines.some(l=>l.includes('opt done')&&l.includes('Src cpu-handler.lua')),completions:eligibleJvmLines.filter(l=>l.includes('opt done')&&l.includes('Src cpu-handler.lua')),failures:eligibleJvmLines.filter(l=>l.includes('opt failed')&&l.includes('Src cpu-handler.lua'))});
 report.caveats.push('Execution-init JVM/native contenders use the identical eligible language JAR with two cold-path boundaries. Older linear controls retain the prior JAR. The native contender also changes the audited build-time class list. No existing control is silently replaced.');
 report.summary=[];''')
p.with_name('chase-run.mjs').write_text(s)
PY
cp chase/reference.mjs peer/reference.mjs
cp peer/reference.mjs reports/chase-truffle/javascript-reference.mjs
node engines/truffle/native/chase-run.mjs
sha256sum dist/chase/truffle/native-exec-init chase/RuntimeRoots.java chase/image-execution-init.py chase/cold-path-boundaries.py > reports/chase-truffle/sha256.txt
