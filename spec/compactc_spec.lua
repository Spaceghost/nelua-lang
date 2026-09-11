local lester = require 'nelua.thirdparty.lester'
local expect = require 'spec.tools.expect'
local configer = require 'nelua.configer'
local Scope = require 'nelua.scope'
local compactc = require 'nelua.compactc'
local describe, it = lester.describe, lester.it

describe("compact C codegen", function()

it("shortens only compiler generated names when enabled", function()
  local defaults = configer.get_default()
  local old_short_names = defaults.compact_c_short_names
  local old_noerrorloc = defaults.pragmas.noerrorloc
  local old_nocwarnpragmas = defaults.pragmas.nocwarnpragmas
  local old_nocstaticassert = defaults.pragmas.nocstaticassert

  compactc.enable()

  local scope = {usednames = {}}
  expect.equal(Scope.generate_name(scope, 'nelua_long_internal_name'), 'nl1')
  expect.equal(Scope.generate_name(scope, 'another_long_internal_name'), 'nl2')
  assert(defaults.pragmas.noerrorloc)
  assert(defaults.pragmas.nocwarnpragmas)
  expect.equal(defaults.pragmas.nocstaticassert, old_nocstaticassert)

  defaults.compact_c_short_names = false
  local normal_scope = {usednames = {}}
  expect.equal(Scope.generate_name(normal_scope, 'nelua_long_internal_name'),
               'nelua_long_internal_name_1')

  defaults.compact_c_short_names = old_short_names
  defaults.pragmas.noerrorloc = old_noerrorloc
  defaults.pragmas.nocwarnpragmas = old_nocwarnpragmas
  defaults.pragmas.nocstaticassert = old_nocstaticassert
end)

it("can explicitly omit static ABI assertions", function()
  local defaults = configer.get_default()
  local old_nocstaticassert = defaults.pragmas.nocstaticassert
  compactc.enable{static_asserts = false}
  assert(defaults.pragmas.nocstaticassert)
  defaults.pragmas.nocstaticassert = old_nocstaticassert
  defaults.compact_c_short_names = false
end)

end)
