--[[
Lua generator.

Translates an analyzed Nelua AST to Lua 5.4 source. Untyped code (`any`) maps one to one;
typed code keeps the C semantics of the types through the helpers in `nelua.luabuiltins`:
integers wrap at the width of their type, `float32` values are rounded, unsigned 64-bit
integers compare and divide as unsigned, `//`, `%`, `///`, `%%%` and the shifts follow Nelua,
records and arrays are tables copied on assignment and compared structurally.

Besides `--generator lua`, the compile-time evaluator (`nelua.comptime`) runs this generator
on single functions, hooking `LuaContext:funcref` to name the functions they call.
]]

local VisitorContext = require 'nelua.visitorcontext'
local class = require 'nelua.utils.class'
local pegger = require 'nelua.utils.pegger'
local traits = require 'nelua.utils.traits'
local luadefs = require 'nelua.luadefs'
local luabuiltins = require 'nelua.luabuiltins'
local config = require 'nelua.configer'.get()
local Emitter = require 'nelua.emitter'
local bn = require 'nelua.utils.bn'
local typedefs = require 'nelua.typedefs'
local primtypes = typedefs.primtypes

local LuaContext = class(VisitorContext)

function LuaContext:_init(visitors)
  assert(self.context, 'initialization from a promotion expected')
  self.visitors = visitors
  self.luabuiltins = {}
  self.luaversion = config.lua_version
end

-- Marks helper `name` as used so the prelude defines it, returns its name.
function LuaContext:ensure_builtin(name)
  self.luabuiltins[name] = true
  return name
end

--[[
Returns the Lua expression naming the Nelua function `symbol`,
or nil to reference it by its source name (the default).
The compile-time evaluator overrides this.
]]
function LuaContext.funcref() --luacov:disable
  return nil
end --luacov:enable

local visitors = {}

-- Checks whether `type` is a 64-bit unsigned integral.
local function is_u64(type)
  return type and type.is_integral and type.is_unsigned and type.bitsize == 64
end

-- Helper wrapping a value into `type`, nil when Lua's native 64-bit integers or floats fit.
local function wrapper_name(type)
  if not type then return nil end
  if type.is_integral and type.bitsize and type.bitsize < 64 then
    return 'nelua_wrap_'..(type.is_unsigned and 'u' or 'i')..type.bitsize
  elseif type.is_float32 then
    return 'nelua_fround'
  end
end

local function quote_string(value)
  if value:find('"') and not value:find("'") then
    return pegger.single_quote_lua_string(value)
  else
    return pegger.double_quote_lua_string(value)
  end
end

-- Emits the compile-time value of `attr`, returns false when it has none or cannot be emitted.
local function emit_literal(_, emitter, attr)
  local type, value = attr.type, attr.value
  if not type or value == nil then return false end
  if type.is_integral then
    if not bn.isintegral(value) then value = bn.trunc(value) end
    value = type:wrap_value(value)
    if bn.isneg(value) then
      if primtypes.int64:is_inrange(value) and value == primtypes.int64.min then
        emitter:add('math.mininteger')
      else
        emitter:add('(', bn.todecint(value), ')')
      end
    elseif not primtypes.int64:is_inrange(value) then -- wraps into a negative Lua integer
      emitter:add('0x', bn.tohexint(value, 64))
    else
      emitter:add(bn.todecint(value))
    end
  elseif type.is_float then
    local n = bn.tonumber(value)
    if n ~= n then
      emitter:add('(0.0/0.0)')
    elseif n == math.huge then
      emitter:add('math.huge')
    elseif n == -math.huge then
      emitter:add('(-math.huge)')
    else
      local s = string.format('%.17g', n)
      if not s:find('[%.eEn]') then s = s..'.0' end
      if n < 0 then s = '('..s..')' end
      emitter:add(s)
    end
  elseif type.is_boolean then
    emitter:add(tostring(not not value))
  elseif type.is_string and traits.is_string(value) then
    emitter:add(quote_string(value))
  elseif type.is_nilptr or type.is_niltype then
    emitter:add('nil')
  else
    return false
  end
  return true
