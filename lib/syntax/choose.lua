-- A lazy conditional expression that preserves false, nil and nilptr results.
return function(syntax)
  syntax.error('Expected_else', 'expected `else` in choose expression')
  syntax.expression("'choose' WORDSKIP expr `then` @expr @`else` @expr @`end`", function(c, yes, no)
    return syntax.expr('(do if c then in yes else in no end end)', {c=c, yes=yes, no=no})
  end)
end
