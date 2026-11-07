local expect = require 'spec.tools.expect'
local n = require 'nelua.aster'
local bn = require 'nelua.utils.bn'
local lester = require 'nelua.thirdparty.lester'
local describe, it = lester.describe, lester.it

describe("analyzer", function()

it("analyzed ast transform", function()
  expect.analyze_ast("local a = 1;",
    n.Block{
      n.VarDecl{'local',
        { n.IdDecl{
          attr = {
            codename='a',
            name='a',
            staticstorage=true,
            type='int64',
            vardecl=true,
            lvalue=true
          },
          'a', false}},
        { n.Number{
          attr = {
            comptime=true,
            base=10,
            type='int64',
            untyped=true,
            value=bn(1)
          },'1'
        }}
      }
  })
end)

it("local variable", function()
  expect.analyze_ast([[local a: byte = 1]])
  expect.analyze_ast([[local a: byte = 'a'_byte]])
  expect.ast_type_equals("local a = 1", "local a: integer = 1")
  expect.analyze_error("local a: integer = 'string'", "no viable type conversion")
  expect.analyze_error("local a: byte = 1.1", "is fractional")
  expect.analyze_error("local a: byte = {1}", "cannot be initialized using an initializer list")
  expect.analyze_error("local a, b = 1,2,3", "extra expressions in declaration")
  expect.analyze_error("local a: void", "variable declaration cannot be of the type")
  expect.analyze_error("local a: varanys", "variable declaration cannot be of the type")
  expect.analyze_error("local a: integer = 'string'_s", "literal suffix '_s' is undefined for strings")
  expect.analyze_error("local a: byte = 'aa'_byte", "literal suffix '_byte' expects a string of length 1")
end)

it("global variable", function()
  expect.ast_type_equals("global a = 1", "global a: integer = 1")
  expect.analyze_error("do global a = 1 end", "global variables can only be declared in top scope")
end)

it("name collision", function()
  expect.ast_type_equals("local a = 1; local a = 2", "local a: integer = 1; local a: integer = 2")
  expect.ast_type_equals([[
    local a, b
    do
      b = 1
      local a = 2
    end
    a = 1
  ]], [[
    local a: integer, b: integer
    do
      b = 1
      local a: integer = 2
    end
    a = 1
  ]])
end)

it("comptime variable" , function()
  expect.analyze_ast([[local N <comptime> = 255; local a: byte = N]])
  expect.analyze_ast([[local N: number <comptime> = 255; local a: byte = N]])
  expect.analyze_ast([[local N <comptime> = -1; local a: integer = N]])
  expect.analyze_ast([[local N <comptime> = -1 + -1; local a: integer = N]])
  expect.analyze_ast([[local a: integer <comptime> = 1]])
  expect.ast_type_equals(
    [[local a <comptime> = 1; local function f() return a end]],
    [[local a: integer <comptime> = 1; local function f() return a end]])
  expect.analyze_ast([[local a <comptime> = 1 * 2]])
  expect.analyze_ast([[local a <comptime> = 1 * 2 + 3]])
  expect.analyze_ast([[local a <comptime> = 1; local b <comptime> = a]])
  expect.analyze_ast([[global a <comptime> = 1]])
  expect.analyze_error("local a: integer <comptime>", "const variables must have an initial value")
  expect.analyze_error("local a: integer <comptime> = true", "no viable type conversion")
  expect.analyze_error("local a <comptime> = 1; a = 2", "cannot assign a constant variable")
  expect.analyze_error("local a = 1; local c <comptime> = a", "can only assign to compile time expressions")
  expect.analyze_error("local b = 1; local c <comptime> = 1 * 2 + b", "can only assign to compile time expressions")
  expect.analyze_ast("local function f(a: integer <comptime>) end f(1)")
  expect.analyze_error(
    "local function f(a: integer <comptime>) end local a = 1 f(a)",
    "expected a compile time argument")
end)

it("const variable" , function()
  expect.analyze_ast([[local a: integer <const> = 1]])
  expect.analyze_ast([[local function f(x: integer <const>) end]])
  expect.analyze_ast([[local b = 1; local a: integer <const> = b]])
  expect.analyze_error([[local a: integer <const> = 1; a = 2]], "cannot assign a constant variable")
  expect.analyze_error("local a: integer <const>", "const variables must have an initial value")
  expect.analyze_error("local function f(x: integer <const>) x = 2 end", "cannot assign a constant variable")
  expect.analyze_error([[
    local v: record{x: integer} <const> = {x=1}
    v.x = 1
  ]], "cannot assign a constant variable")
  expect.analyze_error([[
    local v: [4]integer <const> = {1,2,3,4}
    v[1] = 1
  ]], "cannot assign a constant variable")
end)

it("auto type" , function()
  expect.ast_type_equals("local a: auto = 1", "local a: integer = 1")
  expect.ast_type_equals("local a: auto <comptime> = 1", "local a: integer <comptime> = 1")
  expect.ast_type_equals("local a: auto = 's'", "local a: string = 's'")
  expect.ast_type_equals("local a: auto = @integer", "local a: type = @integer")
  expect.ast_type_equals("local function f(): auto return 1 end", "local function f(): integer return 1 end")
  expect.analyze_error("local b; local a: auto = b", "must be assigned to expressions where type is known ahead")
  expect.analyze_error("local a: auto = nilptr", "auto variables cannot be assigned to expressions of type")
  expect.analyze_error("local function f(): auto end", "is set to 'auto', but the function never returns")
  expect.analyze_error("local f = function(): auto end", "anonymous functions cannot have 'auto' returns")
end)

it("any type", function()
  expect.analyze_ast([[local i: integer; local a: any; i = a; a = i]])
end)

it("nil type" , function()
  expect.ast_type_equals("local a = nil", "local a: niltype = nil")
end)

it("nilptr type" , function()
  expect.ast_type_equals("local a = nilptr", "local a: pointer = nilptr")
end)

it("numeric types coercion", function()
  expect.analyze_ast([[
    local u:usize, u8:uint8, u16:uint16, u32:uint32, u64:uint64 = 1,1,1,1,1
    local i:isize, i8:int8, i16:int16, i32:int32, i64:int64 = 1,1,1,1,1
    local f32: float32, f64: float64 = 1,1
  ]])
  expect.analyze_ast([[
    local a: uint16 = 1 + 1_u16
    local b: uint16 = 1 + 1
    local b: int16 = -1
  ]])
  expect.ast_type_equals("local a = 1 + 1_u16", "local a: uint16 = 1 + 1_u16")
  expect.ast_type_equals("local a = 1_u16 + 1", "local a: uint16 = 1_u16 + 1")
  expect.ast_type_equals("local a = 1 + 2.0_f32", "local a: float32 = 1 + 2.0_f32")
end)

it("narrow casting", function()
  expect.analyze_ast([[
    local u   = (@usize)  (0xffffffffffffffff)
    local u8  = (@uint8)  (0xffffffffffffffff)
    local u16 = (@uint16) (0xffffffffffffffff)
    local u32 = (@uint32) (0xffffffffffffffff)
    local u64 = (@uint64) (0xffffffffffffffff)
    local i   = (@isize) (-0x8000000000000000)
    local i8  = (@int8)  (-0x8000000000000000)
    local i16 = (@int16) (-0x8000000000000000)
    local i32 = (@int32) (-0x8000000000000000)
    local i64 = (@int64) (-0x8000000000000000)
  ]])

  expect.analyze_ast([[
    local i: integer
    local n: number
    local u: uinteger
    i = u u = i
    i = n n = i
    n = u u = n
  ]])

  expect.analyze_ast([[
    local function f(u: uinteger)
      return u
    end
    local i: integer
    f(i)
  ]])
end)

it("numeric ranges", function()
  expect.analyze_ast([[
    local u:usize, u8:uint8, u16:uint16, u32:uint32, u64:uint64 = 0,0,0,0,0
  ]])

  expect.analyze_ast([[
    local u:usize = 65535_us
    local u8:uint8, u16:uint16, u32:uint32, u64:uint64 = 255,65535,4294967295,18446744073709551615
  ]])
  expect.analyze_error([[local u: uinteger = -1_u]],   "is out of range")
  expect.analyze_error([[local u: uint8 = -1_u8]],  "is out of range")
  expect.analyze_error([[local u: uint16 = -1_u16]], "is out of range")
  expect.analyze_error([[local u: uint32 = -1_u32]], "is out of range")
  expect.analyze_error([[local u: uint64 = -1_u64]], "is out of range")
  expect.analyze_error([[local u: uinteger = 18446744073709551616_u]], 'is out of range')
  expect.analyze_error([[local u: uint8 = 256_u8]], 'is out of range')
  expect.analyze_error([[local u: uint16 = 65536_u16]], 'is out of range')
  expect.analyze_error([[local u: uint32 = 4294967296_u32]], 'is out of range')
  expect.analyze_error([[local u: uint64 = 18446744073709551616_u64]], 'is out of range')

  expect.analyze_ast([[
    local i:isize = 32767_is
    local i8:int8, i16:int16, i32:int32, i64:int64 = 127,32767,2147483647,9223372036854775807
  ]])
  expect.analyze_error([[local i: integer = -9223372036854775808_i]])
  expect.analyze_error([[local i: int8 = -128_i8]], 'is out of range')
  expect.analyze_error([[local i: int16 = -32768_i16]], 'is out of range')
  expect.analyze_error([[local i: int32 = -2147483648_i32]], 'is out of range')
  expect.analyze_error([[local i: int64 = -9223372036854775808_i64]], 'is out of range')
  expect.analyze_error([[local i: integer = 9223372036854775808_i]], 'is out of range')
  expect.analyze_error([[local i: int8 = 128_i8]], 'is out of range')
  expect.analyze_error([[local i: int16 = 32768_i16]], 'is out of range')
  expect.analyze_error([[local i: int32 = 2147483648_i32]], 'is out of range')
  expect.analyze_error([[local i: int64 = 9223372036854775808_i64]], 'is out of range')
  expect.ast_type_equals("local a = -9223372036854775809", "local a: number = -9223372036854775809")
  expect.ast_type_equals(
    "local a = 9223372036854775807 + 9223372036854775807",
    "local a: integer = 9223372036854775807 + 9223372036854775807")
  expect.ast_type_equals(
    "local a = 9223372036854775807_u64 + 9223372036854775807",
    "local a: uinteger = 9223372036854775807_u64 + 9223372036854775807")
  expect.ast_type_equals("local a = 9223372036854775807", "local a: integer = 9223372036854775807")
  expect.ast_type_equals("local a = -9223372036854775807-1", "local a: integer = -9223372036854775807-1")
  expect.ast_type_equals("local a = -9223372036854775808-1", "local a: number = -9223372036854775808-1")
  expect.ast_type_equals("local a = -9223372036854775809", "local a: number = -9223372036854775809")
  expect.ast_type_equals("local a = 9223372036854775807", "local a: integer = 9223372036854775807")
  expect.ast_type_equals("local a = 9223372036854775808", "local a: number = 9223372036854775808")
end)

it("type declaration", function()
  expect.ast_type_equals(
    "local int = @integer; local a: int",
    "local int = @integer; local a: integer")
  expect.analyze_error("local int = 1; local a: int = 2", "invalid type")
  expect.analyze_error("local a: invalid = 2", "undeclared symbol")
  expect.analyze_error("local v: string = @string", "attempt to assign a type to a symbol of type")
end)

it("for loop variables", function()
  expect.ast_type_equals("for i=1,10 do end", "for i:integer=1,10 do end")
  expect.ast_type_equals("for i=1,10,2 do end", "for i:integer=1,10,2 do end")
  expect.ast_type_equals("for i=0_is,1_is-1 do end", "for i:isize=0_is,1_is-1 do end")
  expect.analyze_error("for i:byte=1.1,256 do end", "is fractional")
  expect.analyze_error("for i:byte=1_byte,256 do end", "is out of range")
  expect.analyze_error("for i:byte=256,1,-1 do end", "is out of range")
  expect.analyze_error("for i:byte=1_byte,10_byte,2.1 do end", "fractional step")
  expect.analyze_error("for i='s','b' do end", "must be a number")
  expect.analyze_error("for i=1,2,'s' do end", "invalid operation")
  expect.analyze_error("for i=1,2,0 do end", "step cannot be zero")
  expect.analyze_error("for i=integer,2 do end", "begin: cannot be of")
  expect.analyze_error("for i=1,integer do end", "end: cannot be of")
  expect.analyze_error("for i=1,2,integer do end", "step: cannot be of")
end)

it("variable assignments", function()
  expect.ast_type_equals("local a; a = 1", "local a: integer; a = 1")
  expect.analyze_error("local a: integer; a = 's'", "no viable type conversion")
  expect.analyze_error("local a, b; a, b = 1,2,3", "extra expressions in assign")
end)

it("unary operators", function()
  expect.ast_type_equals("local a = not 1", "local a: boolean = not 1")
  expect.ast_type_equals("local a = -1", "local a: integer = -1")
  expect.ast_type_equals("local a = -1.0", "local a: number = -1.0")
  expect.ast_type_equals("local a = &(@[2]integer){1,2}", "local a: *[2]integer = &(@[2]integer){1,2}")
  expect.analyze_error("local x = &1", "cannot reference compile time value")
  expect.analyze_error([[
    local function f(): integer return 1 end
    local a = &f()
  ]], "cannot reference rvalue")
  expect.analyze_error([[
    local function f(i: *cint) return $i end
    local x: integer = 1
    f(&(@cint)(x))
  ]], "cannot reference rvalue")
  expect.analyze_error([[
    local i = 1
    local a = &(-i)
  ]], "cannot reference rvalue")
  expect.analyze_error("local x: niltype; local b = &x", "cannot reference not addressable type")
  expect.analyze_error("local a = -'s'", "invalid operation")
  expect.ast_type_equals([[
    local x = 1_usize * #@integer
  ]],[[
    local x: usize = 1_usize * #@integer
  ]])
end)

it("unary operator not", function()
  expect.ast_type_equals("local a = ~1", "local a: integer = ~1")
  expect.ast_type_equals("local a = ~1_u32", "local a: uint32 = ~1_u32")
  expect.analyze_error("local a = ~1.0", "invalid operation")
end)

it("binary operator shift", function()
  expect.ast_type_equals("local a = 1_u32 << 1", "local a: uint32 = 1_u32 << 1")
  expect.ast_type_equals("local a = 1_u16 >> 1_u32", "local a: uint16 = 1_u16 >> 1_u32")
  expect.ast_type_equals("local a = 1_u16 >>> 1_u32", "local a: uint16 = 1_u16 >>> 1_u32")
end)

it("binary operator add", function()
  expect.ast_type_equals("local b,c; local a = b + c", "local b: any, c:any; local a: any = b + c")
  expect.ast_type_equals("local a = 1 + 2", "local a: integer = 1 + 2")
  expect.ast_type_equals("local a = 1 + 2.0", "local a: number = 1 + 2.0")
  expect.ast_type_equals("local a = 1_f32 + 2_f32", "local a: float32 = 1_f32 + 2_f32")
  expect.ast_type_equals("local a = 1_f32 + 2_f64", "local a: float64 = 1_f32 + 2_f64")
  expect.ast_type_equals("local a = 1_i8 + 2_u8",   "local a: int8 = 1_i8 + 2_u8")
  expect.ast_type_equals("local a = 1_i8 + 2_u16",  "local a: int16 = 1_i8 + 2_u16")
  expect.ast_type_equals("local a = 1_i8 + 2_u32",  "local a: int32 = 1_i8 + 2_u32")
  expect.ast_type_equals("local a = 1_i8 + 2_u64",  "local a: int64 = 1_i8 + 2_u64")
  expect.ast_type_equals("local a = 1_i8 + 2_f32",  "local a: float32 = 1_i8 + 2_f32")
  expect.ast_type_equals("local a = 1_i8 + 2_f64",  "local a: float64 = 1_i8 + 2_f64")
  expect.ast_type_equals("local a = 1_i16 + 2_u8",  "local a: int16 = 1_i16 + 2_u8")
  expect.ast_type_equals("local a = 1_i16 + 2_u16", "local a: int16 = 1_i16 + 2_u16")
  expect.ast_type_equals("local a = 1_i16 + 2_u32", "local a: int32 = 1_i16 + 2_u32")
  expect.ast_type_equals("local a = 1_i16 + 2_u64", "local a: int64 = 1_i16 + 2_u64")
  expect.ast_type_equals("local a = 1_i16 + 2_f32", "local a: float32 = 1_i16 + 2_f32")
  expect.ast_type_equals("local a = 1_i16 + 2_f64", "local a: float64 = 1_i16 + 2_f64")
  expect.ast_type_equals("local a = 1_i32 + 2_u8",  "local a: int32 = 1_i32 + 2_u8")
  expect.ast_type_equals("local a = 1_i32 + 2_u16", "local a: int32 = 1_i32 + 2_u16")
  expect.ast_type_equals("local a = 1_i32 + 2_u32", "local a: int32 = 1_i32 + 2_u32")
  expect.ast_type_equals("local a = 1_i32 + 2_u64", "local a: int64 = 1_i32 + 2_u64")
  expect.ast_type_equals("local a = 1_i32 + 2_f32", "local a: float32 = 1_i32 + 2_f32")
  expect.ast_type_equals("local a = 1_i32 + 2_f64", "local a: float64 = 1_i32 + 2_f64")
  expect.ast_type_equals("local a = 1_i64 + 2_u8",  "local a: int64 = 1_i64 + 2_u8")
  expect.ast_type_equals("local a = 1_i64 + 2_u16", "local a: int64 = 1_i64 + 2_u16")
  expect.ast_type_equals("local a = 1_i64 + 2_u32", "local a: int64 = 1_i64 + 2_u32")
  expect.ast_type_equals("local a = 1_i64 + 2_u64", "local a: int64 = 1_i64 + 2_u64")
  expect.ast_type_equals("local a = 1_i64 + 2_f32", "local a: float32 = 1_i64 + 2_f32")
  expect.ast_type_equals("local a = 1_i64 + 2_f64", "local a: float64 = 1_i64 + 2_f64")
  expect.ast_type_equals("local a = 1_i32 + 2    ", "local a: int32 = 1_i32 + 2")
  expect.ast_type_equals("local a = 1     + 2_i32", "local a: int32 = 1     + 2_i32")
  expect.ast_type_equals("local a = 1_i64 + 2.1", "local a: number = 1_i64 + 2.1")
  expect.analyze_error("local a = 1 + 's'", "invalid operation")
  expect.analyze_error("local a = 1.0 + 's'", "invalid operation")
end)

it("binary operator mul", function()
  expect.ast_type_equals("local a = 1 * 2", "local a: integer = 1 * 2")
  expect.ast_type_equals("local a = 1_f32; local b = 2.0*a",
                         "local a: float32 = 1_f32; local b: float32 = 2.0*a")
  expect.ast_type_equals("local a = 1_f32; local b = a*2.0",
                         "local a: float32 = 1_f32; local b: float32 = a*2.0")
end)

it("binary operator div", function()
  expect.ast_type_equals("local a = 2 / 2", "local a: number = 2 / 2")
  expect.ast_type_equals("local a = 2.0_f64 / 2_i64", "local a: number = 2.0_f64 / 2_i64")
  expect.ast_type_equals("local b = 1; local a = 2.0 / b", "local b = 1; local a: number = 2.0 / b")
  expect.ast_type_equals("local a = 2_i32 / 2_i32", "local a: number = 2_i32 / 2_i32")
  expect.ast_type_equals(
    "local x = 1; local a = x / 2_f32",
    "local x = 1; local a: float32 = x / 2_f32")
  expect.analyze_ast("local a = 1 / 0")
  expect.analyze_ast("local a = 1 / -0")
  expect.analyze_ast("local a = 1.0 / 0")
  expect.analyze_ast("local a = 1 / 0.0")
  expect.ast_type_equals(
    "local a, b = 1.0, 2; a = b / 1",
    "local a: number, b: integer = 1.0, 2; a = b / 1")
end)

it("binary operator idiv", function()
  expect.ast_type_equals("local a = 2 // 2", "local a: integer = 2 // 2")
  expect.analyze_error("local a = 1 // 0", "divide by zero")
  expect.analyze_ast("local a = 1.0 // 0")
  expect.analyze_ast("local a = 1 // 0.0")
end)

it("binary operator tdiv", function()
  expect.ast_type_equals("local a = 2 /// 2", "local a: integer = 2 /// 2")
  expect.analyze_error("local a = 1 /// 0", "divide by zero")
  expect.analyze_error("local a = (-9223372036854775807-1) /// -1", "divide overflow")
  expect.analyze_ast("local a = 1.0 /// 0")
  expect.analyze_ast("local a = 1 /// 0.0")
end)

it("binary operator mod", function()
  expect.ast_type_equals("local a = 2_u32 % 2_u32", "local a: uint32 = 2_u32 % 2_u32")
  expect.analyze_error("local a = 1 % 0", "divide by zero")
  expect.analyze_ast("local a = 1.0 % 0")
  expect.analyze_ast("local a = 1 % 0.0")
end)

it("binary operator tmod", function()
  expect.ast_type_equals("local a = 2_u32 %%% 2_u32", "local a: uint32 = 2_u32 %%% 2_u32")
  expect.analyze_error("local a = (-9223372036854775807-1) %%% -1", "divide overflow")
  expect.analyze_error("local a = 1 %%% 0", "divide by zero")
  expect.analyze_ast("local a = 1.0 %%% 0")
  expect.analyze_ast("local a = 1 %%% 0.0")
end)

it("binary operator pow", function()
  expect.ast_type_equals("local a = 2 ^ 2", "local a: number = 2 ^ 2")
  expect.ast_type_equals("local a = 2_i32 ^ 2_i32", "local a: number = 2_i32 ^ 2_i32")
end)

it("binary operator eq", function()
  expect.ast_type_equals("local a = 1 == 2", "local a: boolean = 1 == 2")
  expect.ast_type_equals("local a = 1 == 'a'", "local a: boolean = 1 == 'a'")
end)

it("binary operator ne", function()
  expect.ast_type_equals("local a = 1 ~= 2", "local a: boolean = 1 ~= 2")
  expect.ast_type_equals("local a = 1 ~= 'a'", "local a: boolean = 1 ~= 'a'")
end)

it("binary operator lt", function()
  expect.ast_type_equals("local a = 1 < 2", "local a: boolean = 1 < 2")
  expect.analyze_error("local i: integer = 1; if not i < 0 then end", "invalid operation between")
end)

it("binary operator bor", function()
  expect.ast_type_equals("local a = 1 | 2", "local a: integer = 1 | 2")
  expect.analyze_error("local a = 1 | 's'", "attempt to perform a bitwise operation")
end)

it("binary operator band", function()
  expect.ast_type_equals("local a = 1 & 2", "local a: integer = 1 & 2")
  expect.ast_type_equals("local a = 1_i32 & 1", "local a: int32 = 1_i32 & 1")
  expect.ast_type_equals("local a: auto = 1_u32 & 2_u64", "local a: uint64 = 1_u32 & 2_u64")
  expect.analyze_error("local a = 1 & 's'", "attempt to perform a bitwise operation")
end)

it("binary operator bxor", function()
  expect.ast_type_equals("local a = 1 ~ 2", "local a: integer = 1 ~ 2")
  expect.analyze_error("local a = 1 ~ 's'", "attempt to perform a bitwise operation")
  expect.analyze_error("local a = 1; local b = (a ^ a) ~ a", 'bitwise operation with non integral')
end)

it("binary operator shl", function()
  expect.ast_type_equals("local a = 1 << 2", "local a: integer = 1 << 2")
  expect.analyze_error("local a = 1 << 's'", "attempt to perform a bitwise operation")
end)

it("binary operator shr", function()
  expect.ast_type_equals("local a = 1 >> 2", "local a: integer = 1 >> 2")
  expect.analyze_error("local a = 1 >> 's'", "attempt to perform a bitwise operation")
end)

it("binary operator asr", function()
  expect.ast_type_equals("local a = 1 >>> 2", "local a: integer = 1 >>> 2")
  expect.analyze_error("local a = 1 >>> 's'", "attempt to perform a bitwise operation")
end)

it("binary conditional and", function()
  expect.ast_type_equals("local a = 1 and 2", "local a: integer = 1 and 2")
  expect.ast_type_equals("local a = 1_i8 and 2_u8", "local a: int8 = 1_i8 and 2_u8")
  expect.ast_type_equals("local a = 1 and true", "local a: any = 1 and true")
  expect.ast_type_equals("local a = 1 and 2 or 3", "local a: integer = 1 and 2 or 3")
  expect.ast_type_equals("local a = 1 and '2'", "local a: any = 1 and '2'")
  expect.ast_type_equals("local a = 1.0 and '2'", "local a: any = 1.0 and '2'")
  expect.ast_type_equals("local a = 1.0 and 2.0_f32", "local a: float32 = 1.0 and 2.0_f32")
  expect.ast_type_equals("local a = 1.0_f32 and 2.0", "local a: float32 = 1.0_f32 and 2.0")
  expect.ast_type_equals("local a = 1.0_f32 and 2.0_f64", "local a: float64 = 1.0_f32 and 2.0_f64")
  expect.ast_type_equals("local a = 1.0_f64 and 2.0_f32", "local a: float64 = 1.0_f64 and 2.0_f32")
end)

it("binary conditional or", function()
  expect.ast_type_equals("local a = 1 or true", "local a: any = 1 or true")
  expect.ast_type_equals("local a = nilptr and false or 1", "local a: any = nilptr and false or 1")
end)

it("binary operator concat", function()
  expect.analyze_ast("local a = 'a'..'b'")
  expect.analyze_error("local a = 'a' local ab = a..'b'", "invalid operation between types")
end)

it("operation with parenthesis", function()
  expect.ast_type_equals("local a = -(1)", "local a: integer = -(1)")
end)

it("late deduction", function()
  expect.ast_type_equals([[
    local a, b, c
    a = 1
    b = 2
    c = a + b
  ]],[[
    local a:integer, b:integer, c:integer
    a = 1
    b = 2
    c = a + b
  ]])
  expect.ast_type_equals([[
    local a = 1
    a = true
  ]],[[
    local a: any = 1
    a = true
  ]])
  expect.ast_type_equals([[
    local a = 1_integer
    local b = a + 1
  ]],[[
    local a: integer = 1_integer
    local b: integer = a + 1
  ]])
  expect.ast_type_equals([[
    local limit = 1_integer
    for i=1,limit do end
  ]],[[
    local limit = 1_integer
    for i:integer=1,limit do end
  ]])
  expect.ast_type_equals([[
    local a
    a = a + 1
    local x = a
  ]], [[
    local a
    a = a + 1
    local x: any = a
  ]])
  expect.ast_type_equals([[
    local a
    a = a + 1
    local x = a
    local a = 2
  ]], [[
    local a: any
    a = a + 1
    local x: any = a
    local a: integer = 2
  ]])
  expect.ast_type_equals([[
    local x: integer, y: integer = 1, 2
    local x = x + y
  ]], [[
    local x: integer, y: integer = 1, 2
    local x: integer = x + y
  ]])
  expect.ast_type_equals([[
    local a = false
    local b = 2
    do
       local c = b == 1
       a = c
    end
  ]],[[
    local a: boolean = false
    local b: integer = 2
    do
       local c: boolean = b == 1
       a = c
    end
  ]])
  expect.ast_type_equals([[
    local ONE: integer <comptime> = 1
    local z = ONE
    for y=1,z do
      for x=0,y do
        local a = x
      end
    end
    z = 2.0
  ]],[[
    local ONE: integer <comptime> = 1
    local z:number = ONE
    for y:number=1,z do
      for x:number=0,y do
        local a:number = x
      end
    end
    z = 2.0
  ]])
  expect.ast_type_equals([[
    local R = @record{x: integer}
    function R:f() return (@pointer)(self) end
    local r = (@R)()
    do
      local p = r:f()
      p = nilptr
    end
  ]],[[
    local R = @record{x: integer}
    function R:f(): pointer return (@pointer)(self) end
    local r: R = (@R)()
    do
      local p: pointer = r:f()
      p = nilptr
    end
  ]])
  expect.ast_type_equals([[
    local i: integer
    local a: auto = nilptr or &i
    local b: auto = &i and nilptr

  ]],[[
    local i: integer
    local a: *integer = nilptr or &i
    local b: *integer = &i and nilptr
  ]])
  expect.ast_type_equals([[
    local a = 1_integer
    local b = 1_number
    b = b + 1_integer
    a = b
  ]],[[
    local a: number = 1_integer
    local b: number = 1_number
    b = b + 1_integer
    a = b
  ]])
  expect.ast_type_equals([[
    local a, b = 0, 0
    do
      local c = a*b
      b = c + c
    end
  ]],[[
    local a: integer, b: integer = 0, 0
    do
      local c: integer = a*b
      b = c + c
    end
  ]])
end)

it("anonymous functions", function()
  expect.analyze_ast([[
    local function foo(f: function(integer)) end
    foo(function(x: integer) end)
  ]])
  expect.analyze_error([[
    local function foo(f: function(x: integer)) end
    foo(function(x: auto) end)
  ]], "anonymous functions cannot be polymorphic")
  expect.analyze_error([[
    local function foo(f: function(x: integer): integer) end
    foo(function(x: integer): integer end)
  ]], "a return statement is missing")
end)

it("function definition", function()
  expect.analyze_ast([[
    local f
    function f() end
  ]])
  expect.analyze_ast([[
    local function f(...) end
    local function f(...: cvarargs) end
    local function f(...: varanys) end
  ]])
  expect.analyze_ast([[
    global function f(a: integer) end
    local function f(a: integer) end
    function f(a: integer) end
  ]])
  expect.analyze_ast([[
    local f: function(integer): string
    function f(a: integer): string return '' end
  ]])
  expect.analyze_ast([[
    local function f(): type return @integer end
    local int = f()
    local a: int = 0
  ]])
  expect.analyze_error([[
    local function f() return @integer, @string end
    local int, str = f()
  ]], "a type declaration can only assign to the first assignment expression")
  expect.analyze_error([[
    do
      global function f() end
    end
  ]], "can only be declared in top scope")
  expect.analyze_error([[
    local f: isize
    function f(a: integer) return 0 end
  ]], "no viable type conversion")
  expect.analyze_error([[
    local function f(a: integer) end
    function f(a: integer, b:integer) end
  ]], "no viable type conversion")
  expect.analyze_error([[
    local function f(a: integer) end
    function f(a: string) end
  ]], "no viable type conversion")
  expect.analyze_error([[
    local function f(): (integer, string) return 1, '' end
    function f(): integer return 1 end
  ]], "no viable type conversion")
  expect.analyze_error([[
    local f: function():(integer, string)
    function f(): integer return 1 end
  ]], "no viable type conversion")
  expect.analyze_ast([[
    local f: function(): type
  ]])
  expect.analyze_error([[
    local function f(): f end
  ]], "invalid type for function return")
end)

it("closures", function()
  expect.analyze_ast([[
    local x: integer = 1
    do
      local y: integer <comptime> = 1
      local function foo()
        print(x, y)
      end
    end
  ]])
  expect.analyze_ast([[ -- block locals are captured like inside a function
    do
      local x: integer = 1
      local function foo()
        print(x)
      end
      local bar = function() print(x) end
    end
  ]])
  expect.analyze_error([[
    do
      local x: integer = 1
      local R = @record{}
      function R.foo()
        print(x)
      end
    end
  ]], "attempt to access upvalue")
end)

it("poly function definition", function()
  expect.analyze_ast([[
    local function f(x: auto) end
    f(1)
    f('s')
  ]])
  expect.analyze_ast([[
    local function f(x: auto) return x end
    local a = f(1)
    local b = f('s')
  ]])
  expect.analyze_ast([[
    local function f(x: auto, y: auto) return x, y end
    local a = f(1, 's')
    local b = f('s', 1)
  ]])
  expect.analyze_ast([[
    local function f(x: auto) return x end
    local a = 1
    f(a)
  ]])
  expect.analyze_ast([[
    local function f(T: type): integer
      return 1
    end
    f(@number)
  ]])
  expect.analyze_ast([[
    local function cast(T: type, value: auto)
      return (@T)(value)
    end
    local a = cast(@number, 1)
  ]])
  expect.analyze_ast([[
    local R = @record{}
    function R.foo(x: auto)
      return 1
    end
    local x = R.foo(2)
  ]])
  expect.analyze_ast([[
    local function f(x: auto): #[x.type]#
      return x
    end
    local function g(x: auto): pointer(#[x.type]#)
      return &x
    end
    local a: integer = f(1)
    local b: *integer = g(1)
  ]])
  expect.analyze_error([[
    local function f(x: auto): #[x.type]#
      return false
    end
    f(1)
  ]], "no viable type conversion from")
  expect.ast_type_equals([[
    ## for i=1,2 do
      local function #|'f'..i|#(): #[i == 1 and primtypes.integer or primtypes.number]#
        return 1
      end
    ## end
  ]],[[
    local function f1(): integer return 1 end
    local function f2(): number return 1 end
  ]])
end)

it("function return", function()
  expect.ast_type_equals(
    "local function f() return 0 end",
    "local function f(): integer return 0 end"
  )
  expect.ast_type_equals([[
    local function f()
      local a, b, c
      a = 1; b = 2; c = a + b
      return c
    end
    ]],[[
    local function f(): integer
      local a: integer, b: integer, c: integer
      a = 1; b = 2; c = a + b
      return c
    end
  ]])
  expect.ast_type_equals([[
    local f
    local x = f()
  ]],[[
    local f: any
    local x: any = f()
  ]])
  expect.analyze_ast([[
    local function f(): record{x: integer, y: integer}
      return {x=1, y=2}
    end
    local a: auto = f()
  ]])
  expect.analyze_ast([[
    local function test(value: isize): isize
      while true do
        if true then
          return value
        end
      end
    end
  ]])
  expect.analyze_ast([[
    local function f(): integer return 1 end
    local function f(): integer if true then return 1 else return 2 end end
    local function f(): integer do return 1 end end
    local function f(): integer switch 1 case 1 then return 1 else return 2 end end
    local function f(): integer switch 1 case 1, 2 then return 1 else return 2 end end
    local function f(): integer error('error!') return 0 end
    local function f(): integer panic('panic!') return 0 end
    local function g() <noreturn> error'error!' end
    local function f(): integer g() return 0 end
    local function f(): (integer, string) return 1 end
  ]])
  expect.analyze_ast([[
    local function f() end
    local a: any
    a = f()
  ]])
  expect.analyze_error([[
    local function f(): integer panic('panic!') end
  ]], "a return statement is missing before function end")
  expect.analyze_error([[
    local function f() end
    local a: integer = f()
  ]], "no viable type conversion from 'void'")
  expect.analyze_error([[
    local function f(): integer end
  ]], "return statement is missing")
  expect.analyze_error([[
    local function f(): integer if false then return 1 end end
  ]], "return statement is missing")
  expect.analyze_error([[
    local function f(): integer switch 1 case 1 then end end
  ]], "return statement is missing")
  expect.analyze_error([[
    local function f(x: boolean): integer
      if x then assert(true) else return 1 end
    end
  ]], "return statement is missing")
  expect.analyze_error([[
    local function test(value: isize): isize
      while true do
        if true then
          break
        end
      end
    end
  ]], "return statement is missing")
  expect.analyze_ast([[
    local function test(value: isize): isize
      while true do
        if true then
          return value
        end
      end
    end
  ]])
  expect.analyze_error([[
    local function f(): integer return 1, 2 end
  ]], "invalid return expression at index")
  expect.analyze_error([[
    local function f(): string return 0 end
  ]], "no viable type conversion")
end)

it("function multiple return", function()
  expect.analyze_ast([[
    local function f(): (integer, string) return 1,'s'  end
    local function g(a: boolean, b: integer, c: string) end
    g(false, f())
    local a: integer, b: string = f()
    local a: integer = f()
  ]])
  expect.analyze_ast([[
    local function f(): (integer, boolean) return 1,false  end
    local a, b, c = f()
  ]])
  expect.analyze_ast([[
    local function f(): varanys end
    local a, b, c
    a, b, c  = f()
    local x = f()
  ]])
  expect.analyze_ast([[
    local function f(): (boolean,integer) return true,1 end
    local function g(): (boolean,integer) return f() end
    local a: boolean, b: integer = g()
  ]])
  expect.analyze_ast([[
    local f: any
    local a, b = f()
  ]])
  expect.analyze_ast([[
    local R = @record{x: integer}
    function R.foo(self: *R): (boolean, integer) return true, self.x end
    function R:boo(): (boolean, integer) return true, self.x end
    local r = R{}
    local function foo(): (boolean, integer) return R.foo(r) end
    local function boo(): (boolean, integer) return r:boo() end
  ]])
  expect.ast_type_equals([[
    local function f() return true,1 end
    local function g() return f() end
    local a, b = g()
  ]],[[
    local function f() return true,1 end
    local function g(): (boolean,integer) return f() end
    local a: boolean, b: integer = g()
  ]])
  expect.ast_type_equals([[
    local function f() return true,1 end
    local function g() return 's', f() end
    local a, b = g()
  ]],[[
    local function f() return true,1 end
    local function g(): (string,boolean,integer) return 's', f() end
    local a: string, b: boolean = g()
  ]])
  expect.analyze_error([[
    local function f(): (integer, boolean) return 1,false  end
    local a, b, c
    a, b, c = f()
  ]], 'is assigning to nothing in the expression')
  expect.analyze_error([[
    local function f() return 1,false  end
    local a, b, c
    a, b, c = f()
  ]], 'is assigning to nothing in the expression')
  expect.analyze_error([[
    local function f(): (integer, boolean) return 1,false  end
    local function g(a: boolean, b: integer, c: string) end
    g(false, f())
  ]], 'no viable type conversion')
  expect.analyze_error([[
    local function f(): (integer, boolean) return 1,false  end
    local a: integer, b: number = f()
  ]], 'no viable type conversion')
  expect.analyze_error([[
    local function f(): (integer, boolean) return 1,false  end
    local a: integer, b: number;
    a, b = f()
  ]], 'no viable type conversion')
  expect.analyze_error([[
    local function f(): (integer, number) return 1,'s'  end
  ]], 'no viable type conversion')
end)

it("switch", function()
  expect.analyze_ast([[
    local B <comptime> = 2
    local a = 2
    switch a case 1 then case B then else end
  ]])
  expect.analyze_error(
    "switch 's' case 1 then end",
    'must be convertible to an integral')
  expect.analyze_error(
    "local a; switch a case 1 then case 1.1 then else end",
    'must evaluate to a compile time integral value')
end)

it("switch fallthrough", function()
  expect.analyze_ast([[
    switch 3 case 1 then fallthrough case 2 then fallthrough else end
  ]])
  expect.analyze_error("fallthrough",
    'must be inside a switch case black')
  expect.analyze_error("switch 3 case 1 then else fallthrough end",
    'must be inside a switch case black')
  expect.analyze_error("switch 3 case 1 then fallthrough end",
    'must be followed by another switch block')
  expect.analyze_error("switch 3 case 1 then fallthrough fallthrough case 2 then end",
    'must be used at most once per switch case block')
  expect.analyze_error("switch 3 case 1 then fallthrough print() case 2 then end",
    'must be the very last statement of a switch case block')
end)

it("function call", function()
  expect.ast_type_equals([[
    local function f() return 0 end
    local a = f()
  ]],[[
    local function f(): integer return 0 end
    local a: integer = f()
  ]])
  expect.analyze_ast([[local function f(a: integer) end; f(1_u32)]])
  expect.analyze_ast([[local function f(a) end; f() f(1)]])
  expect.analyze_ast([[local function f(...: cvarargs) end; f('')]])
  expect.analyze_ast([[local function f(a: integer) end; f()]])
  expect.analyze_error([[local a: integer = 1; a()]], "cannot call type")
  expect.analyze_error([[local function f(a: integer) end; f('a')]], "no viable type conversion")
  expect.analyze_error([[local function f(a: integer) end; f(1,1)]], "expected at most 1 arguments but got 2")
  expect.analyze_error([[local function f(a: integer) end; f(nil)]], "expected an argument at index 1 but got nil")
  expect.analyze_error([[local function f(...: cvarargs) end; local r:record{} f(r)]], "invalid type")
end)

it("callbacks", function()
  expect.analyze_ast([[
    local callback_type = @function(x: integer, string): (number, boolean)
    local callback: callback_type = nilptr
  ]])
  expect.analyze_ast([[
    local callback_type = @function(*integer, [4]integer, record{x:integer}): ([4]integer, boolean)
    local callback: callback_type = nilptr
  ]])
  expect.analyze_ast([[
    local Callback = @function(*void)
    local g: function(*integer)
    local f: Callback = (@Callback)(g)
    local f: Callback = (@Callback)(nilptr)
    local p: pointer
    local f: Callback = (@Callback)(p)
    p = (@pointer)(f)
  ]])
  expect.ast_type_equals([[
    local f: function()
  ]],[[
    local f: function(): void
  ]])
  expect.analyze_ast([[
    local f: function(...: cvarargs)
  ]])
  expect.analyze_error([[
    local F: type = @function()
    local f: F = function(x: integer) end
  ]], "is also known as")
  expect.analyze_error([[
    local F: type = @function()
    local g: function(x: integer) = (@F)()
  ]], "is also known as")
  expect.analyze_error([[local r: record{f: function(x: integer)} r.f(true)]], "no viable type conversion")
end)

it("for in", function()
  expect.analyze_ast([[local a,b,c; for i in a,b,c do end]])
  expect.analyze_error(
    [[local a = 1; for i in a do end]],
    "cannot call type")
  expect.analyze_error(
    [[for i in a,b,c,d,e do end]],
    "`in` statement can have at most")

  --[=[
  expect.ast_type_equals([[
  local function iter() return 1 end
  for i in iter do end
  ]],[[
  local function iter():integer return 1 end
  for i:integer in iter do end
  ]])
  ]=]
end)

it("break", function()
  expect.analyze_ast("for i=1,10 do break end")
  expect.analyze_ast("while true do break end")
  expect.analyze_ast("repeat break until true")
  expect.analyze_error("break", "is not inside a loop")
  expect.analyze_error("do break end", "is not inside a loop")
  expect.analyze_error("if true then break end", "is not inside a loop")
end)

it("continue", function()
  expect.analyze_ast("for i=1,10 do continue end")
  expect.analyze_ast("while true do continue end")
  expect.analyze_ast("repeat continue until true")
  expect.analyze_error("continue", "is not inside a loop")
  expect.analyze_error("do continue end", "is not inside a loop")
  expect.analyze_error("if true then continue end", "is not inside a loop")
end)

it("goto", function()
  expect.analyze_ast("goto label ::label::")
  expect.analyze_ast("::label:: goto label")
  expect.analyze_ast("do goto label end ::label::")
  expect.analyze_ast("::label:: do goto label end")
  expect.analyze_ast("local function f() ::label:: do goto label end end")
  expect.analyze_ast("local function f() do goto label end ::label:: end")
  expect.analyze_error("::label:: ::label::", "label 'label' already defined")
  expect.analyze_error("goto label", "no visible label")
  expect.analyze_error("local function f() goto label end ::label::", "no visible label")
  expect.analyze_error("::label:: local function f() goto label end", "no visible label")
  expect.analyze_error([[defer end goto finish ::finish::]], 'cannot mix `goto` and `defer` statements')
  expect.analyze_error([[do defer end goto finish end ::finish::]], 'cannot mix `goto` and `defer` statements')
end)

it("spans", function()
  expect.analyze_ast([[
    require 'span'
    local a: span(boolean)
    local dataptr = a.data
    local size = a.size
    a.data = nilptr
    a.size = 0
    local b: boolean = a[0]
    a[0] = b
    local len = #a
  ]])
  expect.analyze_ast([[
    require 'span'
    local a: span(boolean)
    local b: span(boolean)
    b = a
  ]])
  expect.analyze_error([[
    require 'span'
    local a: span(float64)
    local b: span(int64)
    b = a
  ]], 'no viable conversion')
  expect.analyze_error([[
    require 'span'
    local a: span(float64)
    local b: span(int64)
    b = a
  ]], 'no viable conversion')
  expect.analyze_error([[
    require 'span'
    local v1: span(integer)
    local v2: span(*integer)
    v1 = v2
  ]], "no viable conversion from 'span(pointer(int64))' to 'span(int64)'")
  expect.analyze_error([[require 'span' local a: span(void) ]], 'spans cannot be of')
  expect.analyze_error([[
    require 'span'
    local function f(): span(integer)
      local priv: []integer = {1,2}
      return priv
    end
  ]], 'cannot perform conversion')
  expect.analyze_error([[
    require 'span'
    local a: span(record{})
  ]], 'spans cannot be of empty type')
end)

it("arrays", function()
  expect.analyze_ast([[local N <comptime> = 10; local a: array(integer, N) ]])
  expect.analyze_ast([[local a: array(integer, 10); a[0] = 1]])
  expect.analyze_ast([[local a: array(integer, 2) = {1,2}]])
  expect.analyze_ast([[local a: array(integer, 2); a[0] = 1; a[1] = 2]])
  expect.analyze_ast([[local a: array(integer, 2); a = {1,2}]])
  expect.analyze_ast([[local a: array(integer, 2); a = {}]])
  expect.analyze_ast([[local a: array(integer, 10), b: array(integer, 10); b = a]])
  expect.analyze_ast([[local a: array(integer, 2) <comptime> = {1,2}]])
  expect.analyze_ast([[local a: array(integer) = {1,2}]])
  expect.analyze_ast([[local a: array(integer, 2) = {1}]])
  expect.analyze_ast([[local a: array(integer, (2 << 1))]])
  expect.analyze_ast([[local a: []integer = {}]])
  expect.analyze_ast([[local a: []integer = {1}]])
  expect.analyze_ast([[local a: []integer = {1,2}]])
  expect.analyze_ast([[local a = (@[]integer){}]])
  expect.analyze_ast([[local a = (@[]integer){0}]])
  expect.analyze_ast([[local a = (@[]integer){1,2}]])
  expect.analyze_error([[local X = 2; local a: array(integer, X);]], "unknown comptime value for expression")
  expect.analyze_error([[local a: array(type, 4)]], 'subtype cannot be of compile-time type')
  expect.analyze_error([[local a: array(integer, 2) = {1,2,3}]], 'expected at most 2 values in array literal but got 3')
  expect.analyze_error([[local a: array(integer, 2) = {1.1,2.3}]], 'is fractional')
  expect.analyze_error([[local a: array(integer, 2) = {a=0,2}]], 'fields are disallowed')
  expect.analyze_error([[local a: array(integer, 10), b: array(integer, 11); b = a]], "no viable type conversion")
  expect.analyze_error([[local a: array(integer, 10); a[0] = 1.1]], "is fractional")
  expect.analyze_error([[local a: array(integer, 1.0) ]], "cannot have non integral type")
  expect.analyze_error([[local N <comptime> = -1 local a: array(integer, N) ]], "cannot have negative array size")
  expect.analyze_error([[local Array = @array(integer, 1); local a = Array.l]], "cannot index meta field")
  expect.analyze_error([[local a: array(integer, 2); a[-1] = 1]], 'cannot index negative value')
  expect.analyze_error([[local a: array(integer, 2); a[2] = 1]], 'is out of bounds')
  expect.analyze_error([[local a: array(integer, 2); a['s'] = 1]], 'cannot index with value of type')
  expect.analyze_error([[local a: array(integer)]], 'cannot infer array size in this context')
  expect.analyze_error([[local a: array(integer) = 1]], 'cannot infer array size in this co')
  expect.analyze_error([[local a = (@[]integer)()]], "cannot infer array size in this context")
  expect.analyze_error([[local a: []integer]], "cannot infer array size in this context")
  expect.analyze_error([[local a: *array(integer)]], 'cannot infer array size, use a fixed size')
  expect.analyze_error(
    [[local b; local a: array(integer, 2) <comptime> = {1,b}]],
    'can only assign to compile time expressions')
end)

it("indexing", function()
  expect.analyze_ast([[local a; local c = a[2] ]])
  expect.analyze_error([[local a = 1; a[1] = 2]], 'cannot index variable of type')
  expect.analyze_error([[local a = 1; a.b = 2]], 'cannot index field')
end)

it("records", function()
  expect.analyze_ast([[local R = @record{} local r: R]])
  expect.analyze_ast([[local a: record{x: boolean}; a.x = true]])
  expect.analyze_ast([[local a: record{x: boolean} = {}]])
  expect.analyze_ast([[local a: record{x: boolean} = {x = true}]])
  expect.analyze_ast([[local a: record{x: boolean}; a = {}]])
  expect.analyze_ast([[local a: record{x: boolean}; a = {x = true}]])
  expect.analyze_error([[local a: integer = @record{}]], "attempt to assign a type")
  expect.analyze_error([[local a: record{x: integer}; a.x = true]], "no viable type conversion")
  expect.analyze_error([[local a: record{x: boolean}; local b = a.y]], "cannot index field")
  expect.analyze_error([[local a: record{x: integer} = {x = true}]], "no viable type conversion")
  expect.analyze_error([[local a: record{x: boolean} = {y = 1}]], "is not present in record")
  expect.analyze_error([[local a: record{x: boolean} = {[x] = 1}]], "only string literals are allowed")
  expect.analyze_error([[local a: record{x: boolean} = {false,false}]], "field at index 2 is invalid")
  expect.analyze_ast([[
    local Record: type = @record{x: boolean}
    local a: Record, b: Record
    b = a
  ]])
  expect.analyze_ast([[
    local Record: type = @record{x: boolean}
    local a
    a = Record{x = true}
    a = Record{}
    a = Record{false}
  ]])
  expect.analyze_ast([[
    local Record: type = @record{x: integer, y: integer}
    local a
    a = Record{x=1, 2}
    a = Record{1, y=2}
  ]])
  expect.analyze_ast([[
    local Record = @record{x: boolean}
    local a <const> = Record{}
    local b <const> = Record{x=true}
  ]])
  expect.analyze_error([[
    local Record: type = @record{x: integer, y: integer}
    local a
    a = Record{y = 1, 2}
  ]], "field at index 3 is invalid")
  expect.analyze_error([[
    local a: record{x: boolean}, b: record{x: boolean}
    b = a
  ]], "no viable type conversion")
  expect.analyze_error([[
    local A, B = @record{x: boolean}, @record{x: boolean}
    local a: A, b: B
    b = a
  ]], "no viable type conversion")
  expect.analyze_error([[
    local Record
    local a <comptime> = Record{}
  ]], "can only assign to compile time expressions")
  expect.analyze_error([[
    local Box = @record{n: number}
    local b: Box <comptime> = {n=3}
  ]], "compile time variables cannot be of type")
  expect.ast_type_equals(
    "local a: record{x: boolean}; local b = a.x",
    "local a: record{x: boolean}; local b: boolean = a.x")
  expect.ast_type_equals(
    "local a: record{x: boolean}; local b; b = a.x",
    "local a: record{x: boolean}; local b: boolean; b = a.x")
  expect.analyze_error([[
    local A, B = @record{x: boolean}, @record{x: boolean}
    local a: A, b: B
    b = a
  ]], "no viable type conversion")
  expect.analyze_error([[
    local A = @record{x: type}
  ]], "cannot be of compile-time type")
  expect.analyze_error([[
    local Node = @record{x: integer, leafs: Node}
  ]], "cannot nest")
  expect.analyze_error([[
    local Node = @record{x: integer, leafs: [4]Node}
  ]], "cannot nest")
  expect.analyze_error([[
    local Node = @record{x: integer, leafs: *[4]Node}
  ]], "cannot nest")
  expect.analyze_error([[
    local Record = @record{x: integer, x: boolean}
  ]], "duplicate record field")
end)

it("records metamethods", function()
  expect.analyze_ast([[
    local R = @record{}
    function R:__atindex(x: integer): *integer return nilptr end
    function R:__len(): integer return 0 end
    local r: R
    local x = r[0]
    r[0] = x
    local len = #r
  ]])
  expect.analyze_error([[
    local R = @record{}
    global R.__call: integer = 1
    local r: R
    r()
  ]], "expected meta field '__call' to be a procedure")
  expect.analyze_error([[
    local R = @record{}
    function R:__atindex(x: integer): integer return 0 end
    local r: R
    r[0] = 1
  ]], "in unary operation `deref`")
  expect.analyze_error([[
    local R = @record{}
    function R:__atindex(x: integer) return 0 end
    local r: R
    r[0] = 1
  ]], "in unary operation `deref`")
  expect.analyze_error([[
    local R = @record{}
    local r: R
    local x = r[0]
  ]], "cannot index record")
  expect.analyze_error([[
    local R = @record{}
    local r: R
    local x = #r
  ]], "invalid operation")
  expect.analyze_error([[
    local R = @record{}
    local r: R
    local x = r + r
  ]], "invalid operation")
  expect.analyze_error([[
    local R = @record{f: function(*R, x: integer): integer}
    local r = R{}
    function r:f(x: boolean) return x end
  ]], "no viable type conversion")
end)

it("dependent functions resolution", function()
  expect.ast_type_equals([[
    local A = @record{x:number}
    function A:foo() return self.x end
    local a = A{}
    function A:boo() return a:foo() end
    function A.boo2() return a:foo() end
    local b = a:boo()
    local b2 = A.boo2()
  ]], [[
    local A = @record{x:number}
    function A:foo():number return self.x end
    local a = A{}
    function A:boo():number return a:foo() end
    function A.boo2():number return a:foo() end
    local b:number = a:boo()
    local b2: number = A.boo2()
  ]])

  expect.ast_type_equals([[
    local Foo = @record{x: integer}
    local foo = Foo{x=0}
    function Foo:f() return 1.0 end
    local function f() return foo:f() end
    local x = f()
  ]], [[
    local Foo: type = @record{x: integer}
    local foo: Foo = Foo{x=0}
    function Foo:f(): number return 1.0 end
    local function f(): number return foo:f() end
    local x: number = f()
  ]])
end)

it("record methods", function()
  expect.analyze_ast([[
    local vec2 = @record{x: integer, y: integer}
    function vec2.create(x: integer, y: integer) return vec2{x,y} end
    function vec2:length() return self.x + self.y end
    local v: vec2 = vec2.create(1,2)
    local l: integer = v:length()

    local vec2pointer = @*vec2
    function vec2pointer:len() return self.x + self.y end
    l = v:len()
  ]])
  expect.analyze_error([[
    local vec2 = @record{x: integer, y: integer}
    function vec2.gen(x: integer) vec2{x, x} end
    local a: vec2
    local b = a:gen(1)
  ]], "no viable type conversion")
  expect.analyze_error([[
    local vec2 = @record{x: integer, y: integer}
    local v: vec2 = vec2.create(1,2)
  ]], "cannot index meta field")
  expect.analyze_error([[
    local vec2 = @record{x: integer, y: integer}
    local v: vec2
    local x = v:length()
  ]], "cannot index meta field")
  expect.analyze_error([[
    local vec2 = @record{x: integer, y: integer}
    function vec2.create(x: integer, y: integer) return vec2{x,y} end
    function vec2.create(x: integer, y: integer) return vec2{x,y+1} end
  ]], "cannot redefine meta type field")
  expect.analyze_error([[
    local A = @record{}
    local A.a: integer
    local A.a: integer
  ]], "cannot redefine meta type field")
  expect.analyze_error([[ -- issue #113
    local R = @record{}
    local R.Foo = @record{ x: integer }
    local function x(): R.Fooo return R.Foo{10} end
  ]], "cannot index meta field")
  expect.analyze_error([[
    local B = @record{a: integer}
    local B.lol: function():integer
    function B.lol() return 1 end
  ]], "cannot redefine meta type field")
  expect.analyze_error([[
    local R = @record{}
    function R.hello() end
    local x: R
    x:hello()
  ]], "the function cannot have arguments")
  expect.analyze_error([[
    local R = @record{}
    R:add()
  ]], 'cannot call method')
end)

it("record fields", function()
  expect.analyze_ast([[
    local Math = @record{}
    local Math.PI = 3.14
    local a = Math.PI
  ]])
  expect.analyze_ast([[
    global Math = @record{}
    global Math.mathnumber = @number
    local mathnumber = Math.mathnumber
    local a: mathnumber = 1
  ]])
  expect.analyze_error([[
    local Math = @record{}
    local Math.PI: integer = 3
    Math.PI = 3.14
  ]], "is fractional")
end)

it("type neasting", function()
  expect.analyze_ast([[
    local a: record{x: record{y: integer}}
    a.x.y = 1
    local b = a.x.y
  ]])
  expect.analyze_ast([[
    local a: record{x: record{y: integer}} = {x={y=1}}
  ]])
  expect.analyze_ast([[
    local a: record{a: array(integer, 2)}
    a.a = (@array(integer,2)){1,2}
    local b = a.a
  ]])
  expect.analyze_ast([[
    local a: record{a: array(integer, 2)} = {a={1,2}}
  ]])
end)

it("enums", function()
  expect.analyze_ast([[
    local a: enum{A=0}
    local b: enum(integer){A=0,B}
    local b: enum(byte){A=0,B,C}
    local b: enum(integer){A=0,B=1 + 2}
  ]])
  expect.analyze_ast([[
    local c <comptime> = 2
    local Enum = @enum{A=0,B=1,C=c}
    local e: Enum = Enum.A
    local i: number = e
  ]])
  expect.analyze_ast([[
    local Enum = @enum{A=0}
    local x <comptime> = Enum.A
  ]])
  expect.analyze_ast([[
    local Enum = @enum(byte){A=255}
  ]])
  expect.analyze_error([[
    local e: enum(byte){A=255}
    e = 257
  ]], "is out of range")
  expect.analyze_error([[
    local Enum = @enum(byte){A=256}
  ]], "is out of range")
  expect.analyze_error([[
    local Enum = @enum(byte){A=255,B}
  ]], "is out of range")
  expect.analyze_error([[
    local Enum = @enum(byte){A=256_integer}
  ]], "is out of range")
  expect.analyze_error([[
    local Enum = @enum{A=0,B=3}
    local e: Enum = Enum.A
    local i: string = e
  ]], "no viable type conversion")
  expect.analyze_error([[
    local Enum = @enum{A=0,B}
    local e: Enum = Enum.C
  ]], "cannot index field")
  expect.analyze_error([[
    local Enum = @enum{A,B=3}
  ]], "first enum field requires an initial value")
  expect.analyze_error([[
    local C: integer
    local Enum = @enum{A=C}
  ]], "enum fields can only be assigned to")
  expect.analyze_error([[
    local Enum = @enum{A=1.0}
  ]], "only integral types are allowed in enums")
  expect.analyze_error([[
    local Enum = @enum{A=1}
    local e: Enum
    print(e.A)
  ]], "cannot index field")
end)

it("pointers", function()
  expect.analyze_ast([[
    local a: pointer(integer) = nilptr
    local b: pointer = nilptr
    b = nilptr
    a = nilptr
  ]])
  expect.analyze_ast([[
    local x: usize = 1
    local p: pointer = (@pointer)(x)
    x = (@usize)(p)
  ]])
  expect.analyze_ast([[
    local a: *cchar
    local aa: *[0]cchar
    local b: *byte
    local bb: *[0]byte
    a = aa
    a = b
    a = bb
    aa = aa
    aa = b
    aa = bb
    b = a
    b = aa
    b = bb
    bb = a
    bb = aa
    bb = bb
  ]])
  expect.analyze_ast([[
    local pi: *integer
    local pa: *[0]integer
    local a: [4]integer
    pa = &a
    pi = &a
    local i: integer
    pa = &i
    pi = &i
  ]])
  expect.analyze_ast([[
    local a: **cchar
    local b: **byte
    b = a
  ]])
  expect.ast_type_equals(
    "local a = (@pointer)(nilptr) a = nilptr",
    "local a: pointer = (@pointer)(nilptr) a = nilptr")
  expect.ast_type_equals(
    "local a = nilptr a = (@pointer)(nilptr)",
    "local a: pointer = nilptr a = (@pointer)(nilptr)")
  expect.analyze_ast([[
    local a: pointer(integer) = nilptr
    local b: pointer = nilptr
    b = nilptr
    a = nilptr
  ]])
  expect.analyze_ast([[
    local a: pointer(integer)
    local b: pointer(void)
    b = a
  ]])
  expect.analyze_ast([[
    local a: pointer(integer)
    local b: pointer(integer)
    b = a
  ]])
  expect.analyze_ast([[
    local a: cstring
    local b: pointer(cchar)
    b = a
  ]])
  expect.analyze_error([[
    local x: byte = 1
    local p: pointer = (@pointer)(x)
  ]], "no viable type conversion")
  expect.analyze_error([[
    local p: pointer
    local x: byte = (@byte)(p)
  ]], "no viable type conversion")
  expect.analyze_error([[
    local a: pointer(integer)
    local b: pointer(boolean)
    b = a
  ]], "no viable type conversion")
  expect.analyze_error([[
    local a: pointer(integer)
    local b: pointer
    a = b
  ]], "no viable type conversion")
  expect.analyze_error([[local a: *integer, b: *number; b = a]], "no viable type conversion")
  expect.analyze_error("local a: *auto", "is not addressable thus cannot have a pointer")
  expect.analyze_error("local a: *type", "is not addressable thus cannot have a pointer")
end)

it("dereferencing and referencing", function()
  expect.analyze_ast([[local p: pointer(integer); local i = $p]])
  expect.analyze_ast([[local p: pointer(integer); local i = 1; p = &i]])
end)

it("automatic referencing", function()
  expect.analyze_ast([[
    local R = @record{x: integer}
    local r: R
    local function fr(x: *R) end
    fr(r)

    local A = @[4]integer
    local a: A
    local function fa(x: *A) end
    local function ga(x: *[0]integer) end
    local function ha(x: *[4]integer) end
    fa(a)
    ga(a)
    ha(a)
  ]])
  expect.analyze_ast([[
    local R = @record{x: integer}
    local function fr(x: *R) end
    fr(R{})
  ]])
  expect.analyze_error(
    [[local p: pointer(integer); local a: integer; p = a]],
    "no viable type conversion")
  expect.analyze_error([[
    local R = @record{x: integer}
    local p: pointer(R)
    local r: record{x: R}
    p = r.x
  ]], "no viable type conversion")
  expect.analyze_error([[
    local A = @record{x: integer}
    local B = @record{a: A}
    function B:f() local i: *A = self.a end
  ]], "no viable type conversion")
  expect.analyze_error([[
    local R = @record{x: integer}
    local p: pointer(R)
    local r: record{x: R}
    p = (@pointer(R))(r.x)
  ]], 'no viable type conversion')
  expect.analyze_error([[
    local R = @record{x: integer}
    local p: pointer(R)
    p = R{}
  ]], 'no viable type conversion')
  expect.analyze_error([[
    local R = @record{x: integer}
    local p: pointer(R)
    local function f(): R return R{} end
    p = f()
  ]], 'no viable type conversion')
end)

it("automatic dereferencing", function()
  expect.analyze_ast([[
    local R = @record{x: integer}
    local pr: pointer(R)
    local function fr(x: R) end
    fr(pr)

    local A = @[4]integer
    local pa: pointer(A)
    local function fa(x: A) end
    fa(pa)
  ]])
  expect.analyze_error([[
    local R = @record{x: integer}
    local p: pointer(R)
    local a: R = p
  ]], 'no viable type conversion')
  expect.analyze_error([[
    local A = @[4]integer
    local p: pointer(A)
    local a: A = p
  ]], 'no viable type conversion')
  expect.analyze_error([[
    local R = @record{x: integer}
    local p: pointer(R)
    local a: R = (@R)(p)
  ]], 'no viable type conversion')
  expect.analyze_error([[
    local p: pointer(integer)
    local a: integer = p
  ]], 'no viable type conversion')
  expect.analyze_error([[
    local p: pointer(integer)
    local a: number = 1
    p = a
  ]], 'no viable type conversion')
  expect.analyze_error([[
    local p: pointer
    local a: number = 1
    p = a
  ]], 'no viable type conversion')
end)

it("closures", function()
  expect.analyze_ast([[
    local function f(n: integer)
      local g = function(x: integer): integer return x + n end
      return g(1)
    end
  ]])
  expect.analyze_ast([[
    local function f(n: integer)
      local function g(x: integer): integer return x + n end
      return g(1)
    end
  ]])
  expect.analyze_ast([[
    local function f(n: integer)
      local function g(x: integer): integer <byref> n = n + x return n end
      local h = function(x: integer): integer <byref> n = n + x return n end
      return g(1) + h(1)
    end
  ]])
  expect.analyze_ast([[ -- the capture waits for the type of x to resolve
    local function f(): integer
      local x
      local function g(): integer return x end
      x = 1
      return g()
    end
  ]])
  expect.analyze_ast([[ -- byref without captures is a plain function
    local function f(n: integer)
      local function g(x: integer): integer <byref> return x end
      return g(n)
    end
  ]])
  expect.analyze_ast([[ -- non capturing nested functions remain static and can recurse
    local function f(n: integer)
      local function fact(x: integer): integer
        if x <= 1 then return 1 end
        return x * fact(x - 1)
      end
      return fact(n)
    end
  ]])
  expect.analyze_error([[
    local function f(n: integer)
      local function g(x: integer): integer
        if x <= 0 then return n end
        return g(x - 1)
      end
      return g(1)
    end
  ]], "nested function 'g' captures upvalues and cannot reference itself")
  expect.analyze_error([[
    local function f(n: integer)
      local function g(x: auto) return x + n end
      return g(1)
    end
  ]], "closures cannot be polymorphic")
  expect.analyze_error([[
    local function f(n: integer)
      local g = function(x: auto) return x + n end
      return g(1)
    end
  ]], "closures cannot be polymorphic")
  expect.analyze_error([[
    local function f(n: integer)
      local g = function(x: integer): auto return x + n end
      return g(1)
    end
  ]], "closures cannot have 'auto' returns")
  expect.analyze_error([[
    local function f(n: integer)
      local R = @record{}
      function R.g(x: integer): integer return x + n end
      return R.g(1)
    end
  ]], "attempt to access upvalue 'n'")
  expect.analyze_error([[
    local x = 1
    local function f(): integer <byref> return x end
  ]], "annotation 'byref' is only valid on functions nested inside another function")
  expect.analyze_error([[
    local f = function() <byref> end
  ]], "annotation 'byref' is only valid on functions nested inside another function")
  expect.analyze_ast([[ -- block locals at the top scope are on the stack, byref may share them
    do
      local x = 1
      local function g() <byref> x = x + 1 end
      local h = function() <byref> x = x + 1 end
      g() h()
    end
  ]])
  expect.analyze_error([[
    local function f(n: integer)
      local g = function(x: integer): integer <byref, byref> return x + n end
      return g(1)
    end
  ]], "annotation 'byref' is undefined for functions")
  expect.analyze_ast([[ -- a local named like the function shadows it, this is not a self reference
    local function f(n: integer): integer
      local function g(x: integer): integer local g = 10 return x + n + g end
      return g(1)
    end
  ]])
  expect.analyze_ast([[ -- a parameter named like the function shadows it too
    local function f(n: integer): integer
      local function g(g: integer): integer return g + n end
      return g(1)
    end
  ]])
  expect.analyze_error([[ -- a local declared after the use does not shadow it
    local function f(n: integer): integer
      local function g(x: integer): integer
        if x > 0 then return g(x - 1) + n end
        local g = 10
        return g
      end
      return g(1)
    end
  ]], "nested function 'g' captures upvalues and cannot reference itself")
  expect.analyze_error([[ -- a by value capture of a const stays const
    local function f(): integer
      local x <const> = 1
      local function g(): integer x = 2 return x end
      return g()
    end
  ]], "cannot assign a constant variable")
  expect.analyze_error([[ -- a byref capture of a const local stays const
    local function f(): integer
      local x <const> = 1
      local function g() <byref> x = 2 end
      g()
      return x
    end
  ]], "cannot assign a constant variable")
  expect.analyze_error([[ -- a byref capture of a const parameter stays const
    local function f(n: integer <const>): integer
      local function g() <byref> n = 2 end
      g()
      return n
    end
  ]], "cannot assign a constant variable")
  expect.analyze_error([[ -- a pointer taken through a byref const capture is a const pointer
    local function f(n: integer <const>): integer
      local function g() <byref> local p = &n $p = 2 end
      g()
      return n
    end
  ]], "cannot assign a constant variable")
  expect.analyze_ast([[ -- const captures can be read
    local function f(n: integer <const>): integer
      local x <const> = 1
      local function g(): integer return x + n end
      local function h(): integer <byref> return x + n end
      return g() + h()
    end
  ]])
end)

it("variant types", function()
  expect.analyze_error("local v: integer|string", "variant types require the 'variant' module")
  expect.analyze_error("local v: variant(integer, string)", "variant types require the 'variant' module")
  expect.analyze_ast([[
    require 'variant'
    local V = @variant(integer, string)
    local W = @integer|string
    ## static_assert(V.value == W.value)
    ## static_assert(V.value.is_variant and #V.value.subtypes == 2)
    local v: V = 1
    local w: integer|string|boolean = 'a'
  ]])
  expect.analyze_error([[
    require 'variant'
    local v: integer|string = 1.5
  ]], "no viable conversion from 'float64' to 'variant(int64, string)'")
  expect.analyze_error([[
    require 'variant'
    local v: integer|string = 1
    v:get(@boolean)
  ]], "type 'boolean' is not a member of 'variant(int64, string)'")
  expect.analyze_error([[
    require 'variant'
    local v: integer|integer
  ]], "variant has duplicated type 'int64'")
  expect.analyze_ast([[
    require 'variant'
    local V = @variant(integer, string)
    ## static_assert(#V.value.types == 2 and V.value.types[1] == primtypes.integer)
    ## static_assert(V.value.types[2] == primtypes.string)
    local a: V = 1
    local b: V = 's'
    local eq: boolean = a == b
    local ne: boolean = a ~= 2
    local se: boolean = 's' == b
  ]])
  expect.analyze_error([[
    require 'variant'
    local a: integer|string = 1
    local b: integer|boolean = 1
    local eq = a == b
  ]], "no viable conversion from 'variant(int64, boolean)' to 'variant(int64, string)'")
  -- a boolean member only takes booleans, although anything converts to a boolean
  expect.analyze_error([[
    require 'variant'
    local v: integer|boolean = 1
    local x = v == 'x'
  ]], "no viable conversion from 'string' to 'variant(int64, boolean)'")
  expect.analyze_error([[
    require 'variant'
    local v: integer|boolean = 'x'
  ]], "no viable conversion from 'string' to 'variant(int64, boolean)'")
  expect.analyze_error([[
    require 'variant'
    local v: integer|boolean = true
    local x = 3.5 == v
  ]], "no viable conversion from 'float64' to 'variant(int64, boolean)'")
  expect.analyze_ast([[
    require 'variant'
    local v: integer|boolean = true
    local x: boolean = v == false
    local p: pointer|boolean = nilptr
  ]])
  -- tostring needs every member to be convertible to a string
  expect.analyze_error([[
    require 'variant'
    local R = @record{x: integer}
    local v: variant(R, integer) = 1
    local s = tostring(v)
  ]], "tostring: cannot convert type 'R' to a string")
  -- __eq is instantiated on use, so a member without == support is fine until compared
  expect.analyze_ast([[
    require 'variant'
    local v: variant(function(), integer) = 1
    ## static_assert(v.type.metafields.__eq.type.is_polyfunction)
  ]])
end)

it("record equality with field metamethods", function()
  -- comparing records resolves the `__eq` instance of field types for the C generator
  expect.analyze_ast([[
    local P = @record{x: number}
    function P.__eq(a: P, b: P): boolean return a.x == b.x end
    local R = @record{p: P}
    local S = @record{ps: [2]P, r: R}
    ## static_assert(not P.value.eqsym)
    local a: S, b: S
    local x = a == b
    ## static_assert(P.value.eqsym == P.value.metafields.__eq)
    ## static_assert(not R.value.eqsym and not S.value.eqsym)
  ]])
  -- an `__eq` that cannot compare two values of its type is left alone
  expect.analyze_ast([[
    local Odd = @record{x: integer}
    function Odd.__eq(a: Odd, b: integer): boolean return a.x == b end
    local W = @record{o: Odd}
    local a: W, b: W
    local x = a == b
    ## static_assert(not Odd.value.eqsym)
  ]])
  -- a polymorphic `__eq` gets an instance for the field type pair
  expect.analyze_ast([[
    local Int = @record{x: integer}
    function Int.__eq(a: auto, b: auto): boolean return a.x == b.x end
    local Z = @record{i: Int}
    local function f(a: Z, b: Z) return a == b end
    ## local IntT = Int.value
    ## after_analyze(function()
    ##   static_assert(IntT.eqsym and IntT.eqsym.type.is_function)
    ##   static_assert(#IntT.metafields.__eq.type.evals == 1)
    ## end)
  ]])
  -- an `__eq` taking its arguments by pointer (automatic reference) is used
  expect.analyze_ast([[
    local P = @record{x: integer}
    function P.__eq(a: *P, b: *P): boolean return a.x == b.x end
    local R = @record{p: P}
    local a: R, b: R
    local x = a == b
    ## static_assert(P.value.eqsym == P.value.metafields.__eq)
  ]])
  -- comparing pointers to records compares the pointers, no field `__eq` is instantiated
  expect.analyze_ast([[
    local P = @record{x: integer}
    function P.__eq(a: auto, b: auto): boolean
      ## static_error('poly __eq instantiated')
      return false
    end
    local R = @record{p: P}
    local r1: R, r2: R
    local pa: *R, pb: *R = &r1, &r2
    local x = pa == pb
    local y = pa ~= pb
    ## static_assert(not P.value.eqsym)
  ]])
  -- string fields compare by content through a builtin, not through `string.__eq`
  expect.analyze_ast([[
    require 'string'
    local R = @record{s: string}
    local a: R, b: R
    local x = a == b
    ## static_assert(not primtypes.string.eqsym)
  ]])
end)

it("const pointers", function()
  expect.analyze_ast([[
    local a: integer = 1
    local p: *const integer = &a
    local q: *integer = &a
    p = q
    local v: integer = $p
    local r: *const void = p
    local s: *const void = q
    local t: *integer = (@*integer)(p)
    local u: pointer = (@pointer)(p)
    local cs: *const cchar = 'hi'
    local R = @record{x: integer}
    local rec: R = {x=1}
    local pr: *const R = &rec
    local x: integer = pr.x
    local pa: *const [0]integer = &(@[4]integer){1,2,3,4}
    local y: integer = pa[1]
    local function f(x: *const integer): integer return $x end
    f(&a)
    f(p)
    local function g(r: *const R): integer return r.x end
    g(rec)
    g(pr)
    ## static_assert(types.PointerType(primtypes.integer, true).is_constpointer)
    ## static_assert(not types.PointerType(primtypes.integer).is_constpointer)
    ## static_assert(types.PointerType(primtypes.integer, true) ~= types.PointerType(primtypes.integer))
  ]])
  expect.analyze_error([[local a: integer = 1; local p: *const integer = &a; $p = 2]],
    "cannot assign a constant variable")
  expect.analyze_error([[local a: integer = 1; local p: *const integer = &a; local q: *integer = p]],
    "cannot convert const pointer type 'pointer(const int64)' to non-const pointer type 'pointer(int64)'")
  expect.analyze_error([[local a: integer = 1; local p: *const integer = &a; local q: pointer = p]],
    "cannot convert const pointer")
  expect.analyze_error([[local a: integer = 1; local p: *const integer = &a; local q: *integer = &$p]],
    "cannot convert const pointer")
  expect.analyze_error([[local R = @record{x: integer}; local r: R; local p: *const R = &r; p.x = 1]],
    "cannot assign a constant variable")
  expect.analyze_error([[local R = @record{x: integer}; local r: R; local p: *const R = &r; local q: *integer = &p.x]],
    "cannot convert const pointer")
  expect.analyze_error([[
    local R = @record{x: integer}
    function R:set() self.x = 1 end
    local r: R; local p: *const R = &r; p:set()
  ]], "cannot convert const pointer")
  expect.analyze_error([[
    local R = @record{x: integer}
    function R:set() self.x = 1 end
    local r: R; local p: *const R = &r; ($p):set()
  ]], "cannot automatic reference read-only value")
  expect.analyze_error([[local a: [4]integer; local p: *const [4]integer = &a; p[1] = 2]],
    "cannot assign a constant variable")
  expect.analyze_error([[local a: integer = 1; local p: *const integer = &a; local function f(x: *integer) end; f(p)]],
    "cannot convert const pointer")
  expect.analyze_error([[local a: integer = 1; local p: *const integer = &a; local function f(x: pointer) end; f(p)]],
    "cannot convert const pointer")
end)

it("pointers to complex types", function()
  expect.analyze_ast([=[local p: pointer(record{x:isize}); p.x = 0]=])
  expect.analyze_ast([=[local p: pointer(array(isize, 10)); p[0] = 0]=])
  expect.analyze_error([=[local p: pointer(record{x:isize}); p.y = 0]=], "cannot index field")
  expect.analyze_error([=[local p: pointer(array(isize, 10)); p[-1] = 0]=], "cannot index negative value")
end)

it("type construction", function()
  expect.analyze_ast("local a = (@integer)()")
  expect.analyze_ast("local a = (@integer)(0)")
  expect.analyze_ast("local a = (@boolean)(false)")
  expect.analyze_ast("local a = (@string)('')")
  expect.analyze_ast("local a = (@any)(nil)")
  expect.analyze_error("local a = (@integer)(1,2)", "expected at most 1 argument")
  expect.analyze_error("local a = (@integer)(false)", "no viable type conversion")
  expect.analyze_error("local a = (@integer)(nil)", "no viable type conversion")
end)

it("type casting", function()
  expect.analyze_error([[
    local R = @record{}
    local a = 'b'
    local b = (@R)(a)
  ]], "no viable type conversion")
end)

it("annotations", function()
  expect.analyze_ast("local r: record{x: integer} <aligned(8)>")
  expect.analyze_ast("local Record <aligned(8)> = @record{x: integer}")
  expect.analyze_ast("local Record: type <aligned(8)> = @record{x: integer}")
  expect.analyze_error(
    "local function f() <cimport,nodecl> return 0 end",
    "body of a function declaration must be empty")
  expect.analyze_error("local a <cimport>", "must have an explicit type")
  expect.analyze_error("local a: integer <cimport,nodecl> = 2", "cannot assign imported variables")
  expect.analyze_error([[
    local function main1() <entrypoint> end
    local function main2() <entrypoint> end
  ]], "cannot have more than one function entrypoint")
  expect.analyze_error([[local function f(...: varargs) <codename'f'> end]], "polymorphic functions")
  expect.analyze_error([[local function f(...: varargs) <entrypoint> end]],  "polymorphic functions")
  expect.analyze_error("local a <nodecl(1)>", "takes no arguments")
  expect.analyze_error("local a <entrypoint>", "is undefined for variables")
  expect.analyze_error("local a <codename(1)>", "arguments are invalid")
  expect.analyze_error(
    "local function f(): cint <cimport,nodecl> end local b: boolean = f()",
    "expression will always be true")
  expect.analyze_error("local a: string <atomic>", "cannot be atomic")
end)

it("cimport", function()
  expect.analyze_ast([[
    local FILE <cimport, nodecl, cinclude'<stdio.h>', forwarddecl> = @record{}
    local a: *FILE
    local FILE <cimport, nodecl, cinclude'<stdio.h>', forwarddecl> = @record{}
    local b: *FILE
    b = a
  ]])
end)

it("close", function()
  expect.analyze_ast([[
    local R = @record{x: integer}
    function R:__close() end
    local r: R <close>
    local r2: R <close> = R{}
    local pr: *R <close>
    local t: R
    local pr2: *R <close> = &t

    global G = @record{}
    global G.r: R <close>
  ]])
  expect.analyze_error([[
    local R = @record{x: integer}
    function R:__close() end
    local r: R <close>
    r = R{}
  ]], "cannot assign")
  expect.analyze_error([[
    local R = @record{x: integer}
    function R:__close() end
    local pr: *R <close>
    pr = nilptr
  ]], "cannot assign")
  expect.analyze_error([[
    local R = @record{x: integer}
    function R:__close() end
    local r: *R <close>
    r = nilptr
  ]], "cannot assign")
  expect.analyze_error("local function f(a: integer <close>) end", "only allowed in variable declarations")
  expect.analyze_error("local a <close> = 1", "cannot close")
  expect.analyze_error("local r: record{x: integer} <close>", "cannot close")
end)

-- four lines, so the body of each test below starts at line 5
local owned_prelude = "local Buf <owned> = @record{data: pointer, size: usize}\n"..
  "function Buf:__close() end\n"..
  "local function consume(b: Buf) end\n"..
  "local function inspect(b: *Buf) end\n"

it("owned annotation", function()
  expect.analyze_ast(owned_prelude..[[
    local a: Buf
    local b = move(a)
    a = Buf{}
    local c: Buf = move(b)
    local Pair = @record{x: Buf, y: integer} -- owned through its field
    local p: Pair
    local q = move(p)
    local arr: [2]Buf -- owned array
    local arr2 = move(arr)
    local Plain = @record{x: integer}
    local u: Plain
    local v = u -- not owned, copies freely
    ## assert(Buf.value.is_owned and Pair.value.is_owned and not Plain.value.is_owned)
    ## assert(arr.type.is_owned)
  ]])
  expect.analyze_error([[
    local Buf <owned> = @record{x: integer}
  ]], "type 'Buf' is annotated with <owned> but has no '__close' metamethod")
  expect.analyze_error([[
    local E <owned> = @enum{A=0}
  ]], "annotation 'owned' is only valid for record types")
  expect.analyze_error("local x: integer <owned>", "annotation 'owned' is undefined for variables")
  expect.analyze_error("local function f() <owned> end", "annotation 'owned' is undefined for functions")
end)

it("owned copies need move", function()
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    local b = a
  ]], "in variable 'b' declaration: 'a' has owned type 'Buf', write `move(a)` to transfer ownership or take a pointer with `&a`")
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    local b: Buf
    b = a
  ]], "in variable assignment: 'a' has owned type 'Buf', write `move(a)`")
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    consume(a)
  ]], "in call of function 'consume' at argument 1: 'a' has owned type 'Buf', write `move(a)`")
  expect.analyze_error(owned_prelude..[[
    function Buf.byvalue(self: Buf) end
    local a: Buf
    a:byvalue()
  ]], "in method call 'Buf.byvalue' at argument 'self': 'a' has owned type 'Buf'")
  expect.analyze_error(owned_prelude..[[
    local P = @record{b: Buf}
    local a: Buf
    local p: P = {b = a}
  ]], "in record literal field 'b': 'a' has owned type 'Buf', write `move(a)`")
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    local arr: [1]Buf = {a}
  ]], "in array literal at index 1: 'a' has owned type 'Buf', write `move(a)`")
  expect.analyze_error(owned_prelude..[[
    local P = @record{b: Buf}
    local function f(p: *P): Buf
      return p.b
    end
  ]], "return at index 1: 'p.b' has owned type 'Buf' and is not a local of this block, write `move(p.b)`")
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    local function f(): Buf
      return a
    end
  ]], "return at index 1: 'a' has owned type 'Buf' and is not a local of this block, write `move(a)`")
  expect.analyze_error(owned_prelude..[[
    local function f(): Buf
      local a: Buf <close>
      return a
    end
  ]], "return at index 1: cannot return 'a' of owned type 'Buf', it is a <close> variable")
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    local b = (do in a end)
  ]], "in `in` expression: 'a' has owned type 'Buf' and is not a local of this block, write `move(a)`")
  expect.analyze_error(owned_prelude..[[
    local p: *Buf
    local b = $p
  ]], "in variable 'b' declaration: '$p' has owned type 'Buf', write `move($p)`")
  expect.analyze_error(owned_prelude..[[
    local P = @record{b: Buf}
    local p: P
    local q = p
  ]], "'p' has owned type 'P', write `move(p)`")
  expect.analyze_error(owned_prelude..[[
    local arr: [2]Buf
    local arr2 = arr
  ]], "'arr' has owned type 'array(Buf, 2)', write `move(arr)`")
  -- accepted forms
  expect.analyze_ast(owned_prelude..[[
    local a: Buf
    local b = move(a)
    a = Buf{}
    consume(move(a))
    inspect(&b)
    local function make(): Buf
      local r: Buf
      return r -- returning a local is a move
    end
    local function pass(x: Buf): Buf
      return x -- arguments are locals
    end
    local P = @record{b: Buf}
    local p: P = {b = move(b)}
    local function take(p: *P): Buf
      return move(p.b)
    end
    local c = make()
    local d: Buf = pass(move(c))
    local arr: [1]Buf = {move(d)}
    local arr2 = move(arr)
    local e = (do local t: Buf in t end)
    local f = (do in move(e) end)
    local ptr: *Buf = &f
    local g = move($ptr)
    local h = move(arr2[0])
    local i = move((h))
    print(i) -- builtins never take ownership
    local function returns_two(): (Buf, integer)
      local r: Buf
      return r, 1
    end
    local j, k = returns_two()
    local l, m = move(j), k
  ]])
