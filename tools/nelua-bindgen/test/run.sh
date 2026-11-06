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
python3 "$bindgen" --config "$here/sample.json" --prefix C --nullable-returns '^sample_open$' -o "$here/sample_prefix.nelua"
grep -q "^require 'optional'$" "$here/sample_prefix.nelua"
grep -q '^local function sample_open__c(path: \*const cchar, end_: cint): \*C.sample_opaque <cimport'"'"'sample_open'"'"',' "$here/sample_prefix.nelua"
grep -q '^function C.sample_open(path: \*const cchar, end_: cint): \*C.sample_opaque? <inline> return sample_open__c(path, end_) end$' "$here/sample_prefix.nelua"  # --prefix applies to the wrapper
! grep -q '^global function' "$here/sample_prefix.nelua"  # every function is a field of C
! grep -q 'sample_handle_open__c' "$here/sample_prefix.nelua"  # --nullable-returns on the command line replaces the file's list
python3 "$bindgen" "$here/nullable.h" --nullable-returns '^nul_(find|name|first|count|lookup|callback)$' -o "$here/nullable.nelua"
diff -u "$here/nullable.expected.nelua" "$here/nullable.nelua"
cd "$here" && $NELUA -L "$here" --cflags="-I$here" "$here/use_sample.nelua"
cd "$here" && $NELUA -L "$here" --cflags="-I$here" "$here/use_nullable.nelua"
cd "$here" && $NELUA -L "$here" --cflags="-I$here" "$here/use_sample_config.nelua"
cd "$here" && $NELUA -L "$here" --cflags="-I$here" "$here/use_sample_prefix.nelua"  # the --prefix output compiles and runs
rm -f "$here/sample_prefix.nelua"
