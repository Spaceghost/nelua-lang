local lester = require 'nelua.thirdparty.lester'
local expect = require 'spec.tools.expect'
local configer = require 'nelua.configer'
local Scope = require 'nelua.scope'
local CContext = require 'nelua.ccontext'
local compactc = require 'nelua.compactc'
local describe, it = lester.describe, lester.it

local function snapshot()
  local defaults = configer.get_default()
  local active = configer.get()
  return {
    defaults = defaults,
    active = active,
    default_short = defaults.compact_c_short_names,
    active_short = active.compact_c_short_names,
    default_internal = defaults.compact_c_internal_names,
    active_internal = active.compact_c_internal_names,
    default_clean = defaults.compact_c_clean_conditions,
    active_clean = active.compact_c_clean_conditions,
    default_exports = defaults.compact_c_suppress_export_declarations,
    active_exports = active.compact_c_suppress_export_declarations,
    default_noerrorloc = defaults.pragmas.noerrorloc,
    active_noerrorloc = active.pragmas.noerrorloc,
    default_nocwarnpragmas = defaults.pragmas.nocwarnpragmas,
    active_nocwarnpragmas = active.pragmas.nocwarnpragmas,
    default_nocheading = defaults.pragmas.nocheading,
    active_nocheading = active.pragmas.nocheading,
    default_nocstaticassert = defaults.pragmas.nocstaticassert,
    active_nocstaticassert = active.pragmas.nocstaticassert,
  }
end

local function restore(s)
  s.defaults.compact_c_short_names = s.default_short
  s.active.compact_c_short_names = s.active_short
  s.defaults.compact_c_internal_names = s.default_internal
  s.active.compact_c_internal_names = s.active_internal
  s.defaults.compact_c_clean_conditions = s.default_clean
  s.active.compact_c_clean_conditions = s.active_clean
  s.defaults.compact_c_suppress_export_declarations = s.default_exports
  s.active.compact_c_suppress_export_declarations = s.active_exports
  s.defaults.pragmas.noerrorloc = s.default_noerrorloc
  s.active.pragmas.noerrorloc = s.active_noerrorloc
  s.defaults.pragmas.nocwarnpragmas = s.default_nocwarnpragmas
  s.active.pragmas.nocwarnpragmas = s.active_nocwarnpragmas
  s.defaults.pragmas.nocheading = s.default_nocheading
  s.active.pragmas.nocheading = s.active_nocheading
  s.defaults.pragmas.nocstaticassert = s.default_nocstaticassert
  s.active.pragmas.nocstaticassert = s.active_nocstaticassert
end

describe("compact C codegen", function()

it("applies compact settings immediately and to future config builds", function()
  local old = snapshot()
  compactc.enable()

  local defaults = configer.get_default()
  local active = configer.get()
  assert(defaults.compact_c_short_names and active.compact_c_short_names)
  assert(defaults.compact_c_internal_names and active.compact_c_internal_names)
  assert(defaults.compact_c_clean_conditions and active.compact_c_clean_conditions)
  assert(defaults.pragmas.noerrorloc and active.pragmas.noerrorloc)
  assert(defaults.pragmas.nocwarnpragmas and active.pragmas.nocwarnpragmas)
  assert(defaults.pragmas.nocheading and active.pragmas.nocheading)

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

  -- Turning the active feature off takes effect immediately; this is the same
  -- configuration object the hooks consult while generating code.
  defaults.compact_c_short_names = false
  active.compact_c_short_names = false
  local normal_scope = {usednames = {}}
  expect.equal(Scope.generate_name(normal_scope, 'nelua_long_internal_name'),
               'nelua_long_internal_name_1')

  restore(old)
end)

it("can explicitly omit static ABI assertions and duplicate exports", function()
  local old = snapshot()
  compactc.enable{static_asserts = false, export_declarations = false}

  local defaults = configer.get_default()
  local active = configer.get()
  assert(defaults.pragmas.nocstaticassert and active.pragmas.nocstaticassert)
  assert(defaults.compact_c_suppress_export_declarations)
  assert(active.compact_c_suppress_export_declarations)

  restore(old)
end)

end)
