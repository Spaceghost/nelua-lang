local lester = require 'nelua.thirdparty.lester'
local describe, it = lester.describe, lester.it

local expect = require 'spec.tools.expect'
local aster = require 'nelua.aster'
local except = require 'nelua.utils.except'
local errorer = require 'nelua.utils.errorer'

local function parse_error(code, expected)
  local ok, e = except.try(function() aster.parse(code, 'syntaxext_spec.nelua') end)
  errorer.assertf(not ok, 'parse should fail with "%s"', expected)
  expect.contains(expected, e.message or e:get_message())
end

describe("syntax extensions", function()

it("leave files without #syntax unchanged", function()
  expect.parse_ast('local a = 1 | 2', aster.parse('local a = 1 | 2'))
end)

it("statement with a template and a spliced block", function()
  expect.ast_type_equals([=[
    local x = 1
    #syntax [[
      syntax.statement("`unless` @expr @`then` Block @`end`", function(cond, body)
        return syntax.stat('if not (c) then body() end', {c = cond, body = body})
      end)
    ]]
    unless x > 2 then x = 3 x = 4 end
  ]=], [[
    local x = 1
    if not (x > 2) then x = 3 x = 4 end
  ]])
end)

it("statement returning a block splices declarations", function()
  expect.ast_type_equals([=[
    #syntax [[
      syntax.statement("`twice` @name `=` @expr", function(name, e)
        return syntax.block('local n = e local n2 = n * 2', {n = name, n2 = name..'2', e = e})
      end)
    ]]
    twice a = 21
    local b = a2
  ]=], [[
    local a = 21 local a2 = a * 2
    local b = a2
  ]])
end)

it("binary, unary and primary expressions", function()
  expect.ast_type_equals([=[
    local function f(a: integer, b: integer) return a - b end
    #syntax [[
      syntax.binary('bor', "`|>`", function(lhs, rhs)
        table.insert(rhs[1], 1, lhs)
        return rhs
      end)
      syntax.unary("`!!`", function(e) return syntax.expr('e ~= 0', {e = e}) end)
      syntax.expression("`answer`", function() return syntax.expr('42') end)
    ]]
    local a = 10 |> f(3) |> f(1)
    local b = !!a
    local c = answer + 1
  ]=], [[
    local function f(a: integer, b: integer) return a - b end
    local a = f(f(10, 3), 1)
    local b = a ~= 0
    local c = 42 + 1
  ]])
end)

it("extension operators are left associative at their level", function()
  expect.ast_type_equals([=[
    #syntax [[
      syntax.binary('concat', "`<+>`", function(l, r) return syntax.expr('(l - r)', {l = l, r = r}) end)
    ]]
    local a = 10 <+> 3 <+> 2
    local b = 1 + 2 <+> 3 * 4
  ]=], [[
    local a = ((10 - 3) - 2)
    local b = (1 + 2 - 3 * 4)
  ]])
end)

it("is scoped to the rest of the file", function()
  parse_error([=[
    local a = 1 |> f()
    #syntax 'syntax.pipe'
  ]=], 'expected an expression after operator')
  parse_error([=[
    do
      #syntax 'syntax.pipe'
    end
  ]=], '`#syntax` is only allowed between top-level statements')
end)

it("compound assignment module", function()
  expect.ast_type_equals([=[
    #syntax 'syntax.compound'
    local x, s = 1, 'a'
    local t: [4]integer
    x += 2 x //= 3 x <<= 1 x >>= 1 x |= 4 x &= 6 x ^= 2
    t[x] *= 3
  ]=], [[
    local x, s = 1, 'a'
    local t: [4]integer
    x = x + 2 x = x // 3 x = x << 1 x = x >> 1 x = x | 4 x = x & 6 x = x ^ 2
    t[x] = t[x] * 3
  ]])
  expect.run_c([=[
    #syntax 'syntax.compound'
    require 'vector'
    require 'string'
    local v: vector(integer) = {1, 2, 3}
    local calls = 0
    local function idx(): integer calls = calls + 1 return 1 end
    v[idx()] += 40
    local s = 'a'
    s ..= 'b'
    print(v[1], calls, s)
  ]=], '42\t1\tab')
end)

it("pipe module", function()
  expect.run_c([=[
    #syntax 'syntax.pipe'
    local function add(a: integer, b: integer) return a + b end
    local function double(a: integer) return a * 2 end
    local P = @record{k: integer}
    function P:scale(a: integer) return a * self.k end
    local p: P = {k = 10}
    print(3 |> add(4) |> double, 1 + 2 |> double(), 2 |> p:scale())
  ]=], '14\t6\t20')
end)

