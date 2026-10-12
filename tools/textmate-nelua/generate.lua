-- Deterministically emit only TextMate's vendor grammar schema from Lua data.
local mode=assert(arg[1],'usage: generate.lua --generate|--check')
assert(mode=='--generate' or mode=='--check')
local grammar=dofile('grammar.lua')
assert(grammar.scopeName=='source.nelua' and grammar.fileTypes[1]=='nelua')
local function string_json(s)
  return '"'..s:gsub('[%z\1-\31\\"]',function(c)
    if c=='"' or c=='\\' then return '\\'..c end
    return ('\\u%04x'):format(c:byte())
  end)..'"'
end
local function encode(value)
  if type(value)=='string' then return string_json(value) end
  if type(value)=='boolean' or type(value)=='number' then return tostring(value) end
  assert(type(value)=='table','invalid external grammar value')
  local parts={}
  if #value>0 then for i,v in ipairs(value) do parts[i]=encode(v) end
    return '['..table.concat(parts,',')..']' end
  local keys={};for k in pairs(value) do assert(type(k)=='string');keys[#keys+1]=k end;table.sort(keys)
  for i,k in ipairs(keys) do parts[i]=string_json(k)..':'..encode(value[k]) end
  return '{'..table.concat(parts,',')..'}'
end
local bytes=encode(grammar)..'\n';local path='syntaxes/nelua.tmLanguage.json'
if mode=='--check' then
  local f=assert(io.open(path,'rb'));local existing=f:read('a');f:close()
  assert(existing==bytes,'stale TextMate output; check never repairs delivery')
else
  local f=assert(io.open(path..'.tmp','wb'));assert(f:write(bytes));f:close();assert(os.rename(path..'.tmp',path))
end
print('Native Nelua TextMate schema '..mode..': source.nelua, no fallback')
