-- src/view.lua
-- Draws the workbench. Top: the file and transport facts. Middle, on one time axis: ruler
-- with the window, backing waveform, a lane per key, velocity, and the rendered output
-- with the limiter's gain reduction. Bottom: an inspector for whatever is selected or
-- under the mouse, and the file's raw events. Right: every tool, from B.COMMANDS.

local utf8 = require("utf8")
local Midi = require("src.midi")
local Wave = require("src.wave")

local View = {}

local BG = { 0.047, 0.051, 0.059 }
local PANEL = { 0.072, 0.077, 0.088 }
local LINE = { 0.15, 0.16, 0.18 }
local TEXT = { 0.82, 0.84, 0.88 }
local DIM = { 0.47, 0.49, 0.54 }
local FAINT = { 0.27, 0.29, 0.32 }
local ACC = { 0.92, 0.73, 0.42 }
local RED = { 0.93, 0.43, 0.40 }
local SAMPLE = {
  { 0.52, 0.72, 0.96 }, { 0.56, 0.84, 0.62 }, { 0.96, 0.68, 0.46 }, { 0.79, 0.64, 0.96 },
  { 0.90, 0.85, 0.50 }, { 0.50, 0.85, 0.85 },
}
local SIDEBAR = 372
local ROW = 15

local fonts = {}

local function color(c, a) love.graphics.setColor(c[1], c[2], c[3], a or 1) end

local function loadFonts()
  if fonts.body then return end
  local f = io.open("C:/Windows/Fonts/consola.ttf", "rb")
  local data = f and f:read("*a")
  if f then f:close() end
  local function make(size)
    if data then return love.graphics.newFont(love.filesystem.newFileData(data, "consola.ttf"), size) end
    return love.graphics.newFont(size - 1)
  end
  fonts.small, fonts.body, fonts.big = make(12), make(13), make(15)
  love.graphics.setBackgroundColor(BG)
end

