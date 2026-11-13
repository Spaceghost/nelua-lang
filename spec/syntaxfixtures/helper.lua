return function(syntax)
  syntax.expression("'fixture_answer' WORDSKIP", function() return syntax.expr('42') end)
end
