-- A local <close> resource scoped to a do block, including early exits.
return function(syntax)
  syntax.statement("'using' WORDSKIP iddecl `=` @expr @`do` Block @`end`", function(decl, value, body)
    local annots = decl[3] or {}
    local close = false
    for _, annot in ipairs(annots) do if annot[1] == 'close' then close = true end end
    if not close then annots[#annots+1] = syntax.aster.Annotation{'close'} end
    decl[3] = annots
    local block = syntax.aster.Block{syntax.aster.VarDecl{'local', {decl}, {value}}}
    for _, stat in ipairs(body) do block[#block+1] = stat end
    return syntax.aster.Do{block}
  end)
end