it("interpolation module", function()
  expect.run_c([=[
    #syntax 'syntax.interp'
    require 'string'
    require 'math'
    local name, n = 'world', 3
    local s = 'abc'
    local t: [3]integer = {1, 2, 3}
    print($"hello {name}, {n + 1} times")
    print($"pi {math.pi:%.3f} pad {n:%05d} {{lit}} {'}'} {s:upper()} {#s} {t[2]}")
    print($"q \"x\" {(n > 2) and 'big' or 'small'}" .. $"" .. $"!")
    local p: *integer = &n
    print($ p, $"{$p}")
  ]=], 'hello world, 4 times\npi 3.142 pad 00003 {lit} } ABC 3 3\nq "x" big!\n3\t3')
  -- untyped: polymorphic tostring/concat calls carry table addresses when typed
  expect.parse_ast([=[
    #syntax 'syntax.interp'
    require 'string'
    local x = 1
    local a = $"x={x}!"
    local b = $"{x:%d}"
    local c = $"plain"
  ]=], aster.parse([[
    require 'string'
    local x = 1
    local a = ("x=" .. tostring((x)) .. "!")
    local b = (string.format("%d", (x)))
    local c = "plain"
  ]]))
  parse_error([=[
    #syntax 'syntax.interp'
    local a = $"bad } brace"
  ]=], "single '}' in interpolated string")
  parse_error([=[
    #syntax 'syntax.interp'
    local a = $"open {brace"
  ]=], "unterminated '{' in interpolated string")
  parse_error([=[
    #syntax 'syntax.interp'
    local a = $"empty {}"
  ]=], 'empty expression in interpolated string')
end)

it("prefix expressions", function()
  expect.ast_type_equals([=[
    #syntax [[
      syntax.prefixexpr("'$$' {[0-9]+} SKIP", function(n) return syntax.expr(n .. ' * 100') end)
    ]]
    local x = 3
    local p = &x
    local a = $$5 + $p
  ]=], [[
    local x = 3
    local p = &x
    local a = 5 * 100 + $p
  ]])
end)

it("templates use the grammar of the file", function()
  expect.run_c([=[
    #syntax 'syntax.pipe'
    #syntax 'syntax.interp'
    #syntax 'syntax.compound'
    #syntax [[
      syntax.statement("'bump' WORDSKIP @name", function(n)
        return syntax.stat('v += 10', {v = n})
      end)
    ]]
    require 'string'
    local function half(a: integer) return a // 2 end
    local x = 8
    bump x
    print($"{x |> half} {x |> half:%03d} {$"[{x}]"}")
  ]=], '9 009 [18]')
  parse_error([=[
    #syntax [[
      syntax.expression("`oops`", function() return syntax.expr('1 +') end)
    ]]
    local a = oops
  ]=], 'in syntax template: <syntax template>:1:11: syntax error: expected an expression after operator')
end)

it("errors", function()
  parse_error([=[
    #syntax 'syntax.missing_extension'
  ]=], "#syntax module 'syntax.missing_extension' not found")
  parse_error([=[
    #syntax 'syntax.pipe'
    local a = 1 |> 2
  ]=], 'the right side of `|>` must be a function name or a call')
  parse_error([=[
    #syntax [[ syntax.statement("`bad` (", function() end) ]]
  ]=], 'invalid syntax extension grammar')
  parse_error([=[
    #syntax [[ syntax.rules("expr <-- name") ]]
  ]=], "syntax rule 'expr' is already defined")
  parse_error([=[
    #syntax [[ syntax.binary('nope', "`@@`", function() end) ]]
  ]=], "unknown binary operator level 'nope'")
  parse_error([=[
    #syntax [[ syntax.expression("`x1`", function() return 1 end) ]]
    local a = x1
  ]=], 'syntax extension builder must return an AST node, got number')
  parse_error([=[
    #syntax [[ syntax.expression("`x2`", function() return syntax.block('local a = 1') end) ]]
    local a = x2
  ]=], 'returned a block where an expression is expected')
  parse_error([=[
    #syntax [[
      syntax.statement("`chk` @expr", function(e) syntax.raise('bad %s', 'value') end)
    ]]
    chk 1
  ]=], 'syntaxext_spec.nelua:4:5: error: bad value')
  parse_error([=[
    #syntax [[
      error('boom')
    ]]
  ]=], 'syntaxext_spec.nelua:2: boom')
  parse_error([=[
    #syntax 3
  ]=], 'expected a module name string or a long string of Lua code after `#syntax`')
end)

it("error labels and defs", function()
  parse_error([=[
    #syntax [[
      syntax.error('Expected_kw_then', 'expected `then` after the condition')
      syntax.rules("kw_then <-- `then`")
      syntax.statement("`when` expr @kw_then Block `end`", function(c, b) return b end)
    ]]
    when 1 do end
  ]=], 'expected `then` after the condition')
  expect.ast_type_equals([=[
    #syntax [[
      syntax.def('tohex', function(s) return tostring(tonumber(s, 16)) end)
      syntax.expression("'0h' {[0-9a-f]+}->tohex SKIP", function(s) return syntax.expr(s) end)
    ]]
    local a = 0hff
  ]=], [[
    local a = 255
  ]])
end)

end)