local function sampleColor(b, key)
  local s = b:sampleFor(key)
  return s and SAMPLE[(s.n - 1) % #SAMPLE + 1] or DIM
end

-- keep the end of a name ("..194853]-3.wav"), whole UTF-8 characters at a time
local function clipLeft(text, font, w)
  if font:getWidth(text) <= w then return text end
  while #text > 1 and font:getWidth(".." .. text) > w do
    text = text:sub((utf8.offset(text, 2) or 2))
  end
  return ".." .. text
end

-- trim whole UTF-8 characters (labels contain "·") until the text fits
local function clip(text, font, w)
  if font:getWidth(text) <= w then return text end
  while #text > 1 and font:getWidth(text .. "..") > w do
    text = text:sub(1, (utf8.offset(text, -1) or #text) - 1)
  end
  return text .. ".."
end

local function comma(n)
  local s = tostring(math.floor(n))
  while true do
    local r, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
    s = r
    if k == 0 then return s end
  end
end

local function db(g) return g > 0 and 20 * math.log10(g) or -math.huge end

------------------------------------------------------------------------
-- layout
------------------------------------------------------------------------

function View.layout(b, W, H)
  local L = { W = W, H = H }
  local MW = W - SIDEBAR
  L.tlX = 236
  L.tlW = MW - L.tlX - 14
  L.header = { x = 0, y = 0, w = MW, h = 48 }
  local y = 48
  L.ruler = { x = L.tlX, y = y, w = L.tlW, h = 22 }; y = y + 24
  L.backing = { x = L.tlX, y = y, w = L.tlW, h = 44 }; y = y + 48
  L.rowH = 34
  L.lanes = { x = L.tlX, y = y, w = L.tlW, h = L.rowH * #b.lanes }
  L.laneLabels = { x = 0, y = y, w = L.tlX, h = L.lanes.h }; y = y + L.lanes.h + 4
  L.vel = { x = L.tlX, y = y, w = L.tlW, h = 40 }; y = y + 44
  L.out = { x = L.tlX, y = y, w = L.tlW, h = 48 }; y = y + 48 + 14
  local bh = H - y - 10
  local split = math.floor(MW * 0.5)
  L.inspector = { x = 14, y = y, w = split - 28, h = bh }
  L.events = { x = split, y = y, w = MW - split - 14, h = bh }
  L.tools = { x = MW, y = 0, w = SIDEBAR, h = H }
  return L
end

------------------------------------------------------------------------
-- timeline
------------------------------------------------------------------------

local function stripLabel(L, r, title, sub)
  love.graphics.setFont(fonts.body)
  color(TEXT)
  love.graphics.print(title, 14, r.y + 4)
  if sub then
    love.graphics.setFont(fonts.small)
    color(DIM)
    love.graphics.print(clip(sub, fonts.small, L.tlX - 24), 14, r.y + 21)
  end
end

local function gridLines(b, y, h)
  local L = b.L
  local ppq = b.doc.ppq
  local g = b:gridTicks() / ppq
  while g * b.view.ppb < 6 do g = g * 2 end
  local first = math.floor(b:beatOfX(L.tlX) / g) * g
  local last = b:beatOfX(L.tlX + L.tlW)
  local beat = first
  while beat <= last do
    local x = b:xOfBeat(beat)
    if x >= L.tlX then
      local bar = math.abs(beat / 4 - math.floor(beat / 4 + 0.5)) < 1e-6
      local whole = math.abs(beat - math.floor(beat + 0.5)) < 1e-6
      color(LINE, bar and 1 or whole and 0.55 or 0.25)
      love.graphics.rectangle("fill", math.floor(x), y, 1, h)
    end
    beat = beat + g
  end
end

local function drawRuler(b)
  local L, r = b.L, b.L.ruler
  color(PANEL)
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h)
  -- window band and its handles
  local fx, tx = b:xOfBeat(b.from), b:xOfBeat(b.to)
  color(ACC, 0.13)
  love.graphics.rectangle("fill", math.max(r.x, fx), r.y, math.max(0, math.min(r.x + r.w, tx) - math.max(r.x, fx)), r.h)
  color(ACC, 0.9)
  for _, x in ipairs({ fx, tx }) do
    if x >= r.x and x <= r.x + r.w then love.graphics.rectangle("fill", x - 1, r.y, 2, r.h) end
  end
  love.graphics.setFont(fonts.small)
  local barPx = b.view.ppb * 4
  local step = barPx >= 40 and 1 or barPx >= 16 and 4 or 16
  local firstBar = math.max(0, math.floor(b:beatOfX(r.x) / 4))
  for bar = firstBar, math.ceil(b:beatOfX(r.x + r.w) / 4) do
    local x = b:xOfBeat(bar * 4)
    if x >= r.x and x < r.x + r.w then
      color(FAINT)
      love.graphics.rectangle("fill", x, r.y + 12, 1, 10)
      if bar % step == 0 then
        color(DIM)
        love.graphics.print(tostring(bar + 1), x + 3, r.y + 3)
      end
    end
  end
  love.graphics.setFont(fonts.small)
  color(DIM)
  love.graphics.print(("bar     grid %s · %.0f px/beat"):format(b:gridName(), b.view.ppb), 14, r.y + 5)
end

local function frameAtXFor(b, sampleStartBeat)
  return function(px)
    return (b:beatOfX(b.L.tlX + px) - sampleStartBeat) * b.fpb
  end
end

local function drawBacking(b)
  local L, r = b.L, b.L.backing
  color(PANEL)
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h)
  local bk = b.backing
  if not bk then
    stripLabel(L, r, "backing", "none")
    return
  end
  love.graphics.setScissor(r.x, r.y, r.w, r.h)
  -- the backing starts at the window start and is cut at the window end
  local fx, tx = b:xOfBeat(b.from), b:xOfBeat(b.to)
  color(b.backingMuted and FAINT or DIM, 0.9)
  local x0 = math.max(r.x, fx)
  local x1 = math.min(r.x + r.w, tx)
  if x1 > x0 then
    local f = frameAtXFor(b, b.from)
    Wave.draw(bk.peaks, x0, r.y + 2, x1 - x0, r.h - 4, function(px) return f(px + x0 - L.tlX) end)
  end
  love.graphics.setScissor()
  local info = bk.info
  stripLabel(L, r, "backing" .. (b.backingMuted and "  (muted)" or ""),
    info and ("%s %d-bit %d Hz · %.3f s"):format(info.format, info.bits, info.rate, info.seconds or 0) or bk.name)
  love.graphics.setFont(fonts.small)
  color(FAINT)
  love.graphics.print(clipLeft(bk.name, fonts.small, L.tlX - 24), 14, r.y + 34)
end

local function drawLanes(b, playBeat)
  local L, r = b.L, b.L.lanes
  local ppq = b.doc.ppq
  love.graphics.setScissor(r.x, r.y, r.w, r.h)
  for i, lane in ipairs(b.lanes) do
    local y = r.y + (i - 1) * L.rowH
    color(PANEL, (i % 2 == 0) and 0.7 or 1)
    love.graphics.rectangle("fill", r.x, y, r.w, L.rowH)
    if b.hoverLane == i then
      color(TEXT, 0.03)
      love.graphics.rectangle("fill", r.x, y, r.w, L.rowH)
    end
  end
  gridLines(b, r.y, r.h)
  -- outside the window nothing is heard in the loop
  color(BG, 0.45)
  local fx, tx = b:xOfBeat(b.from), b:xOfBeat(b.to)
  love.graphics.rectangle("fill", r.x, r.y, math.max(0, fx - r.x), r.h)
  love.graphics.rectangle("fill", tx, r.y, math.max(0, r.x + r.w - tx), r.h)

  -- original positions of notes that were moved or deleted
  local function ghost(o)
    local lane = b.laneOf[o.key]
    if not lane then return end
    local y = r.y + (lane - 1) * L.rowH
    local x0, x1 = b:xOfTick(o.tick), math.max(b:xOfTick(o.tick + o.len), b:xOfTick(o.tick) + 4)
    color(DIM, 0.5)
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", x0 + 0.5, y + 6.5, x1 - x0 - 1, L.rowH - 13)
  end
  for _, o in ipairs(b.doc.removed) do ghost(o) end

  for _, n in ipairs(b.doc.notes) do
    local lane = b.laneOf[n.key]
    local y = r.y + (lane - 1) * L.rowH
    local c = sampleColor(b, n.key)
    local x0 = b:xOfTick(n.tick)
    local x1 = math.max(b:xOfTick(n.tick + n.len), x0 + 3)
    local change = b.doc:changed(n)
    if change == "moved" or change == "key" or change == "length" then ghost(b.doc.original[n.id]) end

    -- the one-shot: how long the sample really sounds, and where the next hit cuts it
    if b.showTails then
      local tailEnd, cutBy = b:tailEnd(n)
      local tx1 = b:xOfTick(tailEnd)
      color(c, 0.13)
      love.graphics.rectangle("fill", x0, y + L.rowH - 12, tx1 - x0, 5)
      if cutBy then
        color(c, 0.6)
        love.graphics.rectangle("fill", tx1 - 1, y + L.rowH - 14, 2, 9)
      end
    end

    -- where the grid says it should be
    if b.showDev then
      local dev = b:deviation(n.tick)
      if dev ~= 0 then
        local gx = b:xOfTick(n.tick - dev)
        local ms = math.abs(b:msOfTicks(dev))
        color(ms > 20 and ACC or FAINT, ms > 20 and 0.9 or 1)
        love.graphics.rectangle("fill", math.min(gx, x0), y + 3, math.abs(x0 - gx), 1)
        love.graphics.rectangle("fill", gx, y + 1, 1, 5)
      end
    end

    local sounding = false
    if playBeat then
      local tailEnd = b:tailEnd(n)
      sounding = playBeat >= n.tick / ppq and playBeat < tailEnd / ppq
    end
    color(c, (0.28 + 0.62 * n.vel / 127) * (sounding and 1 or 0.85))
    love.graphics.rectangle("fill", x0, y + 7, x1 - x0, L.rowH - 20)
    if sounding then
      color(TEXT, 0.9)
      love.graphics.rectangle("fill", x0, y + 7, x1 - x0, L.rowH - 20)
    end
    if b.sel[n.id] then
      color(ACC)
      love.graphics.setLineWidth(1.5)
      love.graphics.rectangle("line", x0 - 0.5, y + 6.5, x1 - x0 + 1, L.rowH - 19)
    elseif b.hoverNote == n then
      color(TEXT, 0.8)
      love.graphics.setLineWidth(1)
      love.graphics.rectangle("line", x0 - 0.5, y + 6.5, x1 - x0 + 1, L.rowH - 19)
    end
    if change then
      color(ACC)
      love.graphics.rectangle("fill", x0, y + 3, 3, 3)
    end
  end
  love.graphics.setScissor()

  -- lane names
  for i, lane in ipairs(b.lanes) do
    local y = r.y + (i - 1) * L.rowH
    local s = b:sampleFor(lane.key)
    local count = 0
    for _, n in ipairs(b.doc.notes) do if n.key == lane.key then count = count + 1 end end
    color(sampleColor(b, lane.key))
    love.graphics.rectangle("fill", 6, y + 6, 3, L.rowH - 12)
    love.graphics.setFont(fonts.body)
    color(b.hoverLane == i and TEXT or { 0.72, 0.74, 0.78 })
    love.graphics.print(("%3d %-3s"):format(lane.key, lane.name), 14, y + 3)
    local flags = (lane.mute and " M" or "") .. (lane.solo and " S" or "")
    color(ACC)
    love.graphics.print(flags, 14 + fonts.body:getWidth("000 AAA "), y + 3)
    love.graphics.setFont(fonts.small)
    color(DIM)
    local head = ("%2d x · "):format(count)
    local desc = s and ("#%d "):format(s.n) .. clipLeft(s.name, fonts.small, L.tlX - 60 - fonts.small:getWidth(head)) or "no sample (silent)"
    love.graphics.print(head .. desc, 14, y + 18)
  end
end

local function drawVelocity(b)
  local L, r = b.L, b.L.vel
  color(PANEL)
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h)
  love.graphics.setScissor(r.x, r.y, r.w, r.h)
  color(LINE)
  love.graphics.rectangle("fill", r.x, r.y + r.h - 1 - (r.h - 4) * 64 / 127, r.w, 1)
  for _, n in ipairs(b.doc.notes) do
    local x = math.floor(b:xOfTick(n.tick))
    local h = (r.h - 4) * n.vel / 127
    local c = b.sel[n.id] and ACC or sampleColor(b, n.key)
    color(c, b.sel[n.id] and 1 or 0.7)
    love.graphics.rectangle("fill", x, r.y + r.h - 1 - h, 1, h)
    love.graphics.rectangle("fill", x - 1, r.y + r.h - 1 - h - 1, 3, 3)
  end
  love.graphics.setScissor()
  stripLabel(L, r, "velocity", ("-> gain, %d%% sensitivity"):format(b.velSens * 100))
end

local function drawOutput(b)
  local L, r = b.L, b.L.out
  color(PANEL)
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h)
  local out = b.out
  if not out then
    stripLabel(L, r, "output", "rendering...")
    return
  end
  love.graphics.setScissor(r.x, r.y, r.w, r.h)
  local fx, tx = b:xOfBeat(b.from), b:xOfBeat(b.to)
  local x0, x1 = math.max(r.x, fx), math.min(r.x + r.w, tx)
  if x1 > x0 then
    local f = frameAtXFor(b, b.from)
    color(TEXT, 0.55)
    Wave.draw(out.peaks, x0, r.y + 2, x1 - x0, r.h - 4, function(px) return f(px + x0 - L.tlX) end)
    -- limiter gain reduction, 0 dB at the top edge, -12 dB at the bottom
    color(RED, 0.9)
    local prev
    for px = 0, math.floor(x1 - x0) - 1 do
      local frame = f(px + x0 - L.tlX)
      local g = b:grAt(frame)
      local y = r.y + math.min(1, -db(g) / 12) * r.h
      if prev and (g < 0.999 or prev[2] > r.y + 0.5) then love.graphics.line(prev[1], prev[2], x0 + px, y) end
      prev = { x0 + px, y }
    end
  end
  love.graphics.setScissor()
  stripLabel(L, r, "output (rendered)", ("peak %.1f dBFS"):format(db(out.peaks.peak)))
  love.graphics.setFont(fonts.small)
  color(RED, 0.9)
  love.graphics.print(("limiter, down to %.1f dB"):format(db(out.grMin)), 14, r.y + 34)
