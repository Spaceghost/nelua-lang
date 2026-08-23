local lester = require 'nelua.thirdparty.lester'
local describe, it = lester.describe, lester.it

local expect = lester.expect
local compilerbench = require 'spec.tools.compilerbench'
local fs = require 'nelua.utils.fs'

local function temp_path(suffix)
  local path = fs.tmpname()
  fs.deletefile(path)
  return path..(suffix or '')
end

local function with_temp_source(code, callback)
  local path = temp_path('.nelua')
  assert(fs.writefile(path, code))
  local ok, err = xpcall(function()
    callback(path)
  end, debug.traceback)
  fs.deletefile(path)
  assert(ok, err)
end

local function capture_print(callback)
  local lines = {}
  local oldprint = _G.print
  _G.print = function(...)
    local values = {}
    for i=1,select('#', ...) do
      values[i] = tostring(select(i, ...))
    end
    lines[#lines+1] = table.concat(values, '\t')
  end
  local ok, err = xpcall(callback, debug.traceback)
  _G.print = oldprint
  assert(ok, err)
  return table.concat(lines, '\n')
end

local function count_plain(text, substring)
  local count, start = 0, 1
  while true do
    local pos = text:find(substring, start, true)
    if not pos then return count end
    count = count + 1
    start = pos + #substring
  end
end

describe("compiler benchmark", function()

it("parse compiler timing output", function()
  local timings = compilerbench.parse_timing([[
startup      1.5 ms
parse        2.0 ms
preprocess   0.5 ms
analyze      3.0 ms
generate     4.0 ms
total time   11.0 ms
]])
  expect.equal(1.5, timings.startup)
  expect.equal(2.0, timings.parse)
  expect.equal(0.5, timings.preprocess)
  expect.equal(3.0, timings.analyze)
  expect.equal(4.0, timings.generate)
  expect.equal(11.0, timings.total)
end)

it("calculate timing medians without modifying samples", function()
  local samples = {4, 1, 3, 2}
  expect.equal(2.5, compilerbench.median(samples))
  expect.equal(4, samples[1])
  expect.equal(1, samples[2])
  expect.equal(3, samples[3])
  expect.equal(2, samples[4])
  expect.equal(2, compilerbench.median({3, 1, 2}))
end)

it("validate repetition count", function()
  expect.equal(5, compilerbench.parse_runs(nil))
  expect.equal(7, compilerbench.parse_runs('7'))
  local ok, err = pcall(compilerbench.parse_runs, '0')
  assert(not ok and tostring(err):find('positive integer', 1, true), err)
  ok, err = pcall(compilerbench.parse_runs, '2.5')
  assert(not ok and tostring(err):find('positive integer', 1, true), err)
end)

it("discard warmup timing samples", function()
  local calls = 0
  local samples = compilerbench.collect(2, function()
    calls = calls + 1
    return {
      startup = calls,
      parse = calls + 1,
      preprocess = calls + 2,
      analyze = calls + 3,
      generate = calls + 4,
      total = calls + 5,
    }
  end)
  expect.equal(3, calls)
  expect.equal(2, samples.startup[1])
  expect.equal(3, samples.startup[2])
  expect.equal(7, samples.total[1])
  expect.equal(8, samples.total[2])
end)

it("reject incomplete timing samples", function()
  local ok, err = pcall(compilerbench.collect, 1, function()
    return {startup = 1}
  end)
  assert(not ok and tostring(err):find("missing timing phase 'parse'", 1, true), err)
end)

it("default to the upstream compiler workload", function()
  local inputs = compilerbench.resolve_inputs({})
  expect.equal(1, #inputs)
  expect.equal('tests/all_test.nelua', inputs[1])
end)

it("preserve explicit benchmark inputs", function()
  local args = {'first.nelua', 'second.nelua'}
  local inputs = compilerbench.resolve_inputs(args)
  assert(inputs ~= args)
  expect.equal(2, #inputs)
  expect.equal('first.nelua', inputs[1])
  expect.equal('second.nelua', inputs[2])
end)

it("measure a real compiler input and clean generated files", function()
  with_temp_source('local x: integer = 1\n', function(input)
    local outprefix = temp_path()
    assert(fs.writefile(outprefix, 'sentinel'))
    local timings = compilerbench.measure_input(input, outprefix)
    for _,phase in ipairs({'startup', 'parse', 'preprocess', 'analyze', 'generate', 'total'}) do
      assert(type(timings[phase]) == 'number', "missing timing phase '"..phase.."'")
    end
    assert(not fs.isfile(outprefix), 'temporary output file was not removed')
    assert(not fs.isfile(outprefix..'.c'), 'temporary C file was not removed')
  end)
end)

it("clean generated files after a compiler error", function()
  with_temp_source('local =\n', function(input)
    local outprefix = temp_path()
    assert(fs.writefile(outprefix, 'sentinel'))
    assert(fs.writefile(outprefix..'.c', 'sentinel'))
    local ok = pcall(compilerbench.measure_input, input, outprefix)
    assert(not ok, 'invalid source unexpectedly compiled')
    assert(not fs.isfile(outprefix), 'temporary output file was not removed')
    assert(not fs.isfile(outprefix..'.c'), 'temporary C file was not removed')
  end)
end)

it("report every phase for multiple real inputs", function()
  with_temp_source('local x: integer = 1\n', function(first)
    with_temp_source('local y: integer = 2\n', function(second)
      local output = capture_print(function()
        expect.equal(0, compilerbench.main({first, second}, 1))
      end)
      expect.equal(6, count_plain(output, first))
      expect.equal(6, count_plain(output, second))
      for _,phase in ipairs({'startup', 'parse', 'preprocess', 'analyze', 'generate', 'total'}) do
        expect.equal(2, count_plain(output, phase))
      end
    end)
  end)
end)

end)
