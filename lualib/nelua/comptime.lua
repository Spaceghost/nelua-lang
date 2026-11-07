--[[
Compile-time evaluation of Nelua functions.

`comptime(f(args))` and calls of functions annotated with `<comptime>` are evaluated while
the analyzer runs: the function body (and every function it calls) is checked against the
set of constructs that have a compile-time meaning, translated to Lua with the Lua generator,
loaded into a sandboxed environment that mirrors the integer and float semantics of the C
target, called with the compile-time argument values, and the results are injected back into
the AST as compile-time constants (scalars, booleans, strings) or initializer lists (arrays
and records), which the C generator emits as static initializers at the top scope.
]]

local class = require 'nelua.utils.class'
local traits = require 'nelua.utils.traits'
local console = require 'nelua.utils.console'
local bn = require 'nelua.utils.bn'
local aster = require 'nelua.aster'
local Emitter = require 'nelua.emitter'
local typedefs = require 'nelua.typedefs'
local luagenerator = require 'nelua.luagenerator'
local luabuiltins = require 'nelua.luabuiltins'
local primtypes = typedefs.primtypes

local comptime = {}

-- Default limits (see `pragmas.comptime_steps` and `pragmas.comptime_stack`).
comptime.DEFAULT_STEPS = 10000000
comptime.DEFAULT_STACK = 10000
-- Granularity of the instruction count hook.
local HOOK_COUNT = 1000

-- Builtins with a compile-time meaning.
local allowed_builtins = {
  print = true, assert = true, check = true, error = true, panic = true, warn = true,
  likely = true, unlikely = true,
}

-- Variable annotations without a compile-time meaning.
local rejected_annots = {
  close = true, cimport = true, cexport = true, nodecl = true, cinclude = true, atomic = true,
  threadlocal = true, volatile = true, register = true, codename = true, static = true,
  cqualifier = true, cpostqualifier = true, cattribute = true,
}

--[[
Standard library functions with a pure Lua counterpart, by Nelua symbol name.
Their bodies are never checked or translated, the Lua expression is called instead.
]]
comptime.stdlib = {
  ['math.abs'] = 'math.abs', ['math.floor'] = 'nelua_floor', ['math.ifloor'] = 'math.floor',
  ['math.ceil'] = 'nelua_ceil', ['math.iceil'] = 'math.ceil',
  ['math.round'] = 'nelua_round', ['math.iround'] = 'nelua_iround',
  ['math.trunc'] = 'nelua_trunc', ['math.itrunc'] = 'nelua_toint',
  ['math.sqrt'] = 'math.sqrt', ['math.exp'] = 'math.exp', ['math.exp2'] = 'nelua_exp2',
  ['math.pow'] = 'nelua_pow', ['math.log'] = 'math.log',
  ['math.log10'] = 'nelua_log10', ['math.log2'] = 'nelua_log2',
  ['math.cos'] = 'math.cos', ['math.sin'] = 'math.sin', ['math.tan'] = 'math.tan',
  ['math.acos'] = 'math.acos', ['math.asin'] = 'math.asin',
  ['math.atan'] = 'math.atan', ['math.atan2'] = 'math.atan',
  ['math.cosh'] = 'nelua_cosh', ['math.sinh'] = 'nelua_sinh', ['math.tanh'] = 'nelua_tanh',
  ['math.deg'] = 'math.deg', ['math.rad'] = 'math.rad', ['math.sign'] = 'nelua_sign',
  ['math.fract'] = 'nelua_fract', ['math.mod'] = 'nelua_mod', ['math.fmod'] = 'nelua_fmod',
  ['math.modf'] = 'math.modf', ['math.frexp'] = 'nelua_frexp', ['math.ldexp'] = 'nelua_ldexp',
  ['math.min'] = 'math.min', ['math.max'] = 'math.max', ['math.clamp'] = 'nelua_clamp',
  ['math.ult'] = 'math.ult', ['math.tointeger'] = 'math.tointeger', ['math.type'] = 'math.type',
  ['math.isnan'] = 'nelua_isnan', ['math.isinf'] = 'nelua_isinf', ['math.isfinite'] = 'nelua_isfinite',
  ['string.sub'] = 'string.sub', ['string.subview'] = 'string.sub', ['string.rep'] = 'string.rep',
  ['string.reverse'] = 'string.reverse', ['string.upper'] = 'string.upper', ['string.lower'] = 'string.lower',
  ['string.byte'] = 'string.byte', ['string.char'] = 'string.char', ['string.format'] = 'string.format',
  ['string.len'] = 'string.len', ['string.find'] = 'nelua_string_find', ['string.copy'] = 'nelua_copy',
  ['string.__concat'] = 'nelua_concat', ['string.__len'] = 'string.len', ['string.__eq'] = 'nelua_streq',
  ['string.__lt'] = 'nelua_strlt', ['string.__le'] = 'nelua_strle',
  ['tostring'] = 'tostring',
}