end

local emit_zero

-- Emits the zero value of `type`.
emit_zero = function(context, emitter, type)
  if not type then
    emitter:add('nil')
  elseif type.is_integral then
    emitter:add('0')
  elseif type.is_float then
    emitter:add('0.0')
  elseif type.is_boolean then
    emitter:add('false')
  elseif type.is_string then
    emitter:add('""')
  elseif type.is_array then
    local subtype = type.subtype
    emitter:add(context:ensure_builtin('nelua_array'), '(', type.length, ', ')
    if subtype.is_aggregate then
      emitter:add('function() return ')
      emit_zero(context, emitter, subtype)
      emitter:add(' end')
    else
      emit_zero(context, emitter, subtype)
    end
    emitter:add(')')
  elseif type.is_record then
    emitter:add('{')
    for i,field in ipairs(type.fields) do
      if i > 1 then emitter:add(', ') end
      emitter:add(field.name, ' = ')
      emit_zero(context, emitter, field.type)
    end
    emitter:add('}')
  elseif type.is_table then
    emitter:add('{}')
  else
    emitter:add('nil')
  end
end

-- Emits `valnode` as a value of `type`, copying aggregates read from an lvalue.
local function emit_value(context, emitter, type, valnode)
  local vattr = valnode.attr
  if type and type.is_aggregate and vattr.lvalue and not vattr.comptime then
    emitter:add(context:ensure_builtin('nelua_copy'), '(', valnode, ')')
  else
    emitter:add(valnode)
  end
end

-- Emits `valnode` converted to `desttype` following Nelua's implicit conversions.
local function emit_converted(context, emitter, desttype, valnode)
  local vattr = valnode.attr
  local vtype = vattr.type
  if not desttype or not vtype or desttype == vtype or vattr.comptime then
    emit_value(context, emitter, desttype or vtype, valnode)
  elseif desttype.is_integral and vtype.is_scalar then
    local wrap = wrapper_name(desttype)
    if vtype.is_integral and desttype:is_type_inrange(vtype) then
      wrap = nil
    end
    if wrap then emitter:add(context:ensure_builtin(wrap), '(') end
    if vtype.is_float then
      emitter:add(context:ensure_builtin('nelua_toint'), '(', valnode, ')')
    else
      emitter:add(valnode)
    end
    if wrap then emitter:add(')') end
  elseif desttype.is_float and vtype.is_scalar then
    local fround = desttype.is_float32 and not vtype.is_float32
    if fround then emitter:add(context:ensure_builtin('nelua_fround'), '(') end
    if is_u64(vtype) then
      emitter:add(context:ensure_builtin('nelua_utof'), '(', valnode, ')')
    elseif vtype.is_integral then
      emitter:add('(', valnode, ' + 0.0)')
    else
      emitter:add(valnode)
    end
    if fround then emitter:add(')') end
  else
    emit_value(context, emitter, desttype, valnode)
  end
end

-- Emits call arguments `argnodes` converted to the callee argument types (offset by `off`).
local function emit_args(context, emitter, argnodes, calleetype, off)
  local argtypes = calleetype and calleetype.is_procedure and calleetype.argtypes
  if not argtypes then
    emitter:add_list(argnodes, ', ')
    return
  end
  for i=1,#argnodes do
    if i > 1 then emitter:add(', ') end
    emit_converted(context, emitter, argtypes[i+off], argnodes[i])
  end
end

function visitors.Number(_, node, emitter)
  local numstr, literal = node[1], node[2]
  node:assertraisef(literal == nil, 'literals are not supported in lua')
  local attr = node.attr
  local value, base, type = attr.value, attr.base, attr.type
  if base == 2 then
    if bn.isintegral(value) and not bn.isneg(value) then
      emitter:add('0x'..bn.tohexint(value))
    else
      emitter:add(bn.todecsci(value))
    end
  elseif base == 16 and not bn.isintegral(value) then
    emitter:add(bn.todecsci(value))
  elseif type and type.is_integral and not primtypes.int64:is_inrange(value) then
    emitter:add('0x', bn.tohexint(type:wrap_value(value), 64)) -- wraps into a Lua integer
  elseif type and type.is_float and not numstr:find('[%.eEpPxX]') then
    emitter:add(numstr, '.0') -- keep the float subtype
  else
    emitter:add(numstr)
  end
