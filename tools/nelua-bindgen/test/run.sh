#!/bin/sh
# Regenerates sample.nelua, checks it matches the committed expectation, and compiles the smoke program.
# Then does the same through test/sample.json (--config) and checks that command-line flags override the file.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
NELUA=${NELUA:-nelua}
bindgen="$here/../nelua-bindgen.py"
python3 "$bindgen" "$here/sample.h" -o "$here/sample.nelua"
diff -u "$here/sample.expected.nelua" "$here/sample.nelua"
(cd / && python3 "$bindgen" --config "$here/sample.json")  # headers and output resolve relative to the config file
diff -u "$here/sample_config.expected.nelua" "$here/sample_config.nelua"
python3 "$bindgen" --config "$here/sample.json" --prefix C --exclude '^sample_' -o "$here/sample_override.nelua"
grep -q '^global C = @record{}$' "$here/sample_override.nelua"
grep -q '^global C.SAMPLE_VERSION: cint <comptime> = 3$' "$here/sample_override.nelua"
! grep -q 'sample_add' "$here/sample_override.nelua"
grep -q 'SAMPLE_ANON_ONE' "$here/sample_override.nelua"  # --exclude on the command line replaces the file's list
rm -f "$here/sample_override.nelua"
cd "$here" && $NELUA -L "$here" --cflags="-I$here" "$here/use_sample.nelua"
cd "$here" && $NELUA -L "$here" --cflags="-I$here" "$here/use_sample_config.nelua"
