-- tests/test_juice.lua

local Juice = require("src.config.juice")
local util = require("src.util")

local tests = {}

function tests.defaults_validate_cleanly(T)
  local data, issues = Juice.validate(Juice.defaults())
  T.eq(#issues, 0, "no issues: " .. table.concat(issues, "; "))
  T.eq(data.timing.good_ms, 220)
  T.eq(data.wrong_sound.lowpass_hz, 650)
end

function tests.numbers_are_clamped_and_ints_rounded(T)
  local raw = Juice.defaults()
  raw.timing.good_ms = 9999
  raw.flow.demo_repeats = 2.6
  raw.wrong_sound.pitch_semitones = -100
  local data, issues = Juice.validate(raw)
  T.eq(data.timing.good_ms, 500)
  T.eq(data.flow.demo_repeats, 3)
  T.eq(data.wrong_sound.pitch_semitones, -24)
  T.ok(#issues == 2, "two clamp warnings, got " .. #issues)
end

function tests.bad_values_fall_back_to_defaults(T)
  local raw = Juice.defaults()
  raw.audio.metronome = "sometimes"
  raw.lights.wrong_color = { 2, 0, 0 }
  raw.rules.lives = "three"
  raw.layout.frame = "yes"
  local data = Juice.validate(raw)
  T.eq(data.audio.metronome, "count_ins")
  T.eq(data.lights.wrong_color[1], 1.0)
  T.eq(data.rules.lives, 3)
  T.eq(data.layout.frame, true)
end

function tests.missing_keys_get_defaults_and_unknown_keys_survive(T)
  local data, issues = Juice.validate({ timing = { good_ms = 80 }, future = { thing = 1 } })
  T.eq(data.timing.good_ms, 80)
  T.eq(data.timing.perfect_ms, 45)
  T.eq(data.future.thing, 1)
  local unknown = false
  for _, i in ipairs(issues) do if i:find("future.thing", 1, true) then unknown = true end end
  T.ok(unknown, "unknown key reported")
end

function tests.every_entry_has_a_description_and_a_group(T)
  local groups = {}
  for _, g in ipairs(Juice.schema.groups) do groups[g.id] = true end
  for _, e in ipairs(Juice.schema.entries) do
    if e.key ~= "schema_version" then
      T.ok(e.desc and #e.desc > 10, e.key .. " has no description")
      T.ok(groups[e.key:match("^([^.]+)")], e.key .. " is in no group")
      if e.type == "number" or e.type == "int" then
        T.ok(e.min and e.max and e.min <= e.default and e.default <= e.max, e.key .. " default outside its range")
      end
    end
  end
end

function tests.serialize_writes_every_key(T)
  local json = require("lib.json")
  local back = json.decode(Juice.serialize(Juice.defaults()))
  for _, e in ipairs(Juice.schema.entries) do
    T.ok(util.getPath(back, e.key) ~= nil, e.key .. " missing from the written file")
  end
end

function tests.the_shipped_juice_json_is_valid(T)
  local json = require("lib.json")
  local raw = json.decode(assert(util.readFile("juice.json")))
  local _, issues = Juice.validate(raw)
  T.eq(#issues, 0, table.concat(issues, "; "))
end

return tests