end

------------------------------------------------------------------------
-- header
------------------------------------------------------------------------

local function drawHeader(b, playBeat)
  local m, doc = b.midi, b.doc
  local file = doc:file()
  love.graphics.setFont(fonts.body)
  color(TEXT)
  local tempo = m.hasTempo and ("%g BPM in file"):format(m.bpm) or ("no tempo in file -> %g BPM from songs/%s.lua"):format(b.bpm, b.songName)
  love.graphics.print(("%s   SMF %d · %d track · %d ppq · %d notes · %d events · %d bytes   %s   %d/%d"):format(
    b.midiPath:match("[^/]+$"), file.format, file.trackCount, doc.ppq, #doc.notes, #file.events, #doc:bytes(),
    tempo, m.timeSig and m.timeSig[1] or 4, m.timeSig and m.timeSig[2] or 4), 14, 8)

  love.graphics.setFont(fonts.small)
  local winSec = (b.to - b.from) * 60 / b.bpm
  local match = ""
  if b.backing then
    local bs = b.backing.sample.frames / 44100
    match = math.abs(bs - winSec) < 0.002 and (" = backing %.3f s"):format(bs) or (" != backing %.3f s"):format(bs)
  end
  local parts = {
    ("window %s - %s (%g beats, %.3f s%s)"):format(b:bbt(b.from), b:bbt(b.to), b.to - b.from, winSec, match),
    "loop " .. (b.loop and "on" or "off"),
    "metronome " .. (b.metronome and "on" or "off"),
    "choke " .. (b.choke and "on" or "off"),
    ("vel->vol %d%%"):format(b.velSens * 100),
  }
  color(DIM)
  love.graphics.print(table.concat(parts, " · "), 14, 28)

  local undo = #doc.undoStack
  local state = doc:dirty() and ("unsaved · %d edit%s"):format(undo, undo == 1 and "" or "s") or "saved"
  local t = b.transport.playing and ("PLAY %s  %.3f s"):format(b:bbt(playBeat), playBeat * 60 / b.bpm)
    or ("STOP %s"):format(b:bbt(b.playhead))
  love.graphics.setFont(fonts.body)
  local right = state .. "     " .. t
  color(doc:dirty() and ACC or DIM)
  love.graphics.print(state, b.L.header.w - 14 - fonts.body:getWidth(right), 8)
  color(b.transport.playing and ACC or TEXT)
  love.graphics.print(t, b.L.header.w - 14 - fonts.body:getWidth(t), 8)
