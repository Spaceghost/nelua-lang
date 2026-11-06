# Optional types and `?` propagation for Spaceghost/nelua-lang (final design, not implemented)

Base: Design 1 (judge average 6.75 vs 6.5 and 4.25). `T?` is sugar for a preprocessor generic `optional(T)` in
`lib/optional.nelua`, built like `lib/variant.nelua` (record + `__convert` concept + `<nickname>`) and wired like
`A|B` (`visitors.VariantType` -> `aster.GenericType{Id'variant', ...}`). Postfix `expr?` is a `Try` node rewritten
in the analyzer into a `DoExpr` with an early `Return`. Grafted from Designs 2/3: `?` over the stdlib
`(value, errmsg: string, errcode: integer)` triples, a lazy `orelse` operator, `if local x = e then`, static
initializers for comptime optionals, `nilptr` as the empty value of pointer optionals, a statement form `f()?`,
rejection of `opt or v`, and a regex opt-in in bindgen. Nothing new in `types.lua` beyond flags; `cgenerator.lua` is
untouched; `cemitter.lua` gets one truthiness branch.

Observed at master `1ad3d5ce` (judges verified against the worktree): `typeopopt : OptionalType <== '?'`
(syntaxdefs 174) and `aster.register('OptionalType')` exist, prefix form, `visitors.OptionalType` raises "optional
type not implemented yet"; `visitor_convert` (analyzer 183) rewrites any record target with `__convert` and does not
block niltype values; `override_binary_op` only refuses `__eq` for stringy/non-stringy mixes; `add_val2boolean`
(cemitter 81) emits constant `true` for records; `Return` inside `DoExpr` resolves via `get_up_function_scope`
(scope.lua 128) and cgenerator `visitors.Return` (882) runs `emit_close_upscopes`; `opcmp : BinaryOp <== cmp @exprbor`
(syntaxdefs 118); `ifs <-| @expr @'then' Block (...)` (42); `Block` lists `Assign / call` last (17-28); every
fallible stdlib function returns `(value, errmsg: string, errcode: integer)` (io.open, filestream:read/write/close,
os.remove/rename) or `(boolean, string, integer)`; `(@T)()` zero-init is used by `lib/variant.nelua`.

## Syntax

`lualib/nelua/syntaxdefs.lua` deltas (everything else unchanged):

```
-- types: `?` moves from prefix to postfix
typeopunary     <-- typeopptr / typeoparr
typeexprunary   <-- ((typeopunary* typexprsimple)->rfoldleft typeopopt?)~>foldleft
-- expression suffix and statement form
Try             <== `?`
exprsuffixed    <-- (exprprim (indexsuffix / callsuffix / Try)*)~>rfoldright
TryStat         <== call `?`
Block           <== (... / Preprocess / TryStat / Assign / call / `;`)*      -- TryStat before Assign/call
-- orelse: tighter than comparison, looser than `|`
exprcmp         <-- (exprorelse opcmp*)~>foldleft
opcmp     : BinaryOp  <== cmp @exprorelse
exprorelse      <-- (exprbor oporelse*)~>foldleft
oporelse  : BinaryOp  <== `orelse`->'orelse' @exprbor
-- if local
ifs             <-| @ifcond @`then` Block (`elseif` @ifcond @`then` Block)*
ifcond          <-- IfLocal / expr
IfLocal         <== `local` @iddecl `=` @expr
```

`astdefs.lua`: register `Try{Node}`, `TryStat{Node}`, `IfLocal{IdDecl, Node}`; add `'orelse'` to the `BinaryOp`
`one_of`. `foldleft` on `typeopopt?` yields `OptionalType{subtype}` as `typeopgen` yields `GenericType`;
`rfoldright` on `Try` yields `Try{expr}` as `DotIndex` is built. Backticked `orelse` is auto-registered as a keyword
by lpegrex `makekeyword`.

Precedence by construction: `*T?` = `(*T)?`, `*const T?` = `(*const T)?`, `[4]T?` = `([4]T)?`, `A|B?` = `A|(B?)`
(`typevaris` folds at `typeexpr`); an optional variant is written `variant(A,B)?`. `@int?` is a type; `(@int)?` is
`Try{Paren{Type}}` and a compile error. `a?.b?:c()` chains as suffixes. `f()?` as a statement parses as
`TryStat{call}` (the `?` must be last: `f()?:g()` as a statement is a syntax error, bind the value first).
`x? = 1` stays a syntax error (`Try` is not in `var`). `a == b orelse c` parses as `a == (b orelse c)` because
`opcmp` now takes `@exprorelse`. The upstream prefix `?T` is dropped (never implemented upstream).

