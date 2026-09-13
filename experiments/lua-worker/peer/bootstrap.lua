-- SPDX-License-Identifier: MIT
-- Trusted, captured yield boundary. Guest code cannot access coroutine or issue.
-- C frames return normally BEFORE this Lua frame yields on both 5.5 and LuaJIT.
local issue, yield = ...
local raise = error
local function operation(cap, kind, argument)
  issue(cap, kind, argument)
  local ok, status, body = yield()
  if not ok then raise(body, 2) end
  return status, body
end
local methods = {}
function methods:get(key)
  local status, value = operation(self, 1, key)
  if status == 404 then return nil end
  return value
end
function methods:fetch(path)
  local status, body = operation(self, 2, path)
  return {status=status, body=body}
end
return methods, function(cap)
  return function(message) operation(cap, 3, message) end
end
