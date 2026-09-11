--[[
Compact C code generation helpers.

This module is intentionally opt-in and conservative. It is meant for projects
that distribute Nelua-generated C source (for example, amalgamated C99
libraries) where the generated source itself is part of the product.

Enable it before compiler option parsing, typically with:

  NELUA_INIT="require('nelua.compactc').enable()" nelua ...

The profile only changes presentation/reproducibility-oriented code generation
by default. It does not disable runtime checks, garbage collection, variable
initialization, or static ABI assertions.
]]

local configer = require 'nelua.configer'
local Scope = require 'nelua.scope'

local compactc = {}
local installed = false
local original_generate_name = Scope.generate_name

local function install_short_names()
  if installed then return end
  installed = true

  function Scope:generate_name(name, compact)
    local config = configer.get()
    if not config.compact_c_short_names then
      return original_generate_name(self, name, compact)
    end

    -- These names are compiler-generated implementation details. Public C ABI
    -- names fixed with <cexport> / <codename>, and C imports, do not come
    -- through this path and therefore remain stable and descriptive.
    local count = (self.compact_c_name_count or 0) + 1
    self.compact_c_name_count = count
    return 'nl' .. count
  end
end

function compactc.enable(options)
  options = options or {}
  local defaults = configer.get_default()
  local pragmas = defaults.pragmas

  -- Keep output deterministic and omit compiler-warning scaffolding. Both are
  -- output-only changes; they do not alter normal successful program behavior.
  if options.error_locations ~= true then
    pragmas.noerrorloc = true
  end
  if options.warning_pragmas ~= true then
    pragmas.nocwarnpragmas = true
  end

  -- Static assertions remain on by default because a few lines of generated C
  -- are cheaper than silently accepting an ABI disagreement on an odd target.
  if options.static_asserts == false then
    pragmas.nocstaticassert = true
  end

  defaults.compact_c_short_names = options.short_names ~= false
  install_short_names()
end

return compactc