end

function visitors.String(_, node, emitter)
  local value, literal = node[1], node[2]
  node:assertraisef(literal == nil, 'literals are not supported in lua')
  emitter:add(quote_string(value))
end

function visitors.Boolean(_, node, emitter)
  local value = node[1]
  emitter:add(value)
end

function visitors.Nil(_, _, emitter)
  emitter:add('nil')
end

function visitors.Nilptr(_, _, emitter)
  emitter:add('nil')
end

function visitors.Varargs(_, _, emitter)
  emitter:add('...')
end

function visitors.InitList(context, node, emitter)
  local childnodes = node
  local type = node.attr.type
  if type and type.is_array then
    local n, subtype = type.length, type.subtype
    if #childnodes == 0 then
      emit_zero(context, emitter, type)
      return
    end
    local full = #childnodes == n
    if not full then
      emitter:add(context:ensure_builtin('nelua_array'), '(', n, ', ')
      if subtype.is_aggregate then
        emitter:add('function() return ')
        emit_zero(context, emitter, subtype)
        emitter:add(' end')
      else
        emit_zero(context, emitter, subtype)
      end
      emitter:add(', ')
    end
    emitter:add('{[0] = ')
    for i=1,#childnodes do
      if i > 1 then emitter:add(', ') end
      emit_converted(context, emitter, subtype, childnodes[i])
    end
    emitter:add('}')
    if not full then emitter:add(')') end
  elseif type and type.is_record then
    local values = {}
    local lastfieldindex = 0
    for i=1,#childnodes do
      local childnode = childnodes[i]
      local field
      if childnode.is_Pair then
        field = type.fields[childnode[1]]
        values[field.index] = childnode[2]
      else
        field = type.fields[lastfieldindex + 1]
        values[field.index] = childnode
      end
      lastfieldindex = field.index
    end
    emitter:add('{')
    for i,field in ipairs(type.fields) do
      if i > 1 then emitter:add(', ') end
      emitter:add(field.name, ' = ')
      local valnode = values[field.index]
      if valnode then
        emit_converted(context, emitter, field.type, valnode)
      else
        emit_zero(context, emitter, field.type)
      end
    end
    emitter:add('}')
  else
    emitter:add('{')
    emitter:add_list(childnodes, ', ')
    emitter:add('}')
  end
end

function visitors.Pair(_, node, emitter)
  local field, value = node[1], node[2]
  if type(field) == 'string' then
    emitter:add(field)
  else
    emitter:add('[', field, ']')
  end
  emitter:add(' = ', value)
end

-- TODO: Annotation

-- Checks whether `attr` is a symbol of a Nelua function.
local function is_funcsym(attr)
  local type = attr.type
  return attr._symbol and type and type.is_procedure and not attr.builtin
end

function visitors.Id(context, node, emitter)
  local attr = node.attr
  if attr.comptime and emit_literal(context, emitter, attr) then return end
  if is_funcsym(attr) then
    local ref = context:funcref(attr)
    if ref then
      emitter:add(ref)
      return
    end
  end
  local name = node[1]
  emitter:add(name)
end
function visitors.Paren(_, node, emitter)
  local what = node[1]
  emitter:add('(', what, ')')
end
function visitors.Type() end
function visitors.FuncType() end
function visitors.ArrayType() end
function visitors.PointerType() end
function visitors.RecordType() end
function visitors.EnumType() end
function visitors.UnionType() end
function visitors.VarargsType(_, _, emitter)
  emitter:add('...')
end
function visitors.IdDecl(_, node, emitter)
  local name = node[1]
  emitter:add(name)
end

