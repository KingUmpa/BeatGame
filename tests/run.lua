-- tests/run.lua
-- Minimal test harness. Each tests/test_*.lua returns a table of name -> function(T).
--   lovec . --test                 run everything
--   lovec . --test --filter=midi   only tests whose file or name contains "midi"

local util = require("src.util")

local FILES = { "tests.test_midi", "tests.test_mixer", "tests.test_juice", "tests.test_level", "tests.test_round", "tests.test_game_song" }

local T = {}

function T.eq(actual, expected, msg)
  if actual ~= expected then
    error(("%sexpected %s, got %s"):format(msg and (msg .. ": ") or "", tostring(expected), tostring(actual)), 2)
  end
end

function T.near(actual, expected, eps, msg)
  if math.abs(actual - expected) > (eps or 1e-6) then
    error(("%sexpected %s +/- %s, got %s"):format(msg and (msg .. ": ") or "", tostring(expected), tostring(eps), tostring(actual)), 2)
  end
end

function T.ok(cond, msg)
  if not cond then error(msg or "assertion failed", 2) end
end

local R = {}

function R.main(args)
  local filter = util.argValue(args, "--filter", nil)
  local passed, failed = 0, 0
  for _, mod in ipairs(FILES) do
    local tests = require(mod)
    local names = {}
    for name in pairs(tests) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      if not filter or mod:find(filter, 1, true) or name:find(filter, 1, true) then
        local ok, err = pcall(tests[name], T)
        if ok then
          passed = passed + 1
          print("  ok    " .. mod:gsub("^tests%.", "") .. " / " .. name)
        else
          failed = failed + 1
          print("  FAIL  " .. mod:gsub("^tests%.", "") .. " / " .. name .. "\n        " .. tostring(err))
        end
      end
    end
  end
  print(("%d passed, %d failed"):format(passed, failed))
  love.event.quit(failed == 0 and 0 or 1)
end

return R
