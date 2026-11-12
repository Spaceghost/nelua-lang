---
layout: docs
title: Compile-time evaluation
permalink: /comptime/
categories: docs toc
toc: true
order: 9
---

{% raw %}

Compute static data with ordinary Nelua functions. The compiler evaluates the function,
checks its arguments and supported operations, and substitutes the result into the program.
Typed record configurations can be named, reused, nested, and transformed into tables without
building those tables on the target.
{: .lead}

## Two forms

`comptime(f(args))` evaluates one call. The function can also be called normally at runtime:

```nelua
local function add(a: integer, b: integer): integer return a + b end
local SUM <comptime> = comptime(add(20, 22))
assert(SUM == 42)
```

Annotating a named function `<comptime>` makes every call a compile-time call. Such a
function is never emitted to C; a runtime argument is an error:

```nelua
local function square(n: integer): integer <comptime> return n * n end
local N <comptime> = square(7)
assert(N == 49)
```

A normally declared function used through `comptime(...)` can still be emitted to C, even
when all its calls are folded. Use the function annotation when the builder itself should
have no target code. The folded call never runs on the target in either form.

## Named configurations

A `<comptime>` record variable holds an immutable compile-time value. Its fields can be
read as constants, and the whole value can be passed to an evaluable function or copied
into a normal runtime variable. These rules also apply to fixed arrays of records.

```nelua
local Link = @record{baud: uint32, parity: uint8}
local RadioConfig = @record{
  reference_hz: uint32,
  link: Link,
  rates: [3]uint32,
}

local RADIO <comptime> = RadioConfig{
  reference_hz = 32000000,
  link = {baud = 9600},          -- parity defaults to zero
  rates = {9600, 19200, 38400},
}

local function make_table(config: RadioConfig): [3]uint32 <comptime>
  local result: [3]uint32
  for i = 0, 2 do
    assert(config.rates[i] > 0, 'rate must be positive')
    result[i] = config.reference_hz // config.rates[i]
  end
  return result
end

local TABLE = make_table(RADIO)
local PARITY <comptime> = RADIO.link.parity
print(TABLE[0], TABLE[1], TABLE[2]) -- 3333, 1666, 833, separated by tabs
assert(PARITY == 0)
```

