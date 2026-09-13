#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p .deps dist/engines/truffle/lib dist/engines/truffle/classes reports/truffle
sha=$(node -p "require('./engines/pins.json').truffleLua.commit")
if [[ ! -d .deps/trufflelua/.git ]]; then git init -q .deps/trufflelua; git -C .deps/trufflelua remote add origin https://github.com/zhxzkhz/LuaTruffle.git; fi
git -C .deps/trufflelua fetch --depth=1 origin "$sha"
git -C .deps/trufflelua checkout --detach "$sha"
[[ $(git -C .deps/trufflelua rev-parse HEAD) == "$sha" ]]
python3 - <<'PY'
from pathlib import Path
p=Path('.deps/trufflelua/language/pom.xml');s=p.read_text()
assert s.count('<version>RELEASE</version>')==1
p.write_text(s.replace('<version>RELEASE</version>','<version>7.11.0</version>'))
PY
git -C .deps/trufflelua diff > reports/truffle/upstream-build.patch
mvn -B -f .deps/trufflelua/pom.xml -pl language -am -Dmaven.test.skip=true package
mvn -B -f .deps/trufflelua/language/pom.xml org.apache.maven.plugins:maven-dependency-plugin:3.8.1:copy-dependencies -DincludeScope=runtime -DoutputDirectory="$PWD/dist/engines/truffle/lib"
cp .deps/trufflelua/language/target/language.jar dist/engines/truffle/lib/
mkdir -p dist/engines/truffle/baseline-lib
cp dist/engines/truffle/lib/*.jar dist/engines/truffle/baseline-lib/
python3 engines/truffle/patch.py
mvn -B -f .deps/trufflelua/pom.xml -pl language -am -Dmaven.test.skip=true package
cp .deps/trufflelua/language/target/language.jar dist/engines/truffle/lib/
git -C .deps/trufflelua diff > reports/truffle/upstream-full.patch
javac -cp 'dist/engines/truffle/lib/*' -d dist/engines/truffle/classes engines/truffle/*.java
for profile in baseline-lib lib; do
  java --enable-native-access=ALL-UNNAMED -cp "dist/engines/truffle/classes:dist/engines/truffle/$profile/*" TruffleRegression | tee "reports/truffle/$profile-label-regressions.json"
done
cmp reports/truffle/baseline-lib-label-regressions.json reports/truffle/lib-label-regressions.json
{ java -version; mvn --version; git -C .deps/trufflelua rev-parse HEAD; } > reports/truffle/toolchains.txt 2>&1
find dist/engines/truffle -type f -print0 | sort -z | xargs -0 sha256sum > reports/truffle/files-sha256.txt
cp .deps/trufflelua/LICENSE reports/truffle/upstream-LICENSE
tar -czf reports/truffle/upstream-source.tar.gz -C .deps/trufflelua language/src language/pom.xml pom.xml LICENSE README.md
