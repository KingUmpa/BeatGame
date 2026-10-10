-- tests/test_level.lua

local Level = require("src.game.level")
local Midi = require("src.midi")
local json = require("lib.json")
local util = require("src.util")

local MIDI = "assets/midi/vocal_chops_loop.mid"

local function pads(prep)
  local out = {}
  for _, b in ipairs(prep.buttons) do out[#out + 1] = Level.KEYS[b.pad] .. (#b.notes > 1 and ("x" .. #b.notes) or "") end
  return table.concat(out, " ")
end

-- A level built here from the test MIDI, the way the shipped ones were first made: the
-- pattern from beat 16, keys 69 / 71 / 76 / 74 on Q / W / A / S, one button per note, or
-- (grouped) each B3 pair and each E4+D4 pair as one press. The tests use these rather than
-- the files in levels/, which are yours to edit.
local PAD = { [69] = 1, [71] = 2, [76] = 3, [74] = 4 }
local function built(bars, grouped)
  local lv = Level.fromMidi(MIDI)
  lv.bpm, lv.start_beat, lv.bars = 114, 16, bars
  for key, n in pairs({ [69] = 1, [71] = 2, [76] = 3, [74] = 4 }) do
    Level.setSound(lv, 1, key, ("assets/audio/samples/vocal_chops/chop_%d.wav"):format(n))
  end
  local a, z = Level.window(lv)
  local inWin = {}
  for _, n in ipairs(lv.notes) do if n.tick >= a and n.tick < z then inWin[#inWin + 1] = n end end
  local i = 1
  while i <= #inWin do
    local n, m = inWin[i], inWin[i + 1]
    local pair = grouped and m and m.tick - n.tick <= lv.ppq and ((n.key == 71 and m.key == 71) or (n.key == 76 and m.key == 74))
    local last = pair and m or n
    Level.newButton(lv, { track = 1, pad = PAD[n.key], start = n.tick, ["end"] = last.tick + last.len,
      keyLow = math.min(n.key, last.key), keyHigh = math.max(n.key, last.key) })
    i = i + (pair and 2 or 1)
  end
  return lv
end

local tests = {}

function tests.a_level_starts_from_a_midi_file(T)
  local lv = Level.fromMidi(MIDI)
  T.eq(#lv.notes, 84)
  T.eq(lv.ppq, 96)
  T.eq(lv.bpm, 120, "the clip export carries no tempo")
  T.eq(lv.bars, 13, "51.9 beats -> 13 bars")
  T.eq(#lv.buttons, 0)
  T.eq(lv.midi, MIDI)
  T.eq(#Level.rows(lv), 4, "four keys on one track")
  T.eq(Level.rows(lv)[1].key, 76, "highest key on top")
end

function tests.one_button_per_note_follows_the_docx_sequence(T)
  T.eq(pads(Level.prepare(built(1))), "Q W W Q W Q A S")
  T.eq(pads(Level.prepare(built(2))), "Q W W Q W Q A S Q W W Q W Q A")
end

function tests.every_level_in_levels_loads(T)
  local list = Level.list()
  T.ok(#list > 0, "no levels")
  for _, p in ipairs(list) do
    local ok, lv = pcall(Level.load, p)
    T.ok(ok, p .. ": " .. tostring(lv))
    T.eq(lv.midi, (p:gsub("%.json$", ".mid")), p .. " owns the MIDI beside it")
    for _, b in ipairs(lv.buttons) do T.ok(b.pad >= 1 and b.pad <= 4, p .. ": a button off the pads") end
  end
end

function tests.one_button_can_play_several_notes(T)
  local prep = Level.prepare(built(4, true))
  T.eq(#prep.buttons, 24, "30 notes, 24 presses")
  local w = prep.buttons[2]
  T.eq(w.pad, 2); T.eq(#w.notes, 2)
  T.near(w.notes[2].beat - w.notes[1].beat, 0.5, 0.05, "the two B3s half a beat apart")
  local a = prep.buttons[6]
  T.eq(a.pad, 3); T.eq(#a.notes, 2)
  T.ok(a.notes[1].key ~= a.notes[2].key, "E4 then D4 in one box")
end

function tests.a_box_takes_notes_by_track_time_and_key(T)
  local lv = Level.fromMidi(MIDI)
  local b = Level.newButton(lv, { track = 1, pad = 1, start = 1536, ["end"] = 1920, keyLow = 71, keyHigh = 71 })
  local notes = Level.buttonNotes(lv, b)
  T.eq(#notes, 3, "the B3s in the first bar of the pattern")
  for _, n in ipairs(notes) do T.eq(n.key, 71) end
  b.track = 2
  T.eq(#Level.buttonNotes(lv, b), 0, "nothing on another track")
  b.track, b.keyLow, b.keyHigh = 1, 0, 127
  T.eq(#Level.buttonNotes(lv, b), 8)
  Level.fitButton(lv, b)
  T.eq(b.start, 1561); T.eq(b.keyLow, 69); T.eq(b.keyHigh, 76)
end

function tests.overlapping_boxes_share_nothing(T)
  local lv = Level.fromMidi(MIDI)
  lv.start_beat, lv.bars = 16, 1
  local first = Level.newButton(lv, { pad = 1, start = 1536, ["end"] = 1920 })
  local second = Level.newButton(lv, { pad = 2, start = 1700, ["end"] = 1920 })
  local owner, clash = Level.membership(lv)
  local clashes = 0
  for _ in pairs(clash) do clashes = clashes + 1 end
  T.ok(clashes > 0, "notes under both boxes are flagged")
  local prep = Level.prepare(lv)
  local total = 0
  for _, b in ipairs(prep.buttons) do total = total + #b.notes end
  T.eq(total, 8, "each note plays once")
  T.ok(owner and first and second)
end

function tests.a_big_box_replaces_the_boxes_under_it(T)
  -- one button per note, then one box over the bar's three B3s (on Q)
  local lv = built(1)
  local big = Level.newButton(lv, { track = 1, pad = 1, start = 1610, ["end"] = 1775, keyLow = 71, keyHigh = 71 })
  local silent = Level.shadowed(lv)
  T.eq(#silent, 3, "the three per-note W boxes light but play nothing")
  for _, b in ipairs(silent) do T.eq(b.pad, 2) end
  local under = Level.coveredBy(lv, big)
  T.eq(#under, 3)
  Level.removeButtons(lv, under)
  T.eq(#Level.shadowed(lv), 0)
  local prep = Level.prepare(lv)
  T.eq(pads(prep), "Q Qx3 Q Q A S", "one press for the three B3s")
end

function tests.notes_outside_boxes_are_free(T)
  local lv = Level.fromMidi(MIDI)
  lv.start_beat, lv.bars = 16, 1
  Level.newButton(lv, { pad = 1, start = 1536, ["end"] = 1920, keyLow = 69, keyHigh = 69 })
  local prep = Level.prepare(lv)
  T.eq(#prep.buttons[1].notes, 3)
  T.eq(#prep.free, 5)
  -- the A3 at beat 0.26 is boxed; the first free note is the B3 after it
  T.near(prep.free[1].beat, 0.77, 0.01, "beats count from the level's start")
end

function tests.sidecar_round_trip(T)
  local lv = built(4, true)
  lv.buttons[3].color = { 1, 0, 0.5 }
  lv.pads[2].color = { 0.1, 0.2, 0.3 }
  lv.unboxed_notes = "mute"
  local back = Level.normalize(json.decode(Level.toJson(lv)), lv.midiBytes)
  T.eq(#back.buttons, #lv.buttons)
  T.eq(back.buttons[3].color[3], 0.5)
  T.eq(back.buttons[2]["end"], lv.buttons[2]["end"])
  T.eq(back.buttons[6].keyLow, 74); T.eq(back.buttons[6].keyHigh, 76)
  T.eq(back.pads[2].color[2], 0.2)
  T.eq(back.unboxed_notes, "mute")
  T.eq(#back.sounds, 4)
  T.eq(Level.sound(back, 1, 71).sample:match("_2%.wav$") ~= nil, true)
  T.eq(back.source, MIDI)
end

function tests.exclusive_puts_every_note_in_one_choke_group(T)
  local lv = built(1)
  T.eq(lv.exclusive, false, "off by default")
  T.eq(Level.toJson(lv):find("exclusive", 1, true), nil, "off: not written")
  T.ok(Level.choke(lv, 1, 69) ~= Level.choke(lv, 1, 71), "off: each key its own group")
  T.eq(Level.choke(lv, 1, 69), Level.choke(lv, 1, 69))
  lv.exclusive = true
  T.eq(Level.choke(lv, 1, 69), Level.choke(lv, 2, 71), "on: one group for every key and track")
  local back = Level.normalize(json.decode(Level.toJson(lv)), lv.midiBytes)
  T.eq(back.exclusive, true)
  -- layered in a song, two levels never cut each other, exclusive or not
  local other = built(1)
  T.ok(Level.choke(other, 1, 69) ~= Level.choke(lv, 1, 69))
  other.exclusive = true
  T.ok(Level.choke(other, 1, 69) ~= Level.choke(lv, 1, 69), "exclusive groups are per level")
  lv.exclusive = false
  T.ok(Level.choke(other, 1, 69) ~= Level.choke(lv, 1, 69))
end

function tests.a_levels_metronome_round_trips(T)
  local lv = built(1)
  T.eq(lv.metronome, nil, "absent: juice's audio.metronome")
  T.eq(Level.toJson(lv):find("metronome", 1, true), nil)
  lv.metronome = "always"
  T.eq(Level.normalize(json.decode(Level.toJson(lv)), lv.midiBytes).metronome, "always")
  T.eq(Level.normalize({ metronome = "loud" }).metronome, nil, "unknown values are dropped")
end

function tests.a_levels_beat_offset_round_trips(T)
  local lv = built(1)
  T.eq(lv.beat_offset, 0, "absent: on the MIDI's beat")
  T.eq(Level.toJson(lv):find("beat_offset", 1, true), nil, "0: not written")
  lv.beat_offset = 0.25
  T.eq(Level.normalize(json.decode(Level.toJson(lv)), lv.midiBytes).beat_offset, 0.25)
end

-- what plays once a level is locked in under the next: every note it sounds, in order
function tests.a_locked_in_loop_is_every_note_the_level_plays(T)
  local lv = Level.fromMidi(MIDI)
  lv.start_beat, lv.bars = 16, 1
  Level.newButton(lv, { pad = 1, start = 1536, ["end"] = 1920, keyLow = 69, keyHigh = 69 })
  local notes = Level.loopNotes(Level.prepare(lv))
  T.eq(#notes, 8, "3 in the button, 5 free")
  for i = 2, #notes do T.ok(notes[i].beat >= notes[i - 1].beat, "in time order") end
  lv.unboxed_notes = "mute"
  T.eq(#Level.loopNotes(Level.prepare(lv)), 3, "muted free notes stay out")
end

-- a bounce with silence up front starts where its sound does (1 ms before)
function tests.leading_silence_is_trimmed_from_note_samples(T)
  local ffi = require("ffi")
  local frames = 5000
  local d = ffi.new("float[?]", frames * 2)
  for f = 0, frames - 1 do d[f * 2], d[f * 2 + 1] = (f % 7) * 1e-5, 0 end   -- dither, under -60 dB
  for f = 4000, frames - 1 do d[f * 2], d[f * 2 + 1] = 0.5, 0.5 end
  local s = { data = d, frames = frames, rate = 44100 }
  local t = Level.trimmed(s)
  T.eq(t.trimmed, 4000 - 44)
  T.eq(t.frames, frames - (4000 - 44))
  T.eq(t.data[44 * 2], 0.5, "the sound starts 1 ms in")
  T.eq(t.base, s, "keeps the decoded frames alive")
  local loud = { data = ffi.new("float[?]", 20, 0.5), frames = 10 }
  T.eq(Level.trimmed(loud), loud, "nothing to trim: the same sample")
end

-- a round box adds all its buttons in one step of the build-up; lone buttons are steps alone
function tests.a_round_box_adds_its_buttons_at_once(T)
  local Round = require("src.game.round")
  local J = require("src.config.juice").defaults()
  J.flow.grow = "buttons"
  local lv = built(1)                                    -- 8 buttons: Q W W Q W Q A S
  T.eq(#Level.prepare(lv).steps, 8, "no rounds: a step per button")
  T.eq(Level.toJson(lv):find('"rounds"', 1, true), nil, "no rounds: not written")
  local r = Level.newRound(lv, { track = 1, start = 1536, ["end"] = 1680, keyLow = 0, keyHigh = 127 })
  T.eq(Level.fitRound(lv, r), true)
  T.eq(r.start, 1561); T.eq(r.keyLow, 69); T.eq(r.keyHigh, 71)
  T.eq(#Level.roundButtons(lv, r), 3, "the first three buttons")
  local prep = Level.prepare(lv)
  T.eq(#prep.steps, 6, "one round of 3 + 5 lone buttons")
  T.eq(#prep.steps[1].buttons, 3)
  T.eq(Round.count(prep, J), 6)
  T.eq(#Round.new(prep, J, 1, 0):playButtons(), 3, "round 1: the whole box")
  T.eq(#Round.new(prep, J, 2, 0):playButtons(), 4, "round 2: and the next button")
  local back = Level.normalize(json.decode(Level.toJson(lv)), lv.midiBytes)
  T.eq(#back.rounds, 1)
  T.eq(back.rounds[1].start, 1561); T.eq(back.rounds[1].keyHigh, 71)
  T.eq(#Level.prepare(back).steps, 6)
end

-- the A and S at the end of the bar as one round, then the first five buttons (any key)
function tests.rounds_play_in_the_order_of_their_first_button(T)
  local lv = built(1)
  Level.newRound(lv, { track = 1, start = 1840, ["end"] = 1920, keyLow = 0, keyHigh = 127 })
  local first = Level.newRound(lv, { track = 1, start = 1536, ["end"] = 1790, keyLow = 0, keyHigh = 127 })
  local steps = Level.prepare(lv).steps
  T.eq(#steps, 3, "5 buttons, the Q at 1800 alone, then A + S")
  T.eq(#steps[1].buttons, 5); T.eq(#steps[2].buttons, 1); T.eq(#steps[3].buttons, 2)
  -- a bigger box over the first replaces it; overlapping boxes share nothing
  local big = Level.newRound(lv, { track = 1, start = 1536, ["end"] = 1830, keyLow = 0, keyHigh = 127 })
  local covered = Level.roundsCoveredBy(lv, big)
  T.eq(#covered, 1); T.eq(covered[1], first)
  local _, clash = Level.roundMembership(lv)
  local n = 0
  for _ in pairs(clash) do n = n + 1 end
  T.eq(n, 5, "the first five buttons are in two boxes")
  local total = 0
  for _, s in ipairs(Level.prepare(lv).steps) do total = total + #s.buttons end
  T.eq(total, 8, "but each button is added once")
end

function tests.edited_notes_are_written_to_the_levels_own_midi(T)
  local lv = Level.load("levels/01_huntin_wabbits.json")
  T.eq(Level.midiBytes(lv) == util.readFile("levels/01_huntin_wabbits.mid"), true, "unedited: the same bytes")
  local count = #lv.notes
  lv.notes[10].tick = lv.notes[10].tick + 5
  lv.notesDirty = true
  local m = Midi.parse(Level.midiBytes(lv))
  T.eq(#m.notes, count)
  local found = false
  for _, n in ipairs(m.notes) do if n.tick == lv.notes[10].tick and n.key == lv.notes[10].key then found = true end end
  T.ok(found, "the moved note is in the new MIDI")
end

function tests.multi_track_midi_survives(T)
  local doc = { ppq = 96, metas = {}, notes = {
    { track = 1, tick = 0, len = 24, key = 36, vel = 100 },
    { track = 2, tick = 48, len = 24, key = 60, vel = 90 },
    { track = 2, tick = 96, len = 24, key = 62, vel = 80 },
  } }
  local m = Midi.parse(Midi.encode(doc))
  T.eq(m.format, 1); T.eq(m.trackCount, 2); T.eq(#m.notes, 3)
  T.eq(m.notes[2].track, 2); T.eq(m.notes[2].key, 60)
end

return tests
