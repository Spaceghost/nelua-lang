--[[
Pipe operator for Nelua, as a `#syntax` extension:

  #syntax 'syntax.pipe'
  x |> f            -- f(x)
  x |> f(a, b)      -- f(x, a, b)
  x |> obj:m(a)     -- obj:m(x, a)
  s |> trim |> upper()

`|>` binds at the level of `|` (below `..`, shifts and arithmetic, above
comparisons) and is left associative. Generated calls follow native argument
evaluation rules; use separate statements to sequence side effects.
]]

return function(syntax)
  local aster = syntax.aster
  syntax.binary('bor', '`|>`', function(lhs, rhs)
    local tag = rhs.tag
    if tag == 'Call' or tag == 'CallMethod' then
      local args = tag == 'Call' and rhs[1] or rhs[2]
      table.insert(args, 1, lhs)
      return rhs
    elseif tag == 'Id' or tag == 'DotIndex' then
      return aster.Call{{lhs}, rhs}
    end
    syntax.raise('the right side of `|>` must be a function name or a call')
  end)
end
