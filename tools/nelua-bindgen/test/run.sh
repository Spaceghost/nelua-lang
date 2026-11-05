#!/bin/sh
# Regenerates sample.nelua, checks it matches the committed expectation, and compiles the smoke program.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
NELUA=${NELUA:-nelua}
python3 "$here/../nelua-bindgen.py" "$here/sample.h" -o "$here/sample.nelua"
diff -u "$here/sample.expected.nelua" "$here/sample.nelua"
cd "$here" && $NELUA -L "$here" "$here/use_sample.nelua"
