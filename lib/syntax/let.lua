-- Value destructuring: let {x, y = height} = p; let [first, _, third] = a.
-- The source is evaluated once. Ordinary copy/ownership rules still apply.
return function(syntax)
  local aster = syntax.aster
  syntax.rules([=[
    sx_let_field <-| name (`=` @iddecl / $false)
    sx_let_fields <-| sx_let_field (`,` sx_let_field)* `,`?
  ]=])
  local function build(fields, source, record)
    local temp = syntax.gensym('source')
    local out = syntax.block('local t = source', {t=temp, source=source})
    local seen = {}
    for i, field in ipairs(fields) do
      local decl = record and (field[2] or aster.IdDecl{field[1]}) or field
      if type(decl[1]) ~= 'string' then syntax.raise('destructuring needs ordinary binding names') end
      if decl[1] ~= '_' then
        if seen[decl[1]] then syntax.raise("duplicate destructuring binding '%s'", decl[1]) end
        seen[decl[1]] = true
        local value = record and aster.DotIndex{field[1], aster.Id{temp}} or
                                aster.KeyIndex{aster.Number{tostring(i-1)}, aster.Id{temp}}
        out[#out+1] = aster.VarDecl{'local', {decl}, {value}}
      end
    end
    return out
  end
  syntax.statement("'let' WORDSKIP `{` sx_let_fields @`}` @`=` @expr", function(fields, source)
    return build(fields, source, true)
  end)
  syntax.statement("'let' WORDSKIP `[` iddecls @`]` @`=` @expr", function(fields, source)
    return build(fields, source, false)
  end)
end
