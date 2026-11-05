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
| `typedef struct {...} T` | `global T: type <cimport,cinclude'...',ctypedef> = @record{...}` |
| `struct tag {...}` | `global tag: type <cimport,cinclude'...',ctypedef'tag'> = @record{...}` |
| `struct tag;` (opaque) | `<forwarddecl>` record, completed if the definition follows |
| `typedef enum {...} E` | `@enum(cint){...}` |
| anonymous `enum { A = 1 }` | `global A: cint <comptime> = 1` |
| `R (*)(A, B)` | `function(A, B): R` |
| `f(const char*, ...)` | `global function f(a1: *const cchar, ...: cvarargs)` |
| `#define X 3` / `1.5` / `"s"` | `<comptime>` constants |

Bitfields, anonymous members and macros that are not literals are listed in a
`-- Not generated:` trailer instead of being guessed. Records with omitted
fields get `cincomplete` so Nelua never sizes them from partial information.
Types referenced from other headers get opaque `cincomplete` stubs; bind those
headers too, or pass `--all`, when you need their fields.

Only declarations located in the headers given on the command line are bound.
Use `--match REGEX` to narrow further and `--prefix C` to emit `C.name` fields
instead of flat globals. Pass the target triple with `--target` when binding for
a cross target, since struct layouts and `long` sizes follow the target.

`test/run.sh` regenerates `test/sample.nelua`, diffs it against the committed
expectation, and compiles and runs `test/use_sample.nelua` against `sample.c`.
