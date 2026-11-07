--[[
Ownership checker for `<owned>` records.

Owned values (records annotated with `<owned>`, records holding an owned field and arrays of
owned values) are affine: an lvalue of an owned type may not be copied without `move`, and a
variable that was moved may not be read until it is assigned again.

The moved state is `context.ownstate`, a table mapping a symbol to `{state=, node=}` where
`state` is 'moved' (moved on every path) or 'maybe' (moved on some path) and `node` is the
`move` that caused it. The analyzer visitors save, fork, merge and restore it as the AST is
traversed, so the check is flow sensitive within one function body: branches of `if` and
`switch` are merged, loop bodies are merged with the zero-iteration path, a `return`,
`break`, `continue` or `goto` ending a branch does not leak its moves outward, and function
bodies start with no moved variables (there is no inter-procedural analysis).

`context.ownloops` is the stack of loops being traversed, used to report a read of a
variable that is moved by the end of the loop body (so it is read moved in the next iteration).
]]

local aster = require 'nelua.aster'

local ownership = {}

local function copystate(state)
  local copy = {}
  if state then
    for symbol, entry in pairs(state) do
      copy[symbol] = entry
    end
  end
  return copy
end

-- Returns a copy of the moved state, meant to be restored with `restore` before a block is
-- traversed again (the analyzer traverses blocks repeatedly until every type is resolved).
function ownership.snapshot(context)
  return copystate(context.ownstate)
end

function ownership.restore(context, snapshot)
  context.ownstate = copystate(snapshot)
end

-- A function body starts with nothing moved and its moves never leak outward.
function ownership.enter_function(context)
  local saved = {state = context.ownstate, loops = context.ownloops}
  ownership.reset(context)
  return saved
end

function ownership.reset(context)
  context.ownstate = {}
  context.ownloops = nil
end

function ownership.leave_function(context, saved)
  context.ownstate = saved.state
  context.ownloops = saved.loops
end

-- Merges the states reaching a join point: a symbol is 'moved' when every path moved it,
-- 'maybe' when only some did (or some path moved it only maybe).
local function merge_states(states)
  local n = #states
  local result = {}
  for i=1,n do
    for symbol, entry in pairs(states[i]) do
      if not result[symbol] then
        local count, allmoved = 0, true
        for j=1,n do
          local other = states[j][symbol]
          if other then
            count = count + 1
            if other.state ~= 'moved' then
              allmoved = false
            end
          end
        end
        result[symbol] = {state = (count == n and allmoved) and 'moved' or 'maybe', node = entry.node}
      end
    end
  end
  return result
end
ownership.merge_states = merge_states