end)

it("owned moved state", function()
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    local b = move(a)
    print(a.size)
  ]], "variable 'a' of owned type 'Buf' was moved on line 6, assign it again before using it")
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    local b = move(a)
    local c = move(a)
  ]], "variable 'a' of owned type 'Buf' was moved on line 6")
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    consume(move(a))
    a.size = 1
  ]], "variable 'a' of owned type 'Buf' was moved on line 6")
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    consume(move(a))
    inspect(&a)
  ]], "variable 'a' of owned type 'Buf' was moved on line 6")
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    consume(move(a))
    a:__close()
  ]], "variable 'a' of owned type 'Buf' was moved on line 6")
  -- branches
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    local x = false
    if x then
      consume(move(a))
    end
    print(a.size)
  ]], "variable 'a' of owned type 'Buf' may have been moved on line 8 (the move is inside a branch, loop or switch case)")
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    local x = false
    if x then
      consume(move(a))
    else
      consume(move(a))
    end
    print(a.size)
  ]], "variable 'a' of owned type 'Buf' was moved on line 8")
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    local x = false
    if x then
      consume(move(a))
    elseif a.size > 0 then -- evaluated only when the first branch was not taken
      consume(move(a))
    end
    print(a.size)
  ]], "variable 'a' of owned type 'Buf' may have been moved on line 8")
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    local x = false
    if x then
      consume(move(a))
    else
      a = Buf{}
    end
    print(a.size)
  ]], "variable 'a' of owned type 'Buf' may have been moved on line 8")
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    local n = 0
    switch n do
    case 1 then
      consume(move(a))
    end
    print(a.size)
  ]], "variable 'a' of owned type 'Buf' may have been moved on line 9")
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    local n = 0
    switch n do
    case 1 then
      consume(move(a))
      fallthrough
    case 2 then
      print(a.size)
    end
  ]], "variable 'a' of owned type 'Buf' may have been moved on line 9")
  -- loops
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    local x = false
    while x do
      consume(move(a))
      break
    end
    print(a.size)
  ]], "variable 'a' of owned type 'Buf' may have been moved on line 8")
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    local x = false
    while x do
      consume(move(a))
    end
  ]], "variable 'a' of owned type 'Buf' was moved on line 8 in a previous iteration of the loop")
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    for i=1,2 do
      consume(move(a))
    end
  ]], "variable 'a' of owned type 'Buf' was moved on line 7 in a previous iteration of the loop")
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    local x = false
    while x do
      if x then
        consume(move(a))
        continue
      end
      a = Buf{}
    end
  ]], "variable 'a' of owned type 'Buf' may have been moved on line 9 in a previous iteration of the loop")
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    repeat
      consume(move(a))
    until true
    print(a.size)
  ]], "variable 'a' of owned type 'Buf' was moved on line 7")
  -- `<close>` variables
  expect.analyze_error(owned_prelude..[[
    local a: Buf <close>
    local b = move(a)
  ]], "in call of builtin 'move': cannot move 'a' of owned type 'Buf', it is a <close> variable")
  -- `move` operands
  expect.analyze_error(owned_prelude..[[
    local b = move(Buf{})
  ]], "in call of builtin 'move': expected a variable, field, index or dereference of an owned type, but got an rvalue of type 'Buf'")
  expect.analyze_error(owned_prelude..[[
    local i = 1
    local j = move(i)
  ]], "in call of builtin 'move': 'i' has type 'int64', which is not owned")
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    move(a)
  ]], "in call of builtin 'move': the moved value of 'a' is unused")
  expect.analyze_error(owned_prelude..[[
    local a: Buf
    local b = move(a, a)
  ]], "in call of builtin 'move': expected 1 argument but got 2")
  -- accepted forms
  expect.analyze_ast(owned_prelude..[[
    local a: Buf
    local b = move(a)
    a = Buf{} -- live again
    print(a.size)
    local x = false
    if x then
      consume(move(a))
      a = Buf{}
    end
    print(a.size)
    local function f(a: Buf): integer
      if a.size == 0 then
        consume(move(a))
        return 0 -- the move does not leak past the early return
      end
      return a.size
    end
    while x do
      if x then
        consume(move(a))
        break -- nor past the break
      end
      print(a.size)
    end
    while x do
      a = Buf{}
      consume(move(a)) -- assigned before every read of the iteration
    end
    a = Buf{}
    for i=1,2 do
      if x then
        a = Buf{}
        consume(move(a))
        continue
      end
      a = Buf{}
    end
    a = Buf{}
    local P = @record{b: Buf}
    local p: P
    local c = move(p.b)
    local d = move(p.b) -- fields are not tracked, only variables
    local pa = &a
    consume(move(a))
    print(pa.size) -- pointers are not tracked
    switch 1 do
    case 1 then
      a = Buf{}
    else
      a = Buf{}
    end
    print(a.size)
    local arr: [2]Buf
    local arr2 = move(arr)
    arr = {}
    print(#arr)
  ]])
end)

