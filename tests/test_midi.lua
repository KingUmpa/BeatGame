-- tests/test_midi.lua

local Midi = require("src.midi")

-- builders for synthetic files
local function vlq(n)
  local bytes = { n % 128 }
  n = math.floor(n / 128)
  while n > 0 do
    table.insert(bytes, 1, n % 128 + 128)
    n = math.floor(n / 128)
  end
  return string.char(unpack(bytes))
end
local function u32(n) return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256) end
local function u16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function track(body) return "MTrk" .. u32(#body) .. body end
local function file(format, ppq, ...)
  local tracks = { ... }
  return "MThd" .. u32(6) .. u16(format) .. u16(#tracks) .. u16(ppq) .. table.concat(tracks)
end
local EOT = vlq(0) .. "\255\47\0"

local tests = {}

function tests.running_status_and_velocity_zero_off(T)
  -- on C3, (running) on E3, then offs as note-on vel 0 under running status
  local body = vlq(0) .. "\144\60\100" .. vlq(0) .. "\64\90" .. vlq(96) .. "\60\0" .. vlq(48) .. "\64\0" .. EOT
  local m = Midi.parse(file(0, 96, track(body)))
  T.eq(#m.notes, 2)
  T.eq(m.notes[1].key, 60); T.eq(m.notes[1].len, 96); T.eq(m.notes[1].vel, 100)
  T.eq(m.notes[2].key, 64); T.eq(m.notes[2].len, 144)
  T.eq(m.hasTempo, false); T.eq(m.bpm, 120)
end

function tests.overlapping_repeats_pair_first_in_first_out(T)
  local body = vlq(0) .. "\144\60\100" .. vlq(10) .. "\144\60\50" .. vlq(10) .. "\128\60\0" .. vlq(10) .. "\128\60\0" .. EOT
  local m = Midi.parse(file(0, 96, track(body)))
  T.eq(#m.notes, 2)
  T.eq(m.notes[1].vel, 100); T.eq(m.notes[1].len, 20)
  T.eq(m.notes[2].vel, 50); T.eq(m.notes[2].len, 20)
end

function tests.tempo_map_and_multi_byte_delta(T)
  -- 120 BPM for one beat, then 60 BPM; a note at beat 3 (tick 300 needs a 2-byte VLQ)
  local body = vlq(0) .. "\255\81\3\7\161\32" .. vlq(100) .. "\255\81\3\15\66\64"
    .. vlq(200) .. "\144\60\100" .. vlq(100) .. "\128\60\0" .. EOT
  local m = Midi.parse(file(0, 100, track(body)))
  T.eq(m.notes[1].tick, 300)
  T.near(m.notes[1].beat, 3)
  T.near(m.notes[1].time, 0.5 + 2.0, 1e-9, "0.5 s for beat 1 at 120, then 2 beats at 60")
  T.eq(m.hasTempo, true); T.near(m.bpm, 120)
end

function tests.sysex_meta_and_program_change_are_skipped(T)
  local body = vlq(0) .. "\255\3\5Piano" .. vlq(0) .. "\240\3\1\2\247" .. vlq(0) .. "\192\5"
    .. vlq(0) .. "\144\62\80" .. vlq(24) .. "\128\62\0" .. EOT
  local m = Midi.parse(file(0, 96, track(body)))
  T.eq(m.name, "Piano")
  T.eq(#m.notes, 1); T.eq(m.notes[1].key, 62)
end

function tests.format_1_merges_tracks_in_time_order(T)
  local tempo = track(vlq(0) .. "\255\81\3\7\161\32" .. EOT)
  local a = track(vlq(48) .. "\144\60\100" .. vlq(48) .. "\128\60\0" .. EOT)
  local b = track(vlq(0) .. "\145\36\100" .. vlq(96) .. "\129\36\0" .. EOT)
  local m = Midi.parse(file(1, 96, tempo, a, b))
  T.eq(m.trackCount, 3)
  T.eq(#m.notes, 2)
  T.eq(m.notes[1].key, 36); T.eq(m.notes[1].ch, 1); T.eq(m.notes[1].track, 3)
  T.eq(m.notes[2].key, 60); T.eq(m.notes[2].track, 2)
end

function tests.note_names_use_ableton_octaves(T)
  T.eq(Midi.noteName(60), "C3")
  T.eq(Midi.noteName(69), "A3")
  T.eq(Midi.noteName(36), "C1")
end

function tests.reads_the_test_a_clip_export(T)
  local m = Midi.load("Inputs/test_a/midi/Sample_MIDI_Loop.mid")
  T.eq(m.format, 0); T.eq(m.ppq, 96)
  T.eq(m.name, "All I Do Is Think About You")
  T.eq(m.hasTempo, false, "Ableton clip exports carry no tempo")
  T.eq(#m.notes, 84, "same count as the clip in the .als")
  T.eq(m.notes[1].tick, 545); T.eq(m.notes[1].key, 69); T.eq(m.notes[1].vel, 65)
  local keys = {}
  for _, n in ipairs(m.notes) do keys[n.key] = true end
  T.ok(keys[69] and keys[71] and keys[74] and keys[76], "keys 69 71 74 76")
  local count = 0
  for _ in pairs(keys) do count = count + 1 end
  T.eq(count, 4)
end

return tests
