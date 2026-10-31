local lester = require 'nelua.thirdparty.lester'
local describe, it = lester.describe, lester.it

local expect = require 'spec.tools.expect'
local fs = require 'nelua.utils.fs'
local configer = require 'nelua.configer'
local version = require 'nelua.version'
local ccompiler = require 'nelua.ccompiler'
local lfs = require 'lfs'

describe("runner", function()
  local ccinfo = ccompiler.get_cc_info()

it("version numbers" , function()
  if fs.isfile('.git/config') then
    expect.equal(#version.NELUA_GIT_HASH, 40)
    assert(version.NELUA_GIT_BUILD > 0)
    assert(version.NELUA_GIT_DATE ~= 'unknown')
  end
end)

it("compile simple programs" , function()
  expect.run('--no-cache --object examples/helloworld.nelua')
  if ccinfo.is_gcc or ccinfo.is_clang then
    expect.run('--no-cache --assembly examples/helloworld.nelua')
  end
  expect.run('--no-cache --code examples/helloworld.nelua')
  expect.run('--no-cache --binary --strip-bin examples/helloworld.nelua')
  expect.run('--code examples/helloworld.nelua')
  expect.run('--generator lua --no-cache --code examples/helloworld.nelua')
  expect.run('--generator lua --binary examples/helloworld.nelua')
end)

it("run simple programs", function()
  expect.run({'--no-cache', '--timing', '--more-timing', '--eval', "##[[assert(true)]] return 0"})
  expect.run('--generator lua examples/helloworld.nelua', 'hello world')
  expect.run(' examples/helloworld.nelua', 'hello world')
  expect.run({'--generator', 'lua', '--eval', ""}, '')
  expect.run({'--lint', '--eval', ""})
  expect.run({'--generator', 'lua', '--eval', "print(_G.arg[1])", "hello"}, 'hello')
  expect.run({'--eval', ""})
  if ccinfo.is_gcc and not ccinfo.is_clang and ccinfo.is_linux then
    expect.run({'--eval', "## cflags '-w -g' linklib 'm' ldflags '-s'"})
  end
end)

it("error on parsing an invalid program" , function()
  expect.run_error('--aninvalidflag', 'unknown option')
  expect.run_error('--lint --eval invalid')
  expect.run_error('--lint invalid', 'invalid: No such file or directory')
  --expect.run_error({'--eval', "f()"}, 'undefined')
  expect.run_error({'--generator', 'lua', '--eval', "local a = 1_x"}, "literal suffix '_x' is undefined")
  expect.run_error('--cc invgcc examples/helloworld.nelua')
end)

it("print correct generated AST" , function()
  expect.run('--print-ast examples/helloworld.nelua', [[Block {
  Call {
    {
      String {
        "hello world"
      }
    },
    Id {
      "print"
    }
  }
}]])
  expect.run('--print-analyzed-ast examples/helloworld.nelua', [[type = "string"]])
end)

it("print correct code", function()
  expect.run({'--print-ppcode', '--eval', "##print(1)"}, 'print(1)')
  expect.run('--print-code examples/helloworld.nelua', 'hello world')
end)

it("define option", function()
  expect.run({
    '--generator', 'lua',
    '--analyze',
    '--define', 'DEF1',
    '-DDEF2',
    '-D', 'DEF3=1',
    "-DDEF4='asd'",
    '--eval',[[
      ## assert(DEF1 == true)
      ## assert(DEF2 == true)
      ## assert(DEF3 == 1)
      ## assert(DEF4 == 'asd')
    ]]})
  expect.run_error('-D1 examples/helloworld.nelua', "failed parsing parameter '1'")
end)

it("pragma option", function()
  expect.run({
    '--generator', 'lua',
    '--analyze',
    '--pragma', 'DEF1',
    '-PDEF2',
    '-P', 'DEF3=1',
    "-PDEF4='asd'",
    '--eval',[[
      ## assert(context.pragmas.DEF1 == true)
      ## assert(context.pragmas.DEF2 == true)
      ## assert(context.pragmas.DEF3 == 1)
      ## assert(context.pragmas.DEF4 == 'asd')
    ]]})
end)

it("configure module search paths", function()
  expect.run({'-L', './examples', '--eval',[[
    require 'helloworld'
  ]]}, 'hello world')
  expect.run_error({'--eval',[[
    require 'helloworld'
  ]]}, "module 'helloworld' not found")

  expect.run_error({'-L', './examples/invalid', '--analyze', '--eval',[[--nothing]]}, 'is not a valid directory')
  expect.run({'-L', './examples/?.lua', '--analyze', '--eval',[[
    ## assert(config.path:find('examples'))
  ]]})

  local defconfig = configer.get_default()
  local oldaddpath = defconfig.add_path
  defconfig.add_path = {'/tests'}
  expect.run({'-L', './examples', '--analyze', '--eval',[[
    ## assert(config.path:find('examples'))
    ## assert(config.path:find('tests'))
  ]]})
  defconfig.add_path = oldaddpath

  expect.run({'--path', './examples', '--analyze', '--eval',[[
    ## assert(config.path:match('examples'))
  ]]})
end)

it("debug options", function()
  expect.run({'--debug-resolve', '--analyze', '--eval',[[
    local x = 1
  ]]}, "symbol 'x' resolved to type 'int64'")
  expect.run({'--debug-scope-resolve', '--analyze', '--eval',[[
    local x = 1
  ]]}, "scope resolved 1 symbols")
end)

it("program arguments", function()
  expect.run({'--eval',[[
    require 'arg'
    assert(arg[1] == 'a')
    assert(arg[2] == 'b')
    assert(arg[3] == 'c')
    assert(#arg == 3)
  ]], 'a', 'b', 'c'})
end)

it("shared libraries", function()
  if ccinfo.is_gcc or ccinfo.is_clang then
    expect.run({'--shared-lib', 'tests/libmylib.nelua'})
    expect.run({'tests/mylib_test.nelua'},[[
mylib - init
mylib - in top scope
mylib - sum
the sum is:
3
mylib - terminate]])
  end
end)

it("bundled C libraries", function()
  expect.run({'tests/myclib_test.nelua'}, [[hello from C]])
end)

it("invalidates cached binaries when companion C sources change", function()
  for _,nocheading in ipairs{false, true} do
    local prefix = fs.tmpname()
    local mainfile, helperfile, otherfile = prefix..'.nelua', prefix..' helper.c', prefix..' other.c'
    local cachedir = prefix..' cache'
    local config = configer.get()
    local oldcachedir = config.cache_dir
    config.cache_dir = cachedir
    local _ <close> = setmetatable({}, {__close = function()
      config.cache_dir = oldcachedir
      for _,file in ipairs{prefix, mainfile, helperfile, otherfile} do fs.deletefile(file) end
      if fs.isdir(cachedir) then
        for file in lfs.dir(cachedir) do
          if file ~= '.' and file ~= '..' then fs.deletefile(fs.join(cachedir, file)) end
        end
        lfs.rmdir(cachedir)
      end
    end})
    local function helper(value)
      return '#ifndef CACHE_VALUE\n#define CACHE_VALUE '..value..
             '\n#endif\nint helper_one(void) { return CACHE_VALUE; }\n'
    end
    assert(fs.makefile(helperfile, helper(1)))
    assert(fs.makefile(otherfile, 'int helper_two(void) { return 3; }\n'))
    assert(fs.makefile(mainfile, string.format([[
      ## pragmas.nocheading = %s
      ## cfile %q; cfile %q
      local function helper_one(): cint <cimport> end
      local function helper_two(): cint <cimport> end
      print(helper_one() + helper_two())
    ]], tostring(nocheading), fs.basename(helperfile), fs.basename(otherfile))))
    local args = {'--cache-dir', cachedir, mainfile}
    expect.run(args, '4')
    local mtime = fs.getmodtime(helperfile)
    assert(fs.makefile(helperfile, helper(2))) -- same size, same timestamp
    assert(lfs.touch(helperfile, mtime, mtime))
    expect.run(args, '5')

    local binfile = fs.join(cachedir, fs.basename(prefix))..
                    ((ccinfo.is_windows or ccinfo.is_cygwin) and '.exe' or '')
    -- Unchanged contents still reuse the binary, independently of timestamps.
    assert(lfs.touch(binfile, 1, 1))
    expect.run(args, '5')
    expect.equal(fs.getmodtime(binfile), 1)
    local cachefile = binfile..'.hash'
    assert(fs.readfile(cachefile))
    if ccinfo.is_gcc or ccinfo.is_clang then
      local cachehash = fs.readfile(cachefile)
      expect.run({'--strip-bin', '--cache-dir', cachedir, mainfile}, '5')
      assert(fs.readfile(cachefile) ~= cachehash)
      expect.run({'--cache-dir', cachedir, '--cflags=-DCACHE_VALUE=7', mainfile}, '10')
      expect.run({'--cache-dir', cachedir, '--cflags=-DCACHE_VALUE=8', mainfile}, '11')
    end

    assert(fs.makefile(helperfile, 'invalid C source'))
    expect.run_error(args, 'C compilation for')
    assert(not fs.isfile(cachefile)) -- failed builds must not retain a valid stamp
    assert(fs.makefile(helperfile, helper(2)))
    expect.run(args, '5')
    expect.run({'--no-cache', '--cache-dir', cachedir, mainfile}, '5')
    assert(not fs.isfile(cachefile))
    expect.run(args, '5')
    fs.deletefile(helperfile)
    expect.run_error(args, 'failed to read C source file')
  end
end)

it("runtime-free callbacks in a C-owned program", function()
  expect.run({'--no-cache', '--release', 'examples/c_host/kernel.nelua'},
             'runtime-free C host: pass')
end)

it("freestanding leaf with a C-owned entrypoint", function()
  expect.run({'--no-cache', '--release', 'examples/freestanding/kernel.nelua'}, '')
end)

it("static libraries", function()
  if ccinfo.is_gcc or ccinfo.is_clang then
    expect.run({'--static-lib', 'tests/libmylib_static.nelua'})
    expect.run({'tests/mylib_static_test.nelua'},[[
mylib - init
mylib - in top scope
mylib - sum
the sum is:
3
mylib - terminate]])
  end
end)

it("verbose", function()
  expect.run({'--verbose','--eval',[[
    ## assert(true)
    assert(true)
  ]]})
end)

it("version", function()
  expect.run('--version', "Nelua")
  expect.run('--semver', ".")
end)

it("error tracebacks", function()
  expect.run_error({'--eval',[[
    local function f(x: auto)
      ## static_error('fail')
    end
    f(1)
  ]]}, "polymorphic function instantiation")
end)

end)
