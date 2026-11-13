local lester = require 'nelua.thirdparty.lester'
local describe, it = lester.describe, lester.it
local expect = require 'spec.tools.expect'
local aster = require 'nelua.aster'
local except = require 'nelua.utils.except'

local function parse_error(code, message, filename)
  local ok, err = except.try(function() aster.parse(code, filename or 'syntaxlib_spec.nelua') end)
  expect.falsy(ok)
  expect.contains(message, err.message or err:get_message())
  return err
end

describe('syntax library', function()

it('composes and deduplicates packs in each file', function()
  expect.run_c([=[
    #syntax 'syntax.pipe'
    #syntax 'syntax.all'
    #syntax 'syntax.all'
    #syntax [[ syntax.use('syntax.control') ]]
    require 'string'
    local twice = fn(x: integer) => x * 2
    local x = 1
    times 3 do x += 2 end
    print($"answer {x |> twice}, {choose x == 7 then b"10_1010" else 0 end}")
  ]=], 'answer 14, 42')
  -- A cached Lua module must be applied again to a different file's state.
  expect.run_c([=[ #syntax 'syntax.all'
    times 2 do print(choose true then 7 else 0 end) end
  ]=], '7\n7')
  parse_error('local x = choose true then 1 else 2 end', 'syntax error')
end)

it('loads relative helpers and reports dependency cycles', function()
  local ast = aster.parse("#syntax 'pack'\nlocal n = fixture_answer", 'spec/syntaxfixtures/main.nelua')
  expect.ast_equals(aster.parse('local n = 42'), ast)
  parse_error("#syntax 'cycle_a'", 'circular syntax module dependency', 'spec/syntaxfixtures/main.nelua')
  parse_error('#syntax [[ syntax.use(42) ]]', 'syntax.use expects a nonempty module name')
end)

it('lowers control flow and keeps repeat until working', function()
  expect.ast_type_equals([=[
    #syntax 'syntax.control'
    local x = 0
    unless x == 1 then x = 2 else x = 3 end
    until x >= 4 do x = x + 1 end
    guard x == 4 else return end
    loop do break end
    repeat x = x - 1 until x == 0
  ]=], [[
    local x = 0
    if not (x == 1) then x = 2 else x = 3 end
    while not (x >= 4) do x = x + 1 end
    if not (x == 4) then return end
    while true do break end
    repeat x = x - 1 until x == 0
  ]])
end)

it('counts once and preserves break continue and early returns', function()
  expect.run_c([=[
    #syntax 'syntax.control'
    local calls = 0
    local function count() calls = calls + 1 return 5 end
    local n = 0
    times count() as i: integer do
      if i == 2 then continue end
      if i == 5 then break end
      n = n + i
    end
    times 0 do n = 99 end
    times -2 do n = 99 end
    local function check(ok: boolean)
      guard ok else return -1 end
      return 42
    end
    print(n, calls, check(false), check(true))
  ]=], '8\t1\t-1\t42')
end)

it('keeps contextual words usable as ordinary names', function()
  expect.run_c([=[
    #syntax 'syntax.all'
    local unless, guard, times, loop, using, let, choose, collect = 1, 2, 3, 4, 5, 6, 7, 8
    local function fn(x: integer) return x + 1 end
    local n = 1
    print(unless + guard + times + loop + using + let + choose + collect, fn(n))
    do
      local function collect(x: integer) return x * 2 end
      local value = 21
      print(collect(value))
    end
  ]=], '36\t2\n42')
end)

it('chooses lazily and preserves false and null results', function()
  expect.run_c([=[
    #syntax 'syntax.choose'
    local calls = 0
    local function tick() calls = calls + 1 return 9 end
    local condition = true
    local a = choose condition then false else tick() == 0 end
    local b = choose not condition then tick() else 42 end
    local p: *integer = choose condition then nilptr else &calls end
    local c = choose condition then choose false then 1 else 7 end else tick() end
    print(a, b, p == nilptr, c, calls)
  ]=], 'false\t42\ttrue\t7\t0')
end)

it('supports typed expression block and capturing lambdas', function()
  expect.run_c([=[
    #syntax 'syntax.lambda'
    do
    local offset = 10
    local add = fn(x: integer): integer => x + offset
    local half = fn(x: integer) do local y = x // 2 return y end
    local total = 0
    local bump = fn(x: integer) <byref> => (do total = total + x in total end)
    local first = bump(3)
    local second = bump(4)
    print(add(2), half(8), first, second, total)
    end
  ]=], '12\t4\t3\t7\t7')
end)

it('destructures records and arrays with one source evaluation', function()
  expect.run_c([=[
    #syntax 'syntax.let'
    local P = @record{x: integer, y: integer}
    local calls = 0
    local function point(): P calls = calls + 1 return {20, 22} end
    let {x, y = height: integer,} = point()
    let [first, _, third: integer] = (@[3]integer){1, 2, 3}
    local p: P = {4, 5}
    let {x = px, y = py} = &p
    print(x + height, first, third, calls, px, py)
  ]=], '42\t1\t3\t1\t4\t5')
  parse_error([=[#syntax 'syntax.let'
    let {x, y = x} = p
  ]=], "duplicate destructuring binding 'x'")
  parse_error([=[#syntax 'syntax.let'
    let [a, a] = p
  ]=], "duplicate destructuring binding 'a'")
end)

it('composes destructuring and compound assignment in either import order', function()
  for _, first in ipairs{'compound', 'let'} do
    local second = first == 'compound' and 'let' or 'compound'
    expect.run_c(string.format([=[
      #syntax 'syntax.%s'
      #syntax 'syntax.%s'
      let [a, b] = (@[2]integer){20, 21}
      a += b
      a += 1
      print(a)
    ]=], first, second), '42')
  end
end)

it('closes resources on normal return break and continue exits', function()
  expect.run_c([=[
    #syntax 'syntax.using'
    local R = @record{closed: *integer}
    function R:__close() $self.closed = $self.closed + 1 end
    local closed = 0
    local function f(): integer
      using r = R{&closed} do return 42 end
      return 0
    end
    local answer = f()
    for i = 1, 3 do
      using r: R = R{&closed} do
        if i == 1 then continue end
        break
      end
    end
    using r <close> = R{&closed} do end
    print(answer, closed)
  ]=], '42\t4')
end)

it('collects numeric ranges and filters before mapping without a GC', function()
  expect.run_c([=[
    ## pragmas.nogc = true
    #syntax 'syntax.collect'
    require 'vector'
    local calls, mapped = 0, 0
    local function limit() calls = calls + 1 return 6 end
    local function square(x: integer) mapped = mapped + 1 return x * x end
    local values <close> = collect(integer; i = 1, limit() when i % 2 == 0 => square(i))
    local descending <close> = collect(integer; i = 5, 1, -2 => i)
    local empty <close> = collect(integer; i = 1, 0 => i)
    print(#values, values[0], values[2], calls, mapped, descending[2], #empty)
  ]=], '3\t4\t36\t1\t3\t1\t0')
end)

it('collects native generic iterators and exclusive numeric ranges', function()
  expect.run_c([=[
    #syntax 'syntax.collect'
    require 'vector'
    local input: [4]integer = {10, 20, 30, 40}
    local values <close> = collect(integer; i, x in ipairs(input) when i % 2 == 0 => x + 1)
    local range <close> = collect(integer; i = 0, < 3 => i)
    print(#values, values[0], values[1], #range, range[2])
  ]=], '2\t11\t31\t3\t2')
end)

it('collects owned values and closes each element exactly once', function()
  expect.run_c([=[
    ## pragmas.nogc = true
    #syntax 'syntax.all'
    require 'vector'
    local R <owned> = @record{closed: *integer}
    function R:__close() $self.closed = $self.closed + 1 end
    local closed = 0
    using values = collect(R; i = 1, 3 => R{&closed}) do
      assert(#values == 3 and closed == 0)
    end
    print(closed)
  ]=], '3')
end)

it('preserves wide integer literals and emits byte strings', function()
  expect.run_c([=[
    #syntax 'syntax.literals'
    require 'string'
    local wide: uint64 = 18_446_744_073_709_551_615_u64
    local f = 1_234.5_625e-1
    local bytes = hex"00 41_ff"
    print(wide == 0xffffffffffffffff_u64, 1_000 + 2_000, f, b"10 1010", #bytes, bytes:byte(1), bytes:byte(2), bytes:byte(3))
  ]=], 'true\t3000\t123.45625\t42\t3\t0\t65\t255')
  parse_error([=[#syntax 'syntax.literals'
    local a = b"102"
  ]=], 'binary literal needs 0 and 1 digits')
  parse_error([=[#syntax 'syntax.literals'
    local a = hex"abc"
  ]=], 'hex byte string needs pairs')
end)

it('preserves native operator precedence and lazy boolean operands', function()
  expect.run_c([=[
    #syntax 'syntax.operators'
    local calls = 0
    local function yes(): boolean calls = calls + 1 return true end
    local a = false && yes()
    local b = true || yes()
    print(a, b, calls, 2 ** 3 ** 2, 1 + 2 ** 3 * 2, 4 != 5 && true)
  ]=], 'false\ttrue\t0\t512.0\t17.0\ttrue')
end)

it('reports malformed extension syntax at its source', function()
  local code = "#syntax 'syntax.control'\n#syntax 'syntax.choose'\nlocal n = choose true then 1 end"
  local err = parse_error(code, 'expected `else`')
  expect.equal(code:find('end$'), err.errpos)
  expect.contains('syntaxlib_spec.nelua:3:30:', err.message)
  parse_error([=[#syntax 'syntax.lambda'
    local f = fn(x: integer) =>
  ]=], 'expected an expression')
  parse_error([=[#syntax 'syntax.collect'
    local v = collect(integer; i = 1, 2 => )
  ]=], 'expected an expression')
end)

it('runs the complete tour and every complete guide example', function()
  expect.run_c_from_file('examples/syntax_tour.nelua',
    'NELUA: kind 42, bytes 1024, ready, total 22\neven squares: 4, first 4, last 64')
  local file = assert(io.open('docs/pages/syntax-extensions.md', 'r'))
  local guide = file:read('a')
  file:close()
  local count = 0
  for code in guide:gmatch('```nelua\n(.-)```') do
    count = count + 1
    expect.run_c(code)
  end
  expect.truthy(count > 0)
end)

end)
