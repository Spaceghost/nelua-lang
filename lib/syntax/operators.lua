-- Familiar operator spellings. Short-circuiting is inherited from the native AST.
return function(syntax)
  for _, op in ipairs{{'pow', '**', 'pow'}, {'cmp', '!=', 'ne'}, {'and', '&&', 'and'}, {'or', '||', 'or'}} do
    local kind = op[3]
    syntax.binary(op[1], '`'..op[2]..'`', function(lhs, rhs)
      return syntax.aster.BinaryOp{lhs, kind, rhs}
    end)
  end
end