it("builtins", function()
  expect.ast_type_equals("local a = #@integer", "local a: isize = #@integer")
  expect.ast_type_equals("local a = likely(true)", "local a: boolean = likely(true)")
  expect.ast_type_equals("local a = unlikely(true)", "local a: boolean = unlikely(true)")
  expect.analyze_ast("error 'an error'")
  expect.analyze_ast("warn 'an warn'")
  expect.analyze_error("assert(true,'asd', 2)", 'expected at most')
  expect.analyze_error("print:find()", "cannot call method")
  expect.analyze_error("print():find()", 'cannot call type')
end)

it("require builtin", function()
  expect.analyze_ast("require 'examples.helloworld'")
  expect.analyze_ast("local a <comptime> = 'examples.helloworld'; require(a)")
  expect.analyze_ast("require 'examples.helloworld'")
  expect.analyze_error("require 'somelualib'", 'not found')
  expect.analyze_error("local a = 'dynamiclib'; require(a)", 'runtime require unsupported')
  expect.analyze_error([[local function f() require 'string' end]], 'must always be required from the top scope')
end)

it("strict mode", function()
  expect.analyze_ast([[
    local a = 1
    local function f() return 3 end
    global b = 2
    global function g() return 4 end
    assert(a == 1 and b == 2 and f() == 3 and g() == 4)
  ]])
  expect.analyze_error("function f() return 0 end", "undeclared symbol")
  expect.analyze_error("a = 1", "undeclared symbol")
end)
it("concepts", function()
  expect.analyze_ast([[
    local an_integral = #[concept(function(x)
      return x.type.is_integral
    end)]#
    ## static_assert(an_integral.value:is_convertible_from_type(primtypes.integer))
    local an_integer_array = #[concept(function(x)
      return x.type:is_array_of(primtypes.integer)
    end)]#
    ## static_assert(an_integral.value ~= an_integer_array.value)
    local function f(x: an_integral) return x end
    local function g(x: an_integer_array) return #x end
    f(1_uinteger)
    f(2_uinteger)
    f(3)
    f(4)
    g((@[2]integer){1,2})
    g((@[3]integer){1,2,3})
  ]])
  expect.analyze_error([[
    local an_integral = #[concept(function(x)
      return x.type.is_integral
    end)]#
    local function f(x: an_integral) return x end
    f(true)
  ]], "could not match concept")
  expect.analyze_error([[
    local an_integral = #[concept(function(x)
      return x.type.is_integral
    end)]#
    local function f(): an_integral end
  ]], "cannot be of compile-time type")
  expect.analyze_error([[
    local my_concept = #[concept(function(x)
      return primtypes.integer
    end)]#
    local function f(x: my_concept) return x end
    f(true)
  ]], "no viable type conversion")
  expect.analyze_error([[
    local an_integral = #[concept(function(x)
      return primtypes.type
    end)]#
    local function f(x: an_integral) return x end
    f(true)
  ]], "invalid return for concept")
  expect.analyze_error([[
    local an_integral = #[concept(function(x)
      return 1
    end)]#
    local function f(x: an_integral) return x end
    f(true)
  ]], "invalid return for concept")
  expect.analyze_error([[
    local R = 1
    local an_integral = #[concept(function(x)
      return R
    end)]#
    local function f(x: an_integral) return x end
    f(true)
  ]], "invalid return for concept")
