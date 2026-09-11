--[[
Compact C code generation helpers.

This module is intentionally opt-in and conservative. It is meant for projects
that distribute Nelua-generated C source (for example, amalgamated C99
libraries) where the generated source itself is part of the product.

Enable it before compiler option parsing, typically with:

  NELUA_INIT="require('nelua.compactc').enable()" nelua ...

The default profile changes presentation/reproducibility-oriented code
generation only. Runtime checks, garbage collection, initialization semantics,
and static ABI assertions remain unchanged unless explicitly requested.
]]

local configer = require 'nelua.configer'
local Scope = require 'nelua.scope'
local CContext = require 'nelua.ccontext'
local CEmitter = require 'nelua.cemitter'
local cdefs = require 'nelua.cdefs'

local compactc = {}
local installed = false

local original_generate_name = Scope.generate_name
local original_declname = CContext.declname
local original_add_declaration = CContext.add_declaration
local original_add_qualified_declaration = CEmitter.add_qualified_declaration
local original_add_val2boolean = CEmitter.add_val2boolean

local comparison_ops = {
  eq = true, ne = true,
  lt = true, le = true,
  gt = true, ge = true,
}

local function install_hooks()
  if installed then return end
  installed = true

  -- Shorten names that exist only because the compiler needed a temporary.
  function Scope:generate_name(name, compact)
    local config = configer.get()
    if not config.compact_c_short_names then
      return original_generate_name(self, name, compact)
    end

    local count = (self.compact_c_name_count or 0) + 1
    self.compact_c_name_count = count
    return 'nl' .. count
  end

  -- Top-level internal symbols normally inherit their full module path in the
  -- C name. For distributable C that is needless bulk. Keep the human source
  -- name and a tiny `m_` namespace instead. Public/fixed/imported names are
  -- deliberately untouched.
  function CContext:declname(attr)
    local config = configer.get()
    if config.compact_c_internal_names and attr and attr._attr and
       attr.staticstorage and attr.name and attr.codename and
       not attr.cexport and not attr.cimport and not attr.fixedcodename and
       not attr.entrypoint and not attr.nodecl then
      if attr.declname then return attr.declname end

      self.compact_c_used_names = self.compact_c_used_names or {}
      local base = 'm_' .. cdefs.quotename(attr.name)
      local candidate = base
      local suffix = 1
      while self.compact_c_used_names[candidate] or
            (self.cimports and self.cimports[candidate]) do
        suffix = suffix + 1
        candidate = base .. suffix
      end
      self.compact_c_used_names[candidate] = true
      attr.declname = candidate
      return candidate
    end
    return original_declname(self, attr)
  end

  -- In boolean context the surrounding construct already owns precedence.
  -- Nelua normally emits `if((a == b))`; compact output can safely use
  -- `if(a == b)` for the six comparison operators while leaving every other
  -- expression form untouched. Builtin/special comparisons that do not emit a
  -- single outer pair are passed through unchanged.
  function CEmitter:add_val2boolean(val, valtype)
    local config = configer.get()
    valtype = valtype or (type(val) == 'table' and val.attr and val.attr.type)
    if config.compact_c_clean_conditions and valtype and valtype.is_boolean and
       type(val) == 'table' and val.is_BinaryOp and comparison_ops[val[2]] then
      local tmp = self:fork()
      tmp:add_value(val)
      local text = tmp:generate()
      if text:sub(1,1) == '(' and text:sub(-1) == ')' then
        self:add_text(text:sub(2, -2))
        return
      end
    end
    return original_add_val2boolean(self, val, valtype)
  end

  -- A single-header amalgamation already contains its public prototypes before
  -- the generated implementation. Let callers opt out of Nelua's duplicate
  -- cexport declarations and their platform visibility macro entirely.
  function CEmitter:add_qualified_declaration(attr, type, name)
    local config = configer.get()
    if config.compact_c_suppress_export_declarations and attr.cexport then
      self.context.compact_c_suppressed_exports =
        self.context.compact_c_suppressed_exports or {}
      self.context.compact_c_suppressed_exports[attr.codename] = true

      local old_cexport, old_nocstatic = attr.cexport, attr.nocstatic
      attr.cexport, attr.nocstatic = nil, true
      original_add_qualified_declaration(self, attr, type, name)
      attr.cexport, attr.nocstatic = old_cexport, old_nocstatic
      return
    end
    return original_add_qualified_declaration(self, attr, type, name)
  end

  function CContext:add_declaration(code, name)
    local config = configer.get()
    if config.compact_c_suppress_export_declarations and name and
       self.compact_c_suppressed_exports and
       self.compact_c_suppressed_exports[name] then
      return
    end
    return original_add_declaration(self, code, name)
  end
end

local function set_option(defaults, active, name, value)
  defaults[name] = value
  active[name] = value
end

local function set_pragma(defaults, active, name, value)
  defaults.pragmas[name] = value
  active.pragmas = active.pragmas or {}
  active.pragmas[name] = value
end

function compactc.enable(options)
  options = options or {}
  local defaults = configer.get_default()
  local active = configer.get()

  -- `configer` has already constructed an active configuration by the time a
  -- NELUA_INIT hook can require us. Set both the defaults (for the upcoming
  -- option rebuild) and the active table (for direct/compiler-library use).
  -- This makes the profile independent of activation timing.
  if options.error_locations ~= true then
    set_pragma(defaults, active, 'noerrorloc', true)
  end
  if options.warning_pragmas ~= true then
    set_pragma(defaults, active, 'nocwarnpragmas', true)
  end
  if options.heading ~= true then
    set_pragma(defaults, active, 'nocheading', true)
  end

  -- Static assertions stay on unless explicitly disabled. Portable amalgamated
  -- source may disable host ABI assertions and prove portability by compiling
  -- the exact artifact for each target instead.
  if options.static_asserts == false then
    set_pragma(defaults, active, 'nocstaticassert', true)
  end

  set_option(defaults, active, 'compact_c_short_names', options.short_names ~= false)
  set_option(defaults, active, 'compact_c_internal_names', options.internal_names ~= false)
  set_option(defaults, active, 'compact_c_clean_conditions', options.clean_conditions ~= false)
  set_option(defaults, active, 'compact_c_suppress_export_declarations',
             options.export_declarations == false)

  install_hooks()
end

return compactc
