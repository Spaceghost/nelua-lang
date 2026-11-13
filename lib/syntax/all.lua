-- The complete opt-in pack. Individual modules remain independently usable.
return function(syntax)
  for _, name in ipairs{'compound', 'pipe', 'interp', 'control', 'choose', 'lambda',
                        'let', 'using', 'collect', 'literals', 'operators'} do
    syntax.use('syntax.'..name)
  end
end