end)

it("overload and facultative concepts", function()
  expect.analyze_ast([[
    local function h(x: facultative(integer)) end
    local function g(x: overload(integer,niltype)) end

    local R = @record{x: integer}
    local function f(a: R, x: facultative(integer)) end
    f(R{1})
  ]])
  expect.analyze_ast([[
    local R = @record{a: integer, b: number}

    local function hello(r: facultative(R))
      ## if r.type.is_niltype then
        return false
      ## else
        return true
      ## end
    end

    assert(hello() == false)
    assert(hello({10, 20}) == true)
  ]])
  expect.analyze_ast([[
    local io = @record{x: integer}
    local function f(x: overload(io)): integer return x.x end
    f(io{})
  ]])
  expect.analyze_error([[
    local function f(x: overload(integer, string)) return x end
    f(true)
  ]], "cannot match overload concept")
  expect.analyze_error([[
    local function f(x: overload(integer, 1)) return x end
    f(true)
  ]], "in overload concept definition")
  expect.analyze_error([[
    local function f(x: overload(integer)) return x end
    f(true)
  ]], "cannot match overload concept")
end)

it("decltype concept", function()
  expect.ast_type_equals([[
    local x: auto = 1
    local y: decltype(x) = x
  ]], [[
    local x: integer = 1
    local y: integer = x
  ]])
  expect.ast_type_equals([[
    local x: auto = nil
    local y: decltype(x) = x
  ]], [[
    local x: niltype = nil
    local y: niltype = x
  ]])
  expect.ast_type_equals([[
    local Boolean: decltype(boolean) = @boolean
  ]], [[
    local Boolean: type = @boolean
  ]])
  expect.ast_type_equals([[
    local Boolean: decltype(boolean) = @boolean
  ]], [[
    local Boolean: type = @boolean
  ]])
  expect.analyze_ast([[
    local x: integer = 1
    ## assert(types.decltype(scope.node[1][2][1]) == primtypes.integer)
  ]])
  expect.ast_type_equals([[
    local x: integer
    x = 0
    local y: decltype((x + 1.0))
  ]], [[
    local x: integer
    x = 0
    local y: number
  ]])
  expect.analyze_error([[
    local x = 1
    local y: decltype(x) = x
  ]], "type is not resolved yet")
  expect.analyze_error([[
    local x = 1
    local y: decltype(1) = x
  ]], "invalid argument of lua type")
end)

