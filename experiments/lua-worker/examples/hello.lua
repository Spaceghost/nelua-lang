local http = require 'worker.http'
return {
  fetch = function(request, env, ctx)
    local name = request.url:match('/([^/?]+)$') or 'world'
    local greeting = env.CONFIG:get('greeting') or 'Hello'
    local response = env.UPSTREAM:fetch('/echo/' .. name)
    ctx.log('served ' .. name)
    return http.text(greeting .. ' ' .. response.body)
  end
}