-- Whether the flow never falls out of the end of the block.
local function block_exits(blocknode)
  local laststat = blocknode[#blocknode]
  if not laststat then return false end
  if laststat.is_Return or laststat.is_Break or laststat.is_Continue or
     laststat.is_Goto or laststat.is_In then
    return true
  elseif laststat.is_Do then
    return block_exits(laststat[1])
  elseif laststat.is_If then
    local ifpairs, elseblock = laststat[1], laststat[2]
    if not elseblock then return false end
    for i=2,#ifpairs,2 do
      if not block_exits(ifpairs[i]) then return false end
    end
    return block_exits(elseblock)
  elseif laststat.is_call then
    local calleesym = laststat.attr.calleesym
    return (calleesym and calleesym.noreturn) and true or false
  end
  return false
end
ownership.block_exits = block_exits

--[[
Branching (`if`, `switch`): `branches_begin` records the state before the construct,
`branch_begin` starts a branch from it (or from `instate`), `branch_end` collects the branch
state unless the branch exits, and `branches_end` merges the collected states, including the
state before the construct when `fallthrough` is true (no `else`).
]]
function ownership.branches_begin(context)
  return {before = ownership.snapshot(context), outs = {}}
end

function ownership.branch_begin(context, branches, instate)
  context.ownstate = copystate(instate or branches.before)
end

function ownership.branch_end(context, branches, blocknode)
  local out = context.ownstate
  if not block_exits(blocknode) then
    local outs = branches.outs
    outs[#outs+1] = out
  end
  return out
end

function ownership.branches_end(context, branches, fallthrough)
  local outs = branches.outs
  if fallthrough then
    outs[#outs+1] = branches.before
  end
  if #outs == 0 then
    context.ownstate = copystate(branches.before)
  else
    context.ownstate = merge_states(outs)
  end
end

local function raise_moved(node, symbol, entry, suffix)
  local lineno = entry.node:location().lineno or '?'
  if entry.state == 'moved' then
    node:raisef("variable '%s' of owned type '%s' was moved on line %s%s, assign it again before using it",
      symbol.name, symbol.type, lineno, suffix)
  else
    node:raisef("variable '%s' of owned type '%s' may have been moved on line %s%s \z
      (the move is inside a branch, loop or switch case), assign it again before using it",
      symbol.name, symbol.type, lineno, suffix)
  end
end

--[[
Loops: `loop_begin` records the state before the loop and pushes the loop,
`loop_end` pops it and merges the paths out of the loop. `kind` is 'maybe' when the body
may run zero times (`while`, `for`), 'once' when it runs at least once (`repeat`) and
'infinite' when the loop leaves only through `break` (`while true`).
A read of an outer variable inside the body that is moved when the body ends
(or `continue`s) is reported, because the next iteration would read it moved.
]]
function ownership.loop_begin(context)
  local loops = context.ownloops
  if not loops then
    loops = {}
    context.ownloops = loops
  end
  local loop = {
    before = ownership.snapshot(context),
    scope = context.scope,
    breaks = {}, continues = {},
    reads = {}, assigned = {},
  }
  loops[#loops+1] = loop
  return loop
end

function ownership.loop_end(context, loop, bodynode, kind)
  local loops = context.ownloops
  assert(loops[#loops] == loop)
  loops[#loops] = nil
  local bodyexits = block_exits(bodynode)
  local bodyout = context.ownstate
  -- the state a second iteration starts with
  local nextiter = {}
  if not bodyexits then nextiter[#nextiter+1] = bodyout end
  for i=1,#loop.continues do nextiter[#nextiter+1] = loop.continues[i] end
  if #nextiter > 0 then
    local nextstate = merge_states(nextiter)
    for symbol, readnode in pairs(loop.reads) do
      local entry = nextstate[symbol]
      if entry then
        raise_moved(readnode, symbol, entry, " in a previous iteration of the loop")
      end
    end
  end
  -- the states leaving the loop
  local outs = {}
  if kind == 'maybe' then outs[#outs+1] = loop.before end
  if kind ~= 'infinite' and not bodyexits then outs[#outs+1] = bodyout end
  for i=1,#loop.breaks do outs[#outs+1] = loop.breaks[i] end
  if #outs == 0 then
    context.ownstate = copystate(loop.before)
  else
    context.ownstate = merge_states(outs)
  end
end

local function record_loop_exit(context, field)
  local loops = context.ownloops
  local loop = loops and loops[#loops]
  if loop then
    local list = loop[field]
    list[#list+1] = copystate(context.ownstate)
  end
end

function ownership.record_break(context)
  record_loop_exit(context, 'breaks')
end

function ownership.record_continue(context)
  record_loop_exit(context, 'continues')
end

-- Whether `symbol` is declared inside the loop (between the current scope and the loop scope).
local function declared_inside_loop(context, symbol, loop)
  local scope = context.scope
  while scope and scope ~= loop.scope do
    if scope == symbol.scope then return true end
    scope = scope.parent
  end
  return false
end

-- Called for every identifier read; `node` is the `Id` node resolved to `symbol`.
function ownership.check_read(context, symbol, node)
  if node == context.ownassigntarget then return end
  local state = context.ownstate
  if state then
    local entry = state[symbol]
    if entry then
      raise_moved(node, symbol, entry, '')
    end
  end
  local loops = context.ownloops
  if loops and symbol.type and symbol.type.is_owned then
    for i=#loops,1,-1 do
      local loop = loops[i]
      if not loop.assigned[symbol] and not loop.reads[symbol] and
         not declared_inside_loop(context, symbol, loop) then
        loop.reads[symbol] = node
      end
    end
  end
end

-- Called when `symbol` is assigned: it is live again.
function ownership.assign(context, symbol)
  local state = context.ownstate
  if state and state[symbol] then
    state[symbol] = nil
  end
  local loops = context.ownloops
  if loops then
    for i=1,#loops do
      loops[i].assigned[symbol] = true
    end
  end
end

function ownership.mark_moved(context, symbol, node)
  local state = context.ownstate
  if not state then
    state = {}
    context.ownstate = state
  end
  state[symbol] = {state = 'moved', node = node}
end

-- Source text naming an lvalue, for error messages.
local function lvalue_text(node)
  if node.is_Id then
    return node[1]
  elseif node.is_DotIndex then
    return lvalue_text(node[2]) .. '.' .. node[1]
  elseif node.is_KeyIndex then
    return lvalue_text(node[2]) .. '[...]'
  elseif node.is_Paren then
    return lvalue_text(node[1])
  elseif node.is_UnaryOp and node[1] == 'deref' then
    return '$' .. lvalue_text(node[2])
  end
  return 'value'
end

-- Rule 1: copying an lvalue of an owned type needs `move`. `where` is the message prefix.
function ownership.check_copy(context, valnode, where)
  local attr = valnode.attr
  local type = attr.type
  if not (type and type.is_owned and attr.lvalue) or valnode.moveoperand then return end
  local text = lvalue_text(valnode)
  valnode:raisef("%s: '%s' has owned type '%s', write `move(%s)` to transfer ownership or take a pointer with `&%s`",
    where, text, type, text, text)
end

local function scope_within(scope, ancestor)
  while scope do
    if scope == ancestor then return true end
    scope = scope.parent
  end
  return false
end

--[[
Rule 1 for `return` (and `in`): returning a plain local of the function (or of the `do`
expression `ownerscope`) is a move, any other owned lvalue needs `move`.
Returning a `<close>` local is an error, its deferred `__close` would run on the returned value.
]]
function ownership.check_return(context, retnode, ownerscope, where)
  local attr = retnode.attr
  local type = attr.type
  if not (type and type.is_owned and attr.lvalue) or retnode.moveoperand then return end
  local text = lvalue_text(retnode)
  if retnode.is_Id and attr.scope and scope_within(attr.scope, ownerscope) then
    if attr.close then
      retnode:raisef("%s: cannot return '%s' of owned type '%s', it is a <close> variable \z
        and its deferred __close would run on the returned value", where, text, type)
    end
    return
  end
  retnode:raisef("%s: '%s' has owned type '%s' and is not a local of this block, write `move(%s)` to transfer ownership",
    where, text, type, text)
end

--[[
The `move(x)` builtin: yields `x` and resets it to its zero value, marking `x` moved.
`x` must be an lvalue (variable, field, index or dereference) of an owned type.
The call is rewritten in place into
`(do local __moved = x  x = (@T)()  in __moved end)`
(`node.moverewrite` tells `DoExpr` to mark the symbol moved once traversed).
Returns false while the operand type is still unknown.
]]
function ownership.visit_move(context, node, argnodes)
  if #argnodes ~= 1 then
    node:raisef("in call of builtin 'move': expected 1 argument but got %d", #argnodes)
  end
  local argnode = argnodes[1]
  context:traverse_node(argnode)
  while argnode.is_Paren do -- `move((x))`
    argnode = argnode[1]
  end
  local argattr = argnode.attr
  local type = argattr.type
  if not type then return false end
  local text = lvalue_text(argnode)
  if not argattr.lvalue then
    argnode:raisef("in call of builtin 'move': expected a variable, field, index or dereference of an owned type, \z
      but got an rvalue of type '%s' (rvalues already transfer ownership)", type)
  end
  if not type.is_owned then
    argnode:raisef("in call of builtin 'move': '%s' has type '%s', which is not owned \z
      (annotate the record with <owned> or give it an owned field)", text, type)
  end
  if argnode.is_Id and argattr.close then
    argnode:raisef("in call of builtin 'move': cannot move '%s' of owned type '%s', it is a <close> variable \z
      and its deferred __close would run on the emptied value", text, type)
  end
  local parentnode = context:get_visiting_node(1)
  if parentnode and parentnode.is_Block then
    node:raisef("in call of builtin 'move': the moved value of '%s' is unused, \z
      assign it, pass it or return it (call '__close' to release it instead)", text)
  end
  local tname = context.scope:generate_name('__moved')
  local operandnode = argnode:clone()
  operandnode.moveoperand = true
  local zeronode = aster.Call{{}, aster.value(type)}
  local newnode = aster.DoExpr{aster.Block{
    aster.VarDecl{'local', {aster.IdDecl{tname}}, {operandnode}},
    aster.Assign{{argnode:clone()}, {zeronode}},
    aster.In{aster.Id{tname}},
  }}
  newnode:recursive_update_location(node.src, node.pos, node.endpos)
  node.moverewrite = {symbol = argnode.is_Id and argattr or false}
  context:transform_and_traverse_node(node, newnode)
  return true
end

return ownership
