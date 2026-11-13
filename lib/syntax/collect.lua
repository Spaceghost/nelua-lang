-- Typed vector comprehensions. Explicitly require 'vector' in the source file.
return function(syntax)
  local aster = syntax.aster
  syntax.error('Expected_collect_iterator', 'expected a numeric or generic iterator after `;` in collect')
  syntax.error('Expected_=>', 'expected `=>` before the collected expression')
  syntax.rules([=[
    sx_collect_num <-| iddecl `=` @expr @`,` forcmp~? @expr (`,` @expr)~?
    sx_collect_in  <-| iddecls `in` @exprs
  ]=])
  syntax.expression([=[
    'collect' WORDSKIP `(` typeexpr `;`
    ($'num' sx_collect_num / $'in' sx_collect_in)^Expected_collect_iterator
    ('when' WORDSKIP @expr / $false) @`=>` @expr @`)`
  ]=], function(typ, kind, iteration, cond, value)
    local result = syntax.gensym('collect')
    local push = syntax.stat('result:push(value)', {result=result, value=value})
    if cond then push = syntax.stat('if cond then push() end', {cond=cond, push={push}}) end
    local body = aster.Block{push}
    local loop
    if kind == 'num' then
      loop = aster.ForNum{iteration[1], iteration[2], iteration[3], iteration[4], iteration[5], body}
    else
      loop = aster.ForIn{iteration[1], iteration[2], body}
    end
    local block = syntax.block('local result: vector(T)', {result=result, T=typ})
    block[#block+1] = loop
    block[#block+1] = aster.In{aster.Id{result}}
    return aster.DoExpr{block}
  end)
end
