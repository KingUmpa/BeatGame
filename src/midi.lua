-- src/midi.lua
-- Standard MIDI File (.mid) reader and writer. Reads format 0 and 1, running status,
-- sysex and meta events, note-on with velocity 0 as note-off, and the tempo map. Keeps
-- every raw event with its byte offset so tools can show exactly what is in the file.
--
--   local m = Midi.parse(bytes)      -> { format, ppq, name, notes, events, metas, tempos, timeSig }
--   local m = Midi.load(path)        -> same, read through util.readFile
--   local bytes = Midi.encode(doc)   -> format-0 file from { ppq, metas, notes } (see below)
--   Midi.describe(event)             -> "Note On  ch1  A3   69  vel 65"
--   Midi.hex(event.raw)              -> "84 21 90 45 41"
--   Midi.noteName(69)                -> "A3" (Ableton's octave numbering: middle C = C3 = 60)
--
-- Each note: { tick, len, beat, lenBeats, time, key, vel, offVel, ch, track, on, off }
--   on / off are the note's two events. beat = tick / ppq; time = seconds through the
--   file's tempo map (120 BPM if it has none). Ableton's clip export writes no tempo
--   event (m.hasTempo is false), so songs give their own BPM and work in beats.
-- Each event: { index, offset, size, raw, delta, tick, track, status, running, kind, ch,
--   key, vel, meta, data }. offset is 0-based from the start of the file; raw includes the
--   delta-time bytes. kind: note_on, note_off, poly_pressure, cc, program, channel_pressure,
--   pitch_bend, sysex, meta.

local util = require("src.util")

local Midi = {}

local function u32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function u16(s, i)
  local a, b = s:byte(i, i + 1)
  return a * 256 + b
end

-- data bytes and name for each channel status (high nibble)
local CHANNEL = {
  [0x8] = { 2, "note_off" }, [0x9] = { 2, "note_on" }, [0xA] = { 2, "poly_pressure" },
  [0xB] = { 2, "cc" }, [0xC] = { 1, "program" }, [0xD] = { 1, "channel_pressure" },
  [0xE] = { 2, "pitch_bend" },
}

local function parseTrack(s, p, stop, trackIndex, m)
  local tick, status = 0, nil
  local open = {}   -- ch*128+key -> FIFO of sounding notes, so overlapping repeats pair up in order

  local function vlq()
    local v = 0
    repeat
      local b = s:byte(p)
      p = p + 1
      v = v * 128 + b % 128
    until b < 128
    return v
  end

  while p < stop do
    local start = p
    local delta = vlq()
    tick = tick + delta
    local ev = { offset = start - 1, delta = delta, tick = tick, track = trackIndex }
    local b = s:byte(p)
    if b == 0xFF then
      local metaStart = p
      local kind = s:byte(p + 1)
      p = p + 2
      local len = vlq()
      local data = s:sub(p, p + len - 1)
      p = p + len
      ev.kind, ev.status, ev.meta, ev.data = "meta", 0xFF, kind, data
      if kind == 0x03 then
        m.trackNames[trackIndex] = m.trackNames[trackIndex] or data
      elseif kind == 0x51 and len == 3 then
        local x, y, z = data:byte(1, 3)
        m.tempos[#m.tempos + 1] = { tick = tick, usPerBeat = (x * 256 + y) * 256 + z }
      elseif kind == 0x58 and len >= 2 and not m.timeSig then
        m.timeSig = { data:byte(1), 2 ^ data:byte(2) }
      end
      if kind ~= 0x2F then
        m.metas[#m.metas + 1] = { tick = tick, raw = s:sub(metaStart, p - 1), track = trackIndex }   -- FF type len data
      end
    elseif b == 0xF0 or b == 0xF7 then
      p = p + 1
      local len = vlq()   -- not `p = p + vlq()`: vlq moves p, and the old p would be added
      ev.kind, ev.status, ev.data = "sysex", b, s:sub(p, p + len - 1)
      p = p + len
      status = nil
    else
      ev.running = b < 0x80
      if not ev.running then
        status = b
        p = p + 1
      end
      assert(status, "MIDI data byte with no running status")
      local hi, ch = math.floor(status / 16), status % 16
      local spec = CHANNEL[hi]
      local key, vel = s:byte(p), spec[1] == 2 and s:byte(p + 1) or nil
      p = p + spec[1]
      ev.status, ev.ch, ev.key, ev.vel, ev.kind = status, ch, key, vel, spec[2]
      if hi == 0x9 and vel == 0 then ev.kind, ev.zeroVelocityOff = "note_off", true end

      if ev.kind == "note_on" then
        local q = open[ch * 128 + key]
        if not q then
          q = {}
          open[ch * 128 + key] = q
        end
        q[#q + 1] = { tick = tick, key = key, vel = vel, ch = ch, track = trackIndex, on = ev }
      elseif ev.kind == "note_off" then
        local q = open[ch * 128 + key]
        if q and #q > 0 then
          local n = table.remove(q, 1)
          n.len, n.off, n.offVel = tick - n.tick, ev, vel
          m.notes[#m.notes + 1] = n
        end
      end
    end
    ev.raw = s:sub(start, p - 1)
    ev.size = #ev.raw
    ev.index = #m.events + 1
    m.events[ev.index] = ev
    if ev.kind == "meta" and ev.meta == 0x2F then break end
  end

  -- notes still held when the track ends last until the end
  for _, q in pairs(open) do
    for _, n in ipairs(q) do
      n.len = tick - n.tick
      m.notes[#m.notes + 1] = n
    end
  end
  m.lengthTicks = math.max(m.lengthTicks, tick)
end

function Midi.parse(s)
  assert(#s >= 14 and s:sub(1, 4) == "MThd", "not a MIDI file (no MThd header)")
  local headerLen = u32(s, 5)
  local division = u16(s, 13)
  assert(division < 0x8000, "SMPTE time division is not supported")

  local m = {
    format = u16(s, 9), ppq = division, notes = {}, events = {}, metas = {}, tempos = {},
    trackNames = {}, lengthTicks = 0, size = #s, chunks = {},
  }
  m.chunks[1] = { id = "MThd", offset = 0, size = 8 + headerLen }
  local pos, trackIndex = 9 + headerLen, 0
  while pos + 7 <= #s do
    local id, len = s:sub(pos, pos + 3), u32(s, pos + 4)
    m.chunks[#m.chunks + 1] = { id = id, offset = pos - 1, size = 8 + len }
    local body = pos + 8
    pos = body + len
    if id == "MTrk" then
      trackIndex = trackIndex + 1
      parseTrack(s, body, math.min(pos, #s + 1), trackIndex, m)
    end
  end
  m.trackCount = trackIndex
  m.name = m.trackNames[1]

  table.sort(m.tempos, function(a, b) return a.tick < b.tick end)
  m.hasTempo = #m.tempos > 0
  if not m.hasTempo then m.tempos[1] = { tick = 0, usPerBeat = 500000 } end
  m.bpm = 60e6 / m.tempos[1].usPerBeat

  table.sort(m.notes, function(a, b)
    if a.tick ~= b.tick then return a.tick < b.tick end
    return a.key < b.key
  end)
  for _, n in ipairs(m.notes) do
    n.beat = n.tick / m.ppq
    n.lenBeats = n.len / m.ppq
    n.time = Midi.tickToSeconds(m, n.tick)
  end
  m.lengthBeats = m.lengthTicks / m.ppq
  return m
end

function Midi.tickToSeconds(m, tick)
  local t, lastTick, us = 0, 0, 500000
  for _, tp in ipairs(m.tempos) do
    if tp.tick > tick then break end
    t = t + (tp.tick - lastTick) * us / m.ppq / 1e6
    lastTick, us = tp.tick, tp.usPerBeat
  end
  return t + (tick - lastTick) * us / m.ppq / 1e6
end

function Midi.load(path)
  local bytes, err = util.readFile(path)
  if not bytes then error(err, 2) end
  return Midi.parse(bytes)
end

------------------------------------------------------------------------
-- writing
------------------------------------------------------------------------

local function vlqBytes(n)
  local bytes = { n % 128 }
  n = math.floor(n / 128)
  while n > 0 do
    table.insert(bytes, 1, n % 128 + 128)
    n = math.floor(n / 128)
  end
  return string.char(unpack(bytes))
end

local function be32(n)
  return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

local function be16(n)
  return string.char(math.floor(n / 256) % 256, n % 256)
end

-- doc = { ppq, metas = { { tick, raw, track } } (raw = FF type len data), notes = { { tick,
-- len, key, vel, ch, offVel, track } } }; track defaults to 1. One track writes a format 0
-- file, more write format 1. Explicit status on every event (no running status), note-offs
-- as 0x8n with offVel (default 64), and at equal ticks note-offs before note-ons: the layout
-- Ableton's clip export uses, so an unedited file comes back byte for byte.
function Midi.encode(doc)
  local tracks = 1
  for _, mt in ipairs(doc.metas or {}) do tracks = math.max(tracks, mt.track or 1) end
  for _, n in ipairs(doc.notes) do tracks = math.max(tracks, n.track or 1) end
  local chunks = {}
  for t = 1, tracks do
    local evs = {}
    for i, mt in ipairs(doc.metas or {}) do
      if (mt.track or 1) == t then evs[#evs + 1] = { tick = mt.tick, order = 0, seq = i, bytes = mt.raw } end
    end
    for i, n in ipairs(doc.notes) do
      if (n.track or 1) == t then
        local ch = n.ch or 0
        evs[#evs + 1] = { tick = n.tick, order = 2, seq = i, bytes = string.char(0x90 + ch, n.key, n.vel) }
        evs[#evs + 1] = { tick = n.tick + n.len, order = 1, seq = i, bytes = string.char(0x80 + ch, n.key, n.offVel or 64) }
      end
    end
    table.sort(evs, function(a, b)
      if a.tick ~= b.tick then return a.tick < b.tick end
      if a.order ~= b.order then return a.order < b.order end
      return a.seq < b.seq
    end)
    local out, last = {}, 0
    for _, e in ipairs(evs) do
      out[#out + 1] = vlqBytes(e.tick - last) .. e.bytes
      last = e.tick
    end
    out[#out + 1] = "\0\255\47\0"
    local body = table.concat(out)
    chunks[t] = "MTrk" .. be32(#body) .. body
  end
  return "MThd" .. be32(6) .. be16(tracks > 1 and 1 or 0) .. be16(tracks) .. be16(doc.ppq) .. table.concat(chunks)
end

------------------------------------------------------------------------
-- description
------------------------------------------------------------------------

local NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

function Midi.noteName(key)
  return NAMES[key % 12 + 1] .. (math.floor(key / 12) - 2)
end

function Midi.hex(raw)
  return (raw:gsub(".", function(c) return ("%02X "):format(c:byte()) end):sub(1, -2))
end

local META = {
  [0x00] = "Sequence Number", [0x01] = "Text", [0x02] = "Copyright", [0x03] = "Track Name",
  [0x04] = "Instrument", [0x05] = "Lyric", [0x06] = "Marker", [0x07] = "Cue Point",
  [0x20] = "Channel Prefix", [0x21] = "Port", [0x2F] = "End of Track", [0x51] = "Tempo",
  [0x54] = "SMPTE Offset", [0x58] = "Time Signature", [0x59] = "Key Signature",
  [0x7F] = "Sequencer Specific",
}

function Midi.describe(ev)
  local k = ev.kind
  if k == "note_on" or k == "note_off" then
    local s = ("%-8s ch%-2d %-3s %3d  vel %d"):format(k == "note_on" and "Note On" or "Note Off", ev.ch + 1,
      Midi.noteName(ev.key), ev.key, ev.vel)
    if ev.zeroVelocityOff then s = s .. "  (note-on vel 0)" end
    return s
  elseif k == "meta" then
    local name = META[ev.meta] or ("Meta 0x%02X"):format(ev.meta)
    local d = ev.data or ""
    if ev.meta == 0x51 and #d == 3 then
      local us = (d:byte(1) * 256 + d:byte(2)) * 256 + d:byte(3)
      return ("%s  %d us/beat = %.3f BPM"):format(name, us, 60e6 / us)
    elseif ev.meta == 0x58 and #d >= 4 then
      return ("%s  %d/%d, %d clocks/click, %d 32nds/beat"):format(name, d:byte(1), 2 ^ d:byte(2), d:byte(3), d:byte(4))
    elseif ev.meta >= 0x01 and ev.meta <= 0x07 then
      return ("%s  \"%s\""):format(name, d)
    end
    return name
  elseif k == "sysex" then
    return ("SysEx  %d bytes"):format(#(ev.data or ""))
  elseif k == "cc" then
    return ("Control  ch %d  cc %d = %d"):format(ev.ch + 1, ev.key, ev.vel)
  elseif k == "program" then
    return ("Program  ch %d  %d"):format(ev.ch + 1, ev.key)
  elseif k == "pitch_bend" then
    return ("Pitch Bend  ch %d  %d"):format(ev.ch + 1, ev.vel * 128 + ev.key - 8192)
  end
  return k
end

return Midi
