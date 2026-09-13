local http = require 'worker.http'
local count = 0
return {
  fetch = function(r, env, ctx)
    local name = r.url:match('/([^/?]+)$')
    if name == 'hello' then return http.text('ok')
    elseif name == 'cpu' then
      local n = 0
      for i=1,10000 do n=n+i%97 end
      return http.text(tostring(n))
    elseif name == 'echo64k' then return http.text(r.body)
    elseif name == 'get' then return http.text(env.CONFIG:get('greeting'))
    elseif name == 'chain' then
      local g=env.CONFIG:get('greeting')
      local u=env.UPSTREAM:fetch('/echo')
      return http.text(g..':'..u.body)
    elseif name == 'ops16' then
      local g
      for i=1,16 do g=env.CONFIG:get('greeting') end
      return http.text(g)
    elseif name == 'lifetime' then
      count=count+1
      return http.text(tostring(count))
    end
    error('unknown workload')
  end
}
