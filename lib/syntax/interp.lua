--[[
String interpolation for Nelua, as a `#syntax` extension:

  #syntax 'syntax.interp'
  require 'string'
  local name, n = 'world', 3
  print($"hello {name}, {n + 1} times")     -- hello world, 4 times
  print($"pi is {math.pi:%.3f}")            -- pi is 3.142
  print($"braces: {{literal}}")             -- braces: {literal}

`$"..."` is rewritten while parsing into an ordinary concatenation:
literal pieces stay string literals (with their escapes), `{expr}` becomes
`tostring(expr)`, and `{expr:%fmt}` becomes `string.format('%fmt', expr)`
(a ':' followed by '%' at the top level of the braces starts a format, so
method calls such as `{s:upper()}` still work). `{{` and `}}` are literal
braces. `$"` is claimed before the `$` dereference operator (through
`syntax.prefixexpr`), so `$ "x"` with a space is still a dereference. The embedded expressions are ordinary Nelua expressions, parsed with
the base grammar (as every syntax template is), so other extensions such as
`|>` are not available inside the braces; they are evaluated left to right. The module 'string'
must be required where `tostring` or `string.format` is not yet in scope.
]]

-- Split the raw contents of $"..." into literal and expression pieces.
local function split(raw, raise)
  local pieces = {}
  local lit = {}
  local i, n = 1, #raw
  local function flush()
    if #lit > 0 then pieces[#pieces+1] = {kind='lit', text=table.concat(lit)}; lit = {} end
  end
  while i <= n do
    local c = raw:sub(i, i)
    if c == '\\' then
      lit[#lit+1] = raw:sub(i, i+1); i = i + 2
    elseif c == '{' and raw:sub(i+1, i+1) == '{' then
      lit[#lit+1] = '{'; i = i + 2
    elseif c == '}' and raw:sub(i+1, i+1) == '}' then
      lit[#lit+1] = '}'; i = i + 2
    elseif c == '}' then
      raise("single '}' in interpolated string (use '}}' for a literal brace)")
    elseif c == '{' then
      flush()
      local depth, j, quote = 1, i + 1, nil
      local fmtpos
      while j <= n do
        local d = raw:sub(j, j)
        if quote then
          if d == '\\' then j = j + 1 elseif d == quote then quote = nil end
        elseif d == "'" or d == '"' then quote = d
        elseif d == '{' or d == '(' or d == '[' then depth = depth + 1
        elseif d == ')' or d == ']' then depth = depth - 1
        elseif d == '}' then
          depth = depth - 1
          if depth == 0 then break end
        elseif d == ':' and depth == 1 and raw:sub(j+1, j+1) == '%' then fmtpos = fmtpos or j
        end
        j = j + 1
      end
      if j > n then raise("unterminated '{' in interpolated string") end
      local inner = raw:sub(i + 1, j - 1)
      local expr, fmt = inner, nil
      if fmtpos then
        expr = raw:sub(i + 1, fmtpos - 1)
        fmt = raw:sub(fmtpos + 1, j - 1)
      end
      if not expr:find('%S') then raise('empty expression in interpolated string') end
      pieces[#pieces+1] = {kind='expr', text=expr, fmt=fmt}
      i = j + 1
    else
      lit[#lit+1] = c; i = i + 1
    end
  end
  flush()
  return pieces
end

return function(syntax)
  syntax.prefixexpr([=['$"' {('\' . / [^"])*} '"' SKIP]=], function(raw)
    local pieces = split(raw, syntax.raise)
    if #pieces == 0 then return syntax.expr('""') end
    local parts = {}
    for _, p in ipairs(pieces) do
      if p.kind == 'lit' then
        parts[#parts+1] = '"' .. p.text .. '"'
      elseif p.fmt then
        parts[#parts+1] = string.format('string.format(%q, (%s))', p.fmt, p.text)
      else
        parts[#parts+1] = 'tostring((' .. p.text .. '))'
      end
    end
    if #parts == 1 and pieces[1].kind == 'lit' then return syntax.expr(parts[1]) end
    return syntax.expr('(' .. table.concat(parts, ' .. ') .. ')')
  end)
end