function visitors.DotIndex(context, node, emitter)
  local name, obj = node[1], node[2]
  local attr = node.attr
  if attr.comptime and emit_literal(context, emitter, attr) then return end
  local objtype = obj.attr.type
  if objtype and objtype.is_type and is_funcsym(attr) then
    local ref = context:funcref(attr)
    if ref then
      emitter:add(ref)
      return
    end
  end
  emitter:add(obj, '.', name)
end

function visitors.ColonIndex(_, node, emitter)
  local name, obj = node[1], node[2]
  emitter:add(obj, ':', name)
end

function visitors.KeyIndex(_, node, emitter)
  local index, obj = node[1], node[2]
  emitter:add(obj, '[', index, ']')
end

function visitors.Call(context, node, emitter)
  local args, callee = node[1], node[2]
  local attr = node.attr
  local isblockcall = context:get_visiting_node(1).is_Block
  if isblockcall then emitter:add_indent() end
  local calleetype = attr.calleetype
  if calleetype and calleetype.is_type then -- type cast or zero initializer
    local argnode = args[1]
    if not argnode then
      emit_zero(context, emitter, attr.type)
    elseif not (attr.comptime and emit_literal(context, emitter, attr)) then
      emit_converted(context, emitter, attr.type, argnode)
    end
  else
    local calleesym = attr.calleesym
    local ref = calleesym and is_funcsym(calleesym) and context:funcref(calleesym)
    if ref then
      emitter:add(ref)
    else
      emitter:add(callee)
    end
    emitter:add('(')
    emit_args(context, emitter, args, calleetype, 0)
    emitter:add(')')
  end
  if isblockcall then emitter:add_ln() end
end

function visitors.CallMethod(context, node, emitter)
  local name, args, callee = node[1], node[2], node[3]
  local attr = node.attr
  local isblockcall = context:get_visiting_node(1).is_Block
  if isblockcall then emitter:add_indent() end
  local calleesym = attr.calleesym
  local ref = calleesym and is_funcsym(calleesym) and context:funcref(calleesym)
  if ref then -- call the Nelua function with the object as first argument
    local calleetype = attr.calleetype
    emitter:add(ref, '(')
    emit_converted(context, emitter, calleetype and calleetype.argtypes[1], callee)
    if #args > 0 then emitter:add(', ') end
    emit_args(context, emitter, args, calleetype, 1)
    emitter:add(')')
  else
    emitter:add(callee, ':', name, '(', args, ')')
  end
  if isblockcall then emitter:add_ln() end
end

function visitors.Block(context, node, emitter)
  local stats = node
  emitter:inc_indent()
  context:push_forked_scope(node)
  emitter:add_list(stats, '')
  context:pop_scope()
  emitter:dec_indent()
end

function visitors.Return(context, node, emitter)
  local retnodes = node
  emitter:add_indent("return")
  if #retnodes > 0 then
    emitter:add(' ')
    local rettypes = context.state.rettypes
    for i=1,#retnodes do
      if i > 1 then emitter:add(', ') end
      emit_converted(context, emitter, rettypes and rettypes[i], retnodes[i])
    end
  end
  emitter:add_ln()
end

function visitors.In(context, node, emitter)
  local retnode = node[1]
  emitter:add_indent("return ")
  emit_value(context, emitter, retnode.attr.type, retnode)
  emitter:add_ln()
end

function visitors.DoExpr(context, node, emitter)
  local block = node[1]
  emitter:add_ln('(function()')
  context:push_forked_state{loopinfo = false}
  emitter:add(block)
  context:pop_state()
  emitter:add_indent('end)()')
end

function visitors.If(_, node, emitter)
  local ifpairs, elsenode = node[1], node[2]
  for i=1,#ifpairs,2 do
    local condnode, blocknode = ifpairs[i], ifpairs[i+1]
    if i == 1 then
      emitter:add_indent("if ")
      emitter:add(condnode)
      emitter:add_ln(" then")
    else
      emitter:add_indent("elseif ")
      emitter:add(condnode)
      emitter:add_ln(" then")
    end
    emitter:add(blocknode)
  end
  if elsenode then
    emitter:add_indent_ln("else")
    emitter:add(elsenode)
  end
  emitter:add_indent_ln("end")
