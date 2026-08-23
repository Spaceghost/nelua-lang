--[[
Compiler benchmark utility.

Runs the compiler in fresh processes and summarizes its existing timing output.
This is intended for comparing compiler changes, not generated program speed.
Use NELUA_BENCH_RUNS to change repetitions and pass source files as arguments.
]]

local executor = require 'nelua.utils.executor'
local fs = require 'nelua.utils.fs'
local platform = require 'nelua.utils.platform'

local compilerbench = {}
local nelua = platform.is_windows and 'nelua.bat' or './nelua'

local phase_order = {
  'startup',
  'parse',
  'preprocess',
  'analyze',
  'generate',
  'total',
}

-- Parse the output produced by the compiler's `--timing` option.
function compilerbench.parse_timing(output)
  local timings = {}
  for name,value in output:gmatch('([%a ]-)%s+([%d.]+)%s+ms') do
    name = name:match('^%s*(.-)%s*$')
    if name == 'total time' then
      name = 'total'
    end
    timings[name] = tonumber(value)
  end
  return timings
end

-- Return the median without modifying the input list.
function compilerbench.median(values)
  assert(#values > 0, 'cannot calculate median of an empty list')
  local sorted = {}
  for i,value in ipairs(values) do
    sorted[i] = value
  end
  table.sort(sorted)
  local middle = math.floor(#sorted / 2) + 1
  if #sorted % 2 == 1 then
    return sorted[middle]
  end
  return (sorted[middle-1] + sorted[middle]) / 2
end

-- Parse the number of measured runs, defaulting to five.
function compilerbench.parse_runs(value)
  local runs = value == nil and 5 or tonumber(value)
  assert(runs and runs >= 1 and runs == math.floor(runs),
    'NELUA_BENCH_RUNS must be a positive integer')
  return runs
end

-- Copy explicit inputs or select the upstream compiler workload.
function compilerbench.resolve_inputs(args)
  local inputs = {}
  for i,input in ipairs(args) do
    inputs[i] = input
  end
  if #inputs == 0 then
    inputs[1] = 'tests/all_test.nelua'
  end
  return inputs
end

-- Collect one warmup followed by `runs` complete timing samples.
function compilerbench.collect(runs, measure)
  local samples = {}
  for _,phase in ipairs(phase_order) do
    samples[phase] = {}
  end

  for run=0,runs do
    local timings = measure(run)
    if run > 0 then
      for _,phase in ipairs(phase_order) do
        local value = timings[phase]
        assert(type(value) == 'number', string.format("missing timing phase '%s'", phase))
        samples[phase][run] = value
      end
    end
  end
  return samples
end

--luacov:disable

-- Measure one input in a fresh compiler process and remove generated files.
function compilerbench.measure_input(input, outprefix)
  outprefix = outprefix or fs.tmpname()
  local output, err = executor.evalex(nelua, {
    '--no-color', '--no-cache', '--timing', '--code', '--output', outprefix, input
  })
  fs.deletefile(outprefix)
  fs.deletefile(outprefix..'.c')
  assert(output, err)
  return compilerbench.parse_timing(output)
end

local function report_input(input, samples)
  for _,phase in ipairs(phase_order) do
    print(string.format('%-28s %-12s %10.1f',
      input, phase, compilerbench.median(samples[phase])))
  end
end

function compilerbench.main(args, runs)
  runs = runs or compilerbench.parse_runs(os.getenv('NELUA_BENCH_RUNS'))
  local inputs = compilerbench.resolve_inputs(args)

  print(string.format('%-28s %-12s %10s', 'input', 'phase', 'median ms'))
  print(string.rep('-', 52))
  for _,input in ipairs(inputs) do
    local samples = compilerbench.collect(runs, function()
      return compilerbench.measure_input(input)
    end)
    report_input(input, samples)
  end
  return 0
end

if not ... then
  os.exit(compilerbench.main(arg))
end

--luacov:enable

return compilerbench
