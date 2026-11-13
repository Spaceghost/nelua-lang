---
layout: docs
title: Syntax extensions
permalink: /syntax-extensions/
categories: docs toc
toc: true
order: 10
---

{% raw %}

Extend the language one file at a time. Load a ready-made syntax module, combine a
pack, or write grammar rules that turn your own notation into ordinary Nelua.
The type checker, ownership checks and C generator continue to do their usual work.
There is no extension interpreter in the resulting program.

## Start here

Use the complete pack for exploration, or load only the modules your file uses:

```nelua
#syntax 'syntax.all'
require 'string'
local double = fn(x: integer) => x * 2
local n = 1_000
times 3 do n += 1 end
print($"{n |> double}: {choose n > 1_000 then 'grown' else 'same' end}")
-- 2006: grown
assert(n == 1003)
```

`#syntax` runs during parsing and affects the rest of its source file. Put it
between top-level statements. A required file enables its own syntax; enabling a
module in a library does not enable it for that library's callers. Nothing is
enabled implicitly in ordinary upstream-compatible source files.

Run the complete tour with `./nelua examples/syntax_tour.nelua` from the compiler
checkout. Its source is in
[examples/syntax_tour.nelua](https://github.com/Spaceghost/nelua-lang/blob/master/examples/syntax_tour.nelua).

## Choose your modules

| Module | Adds | Lowers to |
| --- | --- | --- |
| `syntax.compound` | `x += 1`, `a[i] *= 2` | Assignments, with a temporary pointer for complex targets |
| `syntax.pipe` | `x |> f(a) |> g` | Ordinary calls |
| `syntax.interp` | `$"hello {name}, {n:%04d}"` | String literals, concatenation, `tostring`, `string.format` |
| `syntax.control` | `unless`, `until … do`, `guard`, `loop`, `times` | `if`, `while`, numeric `for` |
| `syntax.choose` | `choose test then a else b end` | A `do` expression containing `if` and `in` |
| `syntax.lambda` | `fn(x) => expr`, `fn(x) do … end` | An anonymous function |
| `syntax.let` | `let {x, y = other} = value`, `let [a, _, c] = value` | One source temporary and local declarations |
| `syntax.using` | `using name = value do … end` | A scoped local with `<close>` |
| `syntax.collect` | `collect(T; i = lo, hi when test => value)` | A `vector(T)`, a loop, an optional `if`, and `push` |
| `syntax.literals` | `1_000`, `b"1010_0101"`, `hex"de ad be ef"` | Number and string literals |
| `syntax.operators` | `**`, `!=`, `&&`, `||` | Native power, comparison and boolean operators |

`syntax.all` loads all the modules above. Loading a module again is a no-op in
that file, including when two packs share it. It does not add `require 'string'`
or `require 'vector'`: runtime dependencies remain explicit.

## Compound assignment

```nelua
#syntax 'syntax.compound'
local n = 10
n += 2
n *= 3
n //= 4
assert(n == 9)
local data: [2]integer = {5, 6}
local calls = 0
local function index() calls = calls + 1 return 0 end
data[index()] += 7
assert(data[0] == 12 and calls == 1)
```

Supported spellings are `+= -= *= /= //= %= ^= ..= |= &= <<= >>=`. Here `^=`
means power, as `^` does in Nelua. `~=` keeps its existing meaning, not-equal.
There is no xor-assignment spelling. The operator module does not add `**=`.

A complex target such as `data[index()]` is addressed once through a temporary
pointer, before the assignment. Simple names, fields, and constant or plain-name
indexes use the ordinary `target = target op value` rewrite. They therefore keep
the native assignment rules, including ownership restrictions and any changes
to an index variable caused by the right-hand side.

## Pipe calls

```nelua
#syntax 'syntax.pipe'
local function add(a: integer, b: integer) return a + b end
local function twice(a: integer) return a * 2 end
local result = 3 |> add(4) |> twice
assert(result == 14)
```

`x |> f` becomes `f(x)`. `x |> f(a, b)` becomes `f(x, a, b)`, and
`x |> object:method(a)` becomes `object:method(x, a)`. The right side must be a
function name, field, or call. The left expression appears once in the result.
It is not a placeholder-based pipeline, and it does not implicitly move an owned
variable.

Pipes group left at the bitwise-or level: arithmetic binds more tightly,
comparisons less tightly. Write parentheses around a larger boolean or comparison
that you want to pipe. Generated calls follow native argument evaluation rules;
use separate local declarations to sequence side effects in multiple arguments.

## Interpolated strings

```nelua
#syntax 'syntax.interp'
#syntax 'syntax.pipe'
require 'string'
local name, n = 'world', 3
local function twice(x: integer) return x * 2 end
local greeting = $"hello {name}, {n + 1} times"
local formatted = $"{{count}} {n:%04d}, doubled {n |> twice}"
assert(greeting == 'hello world, 4 times')
assert(formatted == '{count} 0003, doubled 6')
```

`{expression}` calls `tostring`; `{expression:%format}` calls `string.format`.
Only a top-level colon followed by `%` starts a format, so method calls such as
`{name:upper()}` work. `{{` and `}}` produce literal braces. Ordinary string
escapes, quoted strings inside expressions, nested braces and nested interpolated
strings are supported. Embedded expressions use the grammar active at the string's
position, including pipes and your own extensions.

`$"` must be adjacent. `$ pointer` remains dereference. Interpolation can allocate
strings, just as its generated concatenation and formatting calls can. Separate
side effects into statements when their order matters. Empty expressions,
unclosed expressions and an unmatched single `}` produce compile errors.

## Control flow

```nelua
#syntax 'syntax.control'
local total = 0
times 4 as i: integer do
  if i == 2 then continue end
  total = total + i
end
assert(total == 8)
until total >= 10 do total = total + 1 end
unless total > 10 then total = 20 else total = 30 end
loop do
  total = total + 1
  if total == 22 then break end
end
local function positive(n: integer): boolean
  guard n > 0 else return false end
  return true
end
assert(total == 22 and positive(total) and not positive(0))
repeat total = total - 1 until total == 20
assert(total == 20)
```

`unless condition then … [else …] end` tests the negated condition.
`until condition do … end` is a pre-test loop equivalent to `while not condition`;
ordinary `repeat … until condition` still works and remains a post-test loop.
`loop do … end` is `while true`.

`guard condition else … end` runs its block when the condition is false. It does
not insert a return or require the block to exit; write `return`, `break`, or
`continue` when that is your intent.

`times count [as index] do … end` is a numeric `for` from one through `count`.
The count is evaluated once on entry. Zero and negative integer counts run no
iterations. An explicit index accepts the normal declaration type and annotations;
an omitted index gets a generated name. Count and index types follow native
numeric-for rules. `break` and `continue` target this loop as usual.

The new words are contextual. You can still declare variables named `guard`,
`times`, `unless`, or `loop`, and call functions with those names.

## Conditional expressions

```nelua
#syntax 'syntax.choose'
local calls = 0
local function expensive(): integer calls = calls + 1 return 99 end
local condition = true
local n = choose condition then 42 else expensive() end
local flag = choose condition then false else true end
local nested = choose condition then choose false then 1 else 7 end else 0 end
assert(n == 42 and flag == false and nested == 7 and calls == 0)
```

Only the selected branch runs, and the condition runs once. A selected `false`,
`nil`, or `nilptr` is preserved; this is not an `and`/`or` fallback idiom. Both
branches are still analyzed and must satisfy the normal type rules for a `do`
expression. It is an expression form: use `if` when you need statements in a branch.

## Concise functions and closures

```nelua
#syntax 'syntax.lambda'
local function make_adder(offset: integer)
  return fn(x: integer): integer => x + offset
end
local add = make_adder(10)
local half = fn(x: integer) do
  local result = x // 2
  return result
end
assert(add(2) == 12 and half(8) == 4)
do
  local total = 0
  local bump = fn(x: integer) <byref> => (do total = total + x in total end)
  local first = bump(3)
  local second = bump(4)
  assert(first == 3 and second == 7 and total == 7)
end
```

The parameter list, optional `: returntype`, and optional function annotations
are the same as for `function`. `=> expression` becomes `return expression`;
`do … end` uses its statements as the function body. Use a block for multiple
returns or early exits. Parenthesize the whole concise function if you need to
call it immediately: `(fn(x: integer) => x + 1)(2)`.

Captures are the fork's existing closure records. By-value captures copy their
values; `<byref>` captures pointers and must not outlive the captured frame. Native
closure restrictions, including which scopes accept `<byref>`, still apply.

## Destructuring locals

```nelua
#syntax 'syntax.let'
local Point = @record{x: integer, y: integer}
local calls = 0
local function make_point(): Point calls = calls + 1 return {20, 22} end
let {x, y = height: integer,} = make_point()
let [first, _, third] = (@[3]integer){10, 20, 30}
assert(x + height == 42 and first + third == 40 and calls == 1)
```

Record patterns bind fields by name; `field = localname` renames a binding and
accepts a typed local declaration. Record patterns allow a trailing comma. Array
patterns start at index zero, accept typed declarations, and use `_` to skip a
position. A record alias of `_` skips that field. Duplicate bound names are an
extension error. Missing fields and out-of-bounds constant indexes receive the
normal compiler diagnostics.

The source is evaluated once into a temporary; bindings are separate local
declarations visible after the statement. They are values, not references, and
do not track later source changes. Pointers to records can be destructured using
normal field access. Copying an owned lvalue is still rejected; use native
references and explicit `move` where ownership is involved. Keep resource-owning
sources in a `using` block and destructure a borrowed pointer; the hidden source
temporary does not schedule cleanup. Nested patterns and assignment into existing
locals are not part of this form.

## Scoped resources

```nelua
#syntax 'syntax.using'
local Resource = @record{closed: *integer}
function Resource:__close() $self.closed = $self.closed + 1 end
local closed = 0
local function use_resource(): integer
  using resource: Resource = Resource{&closed} do
    return 42
  end
  return 0
end
local answer = use_resource()
assert(answer == 42 and closed == 1)
```

`using name = expression do … end` creates a `do` scope with a local `<close>`
binding. The initializer runs once and cleanup follows normal Nelua rules on
fallthrough, `return`, `break`, and `continue`. The binding is visible only inside
the block. Type annotations and existing declaration annotations work; an
explicit `<close>` is not duplicated. Nest blocks for multiple resources; cleanup
runs in the usual reverse scope order. This is deterministic scope cleanup and
does not add exception handling or cleanup after process termination.

## Vector comprehensions

```nelua
## pragmas.nogc = true
#syntax 'syntax.collect'
require 'vector'
local squares <close> = collect(integer; i = 1, 8 when i % 2 == 0 => i * i)
local descending <close> = collect(integer; i = 5, 1, -2 => i)
local exclusive <close> = collect(integer; i = 0, < 3 => i)
local input: [4]integer = {10, 20, 30, 40}
local selected <close> = collect(integer; i, value in ipairs(input) when i % 2 == 0 => value + 1)
assert(#squares == 4 and squares[3] == 64)
assert(#descending == 3 and descending[2] == 1)
assert(#exclusive == 3 and exclusive[2] == 2)
assert(#selected == 2 and selected[0] == 11 and selected[1] == 31)
```

Write `collect(ElementType; iterator => expression)` with an optional
`when condition` before `=>`. The iterator can be a numeric loop, including a
step or comparison bound, or a generic iterator such as `i, value in ipairs(a)`.
The semicolon distinguishes this notation from an ordinary `collect(value)` call.
Its initialization follows the corresponding native `for` rules. The filter runs
once per visited iteration; the mapped expression runs once per accepted one.
Elements are pushed in iteration order into a zero-based `vector(ElementType)`.
An empty range or a filter that never matches produces an empty vector.

The element type is explicit and `vector` must be in scope. This form allocates
and grows a vector using the normal default allocator. It works under `nogc` with
`<close>`, `using`, or explicit destruction. It is not a lazy iterator, a fixed
array constructor, or a freestanding heap substitute. Element insertion and
returning the result retain the vector library's normal ownership rules.

## Literal notation

```nelua
#syntax 'syntax.literals'
require 'string'
local size = 1_024
local wide: uint64 = 18_446_744_073_709_551_615_u64
local decimal = 1_234.5_625e-1
local flags = b"10 1010"
local bytes = hex"00 41_ff"
assert(size == 1024 and wide == 0xffffffffffffffff_u64)
assert(decimal == 123.45625 and flags == 42)
assert(#bytes == 3 and bytes:byte(1) == 0 and bytes:byte(3) == 255)
```

Grouped decimal literals require a separator in their integer part. Groups must
contain digits; fractional and exponent groups may also use `_`. Existing suffixes
such as `_u64` are passed to the native literal machinery. Ungrouped decimals,
hexadecimal numbers and native binary numbers retain their existing syntax.
The decimal digits are passed as text, so wide integers are not rounded through
Lua's floating-point type.

`b"…"` is a binary integer with optional spaces or underscores. It needs at least
one digit and permits only `0` and `1` after separators are removed. `hex"…"` is a
byte string; each byte needs two hexadecimal digits. Spaces and underscores are
ignored, upper and lower case both work, and an empty byte string is allowed.
Embedded zero bytes are preserved. These forms do not interpret string escapes.
Overflow and supported integer widths remain the native compiler's responsibility.

## Alternative operators and precedence

```nelua
#syntax 'syntax.operators'
local calls = 0
local function tick(): boolean calls = calls + 1 return true end
local a = false && tick()
local b = true || tick()
assert(not a and b and calls == 0)
assert(4 != 5 && 2 ** 3 ** 2 == 512)
assert(1 + 2 ** 3 * 2 == 17)
```

`!=` is `~=`, `&&` is `and`, `||` is `or`, and `**` is `^`. Both boolean operators
short-circuit exactly as their native equivalents do. Power groups to the right
and follows Nelua's native numeric promotion rules, so an integer-looking power
can produce a floating-point value. Built-in spellings remain available.

`syntax.binary(level, token, builder)` attaches an operator at an existing level.
The table runs from weakest to strongest; these are the actual API level names.

| Level | Native examples | Shipped additions |
| --- | --- | --- |
| `or` | `or` | `||` |
| `and` | `and` | `&&` |
| `cmp` | `== ~= < <= > >=` | `!=` |
| `orelse` | `orelse` | — |
| `bor` | bitwise `\|` | `\|>` |
| `bxor` | `~` | — |
| `band` | `&` | — |
| `bshift` | `<< >> >>>` | — |
| `concat` | `..` | — |
| `arit` | `+ -` | — |
| `fact` | `* / // /// % %%%` | — |
| `pow` | `^` | `**` |

The power level's right operand is a unary expression, which can contain another
power; this gives power its right grouping. Prefix unary operators sit between
multiplication and power, as in the base grammar. Other added binary operators
fold left at their level, including added operators at `concat`. Native `..`
retains its own right-recursive operand rule. Use parentheses to make mixed
operator intent clear; the API does not create arbitrary new precedence levels.

## Write an inline extension

The following adds a contextual `check condition else message` statement:

```nelua
#syntax [[
  syntax.statement("'check' WORDSKIP expr `else` @expr", function(condition, message)
    return syntax.stat('assert(c, message)', {c=condition, message=message})
  end)
]]
local answer = 42
check answer == 42 else 'unexpected answer'
```

The pattern uses [LPegRex](https://github.com/edubart/lpegrex) and can reference
base grammar rules from `lualib/nelua/syntaxdefs.lua`: `expr`, `exprs`, `Block`,
`name`, `iddecl`, `iddecls`, `typeexpr`, `funcargs`, and more. Captures become
builder arguments in order. `name` captures text; `expr` captures an AST node;
`iddecls` captures a list. `@expr` commits to an expression and reports an error
if it is missing. Delay committed matches until the extension's opening is
unambiguous, so normal calls and assignments can backtrack into the base grammar.

Backticks use Nelua's token machinery, including whitespace and comments. A new
word in backticks becomes reserved for the remainder of the file. For contextual
words use `'word' WORDSKIP`, which also checks the identifier boundary. A raw
quoted punctuation literal does not skip whitespace; add `SKIP` explicitly when
that is required.

## Builder API reference

| Call | Contract |
| --- | --- |
| `syntax.statement(peg, builder, options)` | Add a statement before built-in alternatives. Return one AST node or a `Block` to splice into its enclosing block. Optional `{fallback=true}` tries the rule after specific statements, before native assignments and calls. |
| `syntax.expression(peg, builder)` | Add a primary expression before the built-in simple expressions. Return one expression AST. |
| `syntax.prefixexpr(peg, builder)` | Match an expression before built-in prefix operators; useful for claiming `$"` before `$`. |
| `syntax.unary(token, builder)` | Add a prefix operator. The builder receives its operand. |
| `syntax.binary(level, token, builder)` | Add an infix operator at a listed precedence. The builder receives left and right operands. |
| `syntax.rules(text)` | Add named LPegRex helper rules. Existing rule names cannot be shadowed; use a module-specific prefix. |
| `syntax.error(label, message)` | Give a PEG error label a readable diagnostic. Use `@rule` or `^Label` to throw it. |
| `syntax.def(name, value)` | Expose an LPegRex definition, for example a `->name` capture transform. |
| `syntax.use(module)` | Load another extension into the same file's state. Shared dependencies are applied once; cycles are errors. |
| `syntax.gensym(prefix)` | Get a compiler-unique identifier for a temporary. Reserve the `__sx_` namespace for generated code. |
| `syntax.expr(text, substitutions)` | Parse a template containing exactly one expression. |
| `syntax.stat(text, substitutions)` | Parse statements; return a single node or a spliced block. |
| `syntax.block(text, substitutions)` | Parse statements and always return a block. |
| `syntax.raise(message, ...)` | Raise a formatted compile error at the syntax use being expanded. |
| `syntax.aster` | Access ordinary AST constructors, such as `BinaryOp`, `Function`, and `VarDecl`. |
| `syntax.levels` | Inspect the level-to-right-operand-rule mapping used by `binary`. |

Builders execute bottom-up after parsing. Child extensions have already become
ordinary AST before a parent builder sees them. A builder must return an AST
node, not a Lua number, string, or plain list. Use `syntax.aster.Number{'42'}`,
`syntax.aster.String{'text'}`, or a template to create literal expressions.
An expression builder cannot return a block of statements; wrap statements in
a native `(do … in value end)` expression instead.

Call registration methods and `syntax.use` while the module loads or inside an
inline `#syntax` directive. Builders run after the source has been parsed; their
job is to construct the replacement AST, rather than change the accepted grammar.

## Templates, substitution and generated names

```nelua
#syntax [[
  syntax.statement("'twice' WORDSKIP expr `do` Block @`end`", function(value, body)
    local name = syntax.gensym('repeat')
    return syntax.stat('for index = 1, count do body() end', {
      index=name, count=value, body=body,
    })
  end)
]]
local n = 0
twice 2 do n = n + 3 end
assert(n == 6)
```

Substitution is structural. An identifier whose name is a substitution key is
replaced by an AST clone, a numeric or boolean literal, or an identifier when the
value is a Lua string. A string substitution is an identifier, not a string
literal: use `syntax.aster.String{value}` for a literal. String substitutions
also rename declarations, field names, labels and other named AST slots.

An empty statement call such as `body()` splices a captured `Block` or list of
statements. A placeholder in an argument or expression list can splice a list
of expressions. Lists cannot replace a single expression. Cloning substitutions
lets a builder reuse a captured tree without sharing mutable AST nodes.

Templates use the grammar active where the extension is used, so they can contain
other enabled extensions. That grammar is recorded per syntax use, rather than
taken from the end of the file. A template cannot contain `#syntax`. Expansion
inside a template happens before its placeholders are substituted: placeholder
names should stand on their own, rather than depend on a type known only after
substitution. Generated trees receive the original syntax use's source location,
so analyzer errors refer to the source construct.

`gensym` prevents accidental reuse between builders. It does not make arbitrary
captured user code hygienic: avoid fixed helper names, and keep generated locals
in the narrowest appropriate scope. A returned statement `Block` is spliced and
does not add scope; return a `Do` statement when bindings must remain private.

## Package and compose extensions

Save a Lua module next to your source file, for example `project_syntax.lua`:

```lua
return function(syntax)
  syntax.use('syntax.control')
  syntax.use('syntax.compound')
  syntax.statement("'bump' WORDSKIP name", function(name)
    return syntax.stat('target += 1', {target=name})
  end)
end
```

Then use `#syntax 'project_syntax'` in your source file. Dots in module names map
to directories as in Lua. A top-level directive searches beside the source file,
then the Nelua library path and the Lua package path. A nested `syntax.use` first
searches beside the module doing the loading. The module must return a function
taking the syntax API; it should keep file-specific state inside that function,
because the compiler caches the loaded Lua module across parsed files.

Helpers should use module-specific rule and definition names. Two different
modules defining the same helper rule are an error; two modules claiming the same
surface spelling may compete by PEG registration order. The first matching
alternative wins. Use a single project pack to make registration order explicit,
and test it with every extension you plan to combine.

Broad statement rules that start with `var`, such as compound assignment, should
use `{fallback=true}`. A committed index error while probing `var` can otherwise
consume a contextual opening such as `let [a, b]` before its own rule gets tried.

## Diagnostics and practical limits

Read the compiler's named error and its highlighted source construct. A missing
module names the module and searched paths; circular `syntax.use` dependencies
are rejected. Invalid PEG rules are reported at the directive, and
`syntax.raise` reports at the construct the builder is expanding. A bad template
adds an `in syntax template` diagnostic. Once expansion succeeds, normal Nelua
diagnostics handle types, declarations, ownership and unsupported target features.

Extension Lua has the compiler process's host access, like preprocessor Lua;
load modules you trust. It is distinct from the bounded `comptime` evaluator.
Do not use host-dependent builder decisions when cross-target output needs to
be reproducible. The extensions add no runtime framework, but their generated
code has the same costs and platform requirements as hand-written equivalents.

In particular, interpolation may allocate, comprehensions allocate a vector,
closures retain their lifetime rules, and freestanding mode continues to reject
heap-dependent code. Loading `syntax.all` alone requires none of those runtime
libraries. Static editor grammars cannot infer arbitrary file-local PEG rules;
custom forms may need your editor's grammar updated, even when the compiler
accepts them. Both code generators receive standard AST, and their existing
feature restrictions still apply.

To validate an extension, compare its expansion to ordinary Nelua, run it with
side-effecting operands, try its malformed forms, and check that unrelated source
still parses. The regression coverage is in `spec/syntaxext_spec.lua` and
`spec/syntaxlib_spec.lua`; the complete guide examples are executable checks.

{% endraw %}
