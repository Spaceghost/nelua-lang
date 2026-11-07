local lester = require 'nelua.thirdparty.lester'
local describe, it = lester.describe, lester.it

local config = require 'nelua.configer'.get()
local expect = require 'spec.tools.expect'

describe("Lua generator", function()

it("empty file", function()
  expect.generate_lua("", "")
end)
it("return", function()
  expect.generate_lua("return")
  expect.generate_lua("return 1")
  expect.generate_lua("return 1, 2")
end)
it("number", function()
  expect.generate_lua("return 1, 1.2, 1e2, 1.2e3, 0x1f, 0b10",
                      "return 1, 1.2, 1e2, 1.2e3, 0x1f, 0x2")
  expect.generate_lua("return 0x3p5, 0x3.5, 0x3.5p7, 0xfa.d7p-5, 0b11.11p2",
                      "return 96.0, 3.3125, 424.0, 7.8387451171875, 15.0")
  expect.generate_lua("return 0x0, 0xffffp4",
                      "return 0x0, 1048560.0")
  expect.generate_lua("return 0xffffffffffffffff.001",
                      "return 1.8446744073709552e+19")
end)
it("string", function()
  expect.generate_lua([[return 'a', "b", [=[c]=] ]], [[return "a", "b", "c"]])
  expect.generate_lua([[return "'", '"']])
  expect.generate_lua([[return "'\001", '"\001']])
end)
it("boolean", function()
  expect.generate_lua("return true, false")
end)
it("nil", function()
  expect.generate_lua("return nil")
end)
it("varargs", function()
  expect.generate_lua([[return function(...)
  return ...
end]])
end)
it("table", function()
  expect.generate_lua("return {}")
  expect.generate_lua('local a\nreturn {a, "b", 1}')
  expect.generate_lua('return {a = 1, [1] = 2}')
end)
it("function", function()
  expect.generate_lua("return function() end")
  expect.generate_lua("return function()\n  return\nend")
  expect.generate_lua("return function(a, b, c) end")
end)
it("indexing", function()
  expect.generate_lua("local a\nreturn a.b")
  expect.generate_lua("local a, b\nreturn a[b], a[1]")
  expect.generate_lua('return ({})[1]', 'return ({})[1]')
  expect.generate_lua('return ({}).a', 'return ({}).a')
end)
it("call", function()
  expect.generate_lua("local f\nf()")
  expect.generate_lua("local f\nreturn f()")
  expect.generate_lua("local f, g\nf(g())")
  expect.generate_lua("local f, a\nf(a, 1)")
  expect.generate_lua("local f\nf 'a'", 'local f\nf("a")')
  expect.generate_lua("local f\nf {}", 'local f\nf({})')
  expect.generate_lua('local a\na.f()')
  expect.generate_lua('local a\na.f "s"', 'local a\na.f("s")')
  expect.generate_lua("local a\na.f {}", "local a\na.f({})")
  expect.generate_lua("local a\na:f()")
  expect.generate_lua("local a\nreturn a:f()")
  expect.generate_lua("local a\na:f(a, 1)")
  expect.generate_lua('local a\na:f "s"', 'local a\na:f("s")')
  expect.generate_lua("local a\na:f {}", 'local a\na:f({})')
  --expect.generate_lua('("a"):len()', '("a"):len()')
  expect.generate_lua('local g\ng()()', 'local g\ng()()')
  expect.generate_lua('({})()', '({})()')
  --expect.generate_lua('("a"):f()', '("a"):f()')
  expect.generate_lua('local g\ng():f()', 'local g\ng():f()')
  expect.generate_lua('({}):f()', '({}):f()')
end)
it("if", function()
  expect.generate_lua("local a\nif a then\nend")
  expect.generate_lua("local a, b\nif a then\nelseif b then\nend")
  expect.generate_lua("local a, b\nif a then\nelseif b then\nelse\nend")
end)
it("switch", function()
  expect.generate_lua("switch 0 case 1 then else end", [[
local __switchval1 = 0
if __switchval1 == 1 then
else
end]])
  expect.generate_lua("switch 0 case 1 then local f f() case 2 then local g g() else local h h() end",[[
local __switchval1 = 0
if __switchval1 == 1 then
  local f
  f()
elseif __switchval1 == 2 then
  local g
  g()
else
  local h
  h()
end]])
end)
it("do", function()
  expect.generate_lua("do\n  return\nend")
end)
it("while", function()
  expect.generate_lua("local a\nwhile a do\nend")
end)
it("repeat", function()
  expect.generate_lua("local a\nrepeat\nuntil a")
end)
it("for", function()
  expect.generate_lua("for i=1,10 do\nend")
  expect.generate_lua("for i=1,10,2 do\nend")
  expect.generate_lua("local a, f\nfor i in a, f() do\nend")
  expect.generate_lua("local f\nfor i, j, k in f() do\nend")
  expect.generate_lua("local f\nfor _ in f() do\nend", "local f\nfor _ in f() do\nend")
end)
it("break", function()
  expect.generate_lua("while true do\n  break\nend")
end)
it("goto", function()
  expect.generate_lua("::mylabel::\ngoto mylabel")
end)
it("variable declaration", function()
  expect.generate_lua("local a")
  expect.generate_lua("local a = 1")
  expect.generate_lua("local a, b, c = 1, 2, nil")
  expect.generate_lua("local a, b, c = 1, 2, 3")
  expect.generate_lua("local a, b = 1", "local a, b = 1, nil")
  expect.generate_lua("local function f() local a end", "local function f()\n  local a\nend")
end)
it("assignment", function()
  expect.generate_lua("local a: any\na = 1", "local a\na = 1")
  expect.generate_lua("local a: any, b: any\na, b = 1, 2", "local a, b\na, b = 1, 2")
  expect.generate_lua("local a: any, x: any, y: any\na.b, a[1] = x, y", "local a, x, y\na.b, a[1] = x, y")
end)
it("function definition", function()
  expect.generate_lua("local function f()\nend")
  expect.generate_lua("local function f()\nend")
  expect.generate_lua("local function f(a)\nend")
  expect.generate_lua("local function f(a, b, c)\nend")
  expect.generate_lua("local a\nfunction a.f()\nend")
  expect.generate_lua("local a\nfunction a.b.f()\nend")
  expect.generate_lua("local a\nfunction a:f()\nend")
  expect.generate_lua("local a\nfunction a.b:f()\nend")
  expect.generate_lua(
    "local function f(a: integer): integer\nreturn 1\nend",
    "local function f(a)\n  return 1\nend")
end)
it("unary operators", function()
  expect.generate_lua("local a\nreturn not a")
  expect.generate_lua("local a\nreturn -a")
  expect.generate_lua("local a\nreturn ~a")
  expect.generate_lua("local a\nreturn #a")
end)
it("binary operators", function()
  expect.generate_lua("local a, b\nreturn a or b, a and b")
  expect.generate_lua("local a, b\nreturn a ~= b, a == b")
  expect.generate_lua("local a, b\nreturn a <= b, a >= b")
  expect.generate_lua("local a, b\nreturn a < b, a > b")
  expect.generate_lua("local a, b\nreturn a | b, a ~ b, a & b")
  expect.generate_lua("local a, b\nreturn a << b, a >> b")
  expect.generate_lua("local a, b\nreturn a + b, a - b")
  expect.generate_lua("local a, b\nreturn a * b, a / b, a // b")
  expect.generate_lua("local a, b\nreturn a % b")
  expect.generate_lua("local a, b\nreturn a ^ b")
  expect.generate_lua("local a, b\nreturn a .. b")
end)
it("lua 5.1 compat operators", function()
  config.lua_version = '5.1'
  expect.generate_lua("local a\nreturn ~a", "local a\nreturn bit.bnot(a)")
  expect.generate_lua("local a, b\nreturn a // b", "local a, b\nreturn math.floor(a / b)")
  expect.generate_lua("local a, b\nreturn a ^ b", "local a, b\nreturn math.pow(a, b)")
  expect.generate_lua("local a, b\nreturn a | b", "local a, b\nreturn bit.bor(a, b)")
  expect.generate_lua("local a, b\nreturn a & b", "local a, b\nreturn bit.band(a, b)")
  expect.generate_lua("local a, b\nreturn a ~ b", "local a, b\nreturn bit.bxor(a, b)")
  expect.generate_lua("local a, b\nreturn a << b", "local a, b\nreturn bit.lshift(a, b)")
  expect.generate_lua("local a, b\nreturn a >> b", "local a, b\nreturn bit.rshift(a, b)")
  config.lua_version = '5.4'
end)
it("typed var initialization", function()
  expect.lua_gencode_equals("local a: integer", "local a: integer = 0")
  expect.lua_gencode_equals("local a: boolean", "local a: boolean = false")
  expect.lua_gencode_equals("local a: table", "local a: table = {}")
end)
it("integer width wrapping", function()
  expect.generate_lua([[
local a: uint8, b: uint8 = 200, 100
local c: uint8 = a + b
local d = -a
local e = ~a]], [[
function nelua_wrap_u8(x) return x & 0xff end
local a, b = 200, 100
local c = nelua_wrap_u8(a + b)
local d = nelua_wrap_u8(-a)
local e = nelua_wrap_u8(~a)]])
  expect.generate_lua([[
local a: int32 = 1
local b = a << 31
local c: int32 = a * 65536 * 32768]], [[
function nelua_wrap_i32(x) return ((x & 0xffffffff) ~ 0x80000000) - 0x80000000 end
local a = 1
local b = nelua_wrap_i32(a << 31)
local c = nelua_wrap_i32((nelua_wrap_i32(a * 65536)) * 32768)]])
  -- logical shift right on a narrow signed type works on the bits of the type
  expect.lua_gencode_contains("local a: int8 = -1\nlocal b = a >> 1", {
    "local a = (-1)",
    "local b = nelua_wrap_i8((a & 0xff) >> 1)",
  })
  -- 64-bit integers wrap natively, the other operators go through helpers
  expect.lua_gencode_contains("local a: integer = -7\nlocal b = a >> 1\nlocal c = a >>> 1\nlocal d = a /// 2\nlocal e = a %%% 2", {
    "local b = a >> 1",
    "local c = nelua_asr(a, 1)",
    "local d = nelua_tdiv(a, 2)",
    "local e = nelua_tmod(a, 2)",
  })
  -- unsigned 64-bit comparison and division
  expect.lua_gencode_contains("local a: uint64, b: uint64 = 1, 2\nlocal c = a < b\nlocal d = a // b\nlocal e = a % b\nlocal f = a / b\nlocal g = a >= b", {
    "local c = nelua_ult(a, b)",
    "local d = nelua_udiv(a, b)",
    "local e = nelua_umod(a, b)",
    "local f = nelua_utof(a) / nelua_utof(b)",
    "local g = nelua_ule(b, a)",
  })
end)
it("float32 rounding and conversions", function()
  expect.generate_lua([[
local x: float32 = 1
local y = x / 3
local z: float64 = x]], [[
function nelua_fround(x) return (string.unpack('f', string.pack('f', x))) end
local x = 1.0
local y = nelua_fround(x / 3)
local z = x]])
  expect.lua_gencode_contains([[
local function f(a: uint8): uint8 return a + 1 end
local y: float64 = 1.5
local x = f(y)
local i: integer = 3
local g: float64 = i]], {
    "local x = f(nelua_wrap_u8(nelua_toint(y)))",
    "local g = (i + 0.0)",
  })
end)
it("comptime values", function()
  expect.generate_lua([[
local E = @enum{A=0,B}
local e = E.B
local p = (@uint8)(300)
local K <comptime> = 3
local k = K]], [[
local e = 1
local p = 44
local K = 3
local k = 3]])
end)
it("typed arrays and records", function()
  expect.lua_gencode_contains([[
local t: [4]uint8 = {1,2}
local u: [2]integer = {1,2}
local v: [3]integer
local w = u
local x = u[1]]], {
    "local t = nelua_array(4, 0, {[0] = 1, 2})",
    "local u = {[0] = 1, 2}",
    "local v = nelua_array(3, 0)",
    "local w = nelua_copy(u)",
    "local x = u[1]",
  })
  expect.lua_gencode_contains([[
local R = @record{x: integer, y: float64}
local r: R = {x = 1}
local s = r
local eq = r == s
local q: R
local n = r.x]], {
    "local r = {x = 1, y = 0.0}",
    "local s = nelua_copy(r)",
    "local eq = nelua_eq(r, s)",
    "local q = {x = 0, y = 0.0}",
    "local n = r.x",
  })
  -- references to records are the tables themselves
  expect.lua_gencode_contains([[
local R = @record{x: integer}
function R:get(): integer return self.x end
local r: R
local v = r:get()
local p = &r
local w = $p]], {
    "function R:get()",
    "local v = r:get()",
    "local p = r",
    "local w = nelua_copy(p)",
  })
end)
it("typed control flow", function()
  expect.generate_lua("for i=0,<3 do end", [[
do
  local __it, __end, __step = 0, 3, 1
  while __it < __end do
    local i = __it
    do
    end
    __it = __it + __step
  end
end]])
  expect.generate_lua("local n = 2\nfor i=0,10,n do end", [[
local n = 2
do
  local __it, __end, __step = 0, 10, n
  while (__step >= 0 and __it <= __end) or (__step < 0 and __it >= __end) do
    local i = __it
    do
    end
    __it = __it + __step
  end
end]])
  expect.generate_lua("while true do continue end", [[
while true do
  goto __continue1
  ::__continue1::
end]])
  expect.generate_lua("switch 1 case 1, 2 then else end", [[
local __switchval1 = 1
if (__switchval1 == 1 or __switchval1 == 2) then
else
end]])
  expect.generate_lua("local x = (do in 1 end)", [[
local x = (function()
  return 1
end)()]])
end)

end)
