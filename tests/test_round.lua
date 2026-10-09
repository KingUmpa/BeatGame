-- tests/test_round.lua

local Juice = require("src.config.juice")
local Round = require("src.game.round")

-- juice defaults, growing by bars unless a test says otherwise (most of these test the layout
-- and the judging, not the shipped feel)
local function J(changes)
  local j = Juice.defaults()
  j.flow.grow = "bars"
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

-- round 1 of a 1-bar level from beat 0, judged at 120 BPM: its turn starts at beat 8 = 4.0 s,
-- and pads 1 2 3 4 would be due at 4.0 4.5 5.0 5.5 played in time
local function judge(changes, p)
  local j = J(changes)
  return Round.Judge.new(Round.new(p or prepared(1), j, 1, 0), j, 120)
end

local tests = {}

-- a level's first round counts in; then the demo, and the turn straight after it, open until
-- it's over (r:endTurn). The next round rests flow.rest_beats, then waits for the grid.
function tests.a_round_is_count_demo_then_an_open_turn(T)
  local r = Round.new(prepared(1), J(), 1, 8)
  local names = {}
  for _, p in ipairs(r.phases) do names[#names + 1] = ("%s %g-%g"):format(p.name, p.from, p.to) end
  T.eq(table.concat(names, ", "), "count 8-12, demo 12-16, play 16-inf")
  T.eq(r:phaseAt(100), "play", "the turn runs until it's over")
  T.eq(#r:demoButtons(), 4)
  T.eq(#r:demoNotes(), 6, "5 button notes + 1 free note")
  T.eq(r:playButtons()[1].beat, 16)
  r:endTurn(18.5)
  T.eq(r.finish, 18.5)
  T.eq(r:phaseAt(18.6), nil)
  T.eq(#r:freePlayNotes(), 1)
  T.eq(Round.new(prepared(1), J(), 2, r.finish, 4).byName.demo.from, 20, "a beat's rest, then the next bar")
  T.eq(Round.new(prepared(1), J(), 2, 19.5, 4).byName.demo.from, 24, "less than a beat to the bar: the bar after")
end

function tests.muted_free_notes_stay_silent_and_the_rest_stop_with_the_turn(T)
  local r = Round.new(prepared(1, "mute"), J(), 1, 0)
  T.eq(#r:demoNotes(), 5)
  T.eq(#r:freePlayNotes(), 0)
  local p = Round.new(prepared(1), J(), 1, 0)          -- the turn from beat 8, a free note at 8.5
  p:endTurn(8.4)
  T.eq(#p:freePlayNotes(), 0, "the turn was over before it")
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

-- in a song the demo starts on the loop grid (multiples of the level length), so the pattern
-- lines up with the loops locked in under it; the turn follows the demo straight on
function tests.song_rounds_sit_on_the_loop_grid(T)
  local p = prepared(2)
  local r = Round.new(p, J(), 2, 28, 8)                -- bars mode, round 2: the whole 2 bars
  local names = {}
  for _, ph in ipairs(r.phases) do names[#names + 1] = ("%s %g-%g"):format(ph.name, ph.from, ph.to) end
  T.eq(table.concat(names, ", "), "count 28-32, demo 32-40, play 40-inf", "no count-in after round 1: a beat's rest, then the grid")
  T.eq(Round.new(p, J(), 2, 31, 8).byName.demo.from, 32, "a beat's rest lands on the grid")
  T.eq(Round.new(p, J(), 2, 31.5, 8).byName.demo.from, 40, "less than a beat to it: the next one")
  T.eq(Round.new(p, J({ ["flow.rest_beats"] = 0 }), 2, 32, 8).byName.demo.from, 32, "no rest, on the grid: at once")
  T.eq(Round.new(p, J(), 1, 30, 8).byName.demo.from, 40, "round 1: 4 beats of count-in at least")
  local short = Round.new(p, J({ ["flow.grow"] = "buttons" }), 1, 0, 8)   -- one button: a 1-bar pattern
  T.eq(short.byName.demo.from, 8)
  T.eq(short.byName.play.from, 12, "the turn follows the demo straight on, off the grid")
  T.eq(Round.new(p, J(), 1, 8).byName.demo.from, 12, "no grid")
end

-- the turn is the sequence, at any speed: the right pads in order complete it
function tests.the_turn_is_judged_on_the_sequence_not_the_timing(T)
  local j = judge()
  T.eq(#j.expected, 4, "4 buttons, though 5 notes")
  T.eq(j:press(1, 4.3).kind, "correct")
  local h = j:press(2, 4.35)                           -- well before it would be due in time (4.5)
  T.eq(h.kind, "correct")
  T.eq(#h.button.notes, 2)
  T.eq(j:press(3, 6.0).kind, "correct", "late is fine too")
  T.eq(j:done(), false)
  j:press(4, 6.1)
  T.eq(j.outcome, "complete"); T.eq(j.endT, 6.1)
  T.eq(j:passed(), true)
  T.eq(j:open(6.2), false, "over: presses aren't judged")
  local none = prepared(1); none.buttons = {}
  T.eq(judge(nil, none).outcome, "complete", "nothing to press")
end

-- the green flash is the turn's first beat; a press just before it already counts
function tests.a_press_just_before_the_green_flash_counts(T)
  local j = judge()                                    -- timing.early_ms 150
  T.eq(j:open(3.8), false)
  T.eq(j:open(3.9), true)
end

-- a wrong press: the player carries on from where they were, up to rules.mistakes_allowed
function tests.wrong_presses_are_forgiven_up_to_mistakes_allowed(T)
  local j = judge()                                    -- 1 allowed by default
  j:press(1, 4.0)
  T.eq(j:press(3, 4.5).kind, "wrong", "pad 2 is due")
  T.eq(j.outcome, nil, "one is forgiven")
  T.eq(j:press(2, 4.6).kind, "correct", "carrying on from where they were")
  j:press(3, 4.7); j:press(4, 4.8)
  T.eq(j:passed(), true)
  T.eq(j.counts.wrong, 1)
  local k = judge()
  k:press(2, 4.0); k:press(3, 4.1)
  T.eq(k.outcome, "wrong", "the second ends it"); T.eq(k.endT, 4.1)
  T.eq(k:passed(), false)
  local simon = judge({ ["rules.mistakes_allowed"] = 0 })
  simon:press(4, 4.0)
  T.eq(simon.outcome, "wrong", "none allowed: like Simon")
  local lenient = judge({ ["rules.extra_press_is_mistake"] = false })
  for _ = 1, 5 do lenient:press(4, 4.0) end
  T.eq(lenient.outcome, nil, "wrong presses only sound wrong")
end

-- one or two right, then the player stalls: after the grace the guess is wrong, and the
-- buttons left are misses
function tests.stalling_part_way_gives_the_guess_up_after_the_grace(T)
  local j = judge()                                    -- grace 4 beats = 2 s
  j:press(1, 4.0)
  j:press(2, 4.1)                                      -- in time, pad 3 comes 0.5 s after pad 2
  T.eq(#j:sweep(6.5), 0, "still in the grace")
  T.eq(j:open(6.5), true)
  T.eq(j:open(6.7), false, "past it a press is too late")
  local missed = j:sweep(6.65)                         -- 4.1 + 0.5 + 2.0 = 6.6
  T.eq(#missed, 2)
  T.eq(missed[1].pad, 3); T.eq(missed[1].group, j.next, "pad 3 was the one due")
  T.eq(j.outcome, "timeout"); T.near(j.endT, 6.6, 1e-9)
  T.eq(j:passed(), false)
  T.eq(j:mistakes(), 2)
  T.eq(#j:sweep(9), 0, "given up once")
end

-- a player copying it in time is never cut off: the grace runs from when the next button
-- would be due
function tests.the_grace_counts_from_when_the_next_button_would_be_due(T)
  local p = prepared(1)
  table.remove(p.buttons, 2); table.remove(p.buttons, 2)   -- pads 1 and 4, three beats apart
  local j = judge(nil, p)
  j:press(1, 4.0)
  T.eq(#j:sweep(7.4), 0, "pad 4 is due at 5.5 in time: the grace runs from there")
  T.eq(#j:sweep(7.6), 1)
end

-- the player has flow.wait_beats from the green flash to start (0 = forever)
function tests.never_starting_runs_out_after_the_wait(T)
  local j = judge()                                    -- 16 beats = 8 s from 4.0
  T.eq(#j:sweep(11.9), 0)
  T.eq(#j:sweep(12.1), 4, "every button missed")
  T.eq(j.next, 1); T.eq(j.outcome, "timeout")
  T.eq(#judge({ ["flow.wait_beats"] = 0 }):sweep(1e6), 0, "as long as they like")
  local k = judge()
  k:press(3, 4.2)
  T.eq(#k:sweep(7.0), 0, "a wrong first press doesn't start the grace: the wait still stands")
end

-- buttons that start together (a chord) can go in either order; the rest in order
function tests.buttons_starting_together_go_in_either_order(T)
  local p = prepared(1)
  p.buttons[2].beat = 0.05                             -- 25 ms after pad 1's: together (within 50)
  for _, order in ipairs({ { 1, 2 }, { 2, 1 } }) do
    local j = judge(nil, p)
    T.eq(j:press(order[1], 4.0).kind, "correct")
    T.eq(j:press(order[2], 4.1).kind, "correct")
    T.eq(j:press(3, 4.2).kind, "correct")
  end
  T.eq(judge(nil, p):press(3, 4.0).kind, "wrong", "pad 3 waits for both")
  T.eq(judge({ ["timing.together_ms"] = 10 }, p):press(2, 4.0).kind, "wrong", "25 ms apart is in order with 10")
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
