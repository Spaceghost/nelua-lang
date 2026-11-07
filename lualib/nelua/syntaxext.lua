--[[
Syntax extension module.

Lets a Nelua source file extend the grammar it is parsed with, at compile time.
A top-level `#syntax` directive runs Lua code (inline, or a module found on the
Lua and Nelua search paths) that adds grammar rules through the `syntax` API.
The parser stops at the directive, runs it, recompiles the grammar and resumes
right after it, so the extension applies to the rest of that file only.

Every extension rule produces an intermediate node (`SyntaxExt` or
`SyntaxExtBinOp`) that is expanded right after the file is parsed, bottom-up,
by the Lua builder function given with the rule. Builders return ordinary AST
nodes, so the analyzer and every generator only ever see standard Nelua.
]]

local lpegrex = require 'nelua.thirdparty.lpegrex'
local except = require 'nelua.utils.except'
local errorer = require 'nelua.utils.errorer'
local fs = require 'nelua.utils.fs'
local config = require 'nelua.configer'.get()

local syntaxext = {}

-- Binary operator precedence levels, lowest first, with the operand rule on their right.
local binary_levels = {
  ['or'] = 'exprand', ['and'] = 'exprcmp', cmp = 'exprorelse', orelse = 'exprbor',
  bor = 'exprbxor', bxor = 'exprband', band = 'exprbshift', bshift = 'exprconcat',
  concat = 'exprarit', arit = 'exprfact', fact = 'exprunary', pow = 'exprunary',
}
syntaxext.binary_levels = binary_levels

local gensym_counter = 0
local compiled_cache = {}
local module_cache = {}

local function raise_at(node, message, ...)
  local msg = string.format(message, ...)
  if node and node.src and node.pos then
    local loc = {srcname=node.src.name, srccode=node.src.content, pos=node.pos}
    loc.lineno, loc.colno, loc.line, loc.linestart, loc.lineend =
      lpegrex.calcline(node.src.content, node.pos)
    msg = errorer.get_pretty_source_pos_errmsg(loc, msg, 'error')
  else
    msg = 'error: '..msg..'\n'
  end
  except.raise({label = 'ParseError', message = msg})
end

local function maxindex(t)
  local n = 0
  for k in pairs(t) do
    if math.type(k) == 'integer' and k > n then n = k end
  end
  return n
end

local function is_node(v)
  return type(v) == 'table' and v._astnode
end

----------------------------------------------------------------------------------------
-- Templates

local function clear_locations(node)
  for n in node:walk_nodes() do
    n.src, n.pos, n.endpos = nil, nil, nil
  end
end

local renamable_tags = {
  IdDecl = true, DotIndex = true, ColonIndex = true, CallMethod = true,
  Label = true, Goto = true,
}

local function value_to_node(aster, v)
  if is_node(v) then
    return v:clone()
  elseif type(v) == 'string' then
    return aster.Id{v}
  elseif type(v) == 'table' then
    return nil
  end
  return aster.value(v)
end

local function placeholder_of(subs, e)
  if is_node(e) and e.tag == 'Id' and type(e[1]) == 'string' then
    return subs[e[1]]
  end
end

-- statement form `name()` used as a placeholder for a block or a list of statements
local function stat_placeholder_of(subs, e)
  if is_node(e) and e.tag == 'Call' and type(e[1]) == 'table' and #e[1] == 0 then
    local v = placeholder_of(subs, e[2])
    if type(v) == 'table' and (not is_node(v) or v.tag == 'Block') then
      return v
    end
  end
end

local substitute_node

