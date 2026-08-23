local lester = require 'nelua.thirdparty.lester'
local describe, it = lester.describe, lester.it

local expect = lester.expect
local compilerbench = require 'spec.tools.compilerbench'

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

end)
