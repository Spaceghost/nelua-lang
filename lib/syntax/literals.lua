-- Grouped decimal literals, binary digits and hexadecimal byte strings.
-- Values are built as AST literals, never rounded through Lua's number type.
return function(syntax)
  local aster = syntax.aster
  syntax.rules([=[
    sx_decimal_digits <- [0-9]+ ('_' [0-9]+)*
  ]=])
  syntax.expression([=[
    &([0-9]+ '_') {sx_decimal_digits ('.' sx_decimal_digits)? ([eE] [+-]? sx_decimal_digits)?}
    ![0-9] !('_' [0-9]) name~? SKIP
  ]=], function(raw, suffix)
    return aster.Number{(raw:gsub('_', '')), suffix}
  end)
  syntax.expression([=['b"' {[^"\r\n]*} '"' SKIP]=], function(raw)
    local digits = raw:gsub('[%s_]', '')
    if digits == '' or digits:find('[^01]') then
      syntax.raise('binary literal needs 0 and 1 digits, with optional spaces or underscores')
    end
    return aster.Number{'0b'..digits}
  end)
  syntax.expression([=['hex"' {[^"\r\n]*} '"' SKIP]=], function(raw)
    local digits = raw:gsub('[%s_]', '')
    if digits:find('[^0-9a-fA-F]') or #digits % 2 ~= 0 then
      syntax.raise('hex byte string needs pairs of hexadecimal digits')
    end
    return aster.String{(digits:gsub('..', function(byte) return string.char(tonumber(byte, 16)) end))}
  end)
end