local function substitute_list(aster, list, subs)
  local out = {}
  for i=1,maxindex(list) do
    local e = list[i]
    local v = stat_placeholder_of(subs, e)
    if v == nil then
      v = placeholder_of(subs, e)
      if v ~= nil and (is_node(v) or type(v) ~= 'table') then v = nil end -- 1:1 replacement
    end
    if v ~= nil then -- splice a block or a plain list
      for j=1,maxindex(v) do
        local x = v[j]
        out[#out+1] = is_node(x) and x:clone() or value_to_node(aster, x)
      end
    else
      out[#out+1] = substitute_node(aster, e, subs)
    end
  end
  for i=maxindex(list),1,-1 do list[i] = nil end
  for i=1,#out do list[i] = out[i] end
  return list
end

function substitute_node(aster, node, subs)
  if type(node) ~= 'table' then return node end
  if not is_node(node) or node.tag == 'Block' then
    return substitute_list(aster, node, subs)
  end
  local v = placeholder_of(subs, node)
  if v ~= nil then
    local rep = value_to_node(aster, v)
    if not rep then
      error(string.format("template placeholder '%s' holds a list where one node is expected", node[1]), 0)
    end
    return rep
  end
  if renamable_tags[node.tag] and type(node[1]) == 'string' and type(subs[node[1]]) == 'string' then
    node[1] = subs[node[1]]
  end
  for i=1,maxindex(node) do
    node[i] = substitute_node(aster, node[i], subs)
  end
  return node
end

local function parse_template(aster, text, subs)
  local ok, ast = pcall(aster.parse, text, '<syntax template>')
  if not ok then
    local msg = type(ast) == 'table' and ast.message or tostring(ast)
    error('in syntax template: '..msg, 0)
  end
  clear_locations(ast)
  if subs then
    substitute_node(aster, ast, subs)
  end
  return ast
end

----------------------------------------------------------------------------------------
-- Extension state, one per parsed file that uses `#syntax`

local State = {}
State.__index = State

local function new_state(syntax, name)
  local aster = require 'nelua.aster'
  local state = setmetatable({
    base = syntax,
    name = name,
    points = {STAT = {}, EXPR = {}, UNARY = {}},
    rules = {},
    rulenames = {},
    builders = {},
    kinds = {},
    errors = setmetatable({}, {__index = syntax.errors}),
    defs = {},
    modules = {},
    count = 0,
    aster = aster,
  }, State)
  for level in pairs(binary_levels) do
    state.points['BIN_'..level] = {}
  end
  for rname in syntax.grammar_template:gmatch('\n([%w_]+)%s*[:<]') do
    state.rulenames[rname] = true
  end
  state.api = state:make_api()
  return state
end

function State:add(kind, point, rule_of_id, builder)
  if type(builder) ~= 'function' then
    error('syntax extension builder must be a function', 3)
  end
  self.count = self.count + 1
  local id = string.format('ext_%s_%d', kind, self.count)
  table.insert(self.points[point], id)
  table.insert(self.rules, rule_of_id(id))
  self.builders[id] = builder
  self.kinds[id] = kind
  self.rulenames[id] = true
  return id
end

function State:make_api()
  local state = self
  local aster = self.aster
  local api = {aster = aster, levels = binary_levels}

  -- New statement: `peg` is an LPegRex expression (it may use any rule of the
  -- Nelua grammar: expr, exprs, Block, name, iddecls, typeexpr, ...); every capture
  -- it makes is passed to `builder`, which returns the replacement AST node.
  -- A returned `Block` is spliced into the enclosing block (its locals stay visible).
  function api.statement(peg, builder)
    return state:add('stat', 'STAT', function(id)
      return string.format("%s : SyntaxExt <== $'%s' (%s)", id, id, peg)
    end, builder)
  end

  -- New primary expression, tried before every built-in one.
  function api.expression(peg, builder)
    return state:add('expr', 'EXPR', function(id)
      return string.format("%s : SyntaxExt <== $'%s' (%s)", id, id, peg)
    end, builder)
  end

  -- New prefix operator: `token` is an LPegRex token such as "`!!`"; builder(operand).
  function api.unary(token, builder)
    return state:add('unary', 'UNARY', function(id)
      return string.format("%s : SyntaxExt <== (%s) $'%s' exprunary^Expected_expr", id, token, id)
    end, builder)
  end

  -- New binary operator at the precedence `level` of an existing one
  -- (see `syntax.levels`); always left associative; builder(lhs, rhs).
  function api.binary(level, token, builder)
    local rhs = binary_levels[level]
    if not rhs then
      error(string.format("unknown binary operator level '%s'", tostring(level)), 2)
    end
    return state:add('binary', 'BIN_'..level, function(id)
      return string.format("%s : SyntaxExtBinOp <== (%s) $'%s' %s^Expected_expr", id, token, id, rhs)
    end, builder)
  end

  -- Raw helper rules in LPegRex syntax; names may not shadow built-in rules.
  function api.rules(text)
    for rname in ('\n'..text):gmatch('\n%s*([%w_]+)%s*[:<]') do
      if state.rulenames[rname] then
        error(string.format("syntax rule '%s' is already defined", rname), 2)
      end
      state.rulenames[rname] = true
    end
    table.insert(state.rules, text)
  end

  -- Message for an error label thrown with `@rule` or `^Label` in extension rules.
  function api.error(label, message)
    state.errors[label] = message
  end

  -- Value or function made available to the grammar as `%name` / `->name`.
  function api.def(name, value)
    state.defs[name] = value
  end

  -- Unique identifier for names introduced by a builder.
  function api.gensym(prefix)
    gensym_counter = gensym_counter + 1
    return string.format('__sx_%s_%d', prefix or 'g', gensym_counter)
  end

  -- Templates: Nelua source with placeholders. Every identifier that is a key of
  -- `subs` is replaced by its value (a node is cloned, a string is an identifier,
  -- numbers and booleans become literals); a string value also renames
  -- declarations and fields of that name; a statement `key()` whose value is a
  -- `Block` or a list of nodes is replaced by those statements, and so is a list
  -- element (call argument, expression list) whose value is a list.
  function api.expr(text, subs)
    local ast = parse_template(aster, 'return '..text, subs)
    local ret = ast[1]
    if #ast ~= 1 or not ret or ret.tag ~= 'Return' or #ret ~= 1 then
      error('expression template must be exactly one expression: '..text, 2)
    end
    return ret[1]
  end
  function api.stat(text, subs)
    local ast = parse_template(aster, text, subs)
    if #ast == 1 then return ast[1] end
    return ast
  end
  function api.block(text, subs)
    return parse_template(aster, text, subs)
  end

  -- Raises a compile error at the node being expanded.
  function api.raise(message, ...)
    raise_at(state.current, message, ...)
  end

  return api
end

local function find_module(modname, filename)
  local paths = {}
  if filename then
    local dir = fs.dirname(filename)
    if dir and dir ~= '' then
      paths[#paths+1] = fs.join(dir, '?.lua')
    end
  end
  if config.path then
    paths[#paths+1] = config.path:gsub('%.nelua', '.lua')
  end
  paths[#paths+1] = package.path
  return package.searchpath(modname, table.concat(paths, ';'))
end

local function code_lineno(use)
  local content = use.src.content
  local at = content:find(use[1], use.pos, true) or use.pos
  return (lpegrex.calcline(content, at))
end

function State:run(use)
  local env = setmetatable({syntax = self.api, aster = self.aster}, {__index = _G})
  local fn, err
  if use[2] == 'code' then
    local lineno = code_lineno(use)
    local chunkname = '@'..(self.name or '?')
    fn, err = load(string.rep('\n', lineno - 1)..use[1], chunkname, 't', env)
    if not fn then raise_at(use, 'in #syntax code: %s', err) end
  else
    local path, serr = find_module(use[1], self.name)
    if not path then raise_at(use, "#syntax module '%s' not found:%s", use[1], serr) end
    if self.modules[path] then return end -- applying a module twice is a no-op
    self.modules[path] = true
    local mod = module_cache[path]
    if not mod then
      local chunk
      chunk, err = loadfile(path, 't')
      if not chunk then raise_at(use, 'in #syntax module: %s', err) end
      local ok, res = pcall(chunk, use[1], path)
      if not ok then raise_at(use, 'in #syntax module: %s', tostring(res)) end
      if type(res) ~= 'function' then
        raise_at(use, "#syntax module '%s' must return a function taking the syntax API", use[1])
      end
      mod = res
      module_cache[path] = mod
    end
    fn = function() return mod(self.api) end
  end
  local ok, res = xpcall(fn, function(e)
    return e
  end)
  if not ok then
    if type(res) == 'table' then except.reraise(res) end
    raise_at(use, 'in #syntax: %s', tostring(res))
  end
end

function State:compile()
  local points = self.points
  local text = self.base.grammar_template:gsub('@@([%w_]+)@@', function(k)
    local list = points[k]
    if not list or #list == 0 then return '' end
    if k:find('^BIN_') then
      return ' / '..table.concat(list, ' / ')
    end
    return table.concat(list, ' / ')..' / '
  end)
  text = text..'\n-- syntax extensions\n'..table.concat(self.rules, '\n')..'\n'
  local hasdefs = next(self.defs) ~= nil
  local patt = not hasdefs and compiled_cache[text]
  if not patt then
    local defs = {}
    for k,v in pairs(self.base.defs) do defs[k] = v end
    for k,v in pairs(self.defs) do defs[k] = v end
    local ok, res = pcall(lpegrex.compile, text, defs)
    if not ok then
      raise_at(self.lastuse, 'invalid syntax extension grammar: %s',
               tostring(res):gsub('^[^\n]-%.lua:%d+: ', ''))
    end
    patt = res
    if not hasdefs then compiled_cache[text] = patt end
  end
  return patt
end

-- Expands extension nodes bottom-up in place, returns the replacement of `node`.
function State:expand(node)
  if type(node) ~= 'table' then return node end
  local isblock = is_node(node) and node.tag == 'Block'
  local n = maxindex(node)
  if isblock then
    local out = {}
    for i=1,n do
      local child = node[i]
      local stat = is_node(child) and child.tag == 'SyntaxExt' and self.kinds[child[1]] == 'stat'
      local res = self:expand(child)
      if stat and is_node(res) and res.tag == 'Block' then
        for j=1,#res do out[#out+1] = res[j] end
      else
        out[#out+1] = res
      end
    end
    for i=n,1,-1 do node[i] = nil end
    for i=1,#out do node[i] = out[i] end
  else
    for i=1,n do
      node[i] = self:expand(node[i])
    end
  end
  if not is_node(node) then return node end
  local builder, args
  if node.tag == 'SyntaxExt' then
    builder = self.builders[node[1]]
    args = table.pack(table.unpack(node, 2, n))
  elseif node.tag == 'SyntaxExtBinOp' then
    builder = self.builders[node[2]]
    args = table.pack(node[1], node[3])
  else
    return node
  end
  local prev = self.current
  self.current = node
  local ok, res = xpcall(builder, function(e)
    return e
  end, table.unpack(args, 1, args.n))
  self.current = prev
  if not ok then
    if type(res) == 'table' then except.reraise(res) end
    raise_at(node, 'in syntax extension: %s', tostring(res))
  end
  if is_node(res) and res.tag == 'Block' and self.kinds[node[1]] ~= 'stat' then
    raise_at(node, 'syntax extension builder returned a block where an expression is expected')
  end
  if not is_node(res) then
    raise_at(node, 'syntax extension builder must return an AST node, got %s', type(res))
  end
  res:recursive_update_location(node.src, node.pos, node.endpos)
  return res
end

--[[
Parses `content` with the extensible Nelua syntax.
Returns the AST, or nil plus error label and position, and the error messages table
to use (extended when the file declared extension error labels).
]]
function syntaxext.parse(syntax, content, name)
  local patt = syntax.patt
  local pos = 1
  local ast, state
  while true do
    local block, use, errpos = patt:match(content, pos)
    if not block then
      return nil, use, errpos, state and state.errors or syntax.errors
    end
    if not ast then
      ast = block
    else
      for i=1,#block do ast[#ast+1] = block[i] end
      ast.endpos = block.endpos
    end
    if not use then break end
    state = state or new_state(syntax, name)
    state.lastuse = use
    state:run(use)
    patt = state:compile()
    pos = use.endpos
  end
  if state then
    ast = state:expand(ast)
  end
  return ast, nil, nil, state and state.errors or syntax.errors
end

return syntaxext
