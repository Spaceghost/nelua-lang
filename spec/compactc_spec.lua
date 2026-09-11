local lester = require 'nelua.thirdparty.lester'
local expect = require 'spec.tools.expect'
local configer = require 'nelua.configer'
local Scope = require 'nelua.scope'
local CContext = require 'nelua.ccontext'
local compactc = require 'nelua.compactc'
local describe, it = lester.describe, lester.it

describe("compact C codegen", function()

it("shortens compiler generated and module-qualified internal names", function()
  local defaults = configer.get_default()
  local old_short_names = defaults.compact_c_short_names
  local old_internal_names = defaults.compact_c_internal_names
  local old_noerrorloc = defaults.pragmas.noerrorloc
  local old_nocwarnpragmas = defaults.pragmas.nocwarnpragmas
  local old_nocheading = defaults.pragmas.nocheading
  local old_nocstaticassert = defaults.pragmas.nocstaticassert

  compactc.enable()

  local scope = {usednames = {}}
  expect.equal(Scope.generate_name(scope, 'nelua_long_internal_name'), 'nl1')
  expect.equal(Scope.generate_name(scope, 'another_long_internal_name'), 'nl2')

  local context = {}
  local internal = {
    _attr = true,
    staticstorage = true,
    name = 'parse_value',
    codename = 'some_module_parse_value'
  }
  expect.equal(CContext.declname(context, internal), 'm_parse_value')

  -- ABI-visible names are never compacted.
  local exported = {
    _attr = true,
    staticstorage = true,
    name = 'public_name',
    codename = 'melodica_public_name',
    cexport = true
  }
  expect.equal(CContext.declname(context, exported), 'melodica_public_name')

  assert(defaults.pragmas.noerrorloc)
  assert(defaults.pragmas.nocwarnpragmas)
  assert(defaults.pragmas.nocheading)
  expect.equal(defaults.pragmas.nocstaticassert, old_nocstaticassert)

  defaults.compact_c_short_names = false
  local normal_scope = {usednames = {}}
  expect.equal(Scope.generate_name(normal_scope, 'nelua_long_internal_name'),
               'nelua_long_internal_name_1')

  defaults.compact_c_short_names = old_short_names
  defaults.compact_c_internal_names = old_internal_names
  defaults.pragmas.noerrorloc = old_noerrorloc
  defaults.pragmas.nocwarnpragmas = old_nocwarnpragmas
  defaults.pragmas.nocheading = old_nocheading
  defaults.pragmas.nocstaticassert = old_nocstaticassert
end)

it("can explicitly omit static ABI assertions and duplicate exports", function()
  local defaults = configer.get_default()
  local old_nocstaticassert = defaults.pragmas.nocstaticassert
  local old_exports = defaults.compact_c_suppress_export_declarations

  compactc.enable{static_asserts = false, export_declarations = false}
  assert(defaults.pragmas.nocstaticassert)
  assert(defaults.compact_c_suppress_export_declarations)

  defaults.pragmas.nocstaticassert = old_nocstaticassert
  defaults.compact_c_suppress_export_declarations = old_exports
  defaults.compact_c_short_names = false
  defaults.compact_c_internal_names = false
end)

end)