These divisions demonstrate static configuration; they are not a device-qualified clock
or peripheral-register formula. The runnable version is
[`examples/comptime_config.nelua`](https://github.com/Spaceghost/nelua-lang/blob/master/examples/comptime_config.nelua).

Arguments may instead be literal records, inferred initializer lists, or the folded results
of other compile-time calls. Positional fields, named fields, and normal record initializer
ordering all work. Nested records and arrays preserve their types; omitted members receive
the type's zero value. `RadioConfig{}` and `RadioConfig()` create a zero-initialized record.

## Constants and runtime values

`<comptime>` describes when a value is available. A normal variable is a runtime value even
when its initializer is constant; `<const>` makes a variable read-only but does not make it
a compile-time value.

```nelua
local Config = @record{size: integer}
local function size(config: Config): integer <comptime> return config.size end
local CONFIG <comptime> = Config{size = 8}
local N <comptime> = size(CONFIG) -- 8
local copy = CONFIG             -- ordinary runtime record, initialized from the constant
copy.size = 9
assert(CONFIG.size == 8)
-- size(copy)                    -- error: argument 1 is not a compile time value
-- CONFIG.size = 9               -- error: cannot assign to a read-only value
```

The C backend substitutes uses of the compile-time record with values or initializers.
It does not need a runtime configuration object merely to evaluate a constant field read.
A runtime copy is an ordinary record with ordinary record storage and lifetime.

## Value semantics

Each record or array argument is passed by value, including its nested records and arrays.
Changing a local parameter or a runtime copy does not change the named configuration:

```nelua
local Point = @record{x: integer, y: integer}
local Board = @record{origin: Point, cells: [2]Point}
local BOARD <comptime> = Board{origin = {2, 3}, cells = {{4, 5}, {6}}}

local function summarize(board: Board): integer <comptime>
  board.origin.x = board.origin.x + 1
  return board.origin.x * 100 + board.cells[0].y
end
local SUMMARY <comptime> = summarize(BOARD)
assert(SUMMARY == 305 and BOARD.origin.x == 2 and BOARD.cells[1].y == 0)
```

A record result can itself initialize a `<comptime>` variable, be passed to another evaluated
function, or initialize a runtime record. Runtime inputs do not become compile-time inputs
through a cast or by placing them inside a record literal.

## Generated C and freestanding code

Scalar results become constants; array and record results become initializers. At the top
scope they can be C static initializers. For the configuration example, the generated array
contains `3333U`, `1666U`, and `833U`; the `<comptime>` table builder is absent from the C.
Generated names and container wrappers follow the usual C backend conventions.

```sh
nelua examples/comptime_config.nelua
nelua --print-code examples/comptime_config.nelua > comptime_config.c
```

CTFE adds no target interpreter, allocator, GC, or initialization loop. It also works in the
freestanding profile when the emitted program uses only permitted operations. Compile-time
diagnostics such as `assert` or `print` belong to the compiler process; target-side `print`
in the runnable example still requires a hosted program. See the
[runtime-free guide](/runtime-free/) for the freestanding contract.

## Cache behavior

Within one compilation, results are cached by function and converted argument values.
Record fields are serialized in declaration order; omitted zero fields and explicitly
specified zero fields describe the same value. Nested array and record contents, booleans,
strings, and numeric values participate in the key. Distinct floating-point inputs stay
distinct after conversion to the declared parameter type.

Every evaluation receives independent argument values, and substituting a cached aggregate
result does not share mutable state with another use. Compiler-side output happens only
when a call is actually evaluated, so repeating a cached call need not print again.

## Supported subset and numeric behavior

The evaluator translates analyzed function bodies to Lua and runs them in a bounded
environment. It supports scalars, booleans, strings, enums, fixed arrays and ordinary records
of supported values, ordinary control flow, and calls to other evaluable functions.
External variables read by an evaluated function must be `<comptime>` values.

Fixed-width integer operations wrap at their declared widths; unsigned division and
comparisons, shifts, and Nelua's floor/truncating division operations retain their Nelua
semantics. `float32` values round to single precision and `float64` uses the compiler host's
double precision. Transcendental functions mapped to host Lua math may differ from a target
C library in their last digits; CTFE is not a guarantee of cross-platform floating-point
bit identity.

References to evaluator-owned records and arrays allow methods and local aggregate updates.
The evaluator does not dereference target addresses. Records with pointer fields are
rejected, as are optionals, variants, closures, `defer`, `for in` iterators, dynamic containers,
allocators, GC, C function imports, OS APIs, and target I/O. The supported pure `math` and
`string` functions are listed in `lualib/nelua/comptime.lua`.

## Errors and resource limits

A runtime argument reports its argument position and type. An unsupported field, type,
operation, imported function, or external variable reports why evaluation cannot proceed.
Assertions and evaluator errors become compilation failures at the evaluated call.

Each evaluation has instruction and call-depth budgets:

```nelua
## pragmas.comptime_steps = 10000000 -- default Lua-instruction budget
## pragmas.comptime_stack = 10000    -- default nested-call budget
```

An over-budget computation fails compilation with a diagnostic naming the limit. Raise a
budget for a known bounded computation; do not use CTFE for unbounded searches or target I/O.
Large static tables also increase compiler memory use and generated object size.

The analyzer, C and Lua backend specs and `tests/comptime_test.nelua` cover structured
arguments, defaults, named constants, mutation isolation, cache behavior, diagnostics and
agreement with ordinary runtime evaluation.

{% endraw %}