--------------------------------------------------------------------------------
-- Eligibility check

-- Memoized verdicts of `type_error` (false when the type is fine, the message otherwise).
local type_verdicts = setmetatable({}, {__mode = 'k'})

-- Returns an error message when `type` has no compile-time counterpart, nil when it has one.
local function type_error(type)
  local verdict = type_verdicts[type]
  if verdict ~= nil then
    return verdict or nil
  end
  local err = false
  if type.is_void or type.is_niltype or type.is_nilptr or type.is_type or
     type.is_boolean or type.is_integral or type.is_float or type.is_procedure then
    err = false
  elseif type.is_string then
    err = false
  elseif type.is_array then
    type_verdicts[type] = false -- guard against cycles
    err = type_error(type.subtype) or false
  elseif type.is_pointer then
    local subtype = type.subtype
    if subtype and (subtype.is_record or subtype.is_array) and not subtype.is_string then
      type_verdicts[type] = false
      err = type_error(subtype) or false
    else
      err = string.format("pointer type '%s' cannot be used at compile time \z
        (only references to records and arrays are)", type)
    end
  elseif type.is_record then
    if type.is_optional or type.is_variant then
      err = string.format("type '%s' cannot be used at compile time yet", type)
    else
      type_verdicts[type] = false
      for _,field in ipairs(type.fields) do
        if field.type.is_pointer then
          err = string.format("record '%s' has the pointer field '%s', it cannot be used at compile time",
            type, field.name)
          break
        end
        local fielderr = type_error(field.type)
        if fielderr then
          err = string.format("in field '%s' of record '%s': %s", field.name, type, fielderr)
          break
        end
      end
    end
  else
    err = string.format("type '%s' cannot be used at compile time", type)
  end
  type_verdicts[type] = err
  return err or nil
end

-- Checks whether `symbol` is declared inside the scope `funcscope`.
local function is_inside_scope(symbol, funcscope)
  local scope = symbol.scope
  while scope do
    if scope == funcscope then return true end
    scope = scope.parent
  end
  return false
end

-- Gets the definition node of function symbol `symbol`.
local function get_defnode(symbol)
  local defnode = symbol.defnode
  if not defnode then
    local node = symbol.node
    if node and node.is_FuncDef then
      defnode = node
    end
  end
  return defnode
end
comptime.get_defnode = get_defnode

-- Sentinel raised while a called function body still has unresolved types.
local PENDING = setmetatable({}, {__tostring = function() return 'comptime pending' end})
comptime.PENDING = PENDING

-- Accepts every node tag in `ASTNode:walk_trace_nodes`.
local all_tags = setmetatable({}, {__index = function() return true end})

local check_function

-- Checks that function `symbol`, called from `node`, can be evaluated at compile time.
local function check_callee(context, symbol, node, fstate)
  if comptime.stdlib[symbol.name] then return end
  if symbol.cimport then
    node:raisef("in compile-time evaluation of function '%s': \z
      imported C function '%s' cannot be called at compile time", fstate.name, symbol.name)
  end
  local defnode = get_defnode(symbol)
  if not defnode then
    node:raisef("in compile-time evaluation of function '%s': \z
      function '%s' has no definition available at compile time", fstate.name, symbol.name)
  end
  check_function(context, symbol, defnode, fstate.info)
end

local function check_node(context, node, trace, fstate)
  local attr = node.attr
  local parent = trace[#trace]
  local raise = function(msg, ...)
    local locnode = node
    local i = #trace
    while not locnode.pos and i > 0 do -- synthesized nodes point at their source statement
      locnode = trace[i]
      i = i - 1
    end
    locnode:raisef("in compile-time evaluation of function '%s': "..msg, fstate.name, ...)
  end
  if node.is_IdDecl and node[1] == '__forclose' then -- the lowering of a `for in` loop
    raise("`for in` loops cannot be used at compile time (iterators are runtime functions)")
  end
  local type = attr.type
  if type and not node.is_Type and not attr.builtin then
    local err = type_error(type)
    if err then raise(err) end
  end
  if node.is_Defer then
    raise("`defer` cannot be used at compile time")
  elseif node.is_Varargs or node.is_VarargsType then
    raise("variable arguments cannot be used at compile time")
  elseif node.is_Function then
    raise("closures cannot be used at compile time")
  elseif node.is_ForIn then
    raise("`for in` loops cannot be used at compile time (iterators are runtime functions)")
  elseif node.is_Try or node.is_TryStat or node.is_Match or node.is_Fallthrough then
    raise("`%s` cannot be used at compile time yet", node.tag)
  elseif node.is_Annotation then
    local name = node[1]
    if rejected_annots[name] then
      raise("annotation '%s' cannot be used at compile time", name)
    end
  elseif node.is_Call then
    local calleetype = attr.calleetype
    if not calleetype or not attr.type and not calleetype.is_type and not calleetype.is_function then
      error(PENDING, 0) -- types still being resolved, try again in a later pass
    elseif not calleetype.is_type then
      local calleenode = node[2]
      if calleenode.attr.builtin then
        local name = calleenode.attr.name
        if not allowed_builtins[name] then
          raise("builtin '%s' cannot be used at compile time", name)
        end
      else
        local calleesym = attr.calleesym
        if not calleesym then
          if calleetype.is_polyfunction then error(PENDING, 0) end
          raise("indirect calls of function values cannot be used at compile time")
        end
        check_callee(context, calleesym, node, fstate)
      end
    end
  elseif node.is_CallMethod then
    local calleesym = attr.calleesym
    if not calleesym or not attr.calleetype then
      error(PENDING, 0)
    end
    check_callee(context, calleesym, node, fstate)
  elseif node.is_Id or node.is_DotIndex then
    local symbol = attr._symbol and attr
    if symbol then
      local stype = symbol.type
      local iscallee = parent and ((parent.is_Call and parent[2] == node) or
                                   (parent.is_FuncDef and parent[2] == node))
      if symbol.builtin then
        if not (iscallee and allowed_builtins[symbol.name]) then
          raise("builtin '%s' cannot be used at compile time", symbol.name)
        end
      elseif stype and stype.is_procedure then
        if not iscallee and not symbol.anonymous then
          raise("function values cannot be used at compile time, only calls")
        end
      elseif stype and stype.is_type then -- types are fine
        return
      elseif symbol.comptime and symbol.value ~= nil then -- compile-time constants
        return
      elseif node.is_Id and is_inside_scope(symbol, fstate.funcscope) then -- locals
        return
      elseif node.is_DotIndex and not (node[2].attr.type and node[2].attr.type.is_type) then
        return -- a record field
      else
        raise("variable '%s' is declared outside the function and is not <comptime>, \z
          it cannot be read at compile time", symbol.name)
      end
    end
  elseif node.is_UnaryOp and node[1] == 'ref' then
    local argtype = node[2].attr.type
    if argtype and not (argtype.is_record or argtype.is_array) then
      raise("cannot take the address of a value of type '%s' at compile time \z
        (only records and arrays)", argtype)
    end
  end
end

--[[
Checks that the body of function `symbol` defined by `defnode` only uses constructs with a
compile-time meaning, raising an error at the offending node otherwise.
Called functions are checked recursively and recorded in `info.deps` in discovery order.
]]
check_function = function(context, symbol, defnode, info)
  local funcinfo = context.comptimefuncs[symbol]
  if funcinfo then
    if funcinfo.checking then return end -- recursion
    if funcinfo.ok and not info.set[symbol] then -- reuse the verdict, bring its dependencies
      for _,dep in ipairs(funcinfo.deps) do
        if not info.set[dep] then
          info.set[dep] = true
          info.deps[#info.deps+1] = dep
        end
      end
    end
    return
  end
  funcinfo = {checking = true, deps = {}}
  context.comptimefuncs[symbol] = funcinfo
  local fstate = {
    name = symbol.name,
    funcscope = defnode.scope,
    info = {deps = funcinfo.deps, set = {}},
  }
  fstate.info.set[symbol] = true
  funcinfo.deps[1] = symbol
  local type = symbol.type
  if type and type.is_function then
    for _,rettype in ipairs(type.rettypes) do
      local err = type_error(rettype)
      if err then
        defnode:raisef("in compile-time evaluation of function '%s': in return type: %s", symbol.name, err)
      end
    end
  end
  local ok, err = pcall(function()
    for node, trace in defnode:walk_trace_nodes(all_tags) do
      check_node(context, node, trace, fstate)
    end
  end)
  if not ok then
    context.comptimefuncs[symbol] = nil
    error(err, 0)
  end
  funcinfo.checking = nil
  funcinfo.ok = true
  for _,dep in ipairs(funcinfo.deps) do
    if not info.set[dep] then
      info.set[dep] = true
      info.deps[#info.deps+1] = dep
    end
  end
end

--------------------------------------------------------------------------------
-- Lua generation

-- Lua name of function `symbol` inside a generated chunk.
local function funcname(symbol)
  return 'F_'..(symbol.codename or symbol.name or 'anonymous'):gsub('[^%w_]', '_')
end

-- Lua generator context that stands alone from the analyzer context.
local ComptimeLuaContext = class(luagenerator.LuaContext)

function ComptimeLuaContext:_init()
  self.context = self
  self.visitors = luagenerator.visitors
  self.luabuiltins = {}
  self.luaversion = '5.4'
  self.scope = {is_topscope = false}
  self.scopestack = {}
  self.rootstate = {}
  self.statestack = {}
  self.state = self.rootstate
  self.nodestack = {}
  self.pragmas = {}
  self.pragmastack = {}
end

-- Scopes were already resolved by the analyzer, the generator only needs nesting.
function ComptimeLuaContext:push_forked_scope()
  local scope = {is_topscope = false}
  local scopestack = self.scopestack
  scopestack[#scopestack+1] = self.scope
  self.scope = scope
  return scope
end

function ComptimeLuaContext:funcref(symbol)
  return comptime.stdlib[symbol.name] or funcname(symbol)
end

-- Generates the Lua chunk evaluating to the function `symbol` with all its dependencies.
local function generate_chunk(symbol, deps)
  local context = ComptimeLuaContext()
  local emitter = Emitter(context, 0)
  emitter:add_indent('local ')
  for i,dep in ipairs(deps) do
    if i > 1 then emitter:add(', ') end
    emitter:add(funcname(dep))
  end
  emitter:add_ln()
  for _,dep in ipairs(deps) do
    emitter:add_indent(funcname(dep), ' = ')
    luagenerator.emit_function(context, emitter, get_defnode(dep))
    emitter:add_ln()
  end
  emitter:add_indent_ln('return ', funcname(symbol))
  return emitter:generate()
end
comptime.generate_chunk = generate_chunk

--------------------------------------------------------------------------------
-- Sandbox

-- Creates the sandboxed environment shared by every evaluation of a compilation.
local function make_env(context)
  local env = context.comptimeenv
  if env then return env end
  local mathlib = {}
  for k,v in pairs(math) do mathlib[k] = v end
  mathlib.random = nil
  mathlib.randomseed = nil
  local stringlib = {}
  for k,v in pairs(string) do stringlib[k] = v end
  stringlib.dump = nil
  env = {
    math = mathlib,
    string = stringlib,
    tostring = tostring,
    tonumber = tonumber,
    type = type,
    select = select,
    ipairs = ipairs,
    pairs = pairs,
    next = next,
    table = {pack = table.pack, unpack = table.unpack, concat = table.concat},
    utf8 = utf8,
  }
  env._G = env
  env.print = function(...)
    local parts = {}
    for i=1,select('#', ...) do
      parts[i] = tostring((select(i, ...)))
    end
    console.log(table.concat(parts, '\t'))
  end
  env.assert = function(cond, msg)
    if not cond then error(msg or 'assertion failed!', 0) end
    return cond
  end
  env.check = env.assert
  env.error = function(msg) error(msg or 'error!', 0) end
  env.panic = env.error
  env.warn = function(msg) console.warn(tostring(msg)) end
  env.likely = function(x) return x end
  env.unlikely = env.likely
  local prelude = assert(load(luabuiltins.prelude(), '=comptime_prelude', 't', env))
  prelude()
  context.comptimeenv = env
  return env
end

local lua_zero

-- Lua zero value of `type`.
lua_zero = function(type)
  if type.is_integral then return 0
  elseif type.is_float then return 0.0
  elseif type.is_boolean then return false
  elseif type.is_string then return ''
  elseif type.is_array then
    local t = {}
    for i=0,type.length-1 do t[i] = lua_zero(type.subtype) end
    return t
  elseif type.is_record then
    local t = {}
    for _,field in ipairs(type.fields) do t[field.name] = lua_zero(field.type) end
    return t
  end
  return nil
end

local function fround(x)
  return (string.unpack('f', string.pack('f', x)))
end

-- Converts the compile-time value of `attr` to a Lua value of `type`.
local function attr_to_lua(attr, type, node, name)
  local value = attr.value
  local atype = attr.type
  if atype and atype.is_niltype then return nil end
  if type.is_integral then
    if traits.is_integral(value) or traits.is_scalar(value) then
      if not bn.isintegral(value) then value = bn.trunc(value) end
      value = type:wrap_value(value)
      if type.is_unsigned then return bn.touinteger(value) end
      return bn.tointeger(value)
    end
  elseif type.is_float then
    if traits.is_scalar(value) then
      local n = bn.tonumber(value) + 0.0
      if type.is_float32 then n = fround(n) end
      return n
    end
  elseif type.is_boolean then
    if traits.is_boolean(value) then return value end
  elseif type.is_string then
    if traits.is_string(value) then return value end
  elseif type.is_array then
    if traits.is_table(value) and not value._bn and traits.is_type(value.type) then -- a compile-time array literal
      local t = lua_zero(type)
      for i=1,#value do
        t[i-1] = attr_to_lua(value[i], type.subtype, node, name)
      end
      return t
    end
  end
  node:raisef("in call of compile-time function '%s': \z
    cannot pass argument of type '%s' at compile time", name, type)
end

-- Serializes the compile-time value of `attr` for the evaluation cache key.
local function attr_key(attr, type)
  local value = attr.value
  if traits.is_table(value) and not value._bn and traits.is_type(value.type) then
    local parts = {}
    for i=1,#value do parts[i] = attr_key(value[i], type.subtype) end
    return '{'..table.concat(parts, ',')..'}'
  end
  return tostring(type)..':'..string.format('%q', tostring(value))
end

--[[
Runs the compiled chunk of function `symbol` with Lua values `args`,
returns the packed results or raises an error at `node`.
]]
local function run(context, symbol, funcinfo, args, node)
  local env = make_env(context)
  local func = funcinfo.func
  if not func then
    local code = generate_chunk(symbol, funcinfo.deps)
    funcinfo.code = code
    local chunk, err = load(code, '=comptime', 't', env)
    if not chunk then --luacov:disable
      node:raisef("in compile-time evaluation of function '%s': failed to load the generated Lua code: %s\n%s",
        symbol.name, err, code)
    end --luacov:enable
    func = chunk()
    funcinfo.func = func
  end
  local pragmas = context.pragmas
  local maxsteps = pragmas.comptime_steps or comptime.DEFAULT_STEPS
  local maxdepth = pragmas.comptime_stack or comptime.DEFAULT_STACK
  local steps, depth = 0, 0
  local limiterr
  local function hook(event)
    if limiterr then return end -- already failing, let the error unwind
    if event == 'count' then
      steps = steps + HOOK_COUNT
      if steps > maxsteps then
        limiterr = string.format("exceeded the limit of %d steps (raise it with `## pragmas.comptime_steps = N`)",
          maxsteps)
        error(limiterr, 0)
      end
    elseif event == 'call' then
      depth = depth + 1
      if depth > maxdepth then
        limiterr = string.format("exceeded the limit of %d nested calls (raise it with `## pragmas.comptime_stack = N`)",
          maxdepth)
        error(limiterr, 0)
      end
    elseif event == 'return' then
      depth = depth - 1
    end
  end
  debug.sethook(hook, 'cr', HOOK_COUNT)
  local ok, results = pcall(function()
    return table.pack(func(table.unpack(args, 1, args.n)))
  end)
  debug.sethook()
  if not ok then
    local msg = limiterr or tostring(results)
    msg = msg:gsub('^comptime:%d+: ', ''):gsub('^comptime_prelude:%d+: ', '')
    node:raisef("in compile-time evaluation of function '%s': %s", symbol.name, msg)
  end
  return results
end

--------------------------------------------------------------------------------
-- Result injection

local lua_to_node

-- Wraps `valnode` in a type cast to `type`.
local function cast_node(valnode, type)
  return aster.Call{{valnode}, aster.value(type)}
end

-- Converts Lua value `value` to an AST node of `type`.
lua_to_node = function(value, type, node, name)
  if type.is_integral then
    if math.type(value) ~= 'integer' then
      if math.type(value) == 'float' then
        value = math.tointeger(value >= 0 and math.floor(value) or math.ceil(value)) or 0
      else
        node:raisef("in compile-time evaluation of function '%s': expected an integer result but got %s",
          name, type(value))
      end
    end
    local b = type.is_unsigned and bn.fromuinteger(value) or bn.frominteger(value)
    b = type:wrap_value(b)
    local numnode
    if bn.isneg(b) then
      numnode = aster.UnaryOp{'unm', aster.Number{bn.todecint(-b)}}
    elseif not primtypes.int64:is_inrange(b) then
      numnode = aster.Number{'0x'..bn.tohexint(b)}
    else
      numnode = aster.Number{bn.todecint(b)}
    end
    if type == primtypes.integer then
      return numnode
    end
    return cast_node(numnode, type)
  elseif type.is_float then
    if math.type(value) ~= 'float' and math.type(value) ~= 'integer' then
      node:raisef("in compile-time evaluation of function '%s': expected a number result but got %s",
        name, type(value))
    end
    value = value + 0.0
    local numnode
    if value ~= value then
      numnode = aster.Number{'nan'}
    elseif value == math.huge then
      numnode = aster.Number{'inf'}
    elseif value == -math.huge then
      numnode = aster.UnaryOp{'unm', aster.Number{'inf'}}
    else
      local s = string.format('%.17g', math.abs(value))
      if not s:find('[%.eE]') then s = s..'.0' end
      numnode = aster.Number{s}
      if value < 0 then
        numnode = aster.UnaryOp{'unm', numnode}
      end
    end
    if type == primtypes.number then
      return numnode
    end
    return cast_node(numnode, type)
  elseif type.is_boolean then
    return aster.Boolean{not not value}
  elseif type.is_string then
    if not traits.is_string(value) then
      node:raisef("in compile-time evaluation of function '%s': expected a string result but got %s",
        name, type(value))
    end
    return aster.String{value}
  elseif type.is_niltype or type.is_void then
    return aster.Nil{}
  elseif type.is_array then
    if not traits.is_table(value) then
      node:raisef("in compile-time evaluation of function '%s': expected an array result but got %s",
        name, type(value))
    end
    local listnode = aster.InitList{pattr = {desiredtype = type}}
    for i=0,type.length-1 do
      local v = value[i]
      if v == nil then v = lua_zero(type.subtype) end
      listnode[#listnode+1] = lua_to_node(v, type.subtype, node, name)
    end
    return listnode
  elseif type.is_record then
    if not traits.is_table(value) then
      node:raisef("in compile-time evaluation of function '%s': expected a record result but got %s",
        name, type(value))
    end
    local listnode = aster.InitList{pattr = {desiredtype = type}}
    for _,field in ipairs(type.fields) do
      local v = value[field.name]
      if v == nil then v = lua_zero(field.type) end
      listnode[#listnode+1] = aster.Pair{field.name, lua_to_node(v, field.type, node, name)}
    end
    return listnode
  end
  node:raisef("in compile-time evaluation of function '%s': cannot convert a result of type '%s'",
    name, type)
end

-- Finds the list of the parent node holding `node` as its last value, if any.
local function parent_value_list(parent, node)
  local list
  if parent.is_VarDecl then list = parent[3]
  elseif parent.is_Assign then list = parent[2]
  elseif parent.is_Return or parent.is_InitList then list = parent
  elseif parent.is_Call then list = parent[1]
  elseif parent.is_CallMethod then list = parent[2]
  end
  if list and list[#list] == node then
    return list
  end
end

--[[
Replaces `node` with the compile-time `results` of a call returning `rettypes`.
Extra results are spliced after `node` when it is the last value of a multiple assignment,
return or argument list.
]]
local function inject_results(context, node, results, rettypes, name, opts)
  local parent = context:get_visiting_node(1)
  if parent and parent.is_Block then -- a statement, the results are discarded
    local newnode = aster.Do{aster.Block{}}
    newnode:copy_origin(node)
    context:transform_and_traverse_node(node, newnode)
    return
  end
  if #rettypes == 0 then
    node:raisef("in compile-time evaluation of function '%s': the function returns no value", name)
  end
  local nodes = {}
  for i=1,#rettypes do
    local newnode = lua_to_node(results[i], rettypes[i], node, name)
    newnode:recursive_update_location(node.src, node.pos, node.endpos)
    nodes[i] = newnode
  end
  local list = parent and parent_value_list(parent, node)
  if list then
    for i=2,#nodes do
      list[#list+1] = nodes[i]
    end
  end
  context:transform_and_traverse_node(node, nodes[1], opts)
end

--------------------------------------------------------------------------------
-- Analyzer entry points

-- Checks whether `attr` holds a value known at compile time.
local function is_comptime_attr(attr)
  local type = attr.type
  if not type then return false end
  if type.is_niltype then return true end
  return attr.comptime and attr.value ~= nil
end

--[[
Evaluates function `symbol` with arguments `args` (list of `{attr=, node=}`) at compile time,
returns the packed results. Results are cached per function and argument values.
]]
function comptime.evaluate(context, symbol, args, node)
  if symbol.forwarddecl and not symbol.funcdefined then
    return nil -- wait for the definition
  end
  local defnode = get_defnode(symbol)
  if not defnode then
    node:raisef("in compile-time evaluation of function '%s': the function has no definition available",
      symbol.name)
  end
  if not context.comptimefuncs then
    context.comptimefuncs = {}
    context.comptimecache = {}
  end
  local info = {deps = {}, set = {}}
  local ok, err = pcall(check_function, context, symbol, defnode, info)
  if not ok then
    if err == PENDING then return nil end
    error(err, 0)
  end
  local funcinfo = context.comptimefuncs[symbol]
  local argtypes = symbol.type.argtypes
  local luaargs = {n = #argtypes}
  local keys = {}
  for i=1,#argtypes do
    local arg = args[i]
    local argtype = argtypes[i]
    if arg then
      luaargs[i] = attr_to_lua(arg.attr, argtype, arg.node or node, symbol.name)
      keys[i] = attr_key(arg.attr, argtype)
    else
      keys[i] = 'nil'
    end
  end
  local cache = context.comptimecache[symbol]
  if not cache then
    cache = {}
    context.comptimecache[symbol] = cache
  end
  local key = table.concat(keys, ';')
  local results = cache[key]
  if not results then
    results = run(context, symbol, funcinfo, luaargs, node)
    cache[key] = results
  end
  return results
end

-- Marks `node` as waiting for type resolution before it can be evaluated.
local function set_pending(context, node, pending)
  local pendings = context.comptimepending
  if not pendings then
    pendings = {}
    context.comptimepending = pendings
  end
  pendings[node] = pending or nil
end

-- Collects the arguments of call `callnode` (and the object of a method call) as `{attr=, node=}`.
local function collect_args(callnode, argnodes, calleeobjnode)
  local args = {}
  if calleeobjnode then
    args[1] = {attr = calleeobjnode.attr, node = calleeobjnode}
  end
  for i=1,#argnodes do
    local argnode = argnodes[i]
    args[#args+1] = {attr = argnode.attr, node = argnode}
  end
  return args
end

-- Checks that every argument is a compile-time value, returns false when a type is still unknown.
local function check_args(args, name)
  for i,arg in ipairs(args) do
    local attr = arg.attr
    if not attr.type then return false end
    if not is_comptime_attr(attr) then
      arg.node:raisef("in call of compile-time function '%s': argument %d is not a compile time value \z
        (it has type '%s')", name, i, attr.type)
    end
  end
  return true
end

--[[
Visits the `comptime(call)` builtin: evaluates `call` and replaces `node` with its results.
]]
function comptime.visit_builtin(context, node, argnodes, opts)
  if #argnodes ~= 1 then
    node:raisef("in call of builtin 'comptime': expected 1 argument but got %d", #argnodes)
  end
  local callnode = argnodes[1]
  while callnode.is_Paren do callnode = callnode[1] end
  if not callnode.is_call then
    callnode:raisef("in call of builtin 'comptime': expected a function call but got '%s'", callnode.tag)
  end
  context:traverse_node(callnode)
  if not callnode.is_call then
    -- the call was already evaluated (a `<comptime>` function), unwrap it
    local parent = context:get_visiting_node(1)
    local list = parent and parent_value_list(parent, node)
    for i=2,#argnodes do
      if list then list[#list+1] = argnodes[i] end
      argnodes[i] = nil
    end
    set_pending(context, node, false)
    context:transform_and_traverse_node(node, callnode, opts)
    return
  end
  local cattr = callnode.attr
  local calleetype, calleesym = cattr.calleetype, cattr.calleesym
  if not calleetype then -- wait for resolution
    set_pending(context, node, true)
    return
  end
  if calleetype.is_type then
    callnode:raisef("in call of builtin 'comptime': expected a function call but got a type cast")
  end
  local calleeobjnode
  if callnode.is_Call then
    local calleenode = callnode[2]
    if calleenode.attr.builtin then
      callnode:raisef("in call of builtin 'comptime': builtin '%s' cannot be evaluated at compile time",
        calleenode.attr.name)
    end
  else
    calleeobjnode = callnode[3]
  end
  if not calleesym or not calleesym._symbol then
    callnode:raisef("in call of builtin 'comptime': cannot evaluate an indirect call at compile time")
  end
  if calleesym.cimport then
    callnode:raisef("in call of builtin 'comptime': imported C function '%s' cannot be evaluated at compile time",
      calleesym.name)
  end
  if not calleetype.is_function then -- polymorphic call still unresolved
    set_pending(context, node, true)
    return
  end
  local args = collect_args(callnode, callnode.is_Call and callnode[1] or callnode[2], calleeobjnode)
  if not check_args(args, calleesym.name) then
    set_pending(context, node, true)
    return
  end
  local results = comptime.evaluate(context, calleesym, args, node)
  if not results then -- the callee body is not fully resolved yet
    set_pending(context, node, true)
    return
  end
  set_pending(context, node, false)
  inject_results(context, node, results, calleetype.rettypes, calleesym.name, opts)
end

--[[
Visits a call of a function annotated with `<comptime>` after it was resolved,
evaluating it in place. Returns true when the call was handled.
]]
function comptime.visit_comptime_call(context, node, argnodes, calleeobjnode, opts)
  local attr = node.attr
  local calleesym, calleetype = attr.calleesym, attr.calleetype
  if not (calleesym and calleesym._symbol and calleesym.comptimefunc and
          calleetype and calleetype.is_function) then
    return false
  end
  -- inside a `<comptime>` function the evaluator runs the call itself
  local funcscope = context.state.funcscope
  local funcsym = funcscope and funcscope.funcsym
  if funcsym and funcsym.comptimefunc then
    return false
  end
  local args = collect_args(node, argnodes, calleeobjnode)
  if not check_args(args, calleesym.name) then
    set_pending(context, node, true)
    return true
  end
  local results = comptime.evaluate(context, calleesym, args, node)
  if not results then -- the callee body is not fully resolved yet
    set_pending(context, node, true)
    return true
  end
  set_pending(context, node, false)
  inject_results(context, node, results, calleetype.rettypes, calleesym.name, opts)
  return true
end

-- Raises an error for compile-time calls that never resolved, called once the analysis ends.
function comptime.check_pending(context)
  local pendings = context.comptimepending
  if not pendings then return end
  for node in pairs(pendings) do
    node:raisef("in call of builtin 'comptime': the call could not be resolved at compile time \z
      (the function is not defined or has unresolved types)")
  end
end

return comptime
