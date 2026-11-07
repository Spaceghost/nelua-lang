local luabuiltins = require 'nelua.luabuiltins'
local luadefs = {}

luadefs.unary_ops = {
  ['not'] = 'not ',
  ['unm'] = '-',
  ['bnot'] = '~',
  ['len'] = '#',
}

luadefs.binary_ops = {
  ['or'] = 'or',
  ['and'] = 'and',
  ['ne'] = '~=',
  ['eq'] = '==',
  ['le'] = '<=',
  ['ge'] = '>=',
  ['lt'] = '<',
  ['gt'] = '>',
  ['bor'] = '|',
  ['bxor'] = '~',
  ['band'] = '&',
  ['shl'] = '<<',
  ['shr'] = '>>',
  ['asr'] = '>>', -- emitted through `nelua_asr`
  ['add'] = '+',
  ['sub'] = '-',
  ['mul'] = '*',
  ['div'] = '/',
  ['idiv'] = '//',
  ['tdiv'] = '//', -- emitted through `nelua_tdiv`
  ['mod'] = '%',
  ['tmod'] = '%', -- emitted through `nelua_tmod`
  ['pow'] = '^',
  ['concat'] = '..',
}

luadefs.lua51_unary_ops = {
  ['bnot']  = { func = 'bit.bnot', builtin = 'bit'},
}

luadefs.lua51_binary_ops = {
  ['idiv']  = { func = luabuiltins.operators.idiv },
  ['pow']   = { func = 'math.pow' },
  ['bor']   = { func = 'bit.bor', builtin = 'bit' },
  ['band']  = { func = 'bit.band', builtin = 'bit' },
  ['bxor']  = { func = 'bit.bxor', builtin = 'bit' },
  ['shl']   = { func = 'bit.lshift', builtin = 'bit' },
  ['shr']   = { func = 'bit.rshift', builtin = 'bit' }
}

return luadefs
