-- src/game/level.lua
-- A level is a MIDI file plus a sidecar file (levels/*.json) with the button programming:
-- which stretches of the MIDI the player plays, on which pad, lit in which color.
--
-- The MIDI is the music. A button is a box over it: one track, a stretch of time, a range of
-- keys. The notes inside the box are what one press of its pad plays, and the player is
-- judged on hitting the pad when the box starts (when its light comes on), however many
-- notes are inside. Notes outside every box play along on their own (or stay silent:
-- "unboxed_notes").
--
-- The sidecar (format 2):
--   {
--     "format": 2, "name": "All I Do",
--     "midi": "levels/02_all_i_do.mid",          the MIDI this level plays (kept next to it)
--     "source": "Inputs/.../Sample_MIDI_Loop.mid", where that MIDI first came from
--     "bpm": 114, "start_beat": 16, "bars": 2,   the stretch of the MIDI the level uses
--     "backing": { "file": "...wav", "gain": 1 },
--     "unboxed_notes": "play" | "mute",
--     "exclusive": true,                          every note cuts every sound still ringing
--     "metronome": "always" | "count_ins" | "off", clicks under this level (absent: juice's
--                                                 audio.metronome)
--     "pads": [ { "color": [r,g,b] } x4 ],        1 = Q, 2 = W, 3 = A, 4 = S
--     "sounds": [ { "track": 1, "key": 69, "sample": "...wav", "label": "Slice 22" } ],
--     "buttons": [ { "track": 1, "pad": 1, "start": 1561, "end": 1588,
--                    "key_low": 69, "key_high": 69, "color": [r,g,b] (optional) } ],
--     "rounds": [ { "track": 1, "start": 1536, "end": 1700, "key_low": 69, "key_high": 71 } ]
--   }
-- Button and round ticks are the MIDI's own ticks.
--
-- A round is one level up again: a box over buttons (one track, a stretch of time, a range of
-- keys). As the game builds the level up (flow.grow = buttons), each round adds every button
-- whose start is inside it at once; a button in no round is a round of its own. Rounds play
-- in the order of their first button. ("rounds" is left out of the file when there are none.)

local json = require("lib.json")
local util = require("src.util")
local Midi = require("src.midi")

local Level = {}

Level.KEYS = { "Q", "W", "A", "S" }
Level.DEFAULT_COLORS = {
  { 0.20, 0.55, 1.00 },
  { 0.25, 0.95, 0.45 },
  { 1.00, 0.55, 0.12 },
  { 0.95, 0.25, 0.80 },
}

local function color3(c, fallback)
  if type(c) == "table" and #c >= 3 then
    return { util.clamp01(tonumber(c[1]) or 0), util.clamp01(tonumber(c[2]) or 0), util.clamp01(tonumber(c[3]) or 0) }
  end
  return fallback and util.deepcopy(fallback) or nil
end

local function stem(path) return util.basename(path):gsub("%.[^.]+$", "") end

------------------------------------------------------------------------
-- building a level
------------------------------------------------------------------------

-- the MIDI's notes become the level's editable notes (each with an id and its track)
local function takeMidi(lv, bytes)
  local m = Midi.parse(bytes)
  lv.midiBytes = bytes
  lv.ppq = m.ppq
  lv.metas = m.metas
  lv.trackNames = m.trackNames
  lv.trackCount = math.max(1, m.trackCount)
  lv.midiHasTempo, lv.midiBpm = m.hasTempo, m.bpm
  lv.notes = {}
  for i, n in ipairs(m.notes) do
    lv.notes[i] = { id = i, track = n.track or 1, key = n.key, tick = n.tick, len = n.len, vel = n.vel, ch = n.ch, offVel = n.offVel }
  end
  lv.nextNoteId = #lv.notes + 1
  lv.lengthBeats = m.lengthBeats
  return m
end

local function newButtonId(lv)
  lv.nextButtonId = (lv.nextButtonId or 0) + 1
  return lv.nextButtonId
end

local function newRoundId(lv)
  lv.nextRoundId = (lv.nextRoundId or 0) + 1
  return lv.nextRoundId
end

-- a box from the file: { track, start, end, key_low, key_high } -> track, start, end, lo, hi
local function readBox(b)
  local lo, hi = math.floor(tonumber(b.key_low) or 0), math.floor(tonumber(b.key_high) or 127)
  local start = math.max(0, math.floor(b.start))
  return math.max(1, math.floor(tonumber(b.track) or 1)), start, math.max(start + 1, math.floor(b["end"])), math.min(lo, hi), math.max(lo, hi)
end

Level.METRONOMES = { "always", "count_ins", "off" }
local uids = 0

function Level.normalize(raw, midiBytes)
  uids = uids + 1
  local lv = {
    uid = uids,   -- tells levels apart in the mixer's choke groups (Level.choke)
    format = 2,
    name = type(raw.name) == "string" and raw.name or "untitled",
    midi = type(raw.midi) == "string" and raw.midi or nil,
    source = type(raw.source) == "string" and raw.source or nil,
    bpm = tonumber(raw.bpm) or 120,
    start_beat = math.max(0, tonumber(raw.start_beat) or 0),
    bars = math.max(1, math.floor(tonumber(raw.bars) or 1)),
    unboxed_notes = raw.unboxed_notes == "mute" and "mute" or "play",
    exclusive = raw.exclusive == true,
    metronome = util.contains(Level.METRONOMES, raw.metronome) and raw.metronome or nil,
    pads = {}, sounds = {}, buttons = {}, rounds = {},
  }
  if type(raw.backing) == "table" and type(raw.backing.file) == "string" then
    lv.backing = { file = raw.backing.file, gain = tonumber(raw.backing.gain) or 1 }
  end
  for i = 1, 4 do
    local p = type(raw.pads) == "table" and raw.pads[i] or {}
    lv.pads[i] = { color = color3(p.color, Level.DEFAULT_COLORS[i]) }
  end
  for _, s in ipairs(type(raw.sounds) == "table" and raw.sounds or {}) do
    if tonumber(s.key) and type(s.sample) == "string" then
      lv.sounds[#lv.sounds + 1] = { track = math.floor(tonumber(s.track) or 1), key = math.floor(s.key), sample = s.sample, label = s.label }
    end
  end
  for _, b in ipairs(type(raw.buttons) == "table" and raw.buttons or {}) do
    local pad = math.floor(tonumber(b.pad) or 0)
    if pad >= 1 and pad <= 4 and tonumber(b.start) and tonumber(b["end"]) then
      local track, start, stop, lo, hi = readBox(b)
      lv.buttons[#lv.buttons + 1] = {
        id = newButtonId(lv), track = track, pad = pad, start = start, ["end"] = stop,
        keyLow = lo, keyHigh = hi, color = color3(b.color),
      }
    end
  end
  Level.sortButtons(lv)
  for _, r in ipairs(type(raw.rounds) == "table" and raw.rounds or {}) do
    if tonumber(r.start) and tonumber(r["end"]) then
      local track, start, stop, lo, hi = readBox(r)
      lv.rounds[#lv.rounds + 1] = { id = newRoundId(lv), track = track, start = start, ["end"] = stop, keyLow = lo, keyHigh = hi }
    end
  end
  Level.sortRounds(lv)
  if midiBytes then takeMidi(lv, midiBytes) else
    lv.ppq, lv.notes, lv.metas, lv.trackCount, lv.trackNames, lv.nextNoteId, lv.lengthBeats = 96, {}, {}, 1, {}, 1, 0
  end
  return lv
end

function Level.sortButtons(lv)
  table.sort(lv.buttons, function(a, b)
    if a.start ~= b.start then return a.start < b.start end
    return a.pad < b.pad
  end)
end

function Level.sortRounds(lv)
  table.sort(lv.rounds, function(a, b)
    if a.start ~= b.start then return a.start < b.start end
    return a.keyHigh > b.keyHigh
  end)
end

function Level.sortNotes(lv)
  table.sort(lv.notes, function(a, b)
    if a.tick ~= b.tick then return a.tick < b.tick end
    if a.track ~= b.track then return a.track < b.track end
    return a.key < b.key
  end)
end

function Level.load(path)
  local text, err = util.readFile(path)
  if not text then error(err or ("cannot read " .. path), 2) end
  local raw, jerr = json.try_decode(text)
  if not raw then error(path .. ": " .. tostring(jerr), 2) end
  if not raw.midi then error(path .. ": not a level file (no \"midi\" link)", 2) end
  local bytes, merr = util.readFile(raw.midi)
  if not bytes then error(path .. ": its MIDI " .. raw.midi .. " is missing (" .. tostring(merr) .. ")", 2) end
  local lv = Level.normalize(raw, bytes)
  lv.path = path
  return lv
end

-- a new, unsaved level over a MIDI file: the whole file, no buttons yet
function Level.fromMidi(midiPath)
  local bytes = assert(util.readFile(midiPath))
  local lv = Level.normalize({ name = stem(midiPath):gsub("_", " "), midi = midiPath, source = midiPath }, bytes)
  if lv.midiHasTempo then lv.bpm = math.floor(lv.midiBpm * 100 + 0.5) / 100 end
  lv.bars = util.clamp(math.ceil(lv.lengthBeats / 4), 1, 64)
  return lv
end

------------------------------------------------------------------------
-- saving: the sidecar, and the MIDI next to it
------------------------------------------------------------------------

local function round3(c)
  return { math.floor(c[1] * 1000 + 0.5) / 1000, math.floor(c[2] * 1000 + 0.5) / 1000, math.floor(c[3] * 1000 + 0.5) / 1000 }
end

function Level.toJson(lv)
  local out = {
    format = 2, name = lv.name, midi = lv.midi, source = lv.source, bpm = lv.bpm,
    start_beat = lv.start_beat, bars = lv.bars, unboxed_notes = lv.unboxed_notes,
    exclusive = lv.exclusive or nil, metronome = lv.metronome,
    pads = {}, sounds = {}, buttons = {},
  }
  if lv.backing then out.backing = { file = lv.backing.file, gain = lv.backing.gain } end
  for i = 1, 4 do out.pads[i] = { color = round3(lv.pads[i].color) } end
  table.sort(lv.sounds, function(a, b) if a.track ~= b.track then return a.track < b.track end return a.key < b.key end)
  for i, s in ipairs(lv.sounds) do out.sounds[i] = { track = s.track, key = s.key, sample = s.sample, label = s.label } end
  Level.sortButtons(lv)
  for i, b in ipairs(lv.buttons) do
    out.buttons[i] = {
      track = b.track, pad = b.pad, start = b.start, ["end"] = b["end"], key_low = b.keyLow, key_high = b.keyHigh,
      color = b.color and round3(b.color) or nil,
    }
  end
  if lv.rounds and #lv.rounds > 0 then
    Level.sortRounds(lv)
    out.rounds = {}
    for i, r in ipairs(lv.rounds) do
      out.rounds[i] = { track = r.track, start = r.start, ["end"] = r["end"], key_low = r.keyLow, key_high = r.keyHigh }
    end
  end
  return json.encode(out, { indent = "  " }) .. "\n"
end

function Level.midiBytes(lv)
  if not lv.notesDirty and lv.midiBytes then return lv.midiBytes end
  Level.sortNotes(lv)
  return Midi.encode({ ppq = lv.ppq, metas = lv.metas, notes = lv.notes })
end

-- Writes `path` (levels/<name>.json) and its MIDI beside it (levels/<name>.mid), so the level
-- owns the MIDI it plays and the file it came from is never changed.
function Level.save(lv, path)
  path = path or lv.path
  local midiPath = path:gsub("%.json$", "") .. ".mid"
  local bytes = Level.midiBytes(lv)
  local ok, err = util.writeFile(midiPath, bytes)
  if not ok then return nil, err end
  lv.midi = midiPath
  lv.midiBytes, lv.notesDirty = bytes, false
  ok, err = util.writeFile(path, Level.toJson(lv))
  if not ok then return nil, err end
  lv.path = path
  return true
end

function Level.list()
  local out = {}
  for _, f in ipairs(love.filesystem.getDirectoryItems("levels")) do
    if f:match("%.json$") then out[#out + 1] = "levels/" .. f end
  end
  table.sort(out)
  return out
end

------------------------------------------------------------------------
-- reading a level
------------------------------------------------------------------------

function Level.beats(lv) return lv.bars * 4 end

-- the level's stretch of the MIDI, in ticks
function Level.window(lv)
  local a = math.floor(lv.start_beat * lv.ppq + 0.5)
  return a, a + Level.beats(lv) * lv.ppq
end

-- The mixer choke group a note plays in. Normally a key cuts only its own previous note (a
-- Simpler pad with Retrigger); an exclusive level puts every note in one group, so the moment
-- a note triggers, every sound still ringing stops. Notes on the same tick still sound together.
-- Groups belong to their level: levels layered in a song never cut each other.
function Level.choke(lv, track, key)
  local base = (lv.uid or 0) * 1e6
  if lv.exclusive then return base end
  return base + track * 1000 + key + 1
end

function Level.buttonColor(lv, b) return b.color or lv.pads[b.pad].color end

function Level.inButton(b, n)
  return n.track == b.track and n.key >= b.keyLow and n.key <= b.keyHigh and n.tick >= b.start and n.tick < b["end"]
end

function Level.buttonNotes(lv, b)
  local out = {}
  for _, n in ipairs(lv.notes) do if Level.inButton(b, n) then out[#out + 1] = n end end
  return out
end

-- note id -> the button that plays it (the first, if boxes overlap), and the notes claimed twice
function Level.membership(lv)
  local owner, clash = {}, {}
  for _, b in ipairs(lv.buttons) do
    for _, n in ipairs(lv.notes) do
      if Level.inButton(b, n) then
        if owner[n.id] then clash[n.id] = true else owner[n.id] = b end
      end
    end
  end
  return owner, clash
end

-- The boxes on b's track that b makes redundant: every note they cover is inside b too (or,
-- covering no notes, the box itself sits inside b). Drawing or moving b replaces them.
function Level.coveredBy(lv, b)
  local out = {}
  for _, o in ipairs(lv.buttons) do
    if o ~= b and o.track == b.track then
      local notes = Level.buttonNotes(lv, o)
      local inside
      if #notes > 0 then
        inside = true
        for _, n in ipairs(notes) do
          if not Level.inButton(b, n) then inside = false; break end
        end
      else
        inside = o.start >= b.start and o["end"] <= b["end"] and o.keyLow >= b.keyLow and o.keyHigh <= b.keyHigh
      end
      if inside then out[#out + 1] = o end
    end
  end
  return out
end

-- Boxes that play nothing because every note they cover is already played by another box
-- (a note belongs to the first box over it). They still light and still have to be pressed.
function Level.shadowed(lv)
  local owner = Level.membership(lv)
  local out = {}
  for _, b in ipairs(lv.buttons) do
    local notes = Level.buttonNotes(lv, b)
    if #notes > 0 then
      local mine = false
      for _, n in ipairs(notes) do
        if owner[n.id] == b then mine = true; break end
      end
      if not mine then out[#out + 1] = b end
    end
  end
  return out
end

function Level.removeButtons(lv, list)
  local gone = {}
  for _, o in ipairs(list) do gone[o] = true end
  local keep = {}
  for _, o in ipairs(lv.buttons) do
    if not gone[o] then keep[#keep + 1] = o end
  end
  lv.buttons = keep
end

-- shrink (or grow) a box to just cover the notes inside it
function Level.fitButton(lv, b)
  local notes = Level.buttonNotes(lv, b)
  if #notes == 0 then return false end
  local s, e, lo, hi = math.huge, 0, 127, 0
  for _, n in ipairs(notes) do
    s, e = math.min(s, n.tick), math.max(e, n.tick + n.len)
    lo, hi = math.min(lo, n.key), math.max(hi, n.key)
  end
  b.start, b["end"], b.keyLow, b.keyHigh = s, math.max(e, s + 1), lo, hi
  return true
end

function Level.newButton(lv, fields)
  local b = { id = newButtonId(lv), track = fields.track or 1, pad = fields.pad or 1, start = fields.start, ["end"] = fields["end"],
    keyLow = fields.keyLow or 0, keyHigh = fields.keyHigh or 127, color = fields.color }
  lv.buttons[#lv.buttons + 1] = b
  Level.sortButtons(lv)
  return b
end

------------------------------------------------------------------------
-- rounds: boxes over buttons (see the top of the file)
------------------------------------------------------------------------

function Level.inRound(r, b)
  return b.track == r.track and b.start >= r.start and b.start < r["end"] and b.keyHigh >= r.keyLow and b.keyLow <= r.keyHigh
end

function Level.roundButtons(lv, r)
  local out = {}
  for _, b in ipairs(lv.buttons) do if Level.inRound(r, b) then out[#out + 1] = b end end
  return out
end

-- button -> the round that adds it (the first, if rounds overlap), and the buttons in two
function Level.roundMembership(lv)
  local owner, clash = {}, {}
  for _, r in ipairs(lv.rounds) do
    for _, b in ipairs(lv.buttons) do
      if Level.inRound(r, b) then
        if owner[b] then clash[b] = true else owner[b] = r end
      end
    end
  end
  return owner, clash
end

function Level.newRound(lv, fields)
  local r = { id = newRoundId(lv), track = fields.track or 1, start = fields.start, ["end"] = fields["end"],
    keyLow = fields.keyLow or 0, keyHigh = fields.keyHigh or 127 }
  lv.rounds[#lv.rounds + 1] = r
  Level.sortRounds(lv)
  return r
end

-- shrink (or grow) a round to just hold the buttons inside it
function Level.fitRound(lv, r)
  local list = Level.roundButtons(lv, r)
  if #list == 0 then return false end
  local s, e, lo, hi = math.huge, 0, 127, 0
  for _, b in ipairs(list) do
    s, e = math.min(s, b.start), math.max(e, b["end"])
    lo, hi = math.min(lo, b.keyLow), math.max(hi, b.keyHigh)
  end
  r.start, r["end"], r.keyLow, r.keyHigh = s, math.max(e, s + 1), lo, hi
  return true
end

-- the rounds on r's track that r makes redundant: every button they add is inside r too (or,
-- adding nothing, the round itself sits inside r)
function Level.roundsCoveredBy(lv, r)
  local out = {}
  for _, o in ipairs(lv.rounds) do
    if o ~= r and o.track == r.track then
      local list = Level.roundButtons(lv, o)
      local inside = true
      if #list > 0 then
        for _, b in ipairs(list) do
          if not Level.inRound(r, b) then inside = false; break end
        end
      else
        inside = o.start >= r.start and o["end"] <= r["end"] and o.keyLow >= r.keyLow and o.keyHigh <= r.keyHigh
      end
      if inside then out[#out + 1] = o end
    end
  end
  return out
end

function Level.removeRounds(lv, list)
  local gone = {}
  for _, o in ipairs(list) do gone[o] = true end
  local keep = {}
  for _, o in ipairs(lv.rounds) do
    if not gone[o] then keep[#keep + 1] = o end
  end
  lv.rounds = keep
end

function Level.sound(lv, track, key)
  for _, s in ipairs(lv.sounds) do
    if s.track == track and s.key == key then return s end
  end
end

function Level.setSound(lv, track, key, sample)
  local s = Level.sound(lv, track, key)
  if s then s.sample = sample else lv.sounds[#lv.sounds + 1] = { track = track, key = key, sample = sample } end
end

-- (track, key) rows the MIDI uses, track by track, highest key first like a piano roll
function Level.rows(lv)
  local seen, rows = {}, {}
  for _, n in ipairs(lv.notes) do
    local k = n.track * 1000 + n.key
    if not seen[k] then seen[k] = true; rows[#rows + 1] = { track = n.track, key = n.key } end
  end
  for _, s in ipairs(lv.sounds) do
    local k = s.track * 1000 + s.key
    if not seen[k] then seen[k] = true; rows[#rows + 1] = { track = s.track, key = s.key } end
  end
  table.sort(rows, function(a, b)
    if a.track ~= b.track then return a.track < b.track end
    return a.key > b.key
  end)
  return rows
end

-- What the game plays, in beats from the level's start: every button in the level's stretch
-- with the notes it plays, the notes no button plays, and the steps the level is built up in
-- (each a round box's buttons, or a lone button), in order of their first button.
--   { buttons = { { beat, endBeat, pad, color, vel, notes = { { beat, track, key, vel } } } },
--     free = { { beat, track, key, vel } }, steps = { { beat, buttons = { button } } }, bars, unboxed }
function Level.prepare(lv)
  local a, z = Level.window(lv)
  local owner = Level.membership(lv)
  local function rel(tick) return (tick - a) / lv.ppq end
  local out = { buttons = {}, free = {}, bars = lv.bars, unboxed = lv.unboxed_notes }
  local byButton = {}
  for _, b in ipairs(lv.buttons) do
    if b.start >= a and b.start < z then
      local pb = { beat = rel(b.start), endBeat = rel(b["end"]), pad = b.pad, color = Level.buttonColor(lv, b), vel = 0, notes = {}, source = b }
      out.buttons[#out.buttons + 1] = pb
      byButton[b] = pb
    end
  end
  for _, n in ipairs(lv.notes) do
    if n.tick >= a and n.tick < z then
      local e = { beat = rel(n.tick), track = n.track, key = n.key, vel = n.vel, len = n.len / lv.ppq }
      local b = owner[n.id]
      if b then
        if byButton[b] then
          table.insert(byButton[b].notes, e)
          byButton[b].vel = math.max(byButton[b].vel, n.vel)
        end
      else
        out.free[#out.free + 1] = e
      end
    end
  end
  for _, b in ipairs(out.buttons) do if b.vel == 0 then b.vel = 100 end end
  -- the steps: out.buttons is in time order, so each step lands in order of its first button
  local roundOf = Level.roundMembership(lv)
  out.steps = {}
  local byRound = {}
  for _, pb in ipairs(out.buttons) do
    local r = roundOf[pb.source]
    if r and byRound[r] then
      table.insert(byRound[r].buttons, pb)
    else
      local step = { beat = pb.beat, buttons = { pb }, round = r }
      out.steps[#out.steps + 1] = step
      if r then byRound[r] = step end
    end
  end
  return out
end

-- Every note the level sounds as a loop (its buttons' notes and, unless muted, the free ones),
-- in beats from its start: what plays once the level is locked in under the next.
function Level.loopNotes(prep)
  local out = {}
  for _, b in ipairs(prep.buttons) do
    for _, n in ipairs(b.notes) do out[#out + 1] = n end
  end
  if prep.unboxed ~= "mute" then
    for _, n in ipairs(prep.free) do out[#out + 1] = n end
  end
  table.sort(out, function(x, y) return x.beat < y.beat end)
  return out
end

-- A note's sample starts where its sound starts: digital silence before the first frame over
-- -60 dBFS is skipped (keeping 1 ms before it), so a pad sounds the moment it's hit. Bounces
-- often carry 100 ms or so of silence up front. The view shares the decoded frames.
local SILENCE, PREROLL = 0.001, 44
function Level.trimmed(s)
  local d = s.data
  local first
  for f = 0, s.frames - 1 do
    if math.abs(d[f * 2]) > SILENCE or math.abs(d[f * 2 + 1]) > SILENCE then first = f; break end
  end
  local off = math.max(0, (first or 0) - PREROLL)
  if off == 0 then return s end
  local t = {}
  for k, v in pairs(s) do t[k] = v end
  t.base, t.trimmed = s, off   -- keeps the decoded frames alive
  t.data, t.frames = d + off * 2, s.frames - off
  return t
end

-- Decodes a .wav into the mixer once (cached by file, shared across levels and songs).
-- trim: skip its leading silence (notes; never a backing track or anything timed from 0).
local cache = {}
function Level.loadSample(mixer, file, trim)
  if not file then return nil end
  local key = file .. (trim and "#trim" or "")
  if cache[key] == nil then
    local ok, s = pcall(function()
      local bytes = assert(util.readFile(file))
      local sample = mixer:loadSample(love.sound.newSoundData(love.filesystem.newFileData(bytes, util.basename(file))), util.basename(file))
      return trim and Level.trimmed(sample) or sample
    end)
    if not ok then print("level: cannot load " .. file .. ": " .. tostring(s)) end
    cache[key] = ok and s or false
  end
  return cache[key] or nil
end

-- The level's samples in the mixer: audio.sounds[track][key], audio.backing
function Level.loadAudio(lv, mixer)
  local audio = { sounds = {} }
  for _, s in ipairs(lv.sounds) do
    audio.sounds[s.track] = audio.sounds[s.track] or {}
    audio.sounds[s.track][s.key] = Level.loadSample(mixer, s.sample, true)
  end
  if lv.backing then audio.backing = Level.loadSample(mixer, lv.backing.file) end
  function audio.get(track, key) return audio.sounds[track] and audio.sounds[track][key] end
  return audio
end

return Level
