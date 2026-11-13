-- Contextual control-flow sugar. All loops keep native break/continue semantics.
return function(syntax)
  syntax.statement("'unless' WORDSKIP expr `then` Block (`else` Block / $false) @`end`", function(c, yes, no)
    if no then
      return syntax.stat('if not (c) then yes() else no() end', {c=c, yes=yes, no=no})
    end
    return syntax.stat('if not (c) then yes() end', {c=c, yes=yes})
  end)
  -- Do not commit before `do`: a normal repeat ... until condition must still parse.
  syntax.statement("'until' WORDSKIP expr `do` Block @`end`", function(c, body)
    return syntax.stat('while not (c) do body() end', {c=c, body=body})
  end)
  syntax.statement("'loop' WORDSKIP `do` Block @`end`", function(body)
    return syntax.stat('while true do body() end', {body=body})
  end)
  syntax.statement("'guard' WORDSKIP expr `else` Block @`end`", function(c, body)
    return syntax.stat('if not (c) then body() end', {c=c, body=body})
  end)
  syntax.statement("'times' WORDSKIP expr ('as' WORDSKIP @iddecl / $false) `do` Block @`end`", function(n, index, body)
    index = index or syntax.aster.IdDecl{syntax.gensym('index')}
    return syntax.aster.ForNum{index, syntax.aster.Number{'1'}, false, n, false, body}
  end)
end
