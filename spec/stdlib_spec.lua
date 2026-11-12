local lester = require 'nelua.thirdparty.lester'
local describe, it = lester.describe, lester.it

local expect = require 'spec.tools.expect'
local ccompiler = require 'nelua.ccompiler'

describe("standard library", function()

it("require", function()
  expect.run_c_from_file('tests/require_test.nelua')
  expect.run_error('tests/require_itself.nelua', "cannot require itself")
end)
it("builtins", function()
  expect.run_c_from_file('tests/builtins_test.nelua', 'hello', 'warning: hi')
end)
it("traits", function()
  expect.run_c_from_file('tests/traits_test.nelua')
end)
it("libc", function()
  expect.run_c_from_file('tests/libc_test.nelua')
end)
it("math", function()
  expect.run_c_from_file('tests/math_test.nelua')
end)
it("memory", function()
  expect.run_c_from_file('tests/memory_test.nelua')
end)
it("gc", function()
  expect.run_c_from_file('tests/gc_test.nelua')
end)
it("allocators", function()
  expect.run_c_from_file('tests/allocators_test.nelua')
end)
it("gc realloc", function()
  -- the GC must not read a pointer value after it was passed to realloc
  -- (indeterminate after free): gcc 12 reports it as -Wuse-after-free
  local ccinfo = ccompiler.get_cc_info()
  local args = {'--generator', 'c', '--sanitize', 'tests/gc_realloc_test.nelua'}
  if ccinfo.is_gcc and not ccinfo.is_clang and ccinfo.gnuc >= 12 then
    -- notes: the diagnostic needs GC:reregister inlined into
    -- GCAllocator:realloc, so optimize; a bare -Werror=use-after-free drops gcc
    -- to level 1 (definite uses only), restate level 2 to keep "may be used"
    table.insert(args, 1, '--cflags=-O2 -Werror=use-after-free -Wuse-after-free=2')
  end
  expect.run(args, 'gc realloc ok')
end)
it("variant", function()
  expect.run_c_from_file('tests/variant_test.nelua')
  expect.run_c([[
    require 'variant'
    require 'string'
    local V = @variant(integer, string)
    local a: V = 1
    local b: V = 1
    local e: V
    print(a == b, a == 'x', a == e, e == e, a == 1, 1 == a)
    print(a, e)
    local function describe(x: auto): string
      ## if x.type.is_integral then
        return 'int'
      ## else
        return 'str'
      ## end
    end
    b = 's'
    print(a:visit(describe), b:visit(describe))
    local B = @variant(integer, boolean)
    local t: B = true
    local n: B = 1
    print(t == true, t == false, t == 1, n == 1, n == true, 0 == n, t, n)
  ]], "true\tfalse\tfalse\ttrue\ttrue\ttrue\n" ..
      "variant(int64, string): 1\tvariant(int64, string): empty\n" ..
      "int\tstr\n" ..
      "true\tfalse\tfalse\ttrue\tfalse\tfalse\t" ..
      "variant(int64, boolean): true\tvariant(int64, boolean): 1")
  expect.run_error_c([[
    require 'variant'
    local e: integer|string
    local function one(x: auto): integer return 1 end
    print(e:visit(one))
  ]], "attempt to visit an empty variant")
  expect.run_error_c([[
    require 'variant'
    local a: integer|string = 1
    local function ident(x: auto) return x end -- branches disagree on the result type
    local r = a:visit(ident)
  ]], "deduced type 'any'")
end)
it("optional", function()
  expect.run_c_from_file('tests/optional_test.nelua')
end)
it("span", function()
  expect.run_c_from_file('tests/span_test.nelua')
end)
it("sequence", function()
  expect.run_c_from_file('tests/sequence_test.nelua')
end)
it("vector", function()
  expect.run_c_from_file('tests/vector_test.nelua')
end)
it("list", function()
  expect.run_c_from_file('tests/list_test.nelua')
end)
it("hashmap", function()
  expect.run_c_from_file('tests/hashmap_test.nelua')
end)
it("algorithm", function()
  expect.run_c_from_file('tests/algorithm_test.nelua', 'algorithm OK!')
end)
it("heapqueue", function()
  expect.run_c_from_file('tests/heapqueue_test.nelua', 'heapqueue OK!')
end)
it("tuple", function()
  expect.run_c_from_file('tests/tuple_test.nelua', 'tuple OK!')
end)
it("owned", function()
  expect.run_c_from_file('tests/owned_test.nelua', 'owned OK!')
end)
it("comptime", function()
  expect.run_c_from_file('tests/comptime_test.nelua', 'comptime OK!')
end)
it("comptime configuration example", function()
  expect.run_c_from_file('examples/comptime_config.nelua', '3333\t1666\t833')
  expect.run({'--generator', 'lua', '--runner', './nelua-lua', 'examples/comptime_config.nelua'}, '3333\t1666\t833')
end)
it("hash", function()
  expect.run_c_from_file('tests/hash_test.nelua')
end)
it("io", function()
  expect.run_c_from_file('tests/io_test.nelua')
end)
it("os", function()
  expect.run_c_from_file('tests/os_test.nelua')
end)
it("stringbuilder", function()
  expect.run_c_from_file('tests/stringbuilder_test.nelua')
end)
it("string", function()
  expect.run_c_from_file('tests/string_test.nelua')
end)
it("utf8", function()
  expect.run_c_from_file('tests/utf8_test.nelua')
end)
it("pattern matching", function()
  expect.run_c_from_file('tests/pattern_matching_test.nelua')
end)
it("pack", function()
  expect.run_c_from_file('tests/pack_test.nelua')
end)
it("defer", function()
  expect.run_c_from_file('tests/defer_test.nelua')
end)
it("coroutine", function()
  expect.run_c_from_file('tests/coroutine_test.nelua')
end)

local ccinfo = ccompiler.get_cc_info()
if (ccinfo.is_gcc or ccinfo.is_clang) and not ccinfo.is_wasm and not ccinfo.is_windows then
  it("threads", function()
    expect.run_c_from_file('tests/threads_test.nelua')
  end)
end

end)
