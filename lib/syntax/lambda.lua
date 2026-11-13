-- fn(x: integer): integer => x * 2; or fn(x) do ... return x end.
return function(syntax)
  syntax.expression([=[
    'fn' WORDSKIP `(` funcargs `)` (`:` funcrets / $false) (annots / $false)
    (`=>` @expr / `do` Block @`end`)
  ]=], function(args, rets, annots, body)
    if body.tag ~= 'Block' then body = syntax.aster.Block{syntax.aster.Return{body}} end
    return syntax.aster.Function{args, rets, annots, body}
  end)
end
