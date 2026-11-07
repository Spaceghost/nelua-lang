![Nelua Logo](https://nelua.io/assets/img/nelua-logo-64px.png)

[nelua.io](https://nelua.io/)

[![Test Status](https://github.com/edubart/nelua-lang/workflows/test/badge.svg)](https://github.com/edubart/nelua-lang/actions)
[![Discord](https://img.shields.io/discord/680417078959800322.svg)](https://discord.gg/7aaGeG7)

Nelua (stands for **N**ative **E**xtensible **Lua**) is a minimal, efficient,
statically-typed and meta-programmable systems programming language heavily
inspired by Lua, which compiles to C and native code.

**Note:** The language is in alpha state and still evolving.

**Embedding in C, C++ or an operating system?** The
[runtime-free guide](docs/pages/runtime-free.md) covers host-owned memory,
C-ABI exports, no Nelua startup/GC, and audited C-hosted and no-libc examples.

## Quick start

- For basic information check the [Website](https://nelua.io/).
- For first steps and how to use Nelua, start at the [Tutorial](https://nelua.io/tutorial/).
- For a tour of the language's syntax, features and usage read the [Overview](https://nelua.io/overview/).
- For small examples written in Nelua look the [Examples](./examples) folder .
- For questions and discussions go to the [Discussions](https://github.com/edubart/nelua-lang/discussions).
- For a chat with the community join the [Discord server](https://discord.gg/7aaGeG7).
- For cool stuff made with Nelua check [Awesome Nelua](https://github.com/edubart/nelua-lang/wiki/Awesome-Nelua) wiki page and `#showcase` channel in the Discord server.

After installing, you might want to check out the featured example, a Snake
game leveraging the famous [SDL2](https://www.libsdl.org) library:

```bash
nelua examples/snakesdl.nelua
```

## Fork additions

This fork (Spaceghost/nelua-lang) tracks upstream `a5845056` (2025-06-24) and adds,
each with specs in `spec/` and docs under `docs/pages/`. The guide
[What this fork adds](docs/pages/fork.md) explains each one with examples, run-time
cost and limits; the list below is the short form:

- **Const pointers**: `*const T` maps to C `const T*`; reads through it are
  read-only and dropping `const` needs an explicit cast ([overview](docs/pages/overview.md#const-pointers)).
- **`pragmas.freestanding`**: compiler-enforced runtime-free profile, implies
  `nogc` and `noentrypoint`, traps on abort and rejects heap, process, stdio
  and `main` symbols at compile time ([runtime-free](docs/pages/runtime-free.md)).
- **`--target <triple>`**: cross compile with clang or `zig cc`, the triple reaches
  the type-size probe, the cache hash and the compile.
- **`tools/nelua-bindgen`**: generates `<cimport>` bindings from C headers with libclang;
  string and alias macros, `--exclude`, `--opaque`, `--enum-using`, `--nullable-returns REGEX`
  (matched pointer-returning functions get a `*T?` wrapper over the unchanged C prototype)
  and a JSON `--config` with `prepend`/`append` text ([tool README](tools/nelua-bindgen/README.md)).
- **Variants**: tagged unions as `variant(A, B)` or `A|B` through `require 'variant'`,
  with `==` (also against bare member values), `tostring` and `visit` ([overview](docs/pages/overview.md#variant)).
- **`match` statement**: `match v do case local n: integer then ... case string, nil then ... end`
  dispatches on the held type of a variant or an optional with exhaustiveness checking
  (every member and `nil`, or an `else`); `case local n: *T` binds a reference into the subject
  instead of a copy, lvalue and pointer subjects are matched in place, and the whole statement is
  lowered at compile time to a `switch` on the tag with no runtime support code; `match` is a
  contextual word, `string.match` keeps working ([overview](docs/pages/overview.md#variant)).
- **Owned records**: `<owned>` on a record with `__close` makes its values affine: copying
  an lvalue needs the `move` builtin (which zeroes the source), a moved variable cannot be
  read until assigned again (flow sensitive over branches, loops, early exits), records with
  owned fields and arrays of owned values are owned implicitly, and `<close>` variables cannot
  be moved; `heapqueue` and `list` are owned in the stdlib, `vector`, `sequence`, `hashmap`,
  `stringbuilder` and `filestream` are not yet ([overview](docs/pages/overview.md#ownership)).
- **Compile-time function evaluation**: `comptime(f(args))` runs an ordinary Nelua
  function inside the compiler and folds its result (scalars, booleans, strings, and arrays
  or records as static initializers); `<comptime>` on a function evaluates every call and
  never emits it to C. Bodies are translated to Lua with the fork's Lua generator and run in
  a sandbox that keeps the C integer widths, `float32` rounding, unsigned division and the
  Nelua shifts, with step and call-depth limits ([overview](docs/pages/overview.md#compile-time-function-evaluation)).
- **Optionals**: `T?` / `optional(T)` through `require 'optional'`, `nil` and `T` convert
  to it, `== nil` tests emptiness, `*T?` keeps the pointer size with `nilptr` as empty, and
  the postfix `expr?` propagates empty optionals, null pointers and the stdlib
  `(value, errmsg)` / boolean call failures as an early return, also as the statement
  `f()?`; `x orelse d` (`orelse` is a reserved word) unwraps or lazily evaluates a default
  and `if local x = e then` binds the held value; constant optionals at the top scope
  (`= 3`, `= nil`, `= nilptr`, `= &g`) are C static initializers ([overview](docs/pages/overview.md#optional)).
- **Closures**: anonymous and local nested functions capture upvalues by value as
  closure records; `<byref>` captures them by pointer so the closure can mutate the
  enclosing locals ([overview](docs/pages/overview.md#closures)).
- **Editor grammars**: `tools/tree-sitter-nelua` and `tools/textmate-nelua` know
  `*const T`, `A|B` variants, anonymous `function` expressions, the optional suffix `T?`,
  the try suffix `expr?` / `f()?`, `orelse`, `if local` and the `match` statement
  ([installing](docs/pages/installing.md#editor-support)); the Tree-sitter parser is regenerated from the pin named in its README.
- **Static initializers**: top-scope variables initialized with `nilptr`, the
  address of a static object (`&g`, `&arr[3]`, `&rec.field`), casts of those,
  or record/array literals built from them are emitted as C static initializers
  instead of statements in `nelua_main`, so they hold under `noentrypoint` too.
- **`algorithm`, `heapqueue` and `tuple` libraries**: stable `algorithm.sort`,
  `heapsort`, `removeif`, `unpackn`/`packn` over any contiguous container, a generic
  binary-heap priority queue and a generic tuple record with `pack`/`unpack`, absorbed
  from [nelua-batteries](https://github.com/edubart/nelua-batteries) (MIT, Eduardo Bart)
  with the same API ([libraries](docs/pages/libraries.md#algorithm)).
- **Compact C profile** (`lualib/nelua/compactc.lua`), Tree-sitter and TextMate
  grammars (`tools/`), and a binary cache that hashes imported C sources.

Tests run with `make test`; this fork's gate runs it in a Debian container
(`/work/nelua-dev` in the `nelibc-writ` Incus guest on bak) together with
nelibc's smoke matrix against the freshly built compiler.

## About

Nelua is a [systems programming language](https://en.wikipedia.org/wiki/System_programming_language)
for performance-sensitive applications where [Lua](https://en.wikipedia.org/wiki/Lua_(programming_language))
would not be efficient, such as operating systems, real-time applications and
game engines. While it has syntax and semantics similar to Lua, it primarily
focuses on generating efficient C code and provide support for
highly-optimizable low-level programming. Using Nelua idioms such as records,
arrays, manual memory management and pointers should result in performance as
efficient as pure C; on the other hand, when using Lua idioms such as tables,
metatables and untyped variables, the compiler will bake a runtime library for
this sort of dynamic functionality into the program, which could incur some
runtime overhead.


Nelua can do [meta programming](https://en.wikipedia.org/wiki/Metaprogramming)
at compile time through preprocessor constructs written in Lua; since the
compiler itself is also written in Lua, it means that user-provided
preprocessor code can interact at any point with the compiler's internals and
the source code's [AST](https://en.wikipedia.org/wiki/Abstract_syntax_tree).
Such system allows for ad-hoc implementation of high level constructs such as
[classes](https://en.wikipedia.org/wiki/Class_(computer_programming)),
[generics](https://en.wikipedia.org/wiki/Generic_programming) and
[polymorphism](https://en.wikipedia.org/wiki/Polymorphism_(computer_science)),
all without having to add them into the core specification, thus keeping the
language simple, extensible and compact. The same way that Lua's
object-oriented patterns are not built into the language, but can be
nonetheless achieved through [metatables](https://webserver2.tecgraf.puc-rio.br/lua/local/pil/13.html),
in Nelua you could yourself implement a similar functionality which is fully
decided at compile time or dynamically dispatched at runtime.

Nelua can do [extensible programming](https://en.wikipedia.org/wiki/Extensible_programming)
as the programmer may add extensions to the language such as new grammars,
[AST](https://en.wikipedia.org/wiki/Abstract_syntax_tree) definitions,
semantics, type checkers, code generation and behaviors to the compiler at
compile time via the preprocessor.

Nelua provides support for both [garbage-collected](https://en.wikipedia.org/wiki/Garbage_collection_(computer_science))
and [manual](https://en.wikipedia.org/wiki/Manual_memory_management)
memory management in a way that the developer can easily choose between
using garbage collection, or completely disabling
garbage collection, or mixing both.

Nelua first compiles to
[C](https://en.wikipedia.org/wiki/C_(programming_language)), then it executes a
C compiler to produce [native code](https://en.wikipedia.org/wiki/Machine_code).
This way existing C code and libraries can be leveraged and new C libraries can
be created. Another benefit is that Nelua can reach the same target platforms
as C99 compilers, such [GCC](https://en.wikipedia.org/wiki/GNU_Compiler_Collection)
or [Clang](https://en.wikipedia.org/wiki/Clang), while also enjoying
state-of-the-art compiler optimizations provided by them.

The initial motivation for its creation was to replace C/C++ parts of projects
which currently uses Lua with a language that has syntax and semantics similar
to Lua, but allows for fine-grained performance optimizations and does not lose
the ability to go low level, therefore unifying the syntax and semantics across
both compiled and dynamic languages.

## Goals

* Be minimal with a small syntax, manual and API, but powerful
* Be efficient by compiling to optimized C code then native code
* Have syntax, semantics and features similar to Lua
* Optionally statically typed with type checking
* Achieve classes, generics, polymorphism and other higher constructs by meta programming
* Have an optional garbage collector
* Make possible to create clean DSLs by extending the language grammar
* Make programming safe for non experts by doing run/compile-time checks and avoiding undefined behavior
* Possibility to emit low level code (C, assembly)
* Be modular and make users capable of creating compiler plugins to extended
* Generate readable, simple and efficient C code
* Possibility to output freestanding code (dependency free, for kernel dev or minimal runtime)
* No single memory management model, choose for your use case GC or manual

## Why?

* We love to script in Lua.
* We love C performance.
* We want best of both worlds in a single language and with a unified syntax.
* We want to reuse or mix existing C/C++/Lua code.
* We want type safety and optimizations.
* We want to have efficient code while maintaining readability and safety.
* We want the language features and manual to be minimal and fit our brain.
* We want to deploy anywhere C runs.
* We want to extended the language features by meta programming or modding the compiler.
* We want to code with or without garbage collection depending on our use case.
* We want to abuse of static dispatch instead of dynamic dispatch to gain performance and correctness.

## Contributing

You can support or contribute to Nelua in many ways,
giving the project a star on github,
testing out its features,
reporting bugs,
discussing ideas,
helping other users,
spreading it to the world,
sharing projects made with it on github,
creating tutorials or blog posts,
improving its documentation
or through a [donation or sponsorship](https://patreon.com/edubart).

Nelua is open source,
but not very open to contributions in the form of pull requests,
if you would like something fixed or implemented in the core language
try first submitting a bug report or opening a discussion instead of doing a PR.
The authors prefer it this way, so that the ideal solution is always provided,
without unwanted consequences on the project, thus keeping the quality of the software.

Read more about contributing in the [contributing page](https://github.com/edubart/nelua-lang/blob/master/CONTRIBUTING.md).

[![Become a Patron](https://c5.patreon.com/external/logo/become_a_patron_button.png)](https://www.patreon.com/edubart)

## License

MIT License
