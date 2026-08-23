local lester = require 'nelua.thirdparty.lester'
local describe, it = lester.describe, lester.it

local expect = require 'spec.tools.expect'
local fs = require 'nelua.utils.fs'
local configer = require 'nelua.configer'
local version = require 'nelua.version'
local ccompiler = require 'nelua.ccompiler'
local config = configer.get()

local function run_unquiet(args)
  local oldquiet = config.quiet
  config.quiet = false
  local ok, output, errout = pcall(expect.run, args)
  config.quiet = oldquiet
  assert(ok, output)
  return output, errout
end

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

it("more timing reports memory in KiB", function()
  local output = run_unquiet(
    {'--more-timing', '--analyze', '--eval', "local x = 1"})
  assert(output:match('memory%s+%d+%.%d KiB\n'), output)
end)

it("timing without more timing omits memory", function()
  local output = run_unquiet(
    {'--timing', '--analyze', '--eval', "local x = 1"})
  assert(not output:find('memory', 1, true), output)
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
    '--pragma', 'p1=true',
    '-Pp2=true',
    '-P', 'p3=1',
    "-Pp4='asd'",
    '--eval',[[
      ## assert(pragmas.p1 == true)
      ## assert(pragmas.p2 == true)
      ## assert(pragmas.p3 == 1)
      ## assert(pragmas.p4 == 'asd')
    ]]})
  expect.run_error('-P1 examples/helloworld.nelua', "failed parsing pragma '1'")
end)

it("configure module search paths", function()
  local libpath = fs.abspath('lib')
  expect.run({
    '--generator', 'lua',
    '--analyze',
    '--path', libpath..'/?.nelua',
    '--eval', "require 'math'"
  })
  expect.run({
    '--generator', 'lua',
    '--analyze',
    '--add-path', libpath,
    '--eval', "require 'math'"
  })
  expect.run({
    '--generator', 'lua',
    '--analyze',
    '--add-path', libpath..'/?.nelua',
    '--eval', "require 'math'"
  })
  expect.run_error({
    '--generator', 'lua',
    '--analyze',
    '--add-path', 'invalid-path',
    '--eval', "require 'math'"
  }, "path 'invalid-path' is not a valid directory")
end)

it("debug options", function()
  expect.run('--profile-compiler --analyze --eval "local x = 1"', 'profiler')
  expect.run('--debug-resolve --analyze --eval "local x = 1"', 'resolved')
  expect.run('--debug-scope-resolve --analyze --eval "local x = 1"', 'resolved')
end)

it("program arguments", function()
  expect.run({'--generator', 'lua', '--eval', "print(_G.arg[1])", '--', '--hello'}, '--hello')
  expect.run({'--generator', 'lua', '--eval', "print(_G.arg[1])", '--hello'}, '--hello')
end)

it("shared libraries", function()
  expect.run('--shared-lib --eval "global function f() end"')
end)

it("bundled C libraries", function()
  expect.run('--eval "require \'C.stdio\'; C.printf(\'hello\\n\')"', 'hello')
end)

it("static libraries", function()
  expect.run('--static-lib --eval "global function f() end"')
end)

it("verbose", function()
  local oldquiet = config.quiet
  config.quiet = false
  local ok, err = pcall(expect.run, {'--verbose', '--analyze', '--eval', "local x = 1"}, 'using config file')
  config.quiet = oldquiet
  assert(ok, err)
end)

it("version", function()
  expect.run('--version', 'Nelua')
  expect.run('--semver', version.NELUA_SEMVER)
end)

it("error tracebacks", function()
  expect.run_error({'--eval', "## error('test')"}, 'stack traceback')
end)

end)
