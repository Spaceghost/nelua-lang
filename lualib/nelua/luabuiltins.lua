--[[
Lua builtins.

Runtime helpers emitted by the Lua generator so that typed Nelua code keeps its
C semantics when it runs on a Lua 5.4 state: integer wrapping at the width of each
integral type, `float32` rounding, unsigned 64-bit comparison and division,
truncated division, logical/arithmetic shifts, zeroed arrays, value copies of
aggregates and structural equality.

Each helper is a Lua source snippet defining a global function, so the same text
serves the `--generator lua` prelude and the compile-time evaluator environment
(see `nelua.comptime`).
]]

local luabuiltins = {}

local operators = {}
luabuiltins.operators = operators

function operators.idiv(_, _, emitter, lnode, rnode)
  emitter:add('math.floor(', lnode, ' / ', rnode, ')')
end

-- Lua source of every helper, keyed by name (see `luabuiltins.order` for a stable order).
local sources = {}
luabuiltins.sources = sources
-- Helper names in dependency order.
local order = {}
luabuiltins.order = order

local function define(name, source)
  sources[name] = source
  order[#order+1] = name
end

-- Integer wrapping at 8, 16 and 32 bits (64-bit integers wrap natively in Lua).
for _,bits in ipairs{8, 16, 32} do
  local mask = string.format('0x%x', (1 << bits) - 1)
  local msb = string.format('0x%x', 1 << (bits - 1))
  define('nelua_wrap_u'..bits, string.format([[
function nelua_wrap_u%d(x) return x & %s end]], bits, mask))
  define('nelua_wrap_i'..bits, string.format([[
function nelua_wrap_i%d(x) return ((x & %s) ~ %s) - %s end]], bits, mask, msb, msb))
end

-- Rounds a float to `float32` precision.
define('nelua_fround', [[
function nelua_fround(x) return (string.unpack('f', string.pack('f', x))) end]])

-- Float to integer conversion, truncating toward zero (out of range yields 0, as a C cast is undefined).
define('nelua_toint', [[
function nelua_toint(x)
  if math.type(x) == 'integer' then return x end
  if x ~= x or x == math.huge or x == -math.huge then return 0 end
  return math.tointeger(x >= 0 and math.floor(x) or math.ceil(x)) or 0
end]])

-- Float truncation toward zero, keeping the float subtype.
define('nelua_ftrunc', [[
function nelua_ftrunc(x)
  if x ~= x or x == math.huge or x == -math.huge then return x end
  if x >= 0 then return math.floor(x) + 0.0 else return math.ceil(x) + 0.0 end
end]])

-- Unsigned 64-bit integer to float.
define('nelua_utof', [[
function nelua_utof(x)
  if math.type(x) == 'integer' and x < 0 then return (x + 0.0) + 18446744073709551616.0 end
  return x + 0.0
end]])

-- Unsigned 64-bit comparisons.
define('nelua_ult', [[
function nelua_ult(a, b) return math.ult(a, b) end]])
define('nelua_ule', [[
function nelua_ule(a, b) return not math.ult(b, a) end]])

-- Unsigned 64-bit floor division and modulo.
define('nelua_udiv', [[
function nelua_udiv(a, b)
  if b == 0 then error("attempt to perform 'n//0'", 2) end
  if b < 0 then return math.ult(a, b) and 0 or 1 end
  local q = ((a >> 1) // b) << 1
  if not math.ult(a - q * b, b) then q = q + 1 end
  return q
end]])
define('nelua_umod', [[
function nelua_umod(a, b) return a - nelua_udiv(a, b) * b end]])

-- Truncated division and modulo (`///` and `%%%`).
define('nelua_tdiv', [[
function nelua_tdiv(a, b)
  if math.type(a) == 'integer' and math.type(b) == 'integer' then
    local q = a // b
    if q < 0 and q * b ~= a then q = q + 1 end
    return q
  end
  return nelua_ftrunc(a / b)
end]])
define('nelua_tmod', [[
function nelua_tmod(a, b) return math.fmod(a, b) end]])

-- Arithmetic shift right on 64 bits.
define('nelua_asr', [[
function nelua_asr(a, b)
  if b >= 63 then return a < 0 and -1 or 0 end
  if b <= 0 then return a end
  local r = a >> b
  if a < 0 then r = r | ~((-1) >> b) end
  return r
end]])

-- Zeroed array of `n` elements indexed from 0, `z` is the zero value or a constructor for aggregates,
-- `init` holds explicit initial values.
define('nelua_array', [[
function nelua_array(n, z, init)
  local t = {}
  if type(z) == 'function' then
    for i=0,n-1 do t[i] = z() end
  else
    for i=0,n-1 do t[i] = z end
  end
  if init then
    for i=0,n-1 do local v = init[i] if v ~= nil then t[i] = v end end
  end
  return t
end]])

-- Deep copy of aggregates (records and arrays are values in Nelua).
define('nelua_copy', [[
function nelua_copy(v)
  if type(v) ~= 'table' then return v end
  local t = {}
  for k,x in pairs(v) do t[k] = nelua_copy(x) end
  return t
end]])

-- Structural equality of aggregates.
define('nelua_eq', [[
function nelua_eq(a, b)
  if type(a) ~= 'table' or type(b) ~= 'table' then return a == b end
  for k,x in pairs(a) do if not nelua_eq(x, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end]])

-- `math` functions keeping the float subtype of their argument.
define('nelua_floor', [[
function nelua_floor(x)
  if math.type(x) == 'integer' then return x end
  return math.floor(x) + 0.0
end]])
define('nelua_ceil', [[
function nelua_ceil(x)
  if math.type(x) == 'integer' then return x end
  return math.ceil(x) + 0.0
end]])
define('nelua_round', [[
function nelua_round(x)
  if math.type(x) == 'integer' then return x end
  if x >= 0 then return math.floor(x + 0.5) + 0.0 else return math.ceil(x - 0.5) + 0.0 end
end]])
define('nelua_iround', [[
function nelua_iround(x)
  if x >= 0 then return math.tointeger(math.floor(x + 0.5)) or 0 else return math.tointeger(math.ceil(x - 0.5)) or 0 end
end]])
define('nelua_trunc', [[
function nelua_trunc(x)
  if math.type(x) == 'integer' then return x end
  return nelua_ftrunc(x)
end]])
define('nelua_sign', [[
function nelua_sign(x)
  if x > 0 then return math.type(x) == 'integer' and 1 or 1.0 end
  if x < 0 then return math.type(x) == 'integer' and -1 or -1.0 end
  return x
end]])
define('nelua_fract', [[
function nelua_fract(x) return x - math.floor(x) end]])
define('nelua_fmod', [[
function nelua_fmod(a, b) return math.fmod(a, b) end]])
define('nelua_clamp', [[
function nelua_clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end return x end]])
define('nelua_ldexp', [[
function nelua_ldexp(m, e) return m * 2.0^e end]])
define('nelua_frexp', [[
function nelua_frexp(x)
  if x == 0 or x ~= x or x == math.huge or x == -math.huge then return x + 0.0, 0 end
  local e = math.floor(math.log(math.abs(x), 2)) + 1
  local m = x / 2.0^e
  if math.abs(m) >= 1.0 then m = m / 2 e = e + 1 elseif math.abs(m) < 0.5 then m = m * 2 e = e - 1 end
  return m, e
end]])
define('nelua_cosh', [[
function nelua_cosh(x) return (math.exp(x) + math.exp(-x)) / 2 end]])
define('nelua_sinh', [[
function nelua_sinh(x) return (math.exp(x) - math.exp(-x)) / 2 end]])
define('nelua_tanh', [[
function nelua_tanh(x) local a, b = math.exp(x), math.exp(-x) return (a - b) / (a + b) end]])
define('nelua_isnan', [[
function nelua_isnan(x) return x ~= x end]])
define('nelua_isinf', [[
function nelua_isinf(x) return x == math.huge or x == -math.huge end]])
define('nelua_isfinite', [[
function nelua_isfinite(x) return x == x and x ~= math.huge and x ~= -math.huge end]])

define('nelua_pow', [[
function nelua_pow(x, y) return x ^ y end]])
define('nelua_exp2', [[
function nelua_exp2(x) return 2.0 ^ x end]])
define('nelua_log10', [[
function nelua_log10(x) return math.log(x, 10) end]])
define('nelua_log2', [[
function nelua_log2(x) return math.log(x, 2) end]])
define('nelua_mod', [[
function nelua_mod(a, b) return a % b end]])
define('nelua_concat', [[
function nelua_concat(a, b) return a .. b end]])
define('nelua_streq', [[
function nelua_streq(a, b) return a == b end]])
define('nelua_strlt', [[
function nelua_strlt(a, b) return a < b end]])
define('nelua_strle', [[
function nelua_strle(a, b) return a <= b end]])

-- `tostring` of a `float32` (Nelua prints 7 significant digits, 14 for `float64` like Lua).
define('nelua_tostring_f32', [[
function nelua_tostring_f32(x)
  if x ~= x then return 'nan' elseif x == math.huge then return 'inf' elseif x == -math.huge then return '-inf' end
  local s = string.format('%.7g', x)
  if not s:find('[%.eEn]') then s = s .. '.0' end
  return s
end]])

-- `string.find` returning `0, 0` when there is no match, as in Nelua.
define('nelua_string_find', [[
function nelua_string_find(s, pattern, init, plain)
  local b, e = string.find(s, pattern, init, plain)
  if not b then return 0, 0 end
  return b, e
end]])

-- Helpers used by other helpers.
luabuiltins.deps = {
  nelua_umod = {'nelua_udiv'},
  nelua_tdiv = {'nelua_ftrunc'},
  nelua_trunc = {'nelua_ftrunc'},
}

--[[
Returns the prelude source defining the helpers in `names` (a set) and the helpers
they depend on, or every helper when `names` is omitted.
]]
function luabuiltins.prelude(names)
  if names then
    local closed = {}
    local function close(name)
      if closed[name] then return end
      closed[name] = true
      for _,dep in ipairs(luabuiltins.deps[name] or {}) do close(dep) end
    end
    for name in pairs(names) do close(name) end
    names = closed
  end
  local parts = {}
  for _,name in ipairs(order) do
    if not names or names[name] then
      parts[#parts+1] = sources[name]
    end
  end
  return table.concat(parts, '\n')
end

return luabuiltins