## Semantics

- `T?` is `optional(T)` instantiated through `generalize` (one record per `T`). `visitors.OptionalType` raises
  "optional types require the 'optional' module, add `require 'optional'` to the top scope" when `optional` is not
  in scope (variant rule and wording). `T` must be non-comptime, non-void, non-optional, not `niltype`/`type`/`auto`
  (`static_assert` in the generic); `nocopy` payloads are rejected in v1 (`?` copies the operand).
- Flags set by the generic: `is_optional = true`, `subtype = T`, `is_falseable = true`, `is_niche = T.is_pointer or
  T.is_function`. `tostring` prints the nickname `optional(int64)`; codename via `choose_codename`.
- API (methods, shared by both layouts): `has(): boolean`, `get(): T` (checked), `getptr(): *T` (nilptr when
  empty), `get_or(default: T): T` (eager), `set(v: T)`, `clear()`. Fields `v: T` always, `has: boolean` only in
  the general layout; the methods are the documented API.
- Implicit conversions, all through `optT.__convert(x: concept)` exactly like variant: `T -> T?` (any `x` with
  `T:is_convertible_from_attr(x)`, so `3 -> integer?`, `&r -> *R?`), `nil -> T?` (empty), `nilptr -> *T?` (empty,
  never "some NULL"; a NULL `*T` value also converts to empty). Work in declarations, assignments, call arguments,
  init lists and `return` because `visitor_convert` already rewrites them. Never implicit: `T? -> T`, `T? -> U?`,
  `nilptr -> integer?`. `(@T)(opt)` is an error; use `:get()`, `orelse` or `?`.
- Comptime wrapping (graft, Design 2): in `visitor_convert`, when the target `is_optional` and the value attr is
  comptime (or `Nil`), the conversion is rewritten to an init list `(@T?){has = true, v = <value>}` (niche:
  `{v = <value>}`; `nil`/`nilptr`: `(@T?){}`) instead of a `__convert` call. Init lists of comptime fields are
  already C static initializers under `1ad3d5ce`, so top-scope `local x: integer? = 3` and `= nil` stay static.
  No "none" sentinel is needed: emptiness lives in the init list, not in `attr.value`.
- Boolean context (`if opt`, `while opt`, `not opt`, `opt and x`): true iff `opt:has()`; the cemitter branch emits
  the test. Decision for `boolean?`: `BooleanType:get_convertible_from_type` refuses `is_optional and
  subtype.is_boolean` ("test a boolean optional with `~= nil`, `orelse` or `if local`"), so `local b: boolean? =
  false; if b then` is a compile error rather than silently true.
- `opt or y` / `opt and y` where `opt.is_optional` and `y` is not optional and not boolean: compile error
  "use `orelse` to provide a default for an optional" (check in `visitors.BinaryOp` before `binary_operator`, so
  the `any` promotion is never reached). `T? or T?` stays allowed (result `T?`).
- Comparisons: `opt == nil`, `opt ~= nil`, `nil == opt`, `opt == nilptr` (niche only) -> `__eq` metamethod with a
  concept parameter accepting `niltype`, `nilptr` (niche), `T?` and `T`: `== nil`/`== nilptr` is `not opt:has()`;
  `opt == v` is `has and v == v`; `opt == opt2` is `has == has and (not has or v == v)`. Ordering operators are not
  provided. For a niche optional `p == nilptr` is therefore the empty test, not a payload comparison.
