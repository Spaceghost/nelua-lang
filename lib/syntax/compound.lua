--[[
Compound assignment for Nelua, as a `#syntax` extension:

  #syntax 'syntax.compound'
  x += 1          -- x = x + 1
  t.count *= 2    -- t.count = t.count * 2
  v[f()] ..= 's'  -- do local p = &v[f()]; $p = $p .. 's' end

Operators: += -= *= /= //= %= ^= ..= |= &= <<= >>=
(`~=` stays "not equal", so there is no xor-assign). A target made only of
names, fields and constant or plain-name indexes is evaluated twice, like the
spelled-out assignment; any other target is evaluated once through a pointer.
]]

local ops = {
  {'+=', 'add'}, {'-=', 'sub'}, {'*=', 'mul'}, {'//=', 'idiv'}, {'/=', 'div'},
  {'%=', 'mod'}, {'^=', 'pow'}, {'..=', 'concat'}, {'|=', 'bor'}, {'&=', 'band'},
  {'<<=', 'shl'}, {'>>=', 'shr'},
}

local simple_index = {Id = true, Number = true, String = true, Boolean = true}

local function is_simple(node)
  if node.tag == 'Id' then
    return true
  elseif node.tag == 'DotIndex' then
    return is_simple(node[2])
  elseif node.tag == 'KeyIndex' then
    return simple_index[node[1].tag] and is_simple(node[2])
  end
  return false
end

return function(syntax)
  local alts = {}
  for i,op in ipairs(ops) do
    alts[i] = string.format("`%s`->'%s'", op[1], op[2])
  end
  syntax.statement("var (" .. table.concat(alts, ' / ') .. ") @expr", function(target, op, value)
    if is_simple(target) then
      return syntax.stat('t = u', {t = target, u = syntax.aster.BinaryOp{target:clone(), op, value}})
    end
    local p = syntax.gensym('p')
    local deref = syntax.expr('$p', {p = p})
    return syntax.stat('do local p = &t; $p = v end', {
      p = p, t = target, v = syntax.aster.BinaryOp{deref, op, value},
    })
  end)
end