it("generics", function()
  expect.analyze_ast([[
    local myarray = #[generic(function(T, N, B) return types.ArrayType(T, N) end)]#
    local M: integer <comptime> = 4
    local x = @myarray(integer, (M), true)
  ]])
  expect.analyze_ast([[
    local int = @integer
    local proxy = #[generic(function(T) return int end)]#
    local x = @proxy(integer)
  ]])
  expect.analyze_ast([[
    local gen = #[generic(function(S) return primtypes.string end)]#
    local x = @gen('asd')
  ]])
  expect.analyze_error([[
    local myarray = #[generic(function(T, N, B) return types.ArrayType(T, N) end)]#
    local function f(a: myarray) end
  ]], 'variable declaration cannot be of the type')
  expect.analyze_error([[
    local proxy = #[generic(function(T) static_error('my fail') end)]#
    local x = @proxy(integer)
  ]], 'my fail')
  expect.analyze_error([[
    local proxy = 1
    local x = @proxy(integer)
  ]], 'is not a type')
  expect.analyze_error([[
    local x = @integer(integer)
  ]], "cannot generalize")
  expect.analyze_error([[
    local myarray = #[generic(function() end)]#
    local i = 1
    local x = @integer(i)
  ]], "cannot generalize")
  expect.analyze_error([[
    local myarray = #[generic(function() end)]#
    local x = myarray(integer)
  ]], "cannot do type cast on generics")
  expect.analyze_error([[
    local myarray = #[generic(function() end)]#
    local x = @myarray(integer)
  ]], "expected a type or symbol in generic return")
  expect.analyze_error([[
    local X = 1
    local myarray = #[generic(function() return X end)]#
    local x = @myarray(integer)
  ]], "expected a symbol holding a type in generic return")
  expect.analyze_error([[
    local myarray = #[generic(function() end)]#
    local X
    local x = @myarray(X)
  ]], "type is not resolved yet")
  expect.analyze_error([[
    local x = @invalidgeneric(integer)
  ]], "undeclared symbol")
  expect.analyze_error([[
    global Foo: type = #[generalize(function() end)()]#
  ]], "expected a type or symbol in generic return")
  expect.analyze_error([[
    global Foo: type = #[generalize(function() error 'generic fail' end)()]#
  ]], "generic fail")
end)

