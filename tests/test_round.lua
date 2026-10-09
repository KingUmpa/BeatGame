-- tests/test_round.lua

local Juice = require("src.config.juice")
local Round = require("src.game.round")

-- juice defaults, growing by bars and with a 120 ms leeway unless a test says otherwise (most
-- of these test the layout and the judging, not the shipped feel)
local function J(changes)
  local j = Juice.defaults()
  j.flow.grow = "bars"
  j.timing.good_ms = 120
  for key, v in pairs(changes or {}) do require("src.util").setPath(j, key, v) end
  return j
end

-- a prepared level (Level.prepare's shape) at 120 BPM, half a second a beat: one button per
-- beat on pads 1-4; button 2 plays two notes; one free note at beat 0.5
local function prepared(bars, unboxed)
  local p = { bars = bars, unboxed = unboxed or "play", buttons = {}, free = {} }
  for b = 0, bars * 4 - 1 do
    local notes = { { beat = b, track = 1, key = 60 + b % 4, vel = 100 } }
    if b % 4 == 1 then notes[2] = { beat = b + 0.25, track = 1, key = 70, vel = 100 } end
    p.buttons[#p.buttons + 1] = { beat = b, endBeat = b + 0.5, pad = b % 4 + 1, color = { 1, 1, 1 }, vel = 100, notes = notes }
  end
  for bar = 0, bars - 1 do p.free[#p.free + 1] = { beat = bar * 4 + 0.5, track = 1, key = 80, vel = 100 } end
  return p
end

local tests = {}

-- a level's first round counts in; the rounds after it start with the demo, straight after
-- the turn before (the round finishes as its turn ends)
function tests.a_round_is_count_demo_gap_play(T)
  local r = Round.new(prepared(1), J(), 1, 8)
  local names = {}
  for _, p in ipairs(r.phases) do names[#names + 1] = ("%s %g-%g"):format(p.name, p.from, p.to) end
  T.eq(table.concat(names, ", "), "count 8-12, demo 12-16, gap 16-20, play 20-24")
  T.eq(r.finish, 24)
  local r2 = Round.new(prepared(1), J(), 2, r.finish)
  T.eq(r2.byName.demo.from, 24, "round 2's demo starts as round 1's turn ends")
  T.eq(r:phaseAt(21.5), "play")
  T.eq(#r:demoButtons(), 4)
  T.eq(#r:demoNotes(), 6, "5 button notes + 1 free note")
  T.eq(r:playButtons()[1].beat, 20)
  T.eq(#r:freePlayNotes(), 1)
end

function tests.muted_free_notes_stay_silent(T)
  local r = Round.new(prepared(1, "mute"), J(), 1, 0)
  T.eq(#r:demoNotes(), 5)
  T.eq(#r:freePlayNotes(), 0)
end

function tests.demo_repeats_and_the_pattern_grows_by_bars(T)
  local j = J({ ["flow.demo_repeats"] = 2, ["flow.start_bars"] = 1, ["flow.bars_per_round"] = 2 })
  T.eq(Round.count(prepared(4), j), 3, "1 bar, 3 bars, 4 bars")
  T.eq(Round.barsFor(4, j, 2), 3)
  local r = Round.new(prepared(4), j, 2, 0)
  T.eq(#r:demoButtons(), 24, "12 buttons, twice")
  T.eq(Round.count(prepared(4), J({ ["flow.bars_per_round"] = 0 })), 1)
end

-- like Simon: one more button each round; the pattern runs to the end of the bar its last
-- button is in, the whole level once every button is in
function tests.the_pattern_grows_a_button_a_round(T)
  local j = J({ ["flow.grow"] = "buttons" })
  T.eq(j.flow.start_buttons, 1)
  local p = prepared(2)                                  -- 8 buttons over 2 bars
  T.eq(Round.count(p, j), 8)
  local r1 = Round.new(p, j, 1, 0)
  T.eq(#r1:playButtons(), 1); T.eq(r1.beats, 4)
  local r2 = Round.new(p, j, 2, 0)
  T.eq(#r2:demoButtons(), 2)
  T.eq(#r2:demoNotes(), 4, "button 1, button 2 (two notes), the free note in bar 1")
  T.eq(Round.new(p, j, 5, 0).beats, 8, "button 5 is in bar 2")
  T.eq(#Round.new(p, j, 8, 0):playButtons(), 8)
  T.eq(#Round.new(p, j, 12, 0):playButtons(), 8, "never more than the level has")
  local two = J({ ["flow.grow"] = "buttons", ["flow.start_buttons"] = 2, ["flow.buttons_per_round"] = 3 })
  T.eq(Round.count(p, two), 3, "2, 5, 8 buttons")
end

-- in a song the demo and the turn start on the loop grid (multiples of the level length), so
-- the pattern lines up with the loops locked in under it; count-in and countdown stretch
function tests.song_rounds_sit_on_the_loop_grid(T)
  local p = prepared(2)
  local r = Round.new(p, J(), 2, 28, 8)                -- bars mode, round 2: the whole 2 bars
  local names = {}
  for _, ph in ipairs(r.phases) do names[#names + 1] = ("%s %g-%g"):format(ph.name, ph.from, ph.to) end
  T.eq(table.concat(names, ", "), "count 28-32, demo 32-40, gap 40-48, play 48-56", "no count-in after round 1: just the wait for the grid")
  T.eq(Round.new(p, J(), 2, 32, 8).byName.demo.from, 32, "on the grid already: the demo starts at once")
  T.eq(Round.new(p, J(), 1, 30, 8).byName.demo.from, 40, "round 1: 4 beats of count-in at least")
  local j = J({ ["flow.grow"] = "buttons" })
  local short = Round.new(p, j, 1, 0, 8)               -- one button: a 1-bar pattern
  T.eq(short.byName.demo.from, 8); T.eq(short.byName.play.from, 16); T.eq(short.finish, 20)
  T.eq(Round.new(p, J(), 1, 8).byName.demo.from, 12, "no grid outside a song")
end

function tests.presses_are_judged_on_buttons_not_notes(T)
  local r = Round.new(prepared(1), J(), 1, 0)          -- play starts at beat 12 = 6.0 s
  local j = Round.Judge.new(r, J(), 120)
  T.eq(#j.expected, 4, "4 buttons, though 5 notes")
  T.eq(j:press(1, 6.02).kind, "perfect")
  local h = j:press(2, 6.5 - 0.09)                     -- the two-note button, 90 ms early
  T.eq(h.kind, "good")
  T.eq(#h.button.notes, 2)
  T.eq(j:press(3, 7.2).kind, "wrong", "200 ms late is outside 120")
  T.eq(j:press(1, 7.5).kind, "wrong", "pad 1's button is already played")
end

function tests.leeway_comes_from_juice(T)
  local j = Round.Judge.new(Round.new(prepared(1), J(), 1, 0), J({ ["timing.good_ms"] = 250 }), 120)
  T.eq(j:press(1, 6.2).kind, "good")
end

function tests.missed_buttons_and_wrong_presses_are_mistakes(T)
  local j = Round.Judge.new(Round.new(prepared(1), J(), 1, 0), J(), 120)
  j:press(1, 6.0)
  j:press(4, 6.1)
  T.eq(#j:sweep(6.5), 0, "pad 2's button is still in reach")
  T.eq(#j:sweep(6.65), 1)
  T.eq(j:mistakes(), 2)
  T.eq(j:passed(), false, "1 mistake allowed by default")
  local lenient = J({ ["rules.extra_press_is_mistake"] = false })
  local k = Round.Judge.new(Round.new(prepared(1), lenient, 1, 0), lenient, 120)
  k:press(4, 6.1)
  T.eq(k:mistakes(), 0)
end

function tests.the_turn_is_done_after_the_last_beat_plus_leeway(T)
  local j = Round.Judge.new(Round.new(prepared(1), J(), 1, 0), J(), 120)
  T.eq(j:open(5.9), true)
  T.eq(j:open(5.8), false)
  T.eq(j:done(8.1), false)
  T.eq(j:done(8.13), true)
end

function tests.a_button_light_is_a_tap_whatever_its_box(T)
  local Lights = require("src.game.lights")
  local j = J()
  local wide = { beat = 0, endBeat = 4, vel = 127, color = { 1, 0, 0 } }
  local narrow = { beat = 0, endBeat = 0.1, vel = 127, color = { 1, 0, 0 } }
  local gone = j.lights.attack_s + j.lights.hold_s + j.lights.decay_s + 0.01
  for _, dt in ipairs({ 0.005, 0.05, 0.2, gone }) do
    T.eq(Lights.button(j, wide, dt, 0.5), Lights.button(j, narrow, dt, 0.5), "same light at " .. dt .. " s")
  end
  T.ok(Lights.button(j, wide, 0.05, 0.5) > 0)
  T.eq(Lights.button(j, wide, gone, 0.5), 0, "dark after the tap, though the box runs 2 s")
end

return tests