end

function visitors.Switch(context, node, emitter)
  local val, casepairs, elsenode = node[1], node[2], node[3]
  local varname = '__switchval' .. node.pos
  emitter:add_indent_ln("local ", varname, " = ", val)
  node:assertraisef(#casepairs > 0, "switch must have case parts")
  context:push_forked_scope(node)
  for i=1,#casepairs,2 do
    local caseexprs, caseblock = casepairs[i], casepairs[i+1]
    if i == 1 then
      emitter:add_indent('if ')
    else
      emitter:add_indent('elseif ')
    end
    if #caseexprs > 1 then emitter:add('(') end
    for j=1,#caseexprs do
      if j > 1 then emitter:add(' or ') end
      emitter:add(varname, ' == ', caseexprs[j])
    end
    if #caseexprs > 1 then emitter:add(')') end
    emitter:add_ln(' then')
    emitter:add(caseblock)
  end
  if elsenode then
    emitter:add_indent_ln('else')
    emitter:add(elsenode)
  end
  context:pop_scope(node)
  emitter:add_indent_ln("end")
end

function visitors.Do(_, node, emitter)
  local block = node[1]
  emitter:add_indent_ln("do")
  emitter:add(block)
  emitter:add_indent_ln("end")
end

-- Enters a loop, returns its info table (`continue` records the label it needs there).
local function push_loop(context, node)
  local info = {pos = node.pos}
  context:push_forked_state{loopinfo = info}
  return info
end

-- Emits a loop body followed by the `continue` label when one was used.
local function emit_loop_body(_, emitter, blocknode, info)
  emitter:add(blocknode)
  if info.continuelabel then
    emitter:inc_indent()
    emitter:add_indent_ln('::', info.continuelabel, '::')
    emitter:dec_indent()
  end
end

function visitors.While(context, node, emitter)
  local cond, block = node[1], node[2]
  emitter:add_indent_ln("while ", cond, ' do')
  context:push_forked_scope(node)
  local info = push_loop(context, node)
  emit_loop_body(context, emitter, block, info)
  context:pop_state()
  context:pop_scope()
  emitter:add_indent_ln("end")
end

function visitors.Repeat(context, node, emitter)
  local block, cond = node[1], node[2]
  emitter:add_indent_ln("repeat")
  context:push_forked_scope(node)
  local info = push_loop(context, node)
  emit_loop_body(context, emitter, block, info)
  emitter:add_indent_ln('until ', cond)
  context:pop_state()
  context:pop_scope()
end

local for_compare_ops = {
  le = '<=', ge = '>=',
  lt = '<',  gt = '>',
  ne = '~=', eq = '==',
}

function visitors.ForNum(context, node, emitter)
  local itvar, begval, comp, endval, incrval, block =
        node[1], node[2], node[3], node[4], node[5], node[6]
  local attr = node.attr
  local compop = attr.compop or comp or 'le'
  local ittype = itvar.attr.type
  local simple = (compop == 'le' or compop == 'ge') and (attr.fixedstep or not incrval)
  if simple then -- a Lua numeric `for` handles the sign of a constant step
    context:push_forked_scope(node)
    local info = push_loop(context, node)
    emitter:add_indent("for ", itvar, '=')
    emit_converted(context, emitter, ittype, begval)
    emitter:add(',')
    emit_converted(context, emitter, ittype, endval)
    if incrval then
      emitter:add(',')
      emit_converted(context, emitter, ittype, incrval)
    end
    emitter:add_ln(' do')
    emit_loop_body(context, emitter, block, info)
    emitter:add_indent_ln("end")
    context:pop_state()
    context:pop_scope()
  else -- other comparisons or a runtime step, as a `while`
    emitter:add_indent_ln('do')
    emitter:inc_indent()
    emitter:add_indent('local __it, __end, __step = ')
    emit_converted(context, emitter, ittype, begval)
    emitter:add(', ')
    emit_converted(context, emitter, ittype, endval)
    emitter:add(', ')
    if incrval then
      emit_converted(context, emitter, ittype, incrval)
    else
      emitter:add('1')
    end
    emitter:add_ln()
    if compop == 'le' or compop == 'ge' then -- runtime step decides the comparison
      emitter:add_indent_ln('while (__step >= 0 and __it <= __end) or (__step < 0 and __it >= __end) do')
    else
      emitter:add_indent_ln('while __it ', for_compare_ops[compop], ' __end do')
    end
    context:push_forked_scope(node)
    local info = push_loop(context, node)
    emitter:inc_indent()
    emitter:add_indent_ln('local ', itvar, ' = __it')
    emitter:add_indent_ln('do')
    emitter:add(block)
    emitter:add_indent_ln('end')
    if info.continuelabel then
      emitter:add_indent_ln('::', info.continuelabel, '::')
    end
    emitter:add_indent('__it = ')
    if wrapper_name(ittype) then
      emitter:add_ln(context:ensure_builtin(wrapper_name(ittype)), '(__it + __step)')
    else
      emitter:add_ln('__it + __step')
    end
    emitter:dec_indent()
    context:pop_state()
    context:pop_scope()
    emitter:add_indent_ln('end')
    emitter:dec_indent()
    emitter:add_indent_ln('end')
  end
end

function visitors.ForIn(context, node, emitter)
  local itvars, iterator, block = node[1], node[2], node[3]
  context:push_forked_scope(node)
  local info = push_loop(context, node)
  emitter:add_indent("for ", itvars)
  emitter:add_ln(' in ', iterator, ' do')
  emit_loop_body(context, emitter, block, info)
  emitter:add_indent_ln("end")
  context:pop_state()
  context:pop_scope()
end

function visitors.Break(_, _, emitter)
  emitter:add_indent_ln('break')
end

function visitors.Continue(context, node, emitter)
  local info = context.state.loopinfo
  node:assertraisef(info, '`continue` statement is not inside a loop')
  local label = info.continuelabel
  if not label then
    label = '__continue'..info.pos
    info.continuelabel = label
  end
  emitter:add_indent_ln('goto ', label)
end

function visitors.Label(_, node, emitter)
  local name = node[1]
  emitter:add_indent_ln('::', name, '::')
end

function visitors.Goto(_, node, emitter)
  local labelname = node[1]
  emitter:add_indent_ln('goto ', labelname)
end

function visitors.VarDecl(context, node, emitter)
  local varscope, varnodes, valnodes = node[1], node[2], node[3]
  local alltypes = true
  for _,varnode in ipairs(varnodes) do
    local vartype = varnode.attr.type
    if not (vartype and vartype.is_type) then alltypes = false break end
  end
  if alltypes then return end -- type declarations have no runtime counterpart
  local is_local = (varscope == 'local') or not context.scope.is_topscope
  emitter:add_indent()
  if is_local then
    emitter:add('local ')
  end
  emitter:add(varnodes)
  local doassigns = valnodes or not is_local
  for _,varnode in ipairs(varnodes) do
    local vartype = varnode.attr.type
    if vartype and not vartype.is_any then
      doassigns = true
      break
    end
  end
  if doassigns then
    emitter:add(' = ')
    local istart = 1
    if valnodes then
      local nvals = #valnodes
      local lastvalnode = valnodes[nvals]
      for i=1,nvals do
        if i > 1 then emitter:add(', ') end
        local varnode = varnodes[i]
        emit_converted(context, emitter, varnode and varnode.attr.type, valnodes[i])
      end
      istart = nvals+1
      if lastvalnode and lastvalnode.is_call and nvals < #varnodes then
        istart = #varnodes+1 -- the call fills the remaining variables
      end
    end
    for i=istart,#varnodes do
      if i > 1 then emitter:add(', ') end
      local varnode = varnodes[i]
      local vartype = varnode.attr.type
      if vartype and not vartype.is_any then
        emit_zero(context, emitter, vartype)
      else
        emitter:add('nil')
      end
    end
  end
  emitter:add_ln()
end

function visitors.Assign(context, node, emitter)
  local varnodes, valnodes = node[1], node[2]
  emitter:add_indent()
  emitter:add_list(varnodes, ', ')
  emitter:add(' = ')
  for i=1,#valnodes do
    if i > 1 then emitter:add(', ') end
    local varnode = varnodes[i]
    emit_converted(context, emitter, varnode and varnode.attr.type, valnodes[i])
  end
  emitter:add_ln()
end

-- Emits `(args)` and the body of a function, `selfname` is prepended to the arguments.
local function emit_function_body(context, emitter, node, argnodes, blocknode, functype, selfname)
  emitter:add('(')
  if selfname then
    emitter:add(selfname)
    if #argnodes > 0 then emitter:add(', ') end
  end
  emitter:add(argnodes)
  emitter:add_ln(')')
  local rettypes = functype and functype.is_procedure and functype.rettypes or false
  context:push_forked_state{rettypes = rettypes, loopinfo = false}
  context:push_forked_scope(node)
  emitter:add(blocknode)
  context:pop_scope()
  context:pop_state()
  emitter:add_indent('end')
end

function visitors.FuncDef(context, node, emitter)
  local varscope, name, args, block = node[1], node[2], node[3], node[6]
  emitter:add_indent()
  if varscope == 'local' then
    emitter:add('local ')
  end
  emitter:add('function ', name)
  emit_function_body(context, emitter, node, args, block, node.attr.type)
  emitter:add_ln()
end

function visitors.Function(context, node, emitter)
  local args, block = node[1], node[4]
  if #block == 0 then
    emitter:add('function(', args, ') end')
  else
    emitter:add('function')
    emit_function_body(context, emitter, node, args, block, node.attr.type)
  end
end

-- operators
local wrapping_ops = {
  add = true, sub = true, mul = true, div = true, idiv = true, mod = true, pow = true,
  shl = true, band = true, bor = true, bxor = true, unm = true, bnot = true,
}

function visitors.UnaryOp(context, node, emitter)
  local opname, argnode = node[1], node[2]
  local attr = node.attr
  if attr.comptime and emit_literal(context, emitter, attr) then return end
  if opname == 'ref' or opname == 'deref' then -- aggregates are already references
    emitter:add(argnode)
    return
  end
  local op = node:assertraisef(luadefs.unary_ops[opname], 'unary operator "%s" not found', opname)
  if context.luaversion == '5.1' then
    local fallop = luadefs.lua51_unary_ops[opname]
    if fallop then
      emitter:add(fallop.func, '(', argnode, ')')
      return
    end
  end
  argnode.inoperator = true
  local wrap = wrapping_ops[opname] and wrapper_name(attr.type)
  if wrap then
    emitter:add(context:ensure_builtin(wrap), '(', op, argnode, ')')
    return
  end
  local surround = node.attr.inoperator
  if surround then emitter:add('(') end
  emitter:add(op, argnode)
  if surround then emitter:add(')') end
end

local compare_ops = {lt = true, le = true, gt = true, ge = true}

function visitors.BinaryOp(context, node, emitter)
  local lnode, opname, rnode = node[1], node[2], node[3]
  local attr = node.attr
  if attr.comptime and emit_literal(context, emitter, attr) then return end
  local op = node:assertraisef(luadefs.binary_ops[opname], 'binary operator "%s" not found', opname)
  if context.luaversion == '5.1' then
    local fallop = luadefs.lua51_binary_ops[opname]
    if fallop then
      if traits.is_function(fallop.func) then
        fallop.func(context, node, emitter, lnode, rnode)
      else
        emitter:add(fallop.func, '(', lnode, ', ', rnode, ')')
      end
      return
    end
  end
  local type = attr.type
  local ltype, rtype = lnode.attr.type, rnode.attr.type
  lnode.inoperator = true
  rnode.inoperator = true
  local surround = node.inoperator
  if surround then emitter:add('(') end
  if (opname == 'eq' or opname == 'ne') and ltype and ltype.is_aggregate then
    if opname == 'ne' then emitter:add('not ') end
    emitter:add(context:ensure_builtin('nelua_eq'), '(', lnode, ', ', rnode, ')')
  elseif compare_ops[opname] and (is_u64(ltype) or is_u64(rtype)) and
         ltype.is_integral and rtype.is_integral then
    if opname == 'lt' then
      emitter:add(context:ensure_builtin('nelua_ult'), '(', lnode, ', ', rnode, ')')
    elseif opname == 'le' then
      emitter:add(context:ensure_builtin('nelua_ule'), '(', lnode, ', ', rnode, ')')
    elseif opname == 'gt' then
      emitter:add(context:ensure_builtin('nelua_ult'), '(', rnode, ', ', lnode, ')')
    else
      emitter:add(context:ensure_builtin('nelua_ule'), '(', rnode, ', ', lnode, ')')
    end
  elseif (opname == 'idiv' or opname == 'mod') and is_u64(type) then
    local builtin = opname == 'idiv' and 'nelua_udiv' or 'nelua_umod'
    emitter:add(context:ensure_builtin(builtin), '(', lnode, ', ', rnode, ')')
  elseif opname == 'tdiv' or opname == 'tmod' then
    local builtin = opname == 'tdiv' and 'nelua_tdiv' or 'nelua_tmod'
    local wrap = wrapper_name(type)
    if wrap then emitter:add(context:ensure_builtin(wrap), '(') end
    emitter:add(context:ensure_builtin(builtin), '(', lnode, ', ', rnode, ')')
    if wrap then emitter:add(')') end
  elseif opname == 'asr' then
    local wrap = wrapper_name(type)
    if wrap then emitter:add(context:ensure_builtin(wrap), '(') end
    emitter:add(context:ensure_builtin('nelua_asr'), '(', lnode, ', ', rnode, ')')
    if wrap then emitter:add(')') end
  elseif opname == 'shr' and type and type.is_integral and type.is_signed and type.bitsize < 64 then
    -- logical shift on the bits of the type
    local mask = string.format('0x%x', (1 << type.bitsize) - 1)
    emitter:add(context:ensure_builtin(wrapper_name(type)), '((', lnode, ' & ', mask, ') >> ', rnode, ')')
  elseif (opname == 'div' or opname == 'pow') and (is_u64(ltype) or is_u64(rtype)) then
    local wrap = wrapper_name(type)
    if wrap then emitter:add(context:ensure_builtin(wrap), '(') end
    if is_u64(ltype) then
      emitter:add(context:ensure_builtin('nelua_utof'), '(', lnode, ')')
    else
      emitter:add(lnode)
    end
    emitter:add(' ', op, ' ')
    if is_u64(rtype) then
      emitter:add(context:ensure_builtin('nelua_utof'), '(', rnode, ')')
    else
      emitter:add(rnode)
    end
    if wrap then emitter:add(')') end
  else
    local wrap = wrapping_ops[opname] and wrapper_name(type)
    if wrap then
      emitter:add(context:ensure_builtin(wrap), '(', lnode, ' ', op, ' ', rnode, ')')
    else
      emitter:add(lnode, ' ', op, ' ', rnode)
    end
  end
  if surround then emitter:add(')') end
end

local generator = {}

generator.visitors = visitors
generator.LuaContext = LuaContext

-- Emits a Nelua function definition node `node` as an anonymous Lua function expression.
function generator.emit_function(context, emitter, node)
  local varnode, argnodes, blocknode = node[2], node[3], node[6]
  local selfname = varnode.is_ColonIndex and 'self' or nil
  emitter:add('function')
  emit_function_body(context, emitter, node, argnodes, blocknode, node.attr.type, selfname)
end

function generator.generate(context)
  context:promote(LuaContext, visitors)
  local emitter = Emitter(context, -1)
  context.emitter = emitter
  context:traverse_node(context.ast, emitter)
  local code = emitter:generate()
  if next(context.luabuiltins) then
    code = luabuiltins.prelude(context.luabuiltins)..'\n'..code
  end
  return code
end

generator.compiler = require('nelua.luacompiler')

return generator