- `x orelse d` (BinaryOp `'orelse'`, graft): `x` must be `T?` ("`orelse` expects an optional on the left, got
  'int64'"); `d` convertible to `T` -> result `T`; `d: T?` -> result `T?` (chaining). `d` is evaluated only when `x`
  is empty. Rewritten in `visitors.BinaryOp` with `transform_and_traverse_node`:
  `(do local __o = x  if __o:has() then in __o.v end  in d end)` (`in` inside a nested block of a DoExpr is the
  existing `is_resultbreak` path; first red spec verifies it).
- `if local x = e then B1 elseif c then B2 else B3 end` (graft, implemented in `visitors.If`, not a child visitor,
  because the whole `If` node is replaced):
  `do local __o = e  if __o:has() then local x = __o.v  B1 else if c then B2 else B3 end end end`.
  `e` must be `T?` (pointers: write `if p then`); `x: T`, scoped to the then-block; an annotation `x: U` must be
  convertible from `T`; `elseif local` nests the same way; `while local` is a follow-up.
- `expr?` / `f()?` (Try, TryStat). Let `F` be the enclosing function scope (`get_up_function_scope`) with declared
  rettypes `R1..Rn`; errors are compile errors:
  1. `F` must exist with resolved, non-auto rettypes ("`?` requires the enclosing function to declare its return
     types"; polymorphic parents are checked per instance).
  2. Operand kinds: (a) `E.is_optional` -> value `E.subtype`, failure `not has()`; (b) `E.is_pointer` -> value `E`,
     failure `== nilptr`; (c) graft, Design 3: a call whose callee rettypes have `#R >= 2` and `R[2].is_string`
     (the stdlib `(value, errmsg, errcode)` and `(boolean, errmsg, errcode)` shapes) -> value `R[1]`, failure
     `R[2].size ~= 0`, `R[3..]` dropped (`errmsg` kind); (d) a call with `#R == 1` and `R[1].is_boolean` -> no
     value (statement form only), failure `not R[1]` (`ok` kind). Anything else: "`?` expects an optional, a
     pointer or a `(value, errmsg)` call, but got 'int64'". No heuristic on integral or `(T, T)` pairs.
  3. Enclosing kinds from `F.rettypes`: `R1` optional or pointer -> `empty` (return `(@R1)(), (@R2)(), ...`);
     `R2.is_string` -> `errmsg` (return `(@R1)(), msg, (@R3)(), ...`); `R1.is_boolean` and not errmsg -> `ok`
     (return `false, (@R2)(), ...`); else "`?` can only propagate inside a function returning an optional, a
     pointer, `(value, errmsg)` or `(ok, ...)`, but it returns 'int64'".
  4. Propagation table (Design 3): optional/pointer -> empty: ok; errmsg -> errmsg: message unchanged;
     ok -> ok: `false`; errmsg -> ok: `false` (message dropped, documented); errmsg -> empty: empty;
     optional/pointer/ok -> errmsg: compile error (no message to propagate; write the `if` by hand).
  Desugar via `context:transform_and_traverse_node`, names from `scope:generate_name`:
  ```
  (do local __t = <expr>                      -- errmsg kind: local __t, __e = <call>
      if not __t:has() then return <fill> end  -- pointer: __t == nilptr; errmsg: __e.size ~= 0; ok: not __t
  in __t.v end)                               -- pointer/errmsg: in __t end; TryStat: plain Do, no `in`
  ```
  `(@R)()` is zero-init (empty for both layouts, NULL for pointers), stated for every return so `Return` never sees
  fewer nodes than `rettypes`. `.size` keeps the rewrite free of the `string` module (freestanding). `Try` sets
  `callnode.attr.usemultirets` for kind (c) so the `nlmulret` struct is received once.
- Missing-return rule unchanged: `optional` is not `is_nilable`, so a `T?` function still needs a `return` on every
  path; `return nil` is the idiom for empty.

## C layout and ABI

Two layouts chosen in the preprocessor by `is_niche`:

```c
/* general: local x: integer? = 3 ; if x then print(x:get()) end  (top scope: static initializer) */
typedef struct optional_int64_ optional_int64_;
struct optional_int64_ { bool some; int64_t v; };              /* 16 bytes, align 8 on x86-64 */
static optional_int64_ x = {true, 3};                          /* comptime wrapping -> init list */
if(x.some) { ... }                                             /* add_val2boolean: has() call or .some */

/* niche: local function open(p: cstring): *FILE?  return fopen(p, "r") end */
struct optional__FILE_ { FILE* v; };                           /* size == sizeof(FILE*); empty == NULL */
static inline bool optional__FILE__has(optional__FILE_ s) { return s.v != NULL; }

/* propagation through an errmsg triple into an optional-returning function */
local function first_line(p: string): string?  local f = io.open(p)?  return f:read('l')?  end
static optional_nlstring_ first_line(nlstring p) {
  nlfilestream f = ({ nlmulret_nlfilestream_nlstring_nlint64 _t = nelua_io_open(p, ...);
                      if(_t.r2.size != 0) { return (optional_nlstring_){0}; } _t.r1; });
  return optional_nlstring____convert_1(({ nlmulret_nlstring_nlstring_nlint64 _u = nelua_filestream_read(...);
                      if(_u.r2.size != 0) { return (optional_nlstring_){0}; } _u.r1; }));
}

/* orelse is lazy */
int64_t y = ({ optional_int64_ _o = find(1); _o.some ? _o.v : compute_default(); });  /* as a DoExpr with `in` */
```

Codenames as `choose_codename` forms them from the nickname; real output carries the unit prefix and dedup counter.
The `return` inside `({ ... })` is the GNU statement expression the cgenerator already emits for `DoExpr` with
statements; gcc 12, clang and `zig cc` accept it.

`<cimport>`: optional types never appear in a `<cimport>` signature, imported record field or imported variable
(compile error raised where the `cimport` annotation is applied, in `visitor_function_annotations` for functions and
in `visitors.Annotation` for records and variables): a single-field struct is not ABI-identical to
`T*` in portable C. Nullable C pointers keep binding as `*T`; the boundary idioms are the implicit `*T -> *T?`
conversion (`local f: *FILE? = fopen(...)`) and `?` on the raw pointer. bindgen (graft, regex opt-in because
python3-clang 14 does not expose `Type.nullability`): `--nullable-returns REGEX` emits, for each matched
pointer-returning function, the `<cimport 'name'>` declaration under a hidden Nelua name plus an inline wrapper
`local function name(...): *T? return name__c(...) end`, so the header prototype is unchanged and nullability shows
in the Nelua signature; `run.sh` gains one sample. No automatic `_Nullable` detection is promised.

## Interaction with existing features

- `*const T`: `*const T?` is niche with `v: *const T`; `?` on a `*const T` yields `*const T`; `__convert` refuses
  dropping const because `PointerType:get_convertible_from_type` refuses it.
- variant: `variant(A,B)?` and `A|B?` (= `A|(B?)`) instantiate normally; `optional` reuses variant's concept and
  `__convert` shape. A `T?` inside a variant is a record member.
- closures: closure bodies are rewritten before traversal, so `?` inside an anonymous function finds the `__call`
  function scope and propagates out of the closure, never out of the enclosing function (spec'd). Captured `T?`
  values copy by value.
- freestanding: `lib/optional.nelua` requires nothing and uses only `check`, records, `nilptr`; the `?` rewrite uses
  `.size`, a local, `if`, `return`. Specs set `pragmas.abort='trap'` explicitly (the suite forces `'exit'`).
- nogc: plain records, no heap, no destructors; `get`/`get_or`/`orelse` return copies; errmsg views are copied as
  `return errmsg` copies them today.
- multiple returns: `function f(): T?, E` allowed; `?` zero-fills returns 2..n; `?` on a multi-return call takes
  return 1 for kinds (a)/(b) and consumes the whole `nlmulret` for kind (c); `local a, b = f()?` is "`?` yields a
  single value"; `g(f()?)` passes one value.
- concepts/generics: `facultative(T)` stays the compile-time "argument may be nil" tool; `T?` is the runtime value.
  `optional(T)` is callable in the preprocessor; `x.type.is_optional` / `.subtype` work in concepts; `generalize`
  caching makes repeated `T?` one type. Poly functions with declared returns work per instantiation.
- auto: `local x = f()` infers `T?`; `local x: auto = nil` stays niltype; `?` and `orelse` in an `auto`-returning
  function hit rule 1.
- static initializers (fork): comptime wrapping above; a non-comptime initializer is still assigned in `nelua_main`.
- stdlib: no signature changes; `io.open(p)?`, `f:read('l')?`, `f:write(s)?` (TryStat), `os.remove(p)?` work
  through kind (c) unchanged.
- Tree-sitter / TextMate grammars (`tools/`): `orelse` keyword, `?` suffix token.

## Implementation plan (in order; write the specs first, keep them red until step 4)

1. Specs (≈180 lines): `spec/analyzer_spec.lua` "optional types": require-missing error; `integer? = 3`, `= nil`,
   `*integer? = nilptr`, `nilptr -> integer?` error; `T? -> T` error; `optional(niltype)` error; `?` at top scope,
   in `auto` function, in an `integer` function, on `(integer, integer)` call, on `(@int)?`; `boolean?` in `if`
   error; `opt or 3` error; `orelse` typing (T, T?, non-optional left error); `if local` scoping (x invisible in
   else); `opt == nil` boolean; `*FILE?` in cimport error. `spec/cgenerator_spec.lua` "optional types":
   `generate_c` for both struct layouts, the static initializer `{true, 3}` / `{0}`, `(x.v != NULL)`; `run_c` for
   propagation through `integer?`, `*T?` from a nilptr-returning function, `?` on a raw pointer, multi-return
   zero-fill, `?` inside a closure, `?` with a `defer` in scope, `io.open`/`filestream:read` errmsg -> optional,
   errmsg -> errmsg, `f:write(s)?` statement form in an `(ok, errmsg)` function, `orelse` laziness (default is a
   call with a side effect), `if local`/`elseif local`, `== nil`/`~= nil`/`== v`/`== nilptr`, freestanding with
   `abort='trap'`; `run_error_c` for `:get()` on empty. `spec/stdlib_spec.lua` "optional" ->
   `tests/optional_test.nelua` (API coverage, mirrors `tests/variant_test.nelua`). `spec/syntaxdefs_spec.lua`:
   `T?`, `expr?`, `f()?` statement, `a == b orelse c`, `if local`. bindgen: `--nullable-returns` sample in
   `tools/nelua-bindgen/test/run.sh`.
2. `lib/optional.nelua` (≈140 lines): `make_optionalT(T)` with static_asserts, layout switch, flags, nickname,
   concept (T, niltype, nilptr for niche), `__convert`, `__eq`, `has/get/getptr/get_or/set/clear`;
   `global optional: type = #[generalize(make_optionalT)]#`.
3. `lualib/nelua/syntaxdefs.lua` (≈12 lines), `astdefs.lua` (≈10), `types.lua` (`is_optional`, `is_niche` flags on
   RecordType; `BooleanType:get_convertible_from_type` refusal for `boolean?`; ≈6).
4. `lualib/nelua/analyzer.lua` (≈170): `visitors.OptionalType` (clone of VariantType + cimport refusal, 15);
   `visitors.Try`/`TryStat` (classification table, fill builder, DoExpr/Do rewrite, 80); `orelse` branch in
   `visitors.BinaryOp` and the `or`/`and` refusal (30); `IfLocal` desugar in `visitors.If` (30); comptime wrapping
   in `visitor_convert` (15).
5. `lualib/nelua/cemitter.lua` `add_val2boolean`: `elseif valtype.is_optional` -> `.some` / `(v != NULL)` (≈6).
6. `tools/nelua-bindgen/nelua-bindgen.py` `--nullable-returns` (≈25) + README paragraph; tree-sitter/textmate
   tokens (≈10).
7. Docs: `docs/pages/overview.md` `### Optional` after `### Variant` (layout alert, `?`, `orelse`, `if local`,
   stdlib propagation; ≈60) and a paragraph under "Multiple returns"; `docs/pages/libraries.md` entry; README
   "Fork additions" bullet; bindgen README.
8. Container run per the binding flow; expected 520 + new specs, 0 failures. Not run for this document.

## Risks and open questions

- First red specs settle: `visitor_convert` reached for a `Nil` value node in `VarDecl`/`Assign`; a polymorphic
  `__eq(a: concept, b: concept)` accepted by `override_binary_op` with a niltype/nilptr operand; `Return` inside a
  `DoExpr` closes defers via `emit_close_upscopes`; `in` inside a nested `if` of a `DoExpr` (needed by `orelse`).
- Single-field struct vs raw pointer ABI: identical on SysV x86-64 and AAPCS64 but not guaranteed, hence the cimport
  refusal and the bindgen wrapper; an escape hatch is a later extension.
- `require 'optional'` friction (variant precedent); auto-require from `visitors.OptionalType` is a follow-up.
- Errmsg kind is convention-based: a callee returning an empty error string on failure is treated as success (matches
  `filestream`/`io` today); `errmsg -> ok` drops the message silently (a spec documents it; `try!` spelling open).
- `?` copies the operand; `nocopy` payloads rejected in v1; lvalue/pointer-based desugar is v2. `has` field and
  method overlap in the general layout; methods are the API.
- `f()?:g()` statement and `x?.y = v` are syntax errors; `TryStat <== call '?'` is deliberately narrow.
- Comptime wrapping covers `Nil`, comptime scalars and comptime init lists; `local x: integer? = f()` at top scope
  still runs in `nelua_main`. `opt == nil` is never constant-folded (no "none" sentinel in `attr.value`).
- Codename dedup when `*FILE?` and `*const FILE?` coexist relies on `choose_codename`'s counter; readable, noted in
  the overview alert.
- `orelse` precedence (below `|`, above comparison, Zig) is new to Nelua; `a orelse b == c` parses as
  `(a orelse b) == c`, documented.

## First implementation slice

Slice 2 (the `errmsg` and `ok` operand kinds, the `errmsg`/`ok` enclosing kinds with the propagation table above,
and the statement form `f()?` as `TryStat`) is implemented on top of slice 1 and spec'd in `syntaxdefs_spec`,
`analyzer_spec`/`cgenerator_spec` "optional try kinds" and `tests/optional_test.nelua`.

Smallest shippable subset, useful alone: `T?` types over `lib/optional.nelua`, `==`/`~=` against `nil`/`nilptr`,
truthiness, and `expr?` for optional/pointer operands inside optional/pointer-returning functions. No `orelse`,
`if local`, errmsg kind, statement form, comptime wrapping, bindgen or grammar-tool changes (each is an additive
later slice: 2 = errmsg/ok kinds + `TryStat`, 3 = `orelse` + `if local` + `or` refusal, 4 = comptime wrapping +
bindgen + editor grammars).

Files: `syntaxdefs.lua` (postfix `typeopopt`, `Try` suffix: 4 lines), `astdefs.lua` (`Try`: 3), `types.lua`
(`is_optional`/`is_niche` flags: 2), `lib/optional.nelua` (≈110), `analyzer.lua` (`visitors.OptionalType` +
`visitors.Try` kinds (a)/(b) into `empty` only: ≈70), `cemitter.lua` `add_val2boolean` (≈6),
`docs/pages/overview.md` `### Optional` (≈35), README bullet, `tests/optional_test.nelua` (≈60).

Specs to write first, in this order (all red until the analyzer and lib land):

1. analyzer `expect.analyze_error`: `local x: integer?` without `require 'optional'` -> "requires the 'optional' module".
2. analyzer `expect.analyze_ast`: `require 'optional' local x: integer? = 3 local y: integer? = nil local p: *integer? = nilptr`.
3. analyzer `expect.analyze_error`: `local v: integer = x` with `x: integer?` -> "no viable type conversion".
4. analyzer `expect.analyze_error`: `local n: niltype?` -> optional of nil; `local q: integer? = nilptr` -> error.
5. analyzer `expect.analyze_error`: `local y = x?` at top scope -> "requires the enclosing function".
6. analyzer `expect.analyze_error`: `?` inside `local function f(): integer` -> "can only propagate inside a function returning an optional or a pointer".
7. analyzer `expect.analyze_error`: `?` on an `integer` value -> "expects an optional or pointer value"; `(@integer)?` -> error.
8. analyzer `expect.analyze_ast`: `if x then end`, `while x do break end`, `local b = x == nil`, `local c = p == nilptr`.
9. analyzer `expect.analyze_error`: `local b: boolean? = false if b then end` -> "test a boolean optional".
10. cgenerator `expect.generate_c`: `struct ... { bool some; int64_t v; }` for `integer?` and `{ int64_t* v; }` for `*integer?`; `if(` uses `.some` / `!= NULL`.
11. cgenerator `expect.run_c`: `local function find(k: integer): integer? if k == 1 then return 10 end return nil end`; `find(1):get() == 10`, `find(2) == nil`, `find(1) ~= nil`, `find(1) == 10`.
12. cgenerator `expect.run_c`: `local function twice(k: integer): integer? local v = find(k)? return v * 2 end`; `twice(1):get() == 20`, `twice(2) == nil`.
13. cgenerator `expect.run_c`: `*Node?` from a `nilptr`-returning function, `?` on a raw `*Node` operand, `== nilptr` as the empty test, a NULL `*Node` converting to empty.
14. cgenerator `expect.run_c`: `local function g(k: integer): (integer?, integer) local v = find(k)? return v, 1 end`; `g(2)` yields `(empty, 0)`.
15. cgenerator `expect.run_c`: `?` inside an anonymous function with declared `: integer?` returns propagates out of the closure, the enclosing function continues.
16. cgenerator `expect.run_c`: `defer` in scope of a `?` runs on the early return (counter observed after the call).
17. cgenerator `expect.run_error_c`: `find(2):get()` -> the `check` message.
18. cgenerator `expect.run_c` with `## pragmas.nogc = true ## pragmas.freestanding = true ## pragmas.abort = 'trap'`: items 11-12 compile and run.
19. stdlib `expect.run_c` -> `tests/optional_test.nelua`: `has/get/getptr/get_or/set/clear`, `==` between optionals, `*const T?`, `variant(A,B)?`.

Done when the container run shows 520 + these specs with 0 failures (not run for this document).
