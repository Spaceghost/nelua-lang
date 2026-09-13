-- SPDX-License-Identifier: MIT
-- Identical source in native Lua 5.5, LuaJIT and the same-core Wasm backend.
local http = require 'worker.http'
local counter = 0
return {
  fetch = function(request, env, ctx)
    local path = request.url:match('https?://[^/]+(/[^?]*)') or request.url:match('^([^?]+)')
    if path == '/hello' then return http.text('ok') end
    if path == '/echo' then return http.text(request.body) end
    if path == '/counter' then counter=counter+1;return http.text(tostring(counter)) end
    if path == '/cpu' then
      local n=tonumber(request.body)
      assert(n and n>=1 and n<=20000 and n==math.floor(n), 'invalid loop count')
      local sum=0;for i=1,n do sum=sum+i%97 end
      return http.text(tostring(sum))
    end
    if path == '/get' then return http.text(env.CONFIG:get(request.body~='' and request.body or 'greeting') or 'missing') end
    if path == '/chain' then
      local greeting=env.CONFIG:get('greeting')
      local upstream=env.UPSTREAM:fetch('/'..(request.body~='' and request.body or 'echo'))
      return http.text(greeting..':'..upstream.body)
    end
    if path == '/ops16' then
      local value;for i=1,16 do value=env.CONFIG:get('greeting') end
      return http.text(value)
    end
    if path == '/fail' then env.CONFIG:get('greeting');error('http-trace-needle') end
    if path == '/loop' then while true do end end
    return http.text('not found',404)
  end
}
