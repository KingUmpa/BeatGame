-- tests/test_doc.lua

local Midi = require("src.midi")
local Doc = require("src.doc")
local util = require("src.util")

local PATH = "assets/midi/vocal_chops_loop.mid"

local function load()
  local bytes = util.readFile(PATH)
  return Doc.new(Midi.parse(bytes)), bytes
end

local tests = {}

function tests.unedited_file_encodes_back_byte_for_byte(T)
  local doc, bytes = load()
  T.eq(#doc:bytes(), #bytes)
  T.eq(doc:bytes() == bytes, true, "same 739 bytes")
end

function tests.events_keep_offsets_deltas_and_raw_bytes(T)
  local m = Midi.parse(util.readFile(PATH))
  T.eq(#m.events, 171, "2 metas + 84 on + 84 off + end of track")
  local first = m.events[3]
  T.eq(first.kind, "note_on"); T.eq(first.offset, 0x3D); T.eq(first.delta, 545)
  T.eq(Midi.hex(first.raw), "84 21 90 45 41", "2-byte delta then 90 45 41")
  T.eq(m.events[#m.events].meta, 0x2F)
  T.eq(Midi.describe(m.events[2]), "Time Signature  4/4, 36 clocks/click, 8 32nds/beat")
end

function tests.nudging_one_note_changes_only_its_deltas(T)
  local doc, bytes = load()
  local n = doc.notes[10]
  doc:edit("nudge", function() n.tick = n.tick + 1 end)
  local out = doc:bytes()
  T.eq(#out, #bytes, "same length: no delta crosses a VLQ byte boundary")
  local diffs = 0
  for i = 1, #out do if out:byte(i) ~= bytes:byte(i) then diffs = diffs + 1 end end
  T.eq(diffs, 2, "the delta before its note-on grows by 1, the one after shrinks by 1")
  T.eq(doc:changed(n), "moved")
  local f = doc:file()
  T.eq(f.eventsOf[n.id].on.tick, n.tick)
end

function tests.undo_and_redo_restore_exactly(T)
  local doc, bytes = load()
  local ids = { [doc.notes[1].id] = true, [doc.notes[2].id] = true }
  doc:edit("delete", function(d) d:remove(ids) end)
  T.eq(#doc.notes, 82)
  T.eq(#doc.removed, 2)
  T.eq(doc:dirty(), true)
  T.eq(doc:undo(), "delete")
  T.eq(#doc.notes, 84)
  T.eq(doc:bytes() == bytes, true)
  T.eq(doc:redo(), "delete")
  T.eq(#doc.notes, 82)
  T.eq(doc:undo(), "delete")
  T.eq(doc:undo(), nil, "nothing left")
end

function tests.a_drag_is_one_undo_step(T)
  local doc = load()
  local n = doc.notes[5]
  local start = n.tick
  doc:begin("drag")
  for i = 1, 10 do n.tick = start + i * 3; doc:touch() end
  T.eq(n.tick, start + 30)
  doc:undo()
  T.eq(doc.byId[n.id].tick, start)
end

function tests.edits_are_clamped_to_valid_midi(T)
  local doc = load()
  local n = doc.notes[1]
  doc:edit("wild", function() n.vel = 500; n.tick = -40; n.len = 0 end)
  T.eq(n.vel, 127); T.eq(n.tick, 0); T.eq(n.len, 1)
end

function tests.added_notes_encode_and_parse_back(T)
  local doc = load()
  local id
  doc:edit("add", function(d) id = d:add(96 * 50, 60, 24, 100).id end)
  local f = doc:file()
  T.eq(#f.notes, 85)
  T.eq(doc:changed(doc.byId[id]), "added")
  local ev = f.eventsOf[id]
  T.eq(ev.on.key, 60); T.eq(ev.on.tick, 4800); T.eq(ev.off.tick, 4824)
end

return tests