it("custom braces initialization", function()
  expect.analyze_ast([==[
    local vector = @record{data: [4]integer}
    local an_arrayT: type = #[concept(function(x)
      return x.type:is_array_of(primtypes.integer)
    end, function(node)
      return node.tag == 'InitList' and types.ArrayType(primtypes.integer, #node)
    end)]#
    function vector.__convert(data: an_arrayT): vector
      local v: vector
      v.data = data
      return v
    end
    local v: vector = {1,2,3,4}
    assert(v.data[0] == 1 and v.data[1] == 2 and v.data[2] == 3 and v.data[3] == 4)
  ]==])
  expect.analyze_error([==[
    local vector = @record{data: [4]integer}
    local an_arrayT: type = #[concept(function(x)
      return x.type:is_array_of(primtypes.integer)
    end)]#
    function vector.__convert(data: an_arrayT): vector
      local v: vector
      v.data = data
      return v
    end
    local v: vector = {1,2,3,4}
    assert(v.data[0] == 1 and v.data[1] == 2 and v.data[2] == 3 and v.data[3] == 4)
  ]==], "no viable type conversion from")
end)

it("do expressions", function()
  expect.analyze_ast("local a = (do in 1 end)")
  expect.analyze_error("local a = (do end)", "a `in` statement is missing")
  expect.analyze_error("in 1", "no do expression block found")
end)

it("forward type declaration", function()
  expect.analyze_ast("local R <forwarddecl> = @record{}; R = @record{}; local S = @record{r: R}")
  expect.analyze_ast("local U <forwarddecl> = @union{}; U = @union{i: integer, n: number}; local S = @record{u: U}")
  expect.analyze_ast("local R <forwarddecl> = @record{}; local f: function(x: R)")
  expect.analyze_error("local R <forwarddecl> = @record{}; local S = @record{r: R}",
    "cannot be of forward declared type")
  expect.analyze_error("local R <forwarddecl> = @record{}; local r: R",
    "cannot be of forward declared type")
  expect.analyze_error("local R <forwarddecl> = @record{}; local A = @[4]R",
    "cannot be of forward declared type")
  expect.analyze_error("local R <forwarddecl> = @record{}; local function f(x: R) end",
    "cannot be of forward declared type")
  expect.analyze_error("local R <forwarddecl> = @record{}; local function f(): R end",
    "cannot be of forward declared type")
  expect.analyze_error("local U <forwarddecl> = @union{}; local V = @union{u: U}",
    "cannot be of forward declared type")
  expect.analyze_error("global R: type <forwarddecl> = @record{x: integer}",
    "defining fields in types marked with forward declaration is not allowed")
end)

it("cincomplete declaration", function()
  expect.analyze_ast("local R <cincomplete> = @record{x: integer};")
end)

it("forward function declaration", function()
  expect.analyze_ast("local function f() <forwarddecl> end; function f() end")
  expect.analyze_ast("local function f(x: byte): void <forwarddecl> end; function f(x: byte): void end")
  expect.analyze_error(
    "local function f(x: auto): auto <forwarddecl> end function f() end",
    "polymorphic functions cannot be forward declared")
  expect.analyze_error(
    "local function f(x: byte): void <forwarddecl> print(1) end",
    "body of a function declaration must be empty")
end)

it("using annotation", function()
  expect.analyze_ast([[
    local MyEnum <using> = @enum{
      MYENUM_NONE = 0,
      MYENUM_ONE = 1,
    }
    local a: MyEnum = MYENUM_ONE
  ]])
  expect.analyze_ast([[
    local MyEnum <using> = @enum{MyEnumA = 0}
    local function f(x: auto) print(MyEnumA, x) end
    f(1)
  ]])
  expect.analyze_error([[
    local MyEnum <using> = @record{}
  ]], "annotation 'using' can only")
end)

it("union type", function()
  expect.analyze_ast([[local Union = @union{integer,number}; local a: Union]])
  expect.analyze_ast([[local u: union {b: boolean, i: integer}; u.b = true]])
  expect.analyze_ast([[local u: union{b: boolean, i: integer} = {}]])
  expect.analyze_ast([[local u: union{b: boolean, i: integer} = {b=true}]])
  expect.analyze_ast([[local u: union{b: boolean, i: integer} = {i=1}]])
  expect.analyze_error([[
    local u: union{b: boolean, i: integer}
    local v: union{b: boolean, n: number}
    u = v
  ]], "no viable type conversion")
  expect.analyze_error([[
    local U = @union{t: type, i: integer}
  ]], "cannot be of compile-time type")
  expect.analyze_error([[
    local u: union{b: boolean, i: integer} = {b = true, i = 1}
  ]], "unions can only be initialized with at most 1 field")
  expect.analyze_error([[
    local u: union{b: boolean, i: integer} = {i = true}
  ]], "no viable type conversion from")
  expect.analyze_error([[
    local u: union{b: boolean, i: integer} = {true}
  ]], "union field is missing a name")
  expect.analyze_error([[
    local u: union{b: boolean, i: integer} = {[1] = true}
  ]], "only string literals are allowed")
  expect.analyze_error([[
    local u: union{b: boolean, i: integer} = {c = true}
  ]], "is not present in union")
  expect.analyze_ast([[
    -- the union size is padded to its alignment, as in C
    local U = @union{a: int64, b: [10]int8}
    ## static_assert(U.value.size == 16 and U.value.align == 8)
    local W = @union{a: int32, b: [5]int8}
    ## static_assert(W.value.size == 8 and W.value.align == 4)
    local X = @union{a: int8, b: [3]int8}
    ## static_assert(X.value.size == 3 and X.value.align == 1)
  ]])
end)

it("optional types", function()
  expect.analyze_error("local x: integer?", "optional types require the 'optional' module")
  expect.analyze_ast([[
    require 'optional'
    local x: integer? = 3
    local y: integer? = nil
    local z: integer?
    local p: *integer? = nilptr
    local O = @optional(integer)
    ## static_assert(O.value == x.type and O.value == y.type)
    ## static_assert(O.value.is_optional and not O.value.is_niche)
    ## static_assert(O.value.subtype == primtypes.integer)
    ## static_assert(p.type.is_optional and p.type.is_niche)
    ## static_assert(tostring(O.value) == 'optional(int64)')
    local n: integer = 1
    local q: *integer? = &n
    local r: *integer? = (@*integer)(nilptr) -- a null pointer converts to empty
    local w: integer = x:get()
    local b: boolean = x:has()
  ]])
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 3
    local v: integer = x
  ]], "no viable type conversion")
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 3
    local v = (@integer)(x)
  ]], "no viable type conversion")
  expect.analyze_error([[
    require 'optional'
    local n: niltype?
  ]], "optional cannot hold values of type 'niltype'")
  expect.analyze_error([[
    require 'optional'
    local o: optional(integer?)
  ]], "optional of optional type 'optional(int64)' is not allowed")
  expect.analyze_error([[
    require 'optional'
    local q: integer? = nilptr
  ]], "no viable conversion from 'nilptr' to 'optional(int64)'")
  expect.analyze_error([[
    require 'optional'
    local q: integer? = 1.5
  ]], "no viable conversion from 'float64' to 'optional(int64)'")
  expect.analyze_error([[
    require 'optional'
    local a: integer? = 1
    local b: string? = 'a'
    local c = a == b
  ]], "cannot compare 'optional(int64)' with 'optional(string)'")
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 3
    local y = x?
  ]], "`?` requires the enclosing function to declare its return types")
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 3
    local function f()
      local y = x?
      return y
    end
  ]], "`?` requires the enclosing function to declare its return types")
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 3
    local function f(): auto
      local y = x?
      return y
    end
  ]], "`?` requires the enclosing function to declare its return types")
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 3
    local function f(): integer
      local y = x?
      return y
    end
  ]], "`?` can only propagate inside a function returning an optional, a pointer, `(value, errmsg)` or `(ok, ...)`, but it returns 'int64'")
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 3
    local function f(): (integer, integer?)
      local y = x?
      return y, y
    end
  ]], "`?` can only propagate inside a function returning an optional, a pointer, `(value, errmsg)` or `(ok, ...)`, but it returns 'int64'")
  expect.analyze_error([[
    require 'optional'
    local n = 1
    local function f(): integer?
      local y = n?
      return y
    end
  ]], "`?` expects an optional, a pointer or a `(value, errmsg)` call, but got 'int64'")
  expect.analyze_error([[
    require 'optional'
    local function two(): (integer, integer) return 1, 2 end
    local function f(): integer?
      local y = two()?
      return y
    end
  ]], "`?` expects an optional, a pointer or a `(value, errmsg)` call, but got 'int64'")
  expect.analyze_error([[
    require 'optional'
    local function f(): integer?
      local y = (@integer)?
      return y
    end
  ]], "`?` expects an optional, a pointer or a `(value, errmsg)` call, but got 'type'")
  expect.analyze_ast([[
    require 'optional'
    local function find(k: integer): integer?
      if k == 1 then return 10 end
      return nil
    end
    local function next(p: *integer): *integer?
      return p
    end
    local function f(k: integer): integer?
      local v = find(k)?
      return v + 1
    end
    local function g(p: *integer): *integer
      local q = next(p)?
      local r = p?
      return q
    end
    local function h(k: integer): (integer?, integer, *integer)
      local v = find(k)?
      return v, 1, nilptr
    end
    ## static_assert(f.type.rettypes[1].is_optional)
  ]])
  expect.analyze_ast([[
    require 'optional'
    local x: integer? = 3
    local p: *integer? = nilptr
    if x then end
    if p then end
    while x do break end
    repeat until p
    local b: boolean = x == nil
    local c: boolean = p == nilptr
    local d: boolean = nil == x
    local e: boolean = x ~= nil
    local f: boolean = x == 3
    local g: boolean = 3 == x
    local h: boolean = x == x
    local i: boolean = not x
    local k: boolean = x and true
  ]])
  expect.analyze_error([[
    require 'optional'
    local b: boolean? = false
    if b then end
  ]], "test a boolean optional")
  expect.analyze_error([[
    require 'optional'
    local b: boolean? = false
    local c = not b
  ]], "test a boolean optional")
  expect.analyze_error([[
    require 'optional'
    local b: boolean? = false
    local c = b and true
  ]], "test a boolean optional")
  expect.analyze_error([[
    require 'optional'
    local b: boolean? = false
    local c: boolean = b
  ]], "test a boolean optional")
  expect.analyze_ast([[
    require 'optional'
    local b: boolean? = false
    local c = b == nil
    local d = b == false
    local e = b:get_or(true)
  ]])
  expect.analyze_error([[
    require 'optional'
    local function f(p: *integer?): void <cimport,nodecl> end
  ]], "optional types cannot be used in a <cimport> function")
  expect.analyze_error([[
    require 'optional'
    local function f(): *integer? <cimport,nodecl> end
  ]], "optional types cannot be used in a <cimport> function")
  expect.analyze_error([[
    require 'optional'
    local R <cimport,nodecl> = @record{p: *integer?}
  ]], "optional types cannot be used in a <cimport> record field")
  expect.analyze_error([[
    require 'optional'
    local R <cimport,nodecl> = @record{a: [2]integer?}
  ]], "optional types cannot be used in a <cimport> record field")
  expect.analyze_error([[
    require 'optional'
    local x: integer? <cimport,nodecl>
  ]], "optional types cannot be used in a <cimport> variable")
  expect.analyze_error([[
    require 'optional'
    local p: *integer? <cimport,nodecl>
  ]], "optional types cannot be used in a <cimport> variable")
  expect.analyze_ast([[
    require 'optional'
    local R <cimport,nodecl> = @record{p: *integer}
    local x: integer <cimport,nodecl>
    local r: R? = R{p=&x}
  ]])
  expect.analyze_error([[
    require 'optional'
    local function find(k: integer): integer? return nil end
    local function f(k: integer): integer?
      local a, b = find(k)?
      return a
    end
  ]], "`?` yields a single value, but 2 values are expected")
  expect.analyze_error([[
    require 'optional'
    local function find(k: integer): integer? return nil end
    local function f(k: integer): integer?
      local a, b: integer
      a, b = find(k)?
      return a
    end
  ]], "`?` yields a single value, but 2 values are expected")
  expect.analyze_ast([[
    require 'optional'
    local function find(k: integer): integer? return nil end
    local function wrap(v: integer): integer? return v end
    local Node = @record{n: integer, next: *Node}
    local function f(k: integer): integer?
      local a, b = find(k)?, 2 -- `?` is one value among others
      return wrap(find(a)?)? + b -- nested `?`
    end
    local function second(n: *Node): *Node?
      return n?.next? -- chained `?`
    end
    local function g(k: integer): integer?
      local v = (function(j: integer): integer? return find(j) end)(k)? -- `?` on a closure call
      return (do in find(v)? end) -- `?` as the sole `in` expression
    end
  ]])
end)

it("optional types embedded in cimport records", function()
  expect.analyze_error([[
    require 'optional'
    local Inner = @record{o: integer?}
    local Outer <cimport,nodecl> = @record{inner: Inner}
  ]], "optional types cannot be used in a <cimport> record field")
  expect.analyze_error([[
    require 'optional'
    local Inner = @record{o: integer?}
    local Outer <cimport,nodecl> = @record{a: [2]Inner}
  ]], "optional types cannot be used in a <cimport> record field")
  expect.analyze_error([[
    require 'optional'
    local Inner = @record{o: integer?}
    local U = @union{i: Inner, n: integer}
    local Outer <cimport,nodecl> = @record{u: U}
  ]], "optional types cannot be used in a <cimport> record field")
  expect.analyze_error([[
    require 'optional'
    local Outer <cimport,nodecl,forwarddecl> = @record{}
    Outer = @record{o: integer?}
  ]], "optional types cannot be used in a <cimport> record field")
  expect.analyze_error([[
    require 'optional'
    local Inner = @record{o: integer?}
    local Outer <cimport,nodecl,forwarddecl> = @record{}
    Outer = @record{p: *Outer, i: Inner}
  ]], "optional types cannot be used in a <cimport> record field")
  expect.analyze_ast([[
    require 'optional'
    local Inner = @record{o: integer?}
    local Outer <cimport,nodecl> = @record{p: *Inner, a: [2]*Inner}
    local x: Outer
    local o: *Inner = x.p
  ]])
  expect.analyze_ast([[
    require 'optional'
    local Inner = @record{o: integer?}
    local Outer <cimport,nodecl,forwarddecl> = @record{}
    Outer = @record{p: *Inner, q: *Outer, n: integer}
    local x: Outer
    local o: *Inner = x.p
    local n: integer = x.n
  ]])
  expect.analyze_ast([[
    local Inner <forwarddecl> = @record{}
    local Outer <cimport,nodecl> = @record{p: *Inner}
    Inner = @record{n: integer}
    local x: Outer
    local n: integer = x.p.n
  ]])
  expect.analyze_ast([[
    require 'optional'
    local Inner <forwarddecl> = @record{}
    local Outer <cimport,nodecl,forwarddecl> = @record{}
    Outer = @record{p: *Inner, n: clong}
    Inner = @record{o: integer?, k: integer}
    local x: Outer
    local k: integer = x.p.k
    local o: integer? = x.p.o
  ]])
  expect.analyze_error([[
    require 'optional'
    local Inner = @record{o: integer?}
    local x: Inner <cimport,nodecl>
  ]], "optional types cannot be used in a <cimport> variable")
  expect.analyze_error([[
    require 'optional'
    local Inner = @record{o: integer?}
    local x: [2]Inner <cimport,nodecl>
  ]], "optional types cannot be used in a <cimport> variable")
  expect.analyze_error([[
    require 'optional'
    local Inner = @record{o: integer?}
    local function f(a: Inner) <cimport,nodecl> end
  ]], "optional types cannot be used in a <cimport> function")
  expect.analyze_error([[
    require 'optional'
    local Inner = @record{o: integer?}
    local function f(): Inner <cimport,nodecl> end
  ]], "optional types cannot be used in a <cimport> function")
  expect.analyze_ast([[
    require 'optional'
    local Inner = @record{o: integer?}
    local function f(a: *Inner): *Inner <cimport,nodecl> end
    local x: *Inner <cimport,nodecl>
  ]])
  expect.analyze_error([[
    require 'optional'
    local U <cimport,nodecl> = @union{o: integer?, n: integer}
  ]], "optional types cannot be used in a <cimport> union field")
  expect.analyze_error([[
    require 'optional'
    local U <cimport,nodecl,forwarddecl> = @union{}
    U = @union{o: integer?, n: integer}
  ]], "optional types cannot be used in a <cimport> union field")
  expect.analyze_error([[
    require 'optional'
    local Inner = @record{o: integer?}
    local U <cimport,nodecl> = @union{i: Inner, n: integer}
  ]], "optional types cannot be used in a <cimport> union field")
  expect.analyze_ast([[
    require 'optional'
    local Inner = @record{o: integer?}
    local U <cimport,nodecl,forwarddecl> = @union{}
    U = @union{p: *Inner, n: integer}
    local x: U
    local o: *Inner = x.p
  ]])
end)

