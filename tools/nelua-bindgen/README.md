# nelua-bindgen

Generates Nelua `<cimport>` bindings from C headers with libclang, so C APIs
no longer have to be declared by hand.

```sh
apt install python3-clang   # or: pip install libclang
tools/nelua-bindgen/nelua-bindgen.py zlib.h --include-as '<zlib.h>' -o zlib.nelua
tools/nelua-bindgen/nelua-bindgen.py lvgl.h -I lvgl/src --target xtensa-esp32s3-none-elf --match '^lv_' -o lvgl.nelua
```

What it maps:

| C | Nelua |
| --- | --- |
| `int`, `unsigned long`, `size_t`, `int32_t`, ... | `cint`, `culong`, `csize`, `int32`, ... |
| `char*` / `const char*` | `cstring` / `*const cchar` |
| `void*` / `const void*` | `pointer` / `*const void` |
| `T*` / `const T*` | `*T` / `*const T` |
| `T[N]`, `T[]` | `[N]T`, `[0]T` |
| `typedef struct {...} T` | `global T: type <cimport,cinclude'...'> = @record{...}` (no `ctypedef`: the header's own typedef names it) |
| `struct tag {...}`, `typedef struct tag {...} T` | `global tag: type <cimport,cinclude'...',ctypedef'tag'> = @record{...}`, then `global T: type <...,nodecl> = @tag` |
| `struct tag;` (opaque) | `<forwarddecl>` record, completed if the definition follows |
| `typedef enum {...} E` | `@enum(cint){...}` |
| anonymous `enum { A = 1 }` | `global A: cint <comptime> = 1` |
| `R (*)(A, B)` | `function(A, B): R` |
| `f(const char*, ...)` | `global function f(a1: *const cchar, ...: cvarargs)` |
| `#define X 3` / `1.5` | `global X: cint <comptime> = 3` / `float64` |
| `#define S "a\n" "b"` | `global S: cstring <comptime> = "a\nb"` (C escapes decoded, respelled for Nelua) |
| `#define A B` (B an emitted macro or enumerator) | `global A <comptime> = B` / `= E.B` (chains resolve in any source order) |

Bitfields, anonymous members and macros that are not literals are listed in a
`-- Not generated:` trailer instead of being guessed. Records with omitted
fields get `cincomplete` so Nelua never sizes them from partial information.
Types referenced from other headers, or excluded with `--exclude`/`--match`
but still referenced, get opaque `cincomplete` stubs, written before the
declarations so the output compiles; bind those headers too, or pass `--all`, when you need their fields. Function
pointer fields and callback typedefs keep `*const T` for `const T*` parameters.

`--opaque NAME` names either the struct tag or the typedef: with
`typedef struct foo {...} foo_t;` both `--opaque foo` and `--opaque foo_t`
forward declare `foo` once and emit `foo_t` as its alias, so `*foo` and
`*foo_t` stay one Nelua type. Functions, variables and fields that use an
opaque record by value are not generated (Nelua cannot size a forwarddecl
record); they are listed in the `-- Not generated:` trailer.

`--nullable-returns REGEX` opts a function into the fork's optional pointers:
libclang 14 does not expose `_Nullable`, so nullability is declared by name.
`nul_item *nul_find(int id);` matched by `--nullable-returns '^nul_find$'` becomes

```nelua
local function nul_find__c(id: cint): *nul_item <cimport'nul_find',cinclude'"nullable.h"'> end
global function nul_find(id: cint): *nul_item? <inline> return nul_find__c(id) end
```

so the C ABI sees the raw pointer and Nelua sees `*nul_item?` (`if p then`,
`p orelse default`, `if local item = nul_find(1) then`, `nul_find(id)?`).
`--prefix` applies to the wrapper (`global function C.nul_find(...)`), the
hidden `__c` name stays local to the generated module.

Only declarations located in the headers given on the command line are bound.
Pass the target triple with `--target` when binding for a cross target, since
struct layouts and `long` sizes follow the target.

## Options

| Option | Config key | Effect |
| --- | --- | --- |
| `header.h ...` | `headers` | headers to bind (config paths are relative to the config file) |
| `-I DIR` | `include_dirs` | include search directory (repeatable) |
| `-D NAME[=VALUE]` | `defines` | preprocessor define (repeatable) |
| `--target TRIPLE` | `target` | clang target triple used to parse |
| `--include-as '<x.h>'` | `include_as` | `cinclude` spec written into every binding (default `"basename.h"`) |
| `--prefix C` | `prefix` | emit `C.name` fields of a global record instead of flat globals |
| `--match REGEX` | `match` | only bind declarations whose name matches |
| `--exclude REGEX` | `exclude` | skip declarations whose name matches (repeatable); excluded types still referenced become stubs |
| `--opaque NAME` | `opaque` | emit this record (by tag or typedef name) as `<forwarddecl> @record{}` even if its definition is visible; by-value uses are skipped (repeatable) |
| `--nullable-returns REGEX` | `nullable_returns` | pointer-returning functions whose name matches get a `*T?` wrapper: the C prototype is bound unchanged as `local function name__c(...) <cimport'name'>` and `global function name(...): *T? <inline>` forwards to it (repeatable); the output then starts with `require 'optional'`. Matches that do not return a pointer or are variadic are bound as is and listed under `-- Notes:` |
| `--enum-using` | `enum_using` | mark named enums `<using>` so enumerators are also bare globals, as nelua-decl does |
| `--all` | `all` | also bind declarations from transitively included headers |
| `--include-file-regex REGEX` | `include_file_regex` | also bind declarations from included files matching |
| `--no-stubs` | `no_stubs` | do not emit opaque stubs for types from other headers |
| `--prepend TEXT` | `prepend` | verbatim Nelua text written before the declarations (a string or list of lines) |
| `--append TEXT` | `append` | verbatim Nelua text written after the declarations (a string or list of lines) |
| `-o FILE` | `output` | output file (default: stdout) |
| `--config FILE` | | JSON object with the keys above; command-line options override it |
| `--ignore-errors`, `--libclang PATH` | | generate despite clang errors; pick the libclang library |

Config example, `zlib.json` (`nelua-bindgen.py --config zlib.json`):

```json
{
  "headers": ["zlib.h"],
  "include_as": "<zlib.h>",
  "match": "^(z_|Z_|gz|deflate|inflate)",
  "exclude": ["^z_off64_t$"],
  "opaque": ["z_stream_s"],
  "enum_using": true,
  "output": "zlib.nelua",
  "append": ["global ZLIB_BOUND: boolean <comptime> = true"]
}
```

`test/run.sh` regenerates `test/sample.nelua` (from the command line) and
`test/sample_config.nelua` (from `test/sample.json`), diffs both against the
committed expectations, checks that command-line flags override the config
file, and compiles and runs `test/use_sample.nelua` and
`test/use_sample_config.nelua` against `sample.c`; `test/nullable.h` is
generated with `--nullable-returns` (a matched pointer, `const char *` and
typedef'd pointer return, plus a non-pointer and a variadic match that stay as
they are), diffed against `test/nullable.expected.nelua` and exercised by
`test/use_nullable.nelua` (`if p then`, `orelse`, `if local`, `?`). The config run covers
`nullable_returns` from the JSON file (`sample_handle_open`),
`--opaque` on a typedef whose tag differs (`sample_handle`, `sample_ctx`),
skipped by-value uses of an opaque record (`sample_node_make`), a stub for an
excluded but referenced type (`sample_bits`) and alias-macro chains.
