-- Explicit, reproducible Tree-sitter + Nelua scanner delivery. No implicit repair.
local mode=assert(arg[1],'usage: generate.lua --check|--generate NELUA TREE_SITTER')
assert(mode=='--check' or mode=='--generate')
local compiler=assert(arg[2]); local treesitter=assert(arg[3])
local function q(s) return "'"..s:gsub("'","'\\''").."'" end
local function run(command)
  local f=assert(io.popen(command..' 2>&1'));local s=f:read('a');local ok,why,code=f:close()
  assert(ok,command..'\n'..s..'\n'..tostring(why)..'/'..tostring(code));return s
end
local function read(p) local f=assert(io.open(p,'rb'));local s=f:read('a');f:close();return s end
local function write(p,s) local f=assert(io.open(p,'wb'));assert(f:write(s));f:close() end
local pin='b0cbfdb86959b7e5d94943729016d8cc4c4cc115'
assert(run('git -C '..q(assert(compiler:match('^(.*)/[^/]+$')))..' rev-parse HEAD'):match('%w+')==pin,'wrong compiler pin')
assert(run(q(treesitter)..' --version'):match('tree%-sitter 0%.25%.10'),'wrong Tree-sitter pin')
local root=run('pwd'):gsub('%s+$','')
local inputs={'grammar.nelua','src/scanner.nelua','generate.lua'}
local outputs={'src/parser.c','src/grammar.json','src/node-types.json',
  'src/tree_sitter/parser.h','src/tree_sitter/alloc.h','src/tree_sitter/array.h','src/scanner.c','src/grammar_generator.c'}
local temp=os.tmpname();assert(os.remove(temp));run('mkdir '..q(temp))
local function digest(p) return assert(run('sha256sum '..q(p)):match('^(%x+)')) end
local input_hash={};for _,p in ipairs(inputs) do input_hash[p]=digest(root..'/'..p) end
local function build(dir)
  run('mkdir -p '..q(dir..'/src'))
  for _,p in ipairs(inputs) do write(dir..'/'..p,read(root..'/'..p)) end
  local function normalize(path)
    local code=read(path):gsub('/%* Compile command: [^\n]* %*/\n',''):gsub('/%* Compile hash: [^\n]* %*/\n','')
    write(path,code)
  end
  run('cd '..q(dir)..' && env -u CFLAGS -u LDFLAGS -u NELUA_PATH -u LUA_PATH -u LUA_CPATH HOME='..q(dir)..
    ' XDG_CONFIG_HOME='..q(dir..'/config')..' '..q(compiler)..
    ' -c -C -r -P nogc --cc gcc --cache-dir '..q(dir..'/grammar-cache')..' -o src/grammar_generator.c grammar.nelua')
  normalize(dir..'/src/grammar_generator.c')
  run('cd '..q(dir)..' && gcc -std=gnu11 -O2 -Wall -Wextra -Werror src/grammar_generator.c -o grammar-generator && ./grammar-generator > grammar.json')
  run('cd '..q(dir)..' && '..q(treesitter)..' generate --abi 14 grammar.json')
  write(dir..'/src/grammar.json',read(dir..'/grammar.json'))
  run('cd '..q(dir)..' && env -u CFLAGS -u LDFLAGS -u NELUA_PATH -u LUA_PATH -u LUA_CPATH HOME='..q(dir)..
    ' XDG_CONFIG_HOME='..q(dir..'/config')..' '..q(compiler)..
    ' -c -C -r -P nogc -P noentrypoint --cc gcc --cflags=-Isrc --cache-dir '..q(dir..'/cache')..' -o src/scanner.c src/scanner.nelua')
  normalize(dir..'/src/scanner.c')
  local result={};for _,p in ipairs(outputs) do result[p]=read(dir..'/'..p) end
  local manifest={'tree-sitter=0.25.10\nabi=14\nnelua-repository=https://github.com/Spaceghost/nelua-lang\nnelua='..pin..'\n',
    'grammar-flags=-c -C -r -P nogc --cc gcc\nscanner-flags=-c -C -r -P nogc -P noentrypoint --cc gcc --cflags=-Isrc\nnormalization=compile-command-and-compile-hash-comments-only\n'}
  for _,p in ipairs(inputs) do manifest[#manifest+1]='input '..p..' sha256='..input_hash[p]..'\n' end
  for _,p in ipairs(outputs) do manifest[#manifest+1]='output '..p..' sha256='..digest(dir..'/'..p)..'\n' end
  result['PROVENANCE.txt']=table.concat(manifest);return result
end
local ok,problem=xpcall(function()
  local one=build(temp..'/one');local two=build(temp..'/two')
  for _,p in ipairs(inputs) do assert(digest(root..'/'..p)==input_hash[p],'input changed: '..p) end
  for p,s in pairs(one) do assert(s==two[p],'non-reproducible output: '..p) end
  -- Exact regular-file output inventory; reject symlinks and unreviewed C/headers.
  local expected={['src/scanner.nelua']=true};for _,p in ipairs(outputs) do expected[p]=true end
  for p in run('find src -type f -o -type l'):gmatch('[^\n]+') do assert(expected[p],'unexpected output: '..p) end
  assert(run('find src -type l')=='','symlink delivery refused')
  for p,s in pairs(one) do
    if mode=='--check' then assert(read(root..'/'..p)==s,'generated drift: '..p..'; checkout unchanged')
    else write(root..'/'..p..'.tmp',s);assert(os.rename(root..'/'..p..'.tmp',root..'/'..p)) end
  end
  print('Tree-sitter parser and Nelua scanner: two clean generations match; '..mode)
end,debug.traceback)
run('rm -rf '..q(temp));if not ok then error(problem,0) end
