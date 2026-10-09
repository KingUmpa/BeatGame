-- tests/test_song.lua
-- test_a against its own documentation: "Sequence Ordering and Timing.docx" says the chops
-- run 1 2 2 1 2 1 3 4 1 2 2 1 2 1 3 0 in eighth notes at 114 BPM (0 = rest).

local Mixer = require("src.mixer")
local Song = require("src.song")

local DOCX_SEQUENCE = { 1, 2, 2, 1, 2, 1, 3, 4, 1, 2, 2, 1, 2, 1, 3, 0 }

local song
local function load()
  song = song or Song.load(require("songs.test_a"), Mixer.new{ rate = 44100 })
  return song
end

local tests = {}

function tests.every_note_in_the_window_has_a_sample(T)
  local s = load()
  T.eq(next(s.unmapped), nil, "no unmapped keys")
  T.eq(#s.events, 60, "15 hits per 2-bar pattern x 4")
end

function tests.loop_is_eight_bars_of_the_backing_track(T)
  local s = load()
  T.near(s.loopBeats, 32, 0.001)
  T.eq(s.loopFrames, s.backing.frames)
end

function tests.midi_plus_mapping_reproduces_the_docx_sequence(T)
  local s = load()
  -- each hit belongs to the eighth-note pulse it falls in; the clip plays them a sixteenth
  -- late (x.25 / x.75) and humanised, so bucket by floor(beat * 2)
  for rep = 0, 3 do
    local slots = {}
    for i = 1, 16 do slots[i] = 0 end
    for _, e in ipairs(s.events) do
      local pulse = math.floor(e.beat * 2) - rep * 16
      if pulse >= 0 and pulse < 16 then
        T.eq(slots[pulse + 1], 0, "one hit per pulse")
        slots[pulse + 1] = e.pad.n
      end
    end
    T.eq(table.concat(slots, " "), table.concat(DOCX_SEQUENCE, " "), "pattern repeat " .. (rep + 1))
  end
end

function tests.hits_repeat_with_the_loop(T)
  local s = load()
  local first, second = {}, {}
  s:eachEvent(0, s.loopFrames, function(_, f) first[#first + 1] = f end)
  s:eachEvent(s.loopFrames, 2 * s.loopFrames, function(_, f) second[#second + 1] = f - s.loopFrames end)
  T.eq(#first, 60); T.eq(#second, 60)
  for i = 1, #first do T.eq(second[i], first[i]) end
end

function tests.samples_are_loaded_at_mixer_rate(T)
  local s = load()
  for _, pad in ipairs(s.padList) do
    T.eq(pad.sample.rate, 44100)
    T.eq(pad.sample.sourceRate, 48000, "bounces are 48 kHz")
  end
end

return tests