end

------------------------------------------------------------------------
-- inspector
------------------------------------------------------------------------

local function noteLines(b, n)
  local ppq = b.doc.ppq
  local out = {}
  local function add(label, text, c) out[#out + 1] = { label, text, c } end
  local beat = n.tick / ppq
  local s = b:sampleFor(n.key)
  local change = b.doc:changed(n)
  local o = b.doc.original[n.id]

  add("NOTE", ("id %d · %s (%d) · ch %d%s"):format(n.id, Midi.noteName(n.key), n.key, (n.ch or 0) + 1,
    change and ("   [" .. change .. "]") or ""), change and ACC or TEXT)
  add("start", ("tick %d · beat %.3f · bar %s"):format(n.tick, beat, b:bbt(beat)) ..
    (o and o.tick ~= n.tick and ("   was tick %d"):format(o.tick) or ""))
  local dev = b:deviation(n.tick)
  add("grid", dev == 0 and ("on the %s grid"):format(b:gridName())
    or ("%+d ticks = %+.1f ms %s the %s line at %s"):format(dev, b:msOfTicks(dev), dev > 0 and "after" or "before",
      b:gridName(), b:bbt((n.tick - dev) / ppq)))
  add("length", ("%d ticks · %.3f beat · %.0f ms   (ignored: pads play one-shot)"):format(n.len, n.len / ppq, b:msOfTicks(n.len)))
  local g = b:gainFor(n)
  add("velocity", ("%d -> gain 1 - %.2f x (1 - %d/127) = %.3f (%.2f dB)"):format(n.vel, b.velSens, n.vel, g, db(g)))
  if beat >= b.from and beat < b.to then
    local f = math.floor((beat - b.from) * b.fpb + 0.5)
    add("in window", ("beat %.3f -> frame %s @ 44.1 kHz (%.4f s)"):format(beat - b.from, comma(f), f / 44100))
    add("limiter", ("%.2f dB at this hit"):format(db(b:grAt(f))))
  else
    add("in window", "no: outside the window, not heard in the loop", DIM)
  end
  if not b.midi.hasTempo then
    add("tempo", ("none in file: at 120 BPM this is %.3f s, at %g BPM %.3f s"):format(beat * 0.5, b.bpm, beat * 60 / b.bpm), DIM)
  end
  if s then
    add("SAMPLE", ("#%d %s"):format(s.n, s.name), TEXT)
    if s.info then
      add("file", ("%s %d-bit · %d ch · %d Hz · %s frames · %.3f s"):format(s.info.format, s.info.bits, s.info.channels,
        s.info.rate, comma(s.info.frames or 0), s.info.seconds or 0))
    end
    add("loaded", ("16-bit (LÖVE) · %d -> 44100 Hz · %s frames"):format(s.sample.sourceRate or 44100, comma(s.sample.frames)))
    add("sounds", ("%.3f s to -60 dBFS = %.2f beats"):format(s.audible / 44100, s.audible / b.fpb))
    local tailEnd, cutBy = b:tailEnd(n)
    if cutBy then
      add("choke", ("cut after %.3f beat (%.0f ms) by id %d at %s, 6 ms fade"):format((cutBy.tick - n.tick) / ppq,
        b:msOfTicks(cutBy.tick - n.tick), cutBy.id, b:bbt(cutBy.tick / ppq)))
    else
      add("choke", b.choke and "plays out: the next hit on this key comes after it ends" or "off: hits overlap")
    end
  else
    add("SAMPLE", "none mapped to this key: silent (R on its lane to map one)", RED)
  end
  local ev = b.doc:file().eventsOf[n.id]
  if ev then
    add("BYTES", ("on  #%d @0x%04X  %s"):format(ev.on.index, ev.on.offset, Midi.hex(ev.on.raw)), TEXT)
    add("", ("off #%d @0x%04X  %s"):format(ev.off.index, ev.off.offset, Midi.hex(ev.off.raw)), TEXT)
  end
  return out
end

local function stats(b, notes)
  local ppq = b.doc.ppq
  local vmin, vmax, vsum, dsum, dsq, dmax = 127, 0, 0, 0, 0, 0
  for _, n in ipairs(notes) do
    vmin, vmax, vsum = math.min(vmin, n.vel), math.max(vmax, n.vel), vsum + n.vel
    local d = b:msOfTicks(b:deviation(n.tick))
    dsum, dsq, dmax = dsum + d, dsq + d * d, math.max(dmax, math.abs(d))
  end
  local c = math.max(1, #notes)
  local mean = dsum / c
  return { vmin = vmin, vmax = vmax, vmean = vsum / c, dmean = mean, dsd = math.sqrt(math.max(0, dsq / c - mean * mean)), dmax = dmax }
end

local function selectionLines(b, list)
  local out = {}
  local function add(label, text, c) out[#out + 1] = { label, text, c } end
  local keys, seen = {}, {}
  for _, n in ipairs(list) do
    if not seen[n.key] then seen[n.key] = true; keys[#keys + 1] = n.key end
  end
  table.sort(keys)
  local st = stats(b, list)
  add("SELECTION", ("%d notes · keys %s"):format(#list, table.concat(keys, " ")), TEXT)
  add("span", ("tick %d - %d · bar %s - %s"):format(list[1].tick, list[#list].tick, b:bbt(list[1].tick / b.doc.ppq), b:bbt(list[#list].tick / b.doc.ppq)))
  add("velocity", ("%d - %d · mean %.1f"):format(st.vmin, st.vmax, st.vmean))
  add("vs grid", ("%s: mean %+.1f ms · spread %.1f ms · worst %.1f ms"):format(b:gridName(), st.dmean, st.dsd, st.dmax))
  return out, list
end

local function fileLines(b)
  local out = {}
  local function add(label, text, c) out[#out + 1] = { label, text, c } end
  local file = b.doc:file()
  local counts, metas = {}, {}
  for _, e in ipairs(file.events) do
    counts[e.kind] = (counts[e.kind] or 0) + 1
    if e.kind == "meta" then metas[#metas + 1] = Midi.describe(e):match("^[^ ]+ ?[^ ]*") end
  end
  local running, zeroOff = 0, 0
  for _, e in ipairs(file.events) do
    if e.running then running = running + 1 end
    if e.zeroVelocityOff then zeroOff = zeroOff + 1 end
  end
  add("FILE", b.midiPath, TEXT)
  local ch = {}
  for _, c in ipairs(file.chunks) do ch[#ch + 1] = ("%s @0x%04X %d B"):format(c.id, c.offset, c.size) end
  add("chunks", table.concat(ch, " · "))
  add("events", ("%d: note on %d · note off %d · meta %d"):format(#file.events, counts.note_on or 0, counts.note_off or 0, counts.meta or 0))
  add("encoding", ("running status %d · note-off as %s"):format(running, zeroOff > 0 and "note-on vel 0" or "0x80"))
  add("tempo", b.midi.hasTempo and ("%g BPM in the file"):format(b.midi.bpm)
    or ("none (Ableton clip export) -> %g BPM from songs/%s.lua"):format(b.bpm, b.songName))
  local perKey = {}
  for _, lane in ipairs(b.lanes) do
    local c = 0
    for _, n in ipairs(b.doc.notes) do if n.key == lane.key then c = c + 1 end end
    local s = b:sampleFor(lane.key)
    perKey[#perKey + 1] = ("%d x%d -> %s"):format(lane.key, c, s and ("#" .. s.n) or "none")
  end
  add("KEYS", table.concat(perKey, " · "), TEXT)
  local inWin = 0
  for _, n in ipairs(b.doc.notes) do
    local beat = n.tick / b.doc.ppq
    if beat >= b.from and beat < b.to then inWin = inWin + 1 end
  end
  add("window", ("%d notes inside, %d outside (not heard in the loop)"):format(inWin, #b.doc.notes - inWin))
  local st = stats(b, b.doc.notes)
  add("velocity", ("%d - %d · mean %.1f"):format(st.vmin, st.vmax, st.vmean))
  add("vs grid", ("%s: mean %+.1f ms · spread %.1f ms · worst %.1f ms"):format(b:gridName(), st.dmean, st.dsd, st.dmax))
  return out, b.doc.notes
end

-- where notes land against the grid: one bar per millisecond bucket
local function histogram(b, notes, x, y, w, h)
  local half = b:msOfTicks(b:gridTicks()) / 2
  local bins = 41
  local counts, peak = {}, 1
  for i = 1, bins do counts[i] = 0 end
  for _, n in ipairs(notes) do
    local ms = b:msOfTicks(b:deviation(n.tick))
    local i = math.floor((ms + half) / (2 * half) * (bins - 1) + 0.5) + 1
    i = math.max(1, math.min(bins, i))
    counts[i] = counts[i] + 1
    peak = math.max(peak, counts[i])
  end
  local bw = w / bins
  color(LINE)
  love.graphics.rectangle("fill", x, y + h, w, 1)
  love.graphics.rectangle("fill", x + w / 2, y, 1, h)
  for i = 1, bins do
    if counts[i] > 0 then
      color(ACC, 0.85)
      local bh = h * counts[i] / peak
      love.graphics.rectangle("fill", x + (i - 1) * bw + 1, y + h - bh, bw - 2, bh)
    end
  end
  love.graphics.setFont(fonts.small)
  color(DIM)
  love.graphics.print(("-%.0f ms"):format(half), x, y + h + 3)
  love.graphics.printf(("on the %s grid"):format(b:gridName()), x, y + h + 3, w, "center")
  love.graphics.printf(("+%.0f ms"):format(half), x, y + h + 3, w, "right")
end

local function drawInspector(b)
  local r = b.L.inspector
  local sel = b:selectedList()
  local lines, group
  if #sel == 1 then
    lines = noteLines(b, sel[1])
  elseif #sel > 1 then
    lines, group = selectionLines(b, sel)
  elseif b.hoverNote then
    lines = noteLines(b, b.hoverNote)
  else
    lines, group = fileLines(b)
  end
  love.graphics.setFont(fonts.body)
  local y = r.y
  for _, l in ipairs(lines) do
    if y + ROW > r.y + r.h then break end
    local label, text, c = l[1], l[2], l[3]
    local heading = label ~= "" and label:upper() == label
    if heading and y > r.y then y = y + 5 end
    color(heading and ACC or DIM)
    love.graphics.print(label, r.x, y)
    color(c or TEXT, c and 1 or 0.9)
    love.graphics.print(clip(text, fonts.body, r.w - 96), r.x + 96, y)
    y = y + ROW + 1
  end
  if group and y + 70 < r.y + r.h then
    histogram(b, group, r.x + 96, y + 10, math.min(360, r.w - 110), 46)
  end
end

------------------------------------------------------------------------
-- events
------------------------------------------------------------------------

local EV_ROW = 15

local function eventRows(b)
  local file = b.doc:file()
  local bytes = b.doc:bytes()
  local rows = {
    { head = true, text = ("MThd @0x0000  %s  format %d · %d track · %d ppq"):format(Midi.hex(bytes:sub(1, 14)), file.format, file.trackCount, file.ppq) },
    { head = true, text = ("MTrk @0x000E  %s  %d bytes of events"):format(Midi.hex(bytes:sub(15, 22)), #bytes - 22) },
  }
  for _, e in ipairs(file.events) do rows[#rows + 1] = { ev = e } end
  return rows
end

function View.eventAt(b, x, y)
  local r = b.L and b.L.events
  if not r or x < r.x or x >= r.x + r.w then return nil end
  local top = r.y + 38
  if y < top or y >= r.y + r.h then return nil end
  local i = math.floor((y - top) / EV_ROW) + 1 + math.floor(b.eventScroll)
  local rows = eventRows(b)
  return rows[i] and rows[i].ev
end

local function drawEvents(b)
  local r = b.L.events
  local file = b.doc:file()
  local rows = eventRows(b)
  love.graphics.setFont(fonts.body)
  color(ACC)
  love.graphics.print("EVENTS", r.x, r.y)
  color(DIM)
  local orig = b.midi.size
  love.graphics.print(("  what Ctrl+S writes · %d events · %d bytes%s"):format(#file.events, #b.doc:bytes(),
    #b.doc:bytes() ~= orig and (" (file on disk: %d)"):format(orig) or ""), r.x + fonts.body:getWidth("EVENTS"), r.y)
  love.graphics.setFont(fonts.small)
  local cw = fonts.small:getWidth("0")
  local COL = { idx = 0, off = 5, delta = 13, tick = 20, bbt = 27, hex = 37, desc = 50 }
  local function at(col) return r.x + COL[col] * cw end
  color(FAINT)
  love.graphics.print("   #", at("idx"), r.y + 20)
  love.graphics.print("offset", at("off"), r.y + 20)
  love.graphics.print("delta", at("delta"), r.y + 20)
  love.graphics.print(" tick", at("tick"), r.y + 20)
  love.graphics.print("bar", at("bbt"), r.y + 20)
  love.graphics.print("bytes", at("hex"), r.y + 20)
  love.graphics.print("event", at("desc"), r.y + 20)

  -- keep the first selected note's events in view when the selection changes
  local selKey = ""
  local firstSel
  for i, row in ipairs(rows) do
    if row.ev and row.ev.noteId and b.sel[row.ev.noteId] then
      firstSel = firstSel or i
      selKey = selKey .. row.ev.noteId .. ","
    end
  end
  local visible = math.floor((r.h - 38) / EV_ROW)
  if selKey ~= b.lastSelKey then
    b.lastSelKey = selKey
    if firstSel and (firstSel - 1 < b.eventScroll or firstSel > b.eventScroll + visible) then
      b.eventScroll = math.max(0, firstSel - 4)
    end
  end
  b.eventScroll = math.max(0, math.min(b.eventScroll, #rows - visible))

  local top = r.y + 38
  love.graphics.setScissor(r.x, top, r.w, r.h - 38)
  for i = math.floor(b.eventScroll) + 1, math.min(#rows, math.floor(b.eventScroll) + visible + 1) do
    local row = rows[i]
    local y = top + (i - 1 - math.floor(b.eventScroll)) * EV_ROW
    if row.head then
      color(DIM)
      love.graphics.print(row.text, r.x, y)
    else
      local e = row.ev
      local isSel = e.noteId and b.sel[e.noteId]
      local isHover = (b.hoverNote and e.noteId == b.hoverNote.id) or b.hoverEvent == e
      if isSel or isHover then
        color(isSel and ACC or TEXT, isSel and 0.14 or 0.06)
        love.graphics.rectangle("fill", r.x - 4, y, r.w + 4, EV_ROW)
      end
      local isNote = e.kind == "note_on" or e.kind == "note_off"
      local c = isNote and sampleColor(b, e.key) or TEXT
      color(isSel and ACC or DIM)
      love.graphics.print(("%4d"):format(e.index), at("idx"), y)
      love.graphics.print(("0x%04X"):format(e.offset), at("off"), y)
      love.graphics.print(("%5d"):format(e.delta), at("delta"), y)
      love.graphics.print(("%5d"):format(e.tick), at("tick"), y)
      love.graphics.print(b:bbt(e.tick / b.doc.ppq), at("bbt"), y)
      color(isSel and ACC or FAINT)
      love.graphics.print(clip(Midi.hex(e.raw), fonts.small, 12 * cw), at("hex"), y)
      color(c, e.kind == "note_off" and 0.6 or 1)
      love.graphics.print(clip(Midi.describe(e), fonts.small, r.x + r.w - at("desc")), at("desc"), y)
    end
  end
  love.graphics.setScissor()
end

------------------------------------------------------------------------
-- tools
------------------------------------------------------------------------

local function drawTools(b)
  local r = b.L.tools
  color(PANEL)
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h)
  local x, y = r.x + 14, 10
  love.graphics.setFont(fonts.small)
  for _, cmd in ipairs(b.COMMANDS) do
    if cmd.group then
      y = y + (y > 10 and 8 or 0)
      color(ACC)
      love.graphics.print(cmd.group, x, y)
      y = y + ROW
    elseif not cmd.hidden then
      color(cmd.mouse and DIM or TEXT)
      love.graphics.print(cmd.label or cmd.mouse, x, y)
      color(DIM)
      love.graphics.print(clip(cmd.desc, fonts.small, r.w - 28 - 138), x + 138, y)
      y = y + ROW - 1
    end
  end
  if b.status and love.timer.getTime() - b.status.t < 6 then
    color(ACC)
    love.graphics.printf(b.status.text, x, r.h - 44, r.w - 28)
  end
end

------------------------------------------------------------------------

function View.draw(b)
  loadFonts()
  local L = b.L
  if not L then return end
  local playBeat = b.transport:beat()

  drawHeader(b, playBeat or b.playhead)
  drawRuler(b)
  drawBacking(b)
  drawLanes(b, playBeat)
  drawVelocity(b)
  drawOutput(b)

  -- playhead across every strip
  local px = b:xOfBeat(playBeat or b.playhead)
  if px >= L.tlX and px <= L.tlX + L.tlW then
    color(ACC, playBeat and 0.9 or 0.45)
    love.graphics.rectangle("fill", math.floor(px), L.ruler.y, 1, L.out.y + L.out.h - L.ruler.y)
  end

  if b.drag and b.drag.kind == "box" then
    local d = b.drag
    color(ACC, 0.1)
    love.graphics.rectangle("fill", math.min(d.x, d.x2), math.min(d.y, d.y2), math.abs(d.x2 - d.x), math.abs(d.y2 - d.y))
    color(ACC, 0.6)
    love.graphics.rectangle("line", math.min(d.x, d.x2), math.min(d.y, d.y2), math.abs(d.x2 - d.x), math.abs(d.y2 - d.y))
  end

  color(LINE)
  love.graphics.rectangle("fill", 0, L.inspector.y - 8, L.W - SIDEBAR, 1)
  drawInspector(b)
  drawEvents(b)
  drawTools(b)
end

return View