it("optional orelse", function()
  expect.analyze_ast([[
    require 'optional'
    local function find(k: integer): integer?
      if k == 1 then return 10 end
      return nil
    end
    local function dflt(): integer return 7 end
    local a: integer = find(1) orelse 3 -- comptime default
    local b: integer = find(2) orelse dflt() -- lazy default
    local c: integer? = find(2) orelse find(1) -- chaining keeps the optional
    local d: integer = find(2) orelse find(1) orelse 5 -- nested chain
    local e: integer = (find(1) orelse 2) + 1
    local f: boolean = find(1) orelse 2 == 10 -- `a orelse b == c` is `(a orelse b) == c`
    local u: uint8? = nil
    local v: uint8 = u orelse 2
    local n = 1
    local p: *integer? = nilptr
    local q: *integer = p orelse &n -- niche optional yields the pointer
    local s: string? = nil
    local t: string = s orelse 'none'
    local R = @record{x: integer}
    local r: R? = nil
    local rr: R = r orelse {x = 1}
    local bo: boolean? = false
    local bb: boolean = bo orelse true
    local function g(k: integer): integer
      local x = find(k) orelse (do in 1 end)
      return x
    end
  ]])
  expect.analyze_error([[
    require 'optional'
    local n = 1
    local y = n orelse 2
  ]], "`orelse` expects an optional on the left, got 'int64'")
  expect.analyze_error([[
    require 'optional'
    local p: *integer = nilptr
    local y = p orelse nilptr
  ]], "`orelse` expects an optional on the left, got 'pointer(int64)'")
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 1
    local y = x orelse 'a'
  ]], "in `orelse` default: no viable type conversion from 'string' to 'int64'")
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 1
    local y = x orelse nil
  ]], "in `orelse` default: no viable type conversion from 'niltype' to 'int64'")
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 1
    local y: string? = nil
    local z = x orelse y
  ]], "`orelse` default of type 'optional(string)' does not match the optional 'optional(int64)'")
  expect.analyze_error([[
    require 'optional'
    local function f(): integer?
      local x: integer? = 1
      return x? orelse 3 -- `x?` already unwraps
    end
  ]], "`orelse` expects an optional on the left, got 'int64'")
  -- `or` and `and` never promote an optional to `any`
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 1
    local y = x or 3
  ]], "in binary operation `or`: use `orelse` to provide a default for an optional")
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 1
    local y = x and 3
  ]], "in binary operation `and`: use `orelse` to provide a default for an optional")
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 1
    local y = 3 or x
  ]], "in binary operation `or`: use `orelse` to provide a default for an optional")
  expect.analyze_error([[
    require 'optional'
    local x: integer?
    local p: *integer?
    local j = x and p -- two different optionals
  ]], "in binary operation `and`: use `orelse` to provide a default for an optional")
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 1
    local y = x or nil
  ]], "in binary operation `or`: use `orelse` to provide a default for an optional")
  expect.analyze_ast([[
    require 'optional'
    local x: integer? = 1
    local y: integer? = 2
    local z: integer? = x or y -- same optional type stays allowed
    local w: integer? = x and y
    local b: boolean = x and true
    local c: boolean = x or false
    local n: integer = x and 1 or 2 -- ternary idiom tests the optional
    if x and y then end
    if x or 3 == 3 then end
  ]])
end)

it("optional and/or with a boolean", function()
  expect.analyze_ast([[
    require 'optional'
    local x: integer? = 1
    local p: *integer? = nilptr
    local function t(): boolean return true end
    local a = x and true
    local b = x or true
    local c = x or false
    local d = true and x
    local e = false or x
    local f = x and t()
    local g = p or t()
    local h = x and true or false
    local y: integer? = 2
    local z = x or y
    local w = x and y
    ## after_inference(function()
    ##   for _,s in ipairs{a, b, c, d, e, f, g, h} do assert(s.type.is_boolean, s.name) end
    ##   assert(z.type == x.type and w.type == x.type)
    ## end)
  ]])
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 1
    local a = x and 1
  ]], "in binary operation `and`: use `orelse` to provide a default for an optional")
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 1
    local a = x or 'd'
  ]], "in binary operation `or`: use `orelse` to provide a default for an optional")
  expect.analyze_error([[
    require 'optional'
    local b: boolean? = false
    local c = b or true
  ]], "test a boolean optional")
  expect.analyze_error([[
    require 'optional'
    local b: boolean? = false
    local c = true and b
  ]], "test a boolean optional")
end)

it("optional if local", function()
  expect.analyze_ast([[
    require 'optional'
    local function find(k: integer): integer?
      if k == 1 then return 10 end
      return nil
    end
    if local x = find(1) then
      local y: integer = x -- `x` is the held value
    end
    if local x: float64 = find(1) then -- annotation converts from the held type
      local y: float64 = x
    elseif local z = find(2) then
      local w: integer = z
    elseif find(3) then
    else
    end
    local function wrap(k: integer): integer?
      if k < 3 then return k end
      return nil
    end
    local function f(k: integer): integer?
      if local v = find(wrap(k)?) then return v + 1 end -- `?` inside the operand
      return nil
    end
    local n = 1
    local p: *integer? = &n
    if local q = p then local r: *integer = q end
    local s: string? = nil
    if local t = s then local u: string = t end
    local function g(): integer
      if local x = find(1) then return x end
      return 0
    end
    local function h(k: integer): integer
      local r = 0
      while true do
        if local x = find(k) then r = x break else k = 1 continue end
      end
      return r
    end
  ]])
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 1
    if local s = x then else local t = s end
  ]], "undeclared symbol 's'")
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 1
    if local s = x then end
    local t = s
  ]], "undeclared symbol 's'")
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 1
    if x then elseif local s = x then else local t = s end
  ]], "undeclared symbol 's'")
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 1
    if local s: string = x then end
  ]], "in variable 's' declaration: no viable type conversion from 'int64' to 'string'")
  expect.analyze_error([[
    require 'optional'
    local p: *integer = nilptr
    if local x = p then end
  ]], "`if local` expects an optional, got 'pointer(int64)', test a pointer with `if p then`")
  expect.analyze_error([[
    require 'optional'
    local n = 1
    if local x = n then end
  ]], "`if local` expects an optional, got 'int64'")
  expect.analyze_error([[
    require 'optional'
    local b: integer? = 1
    if b then elseif local x = 1 then end
  ]], "`if local` expects an optional, got 'int64'")
  expect.analyze_error([[
    require 'optional'
    local function find(k: integer): integer? return nil end
    local function f(k: integer): integer?
      if local v = find(k)? then return v end -- `?` already unwraps
      return nil
    end
  ]], "`if local` expects an optional, got 'int64'")
end)

it("match statement", function()
  expect.analyze_ast([[
    require 'variant'
    require 'optional'
    local v: integer|string|boolean = 3
    match v do
    case local n: integer then local m: integer = n
    case local s: string then local t: string = s
    case boolean then
    case nil then
    end
    match v do
    case integer, string then
    else
    end
    match v case local b: boolean then else end
    local function get(): integer|string return 1 end
    match get() do
    case local n: integer then
    case local s: string then
    case nil then
    end
    local o: integer? = 5
    match o do
    case local x: integer then local y: integer = x
    case nil then
    end
    match o do
    case integer, nil then
    end
    match o case nil then else end
    local p: *integer? = nilptr
    match p do
    case local q: *integer then local r: *integer = q
    case nil then
    end
    -- reference bindings and pointer subjects
    match v do
    case local n: *integer then local m: *integer = n
    case local s: *const string then local t: *const string = s
    case boolean, nil then
    end
    local vp = &v
    match vp do
    case local n: *integer then
    case string, boolean, nil then
    end
    match o do
    case local x: *integer then local y: *integer = x
    case nil then
    end
    local function f(k: integer): integer
      match o do
      case local x: integer then return x
      case nil then return 0
      end
      return -1
    end
    -- `match` is a contextual word, names and methods keep using it
    local match = 1
    local R = @record{}
    function R.match(x: integer) end
    R.match(match)
  ]])
  expect.analyze_error([[
    require 'variant'
    local v: integer|string = 1
    match v do
    case float64 then
    case nil then
    end
  ]], "`match` case type 'float64' is not a member of 'variant(int64, string)' (members: int64, string)")
  expect.analyze_error([[
    require 'variant'
    local v: integer|string = 1
    match v do
    case local n: *float64 then
    case nil then
    end
  ]], "is not a member of 'variant(int64, string)' or a pointer to one (members: int64, string)")
  expect.analyze_error([[
    require 'variant'
    local v: integer|string = 1
    match v do
    case local n: integer then
    case integer then
    case string, nil then
    end
  ]], "`match` case 'int64' appears more than once")
  expect.analyze_error([[
    require 'variant'
    local v: integer|string = 1
    match v do
    case nil then
    case integer, string, nil then
    end
  ]], "`match` case `nil` appears more than once")
  expect.analyze_error([[
    require 'variant'
    local v: integer|string = 1
    match v do
    case integer then
    end
  ]], "`match` statement is not exhaustive, missing cases: string, nil (add them or an `else` block)")
  expect.analyze_error([[
    require 'optional'
    local o: integer? = 1
    match o do
    case local x: integer then
    end
  ]], "`match` statement is not exhaustive, missing cases: nil (add them or an `else` block)")
  expect.analyze_error([[
    local n = 1
    match n do
    case nil then
    end
  ]], "`match` expects a variant or an optional, got 'int64'")
  expect.analyze_error([[
    require 'optional'
    local o: integer? = 1
    match o do
    case string then
    case nil then
    end
  ]], "`match` case type 'string' is not the held type 'int64' of 'optional(int64)'")
  expect.analyze_error([[
    require 'variant'
    local v: integer|string = 1
    match v do
    case local n: integer, string then
    else
    end
  ]], "`case local` binds a single type, list types in a `case` without a binding")
  expect.analyze_error([[
    require 'variant'
    local v: integer|string = 1
    match v do
    case integer then fallthrough
    case string, nil then
    end
  ]], "`fallthrough` is not allowed in a `match` case")
  expect.analyze_error([[
    require 'variant'
    local v: integer|string = 1
    match v do
    case local n: integer then
    case string, nil then local m = n
    end
  ]], "undeclared symbol 'n'")
  expect.analyze_error([[
    require 'optional'
    local o: integer? = 1
    match o do
    case local x: integer then
    case nil then
    end
    local y = x
  ]], "undeclared symbol 'x'")
  expect.analyze_error([[
    require 'optional'
    local o: integer? = 1
    match o do
    case local x: string then
    case nil then
    end
  ]], "`match` case type 'string' is not the held type 'int64' of 'optional(int64)'")
end)

it("optional try kinds", function()
  -- errmsg kind: the value is the first return, the message is tested with `.size`
  expect.analyze_ast([[
    require 'optional'
    local function open(k: integer): (integer, string, integer)
      if k == 1 then return 10, (@string){}, 0 end
      return 0, 'fail', 1
    end
    local function okmsg(k: integer): (boolean, string, integer)
      if k == 1 then return true, (@string){}, 0 end
      return false, 'fail', 1
    end
    local function only(k: integer): boolean
      return k == 1
    end
    local function a(k: integer): integer?
      local v = open(k)? -- errmsg -> empty
      return v
    end
    local function b(k: integer): (integer, string, integer)
      local v = open(k)? -- errmsg -> errmsg
      okmsg(k)? -- statement form
      return v, (@string){}, 0
    end
    local function c(k: integer): (boolean, string)
      local v: boolean = okmsg(k)?
      return v, (@string){}
    end
    local function d(k: integer): boolean
      okmsg(k)? -- errmsg -> ok, the message is dropped
      only(k)? -- ok -> ok
      open(k)? -- errmsg -> ok
      return true
    end
    local function e(k: integer): (boolean, integer)
      only(k)?
      return true, 1
    end
    local function f(k: integer): integer?
      only(k)? -- ok -> empty
      open(k)? -- errmsg kind, statement form, value dropped
      a(k)? -- optional kind, statement form
      return 1
    end
    local function g(k: integer): *integer
      okmsg(k)?
      return nilptr
    end
    ## static_assert(b.type.rettypes[2].is_string)
  ]])
  expect.analyze_error([[ -- the value of an errmsg call is its first return
    require 'optional'
    local function open(k: integer): (integer, string, integer) return k, (@string){}, 0 end
    local function f(k: integer): integer?
      local v = open(k)?
      local s: string = v
      return v
    end
  ]], "no viable type conversion from 'int64' to 'string'")
  expect.analyze_error([[
    require 'optional'
    local function only(k: integer): boolean return k == 1 end
    local function f(k: integer): boolean
      local v = only(k)?
      return v
    end
  ]], "`?` on a call returning only a boolean yields no value, use the statement form `f()?`")
  expect.analyze_error([[
    require 'optional'
    local function only(k: integer): boolean return k == 1 end
    local function f(k: integer): boolean
      return only(k)?
    end
  ]], "`?` on a call returning only a boolean yields no value, use the statement form `f()?`")
  expect.analyze_error([[
    require 'optional'
    local function open(k: integer): (integer, string, integer) return k, (@string){}, 0 end
    local function f(k: integer): integer
      local v = open(k)?
      return v
    end
  ]], "`?` can only propagate inside a function returning an optional, a pointer, `(value, errmsg)` or `(ok, ...)`, but it returns 'int64'")
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 3
    local function f(): integer
      local y = x?
      return y
    end
  ]], "`?` can only propagate inside a function returning an optional, a pointer, `(value, errmsg)` or `(ok, ...)`, but it returns 'int64'")
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 3
    local function f(): (integer, integer)
      local y = x?
      return y, 1
    end
  ]], "`?` can only propagate inside a function returning an optional, a pointer, `(value, errmsg)` or `(ok, ...)`, but it returns 'int64'")
  expect.analyze_error([[
    require 'optional'
    local function open(k: integer): (integer, string, integer) return k, (@string){}, 0 end
    local function f(k: integer): (integer, integer)
      open(k)?
      return k, 1
    end
  ]], "`?` can only propagate inside a function returning an optional, a pointer, `(value, errmsg)` or `(ok, ...)`, but it returns 'int64'")
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 3
    local function f(): (integer, string)
      local y = x?
      return y, 'x'
    end
  ]], "`?` has no message to propagate into a `(value, errmsg)` function from an optional, a pointer or a boolean call, write the `if` by hand")
  expect.analyze_error([[
    require 'optional'
    local function f(p: *integer): (integer, string)
      local y = p?
      return $y, 'x'
    end
  ]], "`?` has no message to propagate")
  expect.analyze_error([[
    require 'optional'
    local function only(k: integer): boolean return k == 1 end
    local function f(k: integer): (boolean, string)
      only(k)?
      return true, 'x'
    end
  ]], "`?` has no message to propagate")
  expect.analyze_error([[
    require 'optional'
    local function two(): (integer, integer) return 1, 2 end
    local function f(): integer?
      local y = two()?
      return y
    end
  ]], "`?` expects an optional, a pointer or a `(value, errmsg)` call, but got 'int64'")
  expect.analyze_error([[
    require 'optional'
    local function two(): (integer, integer) return 1, 2 end
    local function f(): integer?
      two()?
      return 1
    end
  ]], "`?` expects an optional, a pointer or a `(value, errmsg)` call, but got 'int64'")
  expect.analyze_error([[
    require 'optional'
    local function b(): (boolean, boolean) return true, true end
    local function f(): boolean
      b()?
      return true
    end
  ]], "`?` expects an optional, a pointer or a `(value, errmsg)` call, but got 'boolean'")
  expect.analyze_error([[
    require 'optional'
    local n = 1
    local function f(): integer?
      local y = n?
      return y
    end
  ]], "`?` expects an optional, a pointer or a `(value, errmsg)` call, but got 'int64'")
  expect.analyze_error([[
    require 'optional'
    local function f(): integer?
      local y = (@integer)?
      return y
    end
  ]], "`?` expects an optional, a pointer or a `(value, errmsg)` call, but got 'type'")
  -- the operand is checked before the enclosing function (design rules 2 then 3)
  expect.analyze_error([[
    require 'optional'
    local n = 1
    local function f(): integer
      local y = n?
      return y
    end
  ]], "`?` expects an optional, a pointer or a `(value, errmsg)` call, but got 'int64'")
  expect.analyze_error([[
    require 'optional'
    local function two(): (integer, integer) return 1, 2 end
    local function f(): (integer, integer)
      two()?
      return 1, 2
    end
  ]], "`?` expects an optional, a pointer or a `(value, errmsg)` call, but got 'int64'")
  expect.analyze_error([[
    require 'optional'
    local function only(k: integer): boolean return k == 1 end
    local function f(k: integer): integer
      local v = only(k)?
      return v
    end
  ]], "`?` on a call returning only a boolean yields no value, use the statement form `f()?`")
  -- the operand type wins over the call shape: `(T?, string)` and `(*T, string)` calls are
  -- the optional and pointer kinds, their message is never read
  expect.analyze_ast([[
    require 'optional'
    local function both(k: integer): (integer?, string)
      if k == 1 then return 1, (@string){} end
      return nil, 'both failed'
    end
    local function pboth(k: integer): (*integer, string)
      return nilptr, 'pboth failed'
    end
    local function f(k: integer): integer?
      local v = both(k)?
      local p = pboth(k)?
      return v + $p
    end
    local function g(k: integer): boolean
      both(k)?
      return true
    end
    ## static_assert(f.type.rettypes[1].is_optional)
  ]])
  expect.analyze_error([[
    require 'optional'
    local function both(k: integer): (integer?, string) return nil, 'x' end
    local function f(k: integer): (integer, string)
      local v = both(k)?
      return v, (@string){}
    end
  ]], "`?` has no message to propagate into a `(value, errmsg)` function from an optional, a pointer or a boolean call, write the `if` by hand")
  expect.analyze_error([[
    require 'optional'
    local function pboth(k: integer): (*integer, string) return nilptr, 'x' end
    local function f(k: integer): (integer, string)
      local p = pboth(k)?
      return $p, (@string){}
    end
  ]], "`?` has no message to propagate")
  -- the errmsg kind is decided by the shape alone, a `(string, string)` pair is one
  expect.analyze_ast([[
    require 'optional'
    local function two(): (string, string) return 'a', 'b' end
    local function f(): (string, string)
      local v = two()?
      return v, (@string){}
    end
    local function g(): string?
      return two()?
    end
  ]])
  expect.analyze_error([[
    require 'optional'
    local function open(k: integer): (integer, string, integer) return k, (@string){}, 0 end
    local function f(k: integer): integer?
      local a, b = open(k)?
      return a
    end
  ]], "`?` yields a single value, but 2 values are expected")
  expect.analyze_error([[
    require 'optional'
    local function okmsg(k: integer): (boolean, string, integer) return true, (@string){}, 0 end
    okmsg(1)?
  ]], "`?` requires the enclosing function to declare its return types")
  expect.analyze_error([[
    require 'optional'
    local function okmsg(k: integer): (boolean, string, integer) return true, (@string){}, 0 end
    local function f(k: integer)
      okmsg(k)?
    end
  ]], "`?` requires the enclosing function to declare its return types")
