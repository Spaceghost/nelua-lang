---
layout: docs
title: What this fork adds
permalink: /fork/
categories: docs toc
toc: true
order: 8
---

{% raw %}

[Spaceghost/nelua-lang](https://github.com/Spaceghost/nelua-lang) is upstream Nelua
(`a5845056`, 2025-06-24) plus a small set of language features and tools that a C library
written in Nelua ([nelibc](https://github.com/Spaceghost/nelibc)) and a userland built on it
([nebox](https://github.com/Spaceghost/nebox)) asked for. This page explains each addition in
plain terms: the problem it solves, what the code looks like, what it costs at run time, and
where its limits are. Everything here compiles to the same kind of C upstream emits, needs no
garbage collector and works under `pragmas.nogc` and `pragmas.freestanding`.
{: .lead}

Code written for upstream Nelua compiles unchanged. Every feature below is opt-in: you reach for
it by writing new syntax or by requiring a new library, never by accident.
{: .callout.callout-info}

## At a glance

| Addition | You write | At run time |
| --- | --- | --- |
| [Variants](#variants) | `local v: integer\|string = 3` | a tag byte and a C union |
| [Optionals](#optionals) | `local x: integer? = nil`, `f()?`, `x orelse 0` | a flag and the value (a bare pointer for `*T?`) |
| [`match`](#match) | `match v do case local n: integer then ... end` | one C `switch` on the tag |
| [Ownership](#ownership-and-move) | `local Buf <owned> = @record{...}`, `move(a)` | nothing: all checks are at compile time |
| [Closures](#closures) | `function(x) return x + n end`, `<byref>` | a record holding the captured values |
| [Const pointers](#const-pointers) | `*const T` | C `const T*` |
| [Freestanding](#freestanding) | `## pragmas.freestanding = true` | nothing: it removes code, never adds it |
| [Cross compiling](#cross-compiling) | `nelua --target aarch64-linux-musl` | the target's type sizes and ABI |
| [Bindings](#generated-c-bindings) | `nelua-bindgen zlib.h -o zlib.nelua` | `<cimport>` declarations, no wrappers |
| [Compile-time evaluation](#compile-time-evaluation) | `comptime(f(x))`, `function f() <comptime>` | only the folded result |
| [Syntax extensions](#syntax-extensions) | `#syntax 'syntax.compound'`, then `x += 1` | nothing: rewritten to ordinary Nelua while parsing |
| [Libraries](#libraries) | `require 'algorithm'`, `heapqueue`, `tuple` | ordinary generic records |

## Variants

A variant holds exactly one value out of a fixed list of types, and remembers which one. It is
the building block for "this or that" data without resorting to `any`, pointers to records with
a kind field, or unions that forget their own tag.

```nelua
require 'variant'

local Token = @variant(integer, string, boolean) -- or: @(integer|string|boolean)
local t: Token = 42              -- the member type converts implicitly
print(t == 42)                   -- compares against a bare member value, outputs: true
print(t:is(integer), t:get(integer)) -- outputs: true	42
t = 'end'
print(t:is(string), t:get(string))   -- outputs: true	end
print(t)                         -- outputs: variant(int64, string, boolean): end
```

Under the hood a variant is a plain record: a `uint8` tag followed by a C union of the members.
There is no heap allocation and no hidden pointer, so it works in freestanding code and inside
other records and arrays. A default-initialized variant is *empty* (tag 0), which `match` and
`:is()` treat as its own state.

Useful methods: `:is(T)`, `:get(T)` (checked), `:set(value)`, `:visit(function)`, and `==`
against another variant or a member value. `__eq` is instantiated on first use, so declaring a
variant never compiles comparisons of members you do not compare. In the preprocessor,
`V.value.types` lists the member types in declaration order.

Read more: [Variant in the overview](/overview/#variant).

## Optionals

An optional holds a value or nothing. It replaces the Lua habit of returning `nil` for "not
found" in a typed world, and the C habit of a sentinel value and an `errno`.

```nelua
require 'optional'

local function find(k: integer): integer?   -- `T?` is short for `optional(T)`
  if k == 1 then return 10 end
  return nil
end

local a = find(1) orelse 0                 -- unwrap, or use the default (evaluated lazily)
if local x = find(2) then print(x) end     -- binds the held value only when there is one
if find(2) == nil then print('empty') end  -- outputs: empty
```

Three pieces of syntax come with it:

* **`orelse`** unwraps or yields a default. The default is only evaluated when needed, so
  `cache[k] orelse load(k)` does not call `load` on a hit.
* **`if local x = e then`** tests an optional and binds its value in one step.
* **The postfix `?`** turns "empty" into an early return. In a function that itself returns an
  optional (or a nilable pointer, or the stdlib `(value, errmsg)` pair), `local f = io.open(p)?`
  returns the failure to the caller when there is one and binds the value otherwise. The
  statement form `f()?` works too.

An `integer?` is a flag plus the value. A pointer optional `*T?` keeps the size of a bare
pointer: `nilptr` is its empty state, so a `*Node?` field in a record is free. Constant optionals
at the top scope (`= 3`, `= nil`, `= nilptr`, `= &g`) become C static initializers.

Read more: [Optional in the overview](/overview/#optional),
[library reference](/libraries/#optional).

## `match`

`match` is how you take a variant or an optional apart. It checks that you handled every case
and compiles down to a single C `switch`.

```nelua
require 'variant'

local Shape = @variant(integer, string)  -- a radius, or a named shape
local shapes: [2]Shape = {7, 'square'}

for i = 0, 1 do
  match shapes[i] do
  case local r: integer then print('circle', r)    -- `r` is an `integer` here
  case local name: string then print(name)
  case nil then print('empty')                     -- the default-initialized state
  end
end
```

What the compiler guarantees:

* **Exhaustiveness.** Without an `else`, every member type and `nil` must be covered. Add a
  member to the variant and every `match` without `else` becomes a compile error until you
  write the new case. The error lists exactly what is missing.
* **No duplicates.** A type (or `nil`) can appear in one case only.
* **Several types per case.** `case integer, boolean then` shares a block, without a binding.
* **No run-time cost beyond the `switch`.** The statement is rewritten at compile time into
  `do local __match = &subject; switch __match.tag ... end`. There is no runtime library, no
  function call and no allocation; `break` and `continue` inside a case reach the enclosing
  loop exactly as they would from a `switch`. `fallthrough` is not allowed.

### Binding a copy or a reference

`case local x: T then` binds a *copy* of the held value, which is right for small members.
`case local x: *T then` binds a *pointer to the value inside the subject*, so you can read a
large member in place or change the subject through it; `*const T` gives a read-only pointer.

```nelua
match shapes[0] do
case local r: *integer then $r = $r * 2   -- writes into shapes[0]
case string, nil then
end
print(shapes[0]) -- outputs: 14
```

A subject that is a variable, field, element or dereference is matched *in place*, through its
address; a pointer to a variant or an optional is matched through; only a call result or
constructor is copied into the hidden local. If a member type is itself a pointer (`*integer` in
`variant(*integer, string)`), `case local p: *integer` matches that member exactly before the
reference reading is tried.

The same statement works on optionals, where `nil` is the empty state:

```nelua
require 'optional'

local o: integer? = 5
match o do
case local x: *integer then $x = $x + 1  -- updates the value inside `o`
case nil then
end
print(o orelse 0) -- outputs: 6
```

`match` is a *contextual* keyword, not a reserved word: `string.match`, `s:match(p)` and
`local match = 1` keep working. The statement is only recognized when a `case` follows the
subject.

Read more: [match in the overview](/overview/#variant).

## Ownership and `move`

A record that releases something in `__close` (memory, a file descriptor, a lock) is unsafe to
copy: two copies release it twice. Mark such a record `<owned>` and the compiler makes its
values *affine*: one holder at a time, moves are explicit, and a moved-from variable cannot be
read until it is assigned again.

```nelua
require 'allocators.general'

local Buf <owned> = @record{data: pointer, size: usize}

function Buf.create(size: usize): Buf
  return Buf{data = general_allocator:alloc(size), size = size}
end

function Buf:__close()
  general_allocator:dealloc(self.data)
  self.data = nilptr
end

local a = Buf.create(16)
-- local b = a          -- error: 'a' has owned type 'Buf', write `move(a)` or take `&a`
local c = move(a)       -- ownership passes to `c`; `a` is reset to its zero value
-- print(a.size)        -- error: variable 'a' of owned type 'Buf' was moved on line N
a = Buf.create(8)       -- assigning `a` makes it live again
c:__close()
a:__close()
```

Rules, all enforced at compile time and all free at run time:

* Copying an lvalue of an owned type needs `move`: in assignments and declarations, as a
  by-value argument (including a by-value `self`), inside record and array literals, and in a
  `return` of anything but a plain local. Rvalues (calls, constructors, `move(...)`) transfer
  ownership on their own.
* `move(x)` yields the value and resets `x` to zero, so a stale `__close` releases nothing.
* Reading a moved variable is an error. The check is flow sensitive: a move inside one branch
  of an `if`, a `switch` case or a loop body leaves the variable *maybe moved* afterwards, which
  is also an error; a branch that ends in `return`, `break`, `continue` or `goto` does not leak
  its moves; a variable moved by the end of a loop body is reported where the next iteration
  would read it.
* Records with an owned field and arrays of owned values are owned implicitly.
* A `<close>` variable cannot be moved or returned. Pointers never move: pass `&a` to lend.
* Only variables are tracked, not fields, and nothing is tracked across calls. This is an aid
  against double release and use after release, not a memory safety proof.

In the standard library `heapqueue` and `list` are owned. A `vector` of an owned type owns
its elements and is owned itself: `push`/`insert` take a value with `move`, `pop`/`remove`
hand it back, `clear`, a shrinking `resize`, `removeif` (whose predicate then takes a
reference) and `destroy` close what they drop, and `copy`/`removevalue` are left out; a
`sequence` of an owned type works the same way (and leaves out `unpack`), and so does a
`hashmap` with an owned value type: `set(key, move(v))` closes the value it replaces, `remove`
hands it back, `erase`/`clear`/`destroy` close, and only `mpairs` iterates. Other containers,
and `stringbuilder` and `filestream`, are not owned yet,
because parts of the library still pass them by value; the overview lists the places.

Read more: [Ownership in the overview](/overview/#ownership).

## Closures

Upstream Nelua rejects a nested function that reads a local of the enclosing function. This
fork allows it: the function becomes a *closure record*, a record that holds a copy of each
captured variable and a `__call` metamethod with the body. It is a plain value, needs no GC and
can be returned, stored or passed around.

```nelua
local function make_adder(n: integer)
  return function(x: integer): integer return x + n end
end
local add2 = make_adder(2)
print(add2(1)) -- outputs: 3
```

Captures are **by value**: the closure gets its own copy at creation time, and assigning to a
captured variable inside the closure changes that copy only. When you want the closure to
*share* the enclosing variables, annotate it `<byref>` and the record holds pointers instead:

```nelua
local function sum(limit: integer): integer
  local total = 0
  local function add(v: integer) <byref> total = total + v end
  for i = 1, limit do add(i) end
  return total
end
print(sum(4)) -- outputs: 10
```

A `<byref>` closure points into the enclosing stack frame, so it must not outlive that frame:
do not return it or store it past the function's end. Named nested functions
(`local function g() ... end`) are closures in the same way when they capture something; top
scope functions are unchanged and stay free.

Read more: [Closures in the overview](/overview/#closures).

## Const pointers

`*const T` is a pointer through which you can only read. It maps to C `const T*`, which is what
most C APIs take, so bindings and nelibc can state their intent and the compiler checks it.

```nelua
local function length(s: *const [0]cchar): usize
  -- $s[i] = 0   -- error: cannot write through a `*const` pointer
  local n: usize = 0
  while s[n] ~= 0 do n = n + 1 end
  return n
end
```

A `*T` converts to `*const T` implicitly; going the other way needs an explicit cast, so a
function that promises not to write cannot quietly hand the pointer to one that does.

Read more: [Const pointers in the overview](/overview/#const-pointers).

## Freestanding

`## pragmas.freestanding = true` turns a file into a component that an operating system, a
firmware image or a C program can link directly: no garbage collector, no allocator, no
entry point, no stdio, no panic handler. It implies `nogc` and `noentrypoint`, makes `abort`
a trap, and rejects at compile time any symbol that would drag the runtime in: heap allocation,
process control, stdio and `main`. The guarantee is in the emitted C and in `nm` of the linked
object, not in a convention.

nelibc's kernel-facing profile and the Drift drivers are built this way.

Read more: [Runtime-free native code](/runtime-free/).

## Cross compiling

`nelua --target <triple>` compiles for another architecture with clang or `zig cc`. The triple
reaches the three places it has to: the type-size probe (so `cint`, `csize` and pointer sizes
are the target's, never the host's), the cache hash (so a build for another target never reuses
the host's cached sizes) and the C compile itself.

```sh
nelua --target aarch64-linux-musl --cc 'zig cc' -o hello hello.nelua
```

## Generated C bindings

`tools/nelua-bindgen` reads C headers with libclang and writes `<cimport>` declarations, so a
C API does not have to be transcribed by hand. It maps C integer, pointer, array, struct,
union, enum and function types to their Nelua spellings, keeps `const` (as `*const T`), turns
string and numeric macros into constants, and handles opaque and forward-declared structs.
Options select what to emit (`--match`, `--exclude`), make types opaque (`--opaque`), unpack
enums (`--enum-using`), wrap pointer-returning functions in `*T?` optionals
(`--nullable-returns REGEX`) and prepend or append hand-written text from a JSON `--config`.

```sh
tools/nelua-bindgen/nelua-bindgen.py zlib.h --include-as '<zlib.h>' -o zlib.nelua
```

Read more: [nelua-bindgen README](https://github.com/Spaceghost/nelua-lang/blob/master/tools/nelua-bindgen/README.md).

## Compile-time evaluation

Some values are easiest to describe with a loop: a CRC table, a lookup of powers, a parsed
constant. Upstream Nelua can compute those in its Lua preprocessor, which means writing the
algorithm twice, once in Lua and once in Nelua. The fork can run an *ordinary Nelua function*
inside the compiler and put the result in the program:

```nelua
local function crc32_table(): [256]uint32
  local t: [256]uint32
  for i: uint32 = 0, 255 do
    local c: uint32 = i
    for _ = 1, 8 do
      if c & 1 == 1 then c = 0xEDB88320 ~ (c >> 1) else c = c >> 1 end
    end
    t[i] = c
  end
  return t
end

local CRC = comptime(crc32_table())  -- emitted as a C static initializer, no code runs at startup
print(CRC[1])                        -- outputs: 1996959894
```

Annotating a function `<comptime>` evaluates every call to it and never emits the function to C;
a call with an argument that is not known at compile time is an error naming that argument.

The function is translated to Lua and run in a sandbox that keeps C semantics: integers wrap at
their width, `uint64` divides as unsigned, `float32` rounds to single precision, records and
arrays are values. Each evaluation is bounded (`pragmas.comptime_steps`, `pragmas.comptime_stack`)
and cached per argument values. What it does not run: pointers other than references to records
and arrays, allocators and the GC, `io`/`os`, closures, `defer`, optionals and variants; each is
rejected with an error at the offending line. Records cannot be passed as arguments yet.

Read more: [Compile-time function evaluation in the overview](/overview/#compile-time-function-evaluation).

## Syntax extensions

The preprocessor can generate code, but it cannot change what the parser accepts. A top-level
`#syntax` directive can: it runs Lua code at compile time that adds grammar rules, and the rest of
*that file* is parsed with them. Each rule comes with a builder that turns what it matched into
ordinary Nelua AST, so the type checker and both code generators never see anything new.

Two extensions ship in `lib/syntax/`:

```nelua
#syntax 'syntax.compound'
#syntax 'syntax.pipe'

local x = 5
x += 3          -- x = x + 3; also -= *= /= //= %= ^= ..= |= &= <<= >>=

local t: [4]integer = {1, 2, 3, 4}
local i = 0
local function nexti() i = i + 1 return i end
t[nexti()] *= 10  -- a target with a call in it is evaluated once, through a pointer

local function add(a: integer, b: integer) return a + b end
local function half(a: integer) return a // 2 end
print(x |> half |> add(t[1]))     -- add(half(x), t[1]); outputs: 24
```

Writing one inline:

```nelua
#syntax [[
  syntax.statement("`unless` @expr @`then` Block @`end`", function(cond, body)
    return syntax.stat('if not (c) then body() end', {c = cond, body = body})
  end)
]]

unless x > 10 then print('small') end
```

The `syntax` table offers `statement(peg, builder)`, `expression(peg, builder)` (a new primary
expression), `unary(token, builder)`, `binary(level, token, builder)` (at the precedence of an
existing operator: `or and cmp orelse bor bxor band bshift concat arit fact pow`, always left
associative), `rules(text)` for helper rules, `error(label, message)`, `def(name, value)`,
`gensym(prefix)` and `raise(message, ...)`. Patterns are [LPegRex](https://github.com/edubart/lpegrex)
and may use any rule of the Nelua grammar (`expr`, `exprs`, `Block`, `name`, `typeexpr`, ...).
Builders get the captures and return a node; a statement builder may return a `Block`, which is
spliced into the enclosing block. `syntax.expr`, `syntax.stat` and `syntax.block` build nodes from
Nelua source in which identifiers named in the substitution table are replaced (`body()` as a
statement stands for a whole block).

`#syntax 'name'` loads `name.lua` from the file's directory, the Nelua library path
(`lib/syntax/pipe.lua`) or the Lua path; the module returns a function taking `syntax`.
Limits: `#syntax` is only accepted between top-level statements; extensions do not reach required
files or the files that require this one; templates are parsed with the base grammar; names a
builder introduces are not hygienic unless it uses `gensym`. A backtick keyword in a rule (such as
`` `unless` ``) becomes reserved for the rest of the file; use `'word' WORDSKIP` for a contextual one.

## Libraries

Three libraries were brought over from
[nelua-batteries](https://github.com/edubart/nelua-batteries), adapted to the fork's rules
(no hidden copies of owned values, `*const` where nothing is written):

* **`algorithm`**: `sort` (introsort) and `heapsort` on any indexable container with a `__len`,
  `removeif`, and `packn`/`unpackn` for fixed arrays.
* **`heapqueue`**: a binary heap priority queue, owned, with `push`, `pop`, `top`, `remove`,
  `reserve` and `__close`.
* **`tuple`**: a fixed, heterogeneous tuple with `pack`, `unpack` and indexing.

Read more: [algorithm](/libraries/#algorithm), [heapqueue](/libraries/#heapqueue),
[tuple](/libraries/#tuple).

## Editor support

The Tree-sitter grammar (`tools/tree-sitter-nelua`, with a scanner written in Nelua) and the
TextMate grammar (`tools/textmate-nelua`) know every addition on this page: `*const T`,
`A|B`, `T?`, `expr?`, `orelse`, `if local`, anonymous `function` expressions and the `match`
statement.

## How changes are gated

Each addition lands with a spec in `spec/` and a section in these docs. `make test` runs
upstream's suite plus the fork's specs; nelibc's smoke matrix and nebox's conformance suite are
rebuilt against the fresh compiler in a pinned container before a change reaches `master`.
Work that is not finished stays on a branch and is not described here as done.

{% endraw %}