end)

it("optional static initializers", function()
  expect.analyze_ast([[
    require 'optional'
    local R = @record{x: integer}
    local g: R = {x = 1}
    local x: integer? = 3
    local y: integer? = nil
    local p: *R? = nilptr
    local q: *R? = &g
    local function f(): integer return 1 end
    local z: integer? = f()
    local c: cstring? = 'xyz'
    ## static_assert(x.type == y.type and z.type == x.type)
    ## static_assert(p.type == q.type)
    ## static_assert(c.type.is_niche and c.type.subtype.is_cstring)
    -- an init list into `T?` is typed against `T` and wrapped, unless it spells the optional's own fields
    local a: [2]integer? = {some = true, v = {1, 2}}
    local b: [2]integer? = (@[2]integer?){v = {3, 4}}
    ## static_assert(a.type.is_optional and a.type.subtype.is_array and b.type == a.type)
    local P = @record{x: integer}
    local pa: P? = {x = 1}
    local pb: [2]integer? = {1, 2}
    local pe: P? = {}
    local pr: P? = {x = f()}
    local n = 5
    local c <const> = 6
    local pn: P? = {x = n}
    local pc: P? = {x = c}
    local an: [2]integer? = {n, f()}
    local Q = @record{o: P?, a: [2]integer?}
    local q: Q = {o = {x = 5}, a = {5, 6}}
    local qn: Q = {o = {x = n}, a = {n, 2}}
    local function opt(o: P?): P? return {x = o:get().x} end
    opt({x = 9})
    opt({x = n})
    pa = {x = 3}
    pn = {x = n}
    ## static_assert(pa.type.is_optional and pa.type.subtype == P.value and pr.type == pa.type)
    ## static_assert(pb.type == a.type and pe.type == pa.type)
    ## static_assert(pn.type == pa.type and pc.type == pa.type and an.type == a.type)
  ]])
  expect.analyze_error([[
    require 'optional'
    local a: [2]integer? = {1, 2, 3}
  ]], "expected at most 2 values in array literal but got 3")
  expect.analyze_error([[
    require 'optional'
    local P = @record{x: integer}
    local p: P? = {y = 1}
  ]], "field 'y' is not present in record 'P'")
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 3.5
  ]], "no viable conversion from 'float64' to 'optional(int64)'")
  expect.analyze_error([[
    require 'optional'
    local x: integer? = 'a'
  ]], "no viable conversion from 'string' to 'optional(int64)'")
  expect.analyze_error([[
    require 'optional'
    local x: integer? = nilptr
  ]], "no viable conversion from 'nilptr'")
  expect.analyze_error([[
    require 'optional'
    local x: boolean? = nil
    if x then end
  ]], "test a boolean optional")
end)

it("side effects detection", function()
  expect.analyze_ast([[
    local X: integer

    local function f(x: integer): integer
      print(x)
      return x
    end
    ## assert(f.type.sideeffect == true)

    local function f(x: integer): integer
      return x
    end
    ## assert(f.type.sideeffect == false)

    local function f(x: integer): integer
      X = x
      return x
    end
    ## assert(f.type.sideeffect == true)

    local a: [4]integer = {f(1), f(2)}
    local u: union{x: integer, y:number} = {x=f(1)}

    local function f(x: integer) <nosideeffect>
      X = x
      return x
    end
    ## assert(f.type.sideeffect == false)
  ]])
end)

it("invalid type uses", function()
  expect.analyze_error([[local T: type]], "a type declaration must assign to a type")
  expect.analyze_error([[local T: type = nil]], "cannot assign a type to")
  expect.analyze_error([[local T: type = 1]], "cannot assign a type to")
  expect.analyze_error([[local V; local T: type = V]], "cannot assign a type to")
  expect.analyze_error([[local V; local T = @record{x: V}]], "invalid type")
  expect.analyze_error([[local V; local T = @union{x: V}]], "invalid type")
  expect.analyze_error([[local V; local T = @enum(V){A=0}]], "invalid type")
  expect.analyze_error([[local V; local T = @[4]V]], "invalid type")
  expect.analyze_error([[local V; local T = @*V]], "invalid type")
  expect.analyze_error([[local V; local T = @function(V): void]], "invalid type")
  expect.analyze_error([[local V; local T = @function(): V]], "invalid type")
  expect.analyze_error([[local V; local v = (@V)(1)]], "invalid type")
  expect.analyze_error([[local V; local V; local generic = #[generalize()]#; local v: generic(V)]],
    "type is not resolved yet")
end)

it("nocopy type annotation", function()
  expect.analyze_ast([[
    local R <nocopy> = @record{x: integer}
    local x: R
    local r: *R = &x
    local function f(x: R) end
    f(R{})

    local function g(): R
      local r: R
      return r
    end

    local function g(r: R): R
      return r
    end
  ]])
  expect.analyze_error([[
    local R <nocopy> = @record{x: integer}
    local x: R
    local r: R = x
  ]], "non copyable type")
  expect.analyze_error([[
    local R <nocopy> = @record{x: integer}
    local x: R
    local r: R
    r = x
  ]], "non copyable type")
  expect.analyze_error([[
    local R <nocopy> = @record{x: integer}
    local x: R
    local r = x]], "non copyable type")
  expect.analyze_error([[
    local R <nocopy> = @record{x: integer}
    local x: R
    local arr: [4]R = {x}
  ]], "non copyable type")
  expect.analyze_error([[
    local R <nocopy> = @record{x: integer}
    local x: R
    local r: record{x: R} = {x=x}
  ]], "non copyable type")
  expect.analyze_error([[
    local R <nocopy> = @record{x: integer}
    local x: R
    local u: union{x: R} = {x=x}
  ]], "non copyable type")
  expect.analyze_error([[
    local R <nocopy> = @record{x: integer}
    local x: R
    local function f(x: R) end
    f(x)
  ]], "non copyable type")
  expect.analyze_error([[
    local R <nocopy> = @record{x: integer}
    local x: R
    local function f(x: R) end
    f((@R)(x))
  ]], "non copyable type")
  expect.analyze_error([[
    local R <nocopy> = @record{x: integer}
    local x: R
    function R.f(x: R) end
    x:f()
  ]], "non copyable type")
  expect.analyze_error([[
    local R <nocopy> = @record{x: integer}
    local x: *R
    local r: R = $x
  ]], "non copyable type")
  expect.analyze_error([[
    local R <nocopy> = @record{x: integer}
    local r: R
    local function f(): R
      return r
    end
  ]], "non copyable type")
  expect.analyze_error([[
    local R <nocopy> = @record{x: integer}
    local r: R
    local r2: R = (do in r end)
  ]], "non copyable type")
  expect.analyze_error([[
    local R <nocopy> = @record{x: integer}
    local x: *R
    local function f(x: R) end
    f(x)
  ]], "no viable type conversion")
end)

it("polymorphic varargs", function()
  expect.analyze_ast([[
    local function g() return 1 end
    local function f(...: varargs) return g(...) end
    f()
  ]])
  expect.analyze_ast([[
  local function g(...: varargs)
    ## assert(select(1, ...).attr.value == primtypes.integer)
    return 1
  end
  local function f(...: varargs)
    ## assert(select(1, ...).attr.value == primtypes.integer)
    return g(...)
  end
  f(@integer)
  ]])
  expect.analyze_ast([[
    local function f(...: varargs)
      ## static_assert(select(1, ...).attr.value == primtypes.string)
    end

    local a : type = @string
    f(a)
  ]])
  expect.analyze_error([[
    local function f(...: varargs)
      local a = 1 + ...
    end
    f()
  ]], "invalid operation between types 'int64' and 'niltype'")
  expect.analyze_error([[
    local a = ...
  ]], "cannot unpack varargs in this context")
  expect.analyze_error([[
    local function f()
      return ...
    end
  ]], "cannot unpack varargs in this context")
  expect.analyze_error([[
    local function f(...: cvarargs)
      return ...
    end
    f()
  ]], "cannot unpack 'cvarargs'")
end)

it("missing symbols error suggestions", function()
  expect.analyze_error("tostring(0)", "maybe you forgot to require module 'string'?")
  expect.analyze_error("io.write('')", "maybe you forgot to require module 'io'?")
  expect.analyze_error("('a'):upper()", "maybe you forgot to require module 'string'?")
  expect.analyze_error("string.format('%d', 1)", "maybe you forgot to require module 'string'?")
  expect.analyze_error("function f() end", "maybe you forgot to declare it as 'global' or 'local'?")
end)

it("comptime evaluation", function()
  -- results are injected as compile time values
  expect.analyze_ast([=[
    local function fib(n: integer): integer
      if n < 2 then return n end
      return fib(n - 1) + fib(n - 2)
    end
    local F <comptime> = comptime(fib(20))
    local function f(): (integer, string, boolean) return 1, 'a', true end
    local a <comptime>, b <comptime>, c <comptime> = comptime(f())
    local function g(x: auto): auto return x end
    local p <comptime> = comptime(g(2))
    local q <comptime> = comptime(g('s'))
    local function h(): float64 return 1.0 / 0.0 end
    local inf <comptime> = comptime(h())
    local function u(): uint64 return 0xFFFFFFFFFFFFFFFF end
    local um <comptime> = comptime(u())
    local function big(a: int32): int32 return a * 65536 end
    local w <comptime> = comptime(big(65536))
    comptime(f()) -- results of a statement are discarded
    ##[[ after_inference(function()
      assert(tostring(F.value) == '6765' and F.type == primtypes.integer, 'F')
      assert(tostring(a.value) == '1' and b.value == 'a' and c.value == true, 'abc')
      assert(tostring(p.value) == '2' and q.value == 's', 'pq')
      assert(tostring(inf.value) == 'inf', 'inf')
      assert(um.type == primtypes.uint64 and tostring(um.value) == '18446744073709551615', 'um')
      assert(w.type == primtypes.int32 and tostring(w.value) == '0', 'w')
    end) ]]
  ]=])
  -- `<comptime>` functions evaluate at every call site, also recursively
  expect.analyze_ast([=[
    local function fib(n: integer): integer <comptime>
      if n < 2 then return n end
      return fib(n - 1) + fib(n - 2)
    end
    local x <comptime> = fib(15)
    local y <comptime> = comptime(fib(10))
    ##[[ after_inference(function() assert(tostring(x.value) == '610' and tostring(y.value) == '55') end) ]]
  ]=])
  -- aggregates are values, records can be referenced through `self`
  expect.analyze_ast([=[
    local function f(): integer
      local t: [2]integer = {1, 2}
      local u = t
      u[0] = 9
      local p = &t
      p[1] = 7
      return t[0] * 100 + u[0] * 10 + t[1]
    end
    local x <comptime> = comptime(f())
    local R = @record{v: [2]integer}
    function R:bump() self.v[0] = self.v[0] + 1 end
    local function g(): R
      local r: R
      r:bump() r:bump()
      return r
    end
    local r = comptime(g())
    ##[[ after_inference(function()
      assert(tostring(x.value) == '197')
      assert(r.type.is_record)
    end) ]]
  ]=])
  -- `print`, `assert`, strings and `math` run inside the compiler
  expect.analyze_ast([=[
    require 'string'
    require 'math'
    local function f(x: float32): string
      assert(x > 0, 'positive')
      local s: string = 'ab'
      return s:upper() .. string.rep('x', 2) .. s:sub(2, 2) .. tostring(#s) .. tostring(x) .. tostring(2.0) ..
        tostring(math.floor(2.5) + math.sqrt(16.0) + math.max(1, 2))
    end
    local s <comptime> = comptime(f(1.1))
    ##[[ after_inference(function() assert(s.value == 'ABxxb21.12.08.0', s.value) end) ]]
  ]=])
  -- forward declarations wait for their definition
  expect.analyze_ast([=[
    local function f(): integer <forwarddecl> end
    local x <comptime> = comptime(f())
    function f(): integer return 7 end
    ##[[ after_inference(function() assert(tostring(x.value) == '7') end) ]]
  ]=])
  -- `continue` inside `repeat` and non default `for` comparisons
  expect.analyze_ast([=[
    local function f(): integer
      local n = 0
      repeat
        local k = n
        n = n + 1
        if n < 3 then continue end
      until k >= 5
      for i=0,<5 do
        if i == 2 then continue end
        local k = i
        n = n + k
      end
      return n
    end
    local x <comptime> = comptime(f())
    ##[[ after_inference(function() assert(tostring(x.value) == '14') end) ]]
  ]=])
end)

it("comptime evaluation errors", function()
  expect.analyze_error([[
    local function f(a: integer): integer <comptime> return a end
    local x = 1
    local y = f(x)
  ]], "in call of compile-time function 'f': argument 1 is not a compile time value (it has type 'int64')")
  expect.analyze_error([[
    local function f(a: integer): integer return a end
    local function g(): integer return 1 end
    local x = comptime(f(g()))
  ]], "in call of compile-time function 'f': argument 1 is not a compile time value")
  expect.analyze_error([[
    local R = @record{x: integer}
    local function f(r: R): integer return r.x end
    local x = comptime(f(R{1}))
  ]], "argument 1 is not a compile time value (it has type 'R')")
  expect.analyze_error("local x = comptime(1)", "in call of builtin 'comptime': expected a function call but got 'Number'")
  expect.analyze_error("local x = comptime()", "in call of builtin 'comptime': expected 1 argument but got 0")
  expect.analyze_error("local x = comptime(print('a'))", "builtin 'print' cannot be evaluated at compile time")
  expect.analyze_error([[
    local function f(): integer <comptime> return 1 end
    local g = f
  ]], "compile-time function 'f' can only be called, it has no runtime value")
  expect.analyze_error("local f = function(): integer <comptime> return 1 end",
    "annotation 'comptime' is only valid for named functions")
  expect.analyze_error([[
    local function f(): integer <forwarddecl> end
    local x = comptime(f())
  ]], "the call could not be resolved at compile time (the function is not defined or has unresolved types)")
  -- rejected constructs are reported at their line
  expect.analyze_error([[
    local function f(): integer
      defer end
      return 1
    end
    local x = comptime(f())
  ]], "in compile-time evaluation of function 'f': `defer` cannot be used at compile time")
  expect.analyze_error([[
    local function f(): integer
      local a = 1
      local p = &a
      return $p
    end
    local x = comptime(f())
  ]], "pointer type 'pointer(int64)' cannot be used at compile time (only references to records and arrays are)")
  expect.analyze_error([[
    local function f(): integer
      local s: cstring = 'a'
      return 1
    end
    local x = comptime(f())
  ]], "pointer type 'cstring' cannot be used at compile time")
  expect.analyze_error([[
    local R = @record{p: *integer}
    local function f(): integer
      local r: R
      return 1
    end
    local x = comptime(f())
  ]], "record 'R' has the pointer field 'p', it cannot be used at compile time")
  expect.analyze_error([[
    local function g(): integer <cimport 'g'> end
    local function f(): integer
      return g()
    end
    local x = comptime(f())
  ]], "imported C function 'g' cannot be called at compile time")
  expect.analyze_error([[
    local v = 1
    local function f(): integer
      return v
    end
    local x = comptime(f())
  ]], "variable 'v' is declared outside the function and is not <comptime>, it cannot be read at compile time")
  expect.analyze_error([[
    local function f(): integer
      local g = function(): integer return 1 end
      return g()
    end
    local x = comptime(f())
  ]], "closures cannot be used at compile time")
  expect.analyze_error([[
    local function f(): integer return 1 end
    local function g(): integer local h = f return h() end
    local x = comptime(g())
  ]], "function values cannot be used at compile time, only calls")
  expect.analyze_error([[
    local function it(s: integer, c: integer): (boolean, integer) return false, 0 end
    local function f(): integer
      for i in it, 0, 0 do end
      return 1
    end
    local x = comptime(f())
  ]], "`for in` loops cannot be used at compile time (iterators are runtime functions)")
  expect.analyze_error([[
    local function f(): integer
      local x: integer <static> = 1
      return x
    end
    local x = comptime(f())
  ]], "annotation 'static' cannot be used at compile time")
  expect.analyze_error([[
    local C = @record{}
    function C:__close() end
    local function f(): integer
      local c: C <close>
      return 1
    end
    local x = comptime(f())
  ]], "annotation 'close' cannot be used at compile time")
  -- runtime failures become compile errors at the call
  expect.analyze_error([[
    local function f(): integer
      assert(false, 'boom')
      return 1
    end
    local x = comptime(f())
  ]], "in compile-time evaluation of function 'f': boom")
  expect.analyze_error([[
    local function f(): integer
      error('bad')
      return 1
    end
    local x = comptime(f())
  ]], "in compile-time evaluation of function 'f': bad")
  expect.analyze_error([[
    local function f(): integer
      panic('worse')
      return 1
    end
    local x = comptime(f())
  ]], "in compile-time evaluation of function 'f': worse")
  expect.analyze_error([[
    local function f(a: integer, b: integer): integer return a // b end
    local x = comptime(f(1, 0))
  ]], "in compile-time evaluation of function 'f': attempt to divide by zero")
  -- step and stack limits
  expect.analyze_error([[
    ## pragmas.comptime_steps = 100000
    local function f(): integer
      local i = 0
      while true do i = i + 1 end
      return i
    end
    local x = comptime(f())
  ]], "exceeded the limit of 100000 steps (raise it with `## pragmas.comptime_steps = N`)")
  expect.analyze_error([[
    ## pragmas.comptime_stack = 100
    local function f(n: integer): integer
      return f(n + 1) + 1
    end
    local x = comptime(f(0))
  ]], "exceeded the limit of 100 nested calls (raise it with `## pragmas.comptime_stack = N`)")
end)

end)
