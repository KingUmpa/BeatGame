-- src/tools/level_view.lua
-- Draws the LEVEL editor. Top: the level's facts and which layer is being edited. Then, on
-- one time axis over the whole MIDI: the ruler with the level's bars marked, the piano roll
-- (a row per key, grouped by track) with the button boxes over it, and velocity. Below: the
-- board, lit exactly as the game's demo will light it, and the inspector. Right: every tool.
-- Round boxes (over the buttons) show strongly in the ROUNDS layer and faintly in the others;
-- there every button carries the number of the round that adds it.
--
-- With a song open the roll is a lane per level, one above the other, each with a header
-- (its VO line, metronome, mute) and its own keys, all on one axis from each level's first
-- beat. The lane being edited is lit; the others are dimmer, and a click on one edits it.
-- A level shorter than the song repeats out to the song's length, drawn hollow.
--
-- Layout and every clickable area are worked out here, once per drawn frame, so a click
-- always lands on what is on screen.

local utf8 = require("utf8")
local util = require("src.util")
local Level = require("src.game.level")
local Lights = require("src.game.lights")
local Midi = require("src.midi")
local Pads = require("src.render.pads")
local Screen = require("src.render.screen")
local Round = require("src.game.round")

local View = {}

local BG = { 0.047, 0.051, 0.059 }
local PANEL = { 0.072, 0.077, 0.088 }
local LINE = { 0.15, 0.16, 0.18 }
local TEXT = { 0.84, 0.86, 0.9 }
local DIM = { 0.47, 0.49, 0.54 }
local FAINT = { 0.27, 0.29, 0.32 }
local ACC = { 0.92, 0.73, 0.42 }
local RED = { 0.95, 0.35, 0.3 }
local FREE = { 0.58, 0.6, 0.66 }
local ROUND = { 0.85, 0.88, 1.0 }   -- round boxes
local SIDEBAR = 392
local LANE_HEAD, LANE_GAP, TRACK_HEAD = 24, 4, 18
local L_TITLE_W = 210   -- where a lane header's switches start

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
  fonts.small, fonts.body, fonts.big, fonts.title = make(12), make(14), make(17), make(22)
  love.graphics.setBackgroundColor(BG)
end

local function clipLeft(text, font, w)
  if font:getWidth(text) <= w then return text end
  while #text > 1 and font:getWidth(".." .. text) > w do text = text:sub((utf8.offset(text, 2) or 2)) end
  return ".." .. text
end

------------------------------------------------------------------------
-- layout
------------------------------------------------------------------------

-- every box in a lane (its buttons, or its rounds): its time across, its key range down
-- (inside its own track), grown by `pad` pixels
local function boxRects(e, lane, L, list, pad)
  local lv = lane.lv
  local off = e:offset(lv)
  local function X(tick) return L.tlX + (tick / lv.ppq - off - e.view.beat0) * e.view.ppb end
  local out = {}
  for _, b in ipairs(list) do
    local y0, y1
    for i, r in ipairs(lane.rows) do
      if r.track == b.track and r.key >= b.keyLow and r.key <= b.keyHigh then
        local rr = lane.rowRects[i]
        y0 = math.min(y0 or rr.y, rr.y)
        y1 = math.max(y1 or 0, rr.y + rr.h)
      end
    end
    if not y0 then
      -- no row in its key range: span its whole track
      for i, r in ipairs(lane.rows) do
        if r.track == b.track then
          local rr = lane.rowRects[i]
          y0 = math.min(y0 or rr.y, rr.y)
          y1 = math.max(y1 or 0, rr.y + rr.h)
        end
      end
    end
    if y0 then
      local x0 = X(b.start)
      local x1 = math.max(X(b["end"]), x0 + 8)
      out[#out + 1] = { x = x0 - 2 - pad, y = y0 + 2 - pad, w = x1 - x0 + 4 + 2 * pad, h = y1 - y0 - 4 + 2 * pad, button = b }
    end
  end
  return out
end

function View.layout(e, W, H)
  local L = { W = W, H = H, clickables = {}, sliders = {} }
  local MW = W - SIDEBAR
  L.MW = MW
  L.tools = { x = MW, y = 0, w = SIDEBAR, h = H }
  if not e.lv then return L end
  L.tlX = 210
  L.tlW = MW - L.tlX - 16
  L.header = { x = 0, y = 0, w = MW, h = 56 }
  local y = 58
  L.ruler = { x = L.tlX, y = y, w = L.tlW, h = 26 }; y = y + 30

  -- the roll: a lane per level (one, unless a song is open), a row per key, a thin header per
  -- track (in a song, the lane header stands in for a lone track's)
  local bottomH = math.min(330, math.floor(H * 0.36))
  local avail = H - y - 44 - 26 - bottomH
  local lanes, heads, nRows = {}, 0, 0
  for i, ln in ipairs(e.lanes) do
    local rows = i == e.lane and e.rows or Level.rows(ln.lv)
    if #rows == 0 then rows = { { track = 1, key = 60 } } end
    local tracks, last = 0, nil
    for _, r in ipairs(rows) do if r.track ~= last then tracks, last = tracks + 1, r.track end end
    local trackHeads = not (e.song and tracks == 1)
    lanes[i] = { index = i, lv = ln.lv, lane = ln, rows = rows, active = i == e.lane, trackHeads = trackHeads }
    heads = heads + (trackHeads and tracks * TRACK_HEAD or 0) + (e.song and LANE_HEAD + LANE_GAP or 0)
    nRows = nRows + #rows
  end
  local rowH = math.max(12, math.min(52, math.floor((avail - heads) / nRows)))
  L.rowH = rowH
  local rollTop = y
  for _, lane in ipairs(lanes) do
    local laneTop = y
    if e.song then
      lane.head = { x = 0, y = y, w = L.tlX + L.tlW, h = LANE_HEAD }
      y = y + LANE_HEAD
    end
    lane.rowRects, lane.trackHeaders, lane.rowOf = {}, {}, {}
    local top, lastTrack = y, nil
    for k, r in ipairs(lane.rows) do
      if r.track ~= lastTrack then
        if lane.trackHeads then
          lane.trackHeaders[#lane.trackHeaders + 1] = { track = r.track, y = y }
          y = y + TRACK_HEAD
        end
        lastTrack = r.track
      end
      lane.rowRects[k] = { x = L.tlX, y = y, w = L.tlW, h = rowH }
      lane.rowOf[r.track * 1000 + r.key] = k
      y = y + rowH
    end
    lane.roll = { x = L.tlX, y = top, w = L.tlW, h = y - top }
    lane.rect = { x = 0, y = laneTop, w = L.tlX + L.tlW, h = y - laneTop }
    lane.buttonRects = boxRects(e, lane, L, lane.lv.buttons, 0)
    lane.roundRects = boxRects(e, lane, L, lane.lv.rounds, 2)
    if lane.active then
      L.rowRects, L.trackHeaders, L.roll = lane.rowRects, lane.trackHeaders, lane.roll
      L.rowLabels = { x = 0, y = top, w = L.tlX, h = y - top }
      L.buttonRects, L.roundRects = lane.buttonRects, lane.roundRects
    end
    if e.song then y = y + LANE_GAP end
  end
  L.lanes = lanes
  L.rolls = { x = L.tlX, y = rollTop, w = L.tlW, h = y - rollTop }
  y = y + 6
  L.vel = { x = L.tlX, y = y, w = L.tlW, h = 40 }; y = y + 40 + 18
  local bh = H - y - 12
  local size = math.min(bh - 16, 300)
  L.preview = { x = 16, y = y, w = size, h = size }
  L.inspector = { x = 16 + size + 28, y = y, w = MW - size - 60, h = bh }

  return L
end

------------------------------------------------------------------------
-- the open screen
------------------------------------------------------------------------

local function drawOpen(e)
  local L = e.L
  L.openItems = {}
  local x, y = 40, 36
  love.graphics.setFont(fonts.title)
  color(TEXT)
  love.graphics.print("LEVEL editor", x, y)
  love.graphics.setFont(fonts.body)
  color(DIM)
  love.graphics.print("Open a song to see all its levels at once, a level to carry on with it, or a MIDI file to start a new one. You can also drop any of them onto this window.", x, y + 34)
  local colW = (L.MW - 160) / 3
  local function list(title, items, cx)
    local cy = y + 90
    love.graphics.setFont(fonts.big)
    color(ACC)
    love.graphics.print(title, cx, cy)
    cy = cy + 32
    love.graphics.setFont(fonts.body)
    if #items == 0 then
      color(DIM)
      love.graphics.print("none found", cx, cy)
    end
    for _, it in ipairs(items) do
      local r = { x = cx - 8, y = cy - 4, w = colW, h = 40 }
      local mx, my = love.mouse.getPosition()
      local hot = mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h
      color(hot and { 0.16, 0.18, 0.24 } or PANEL)
      love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, 4, 4)
      color(TEXT)
      love.graphics.print(it.title, cx, cy)
      love.graphics.setFont(fonts.small)
      color(DIM)
      love.graphics.print(it.sub, cx, cy + 18)
      love.graphics.setFont(fonts.body)
      L.openItems[#L.openItems + 1] = { rect = r, path = it.path }
      cy = cy + 46
    end
  end
  local songs, levels, midis = {}, {}, {}
  for _, s in ipairs(e.files.songs) do
    songs[#songs + 1] = { title = s.name, sub = s.err and tostring(s.err) or ("%s · %s"):format(s.path, s.levels), path = s.path }
  end
  for _, l in ipairs(e.files.levels) do
    levels[#levels + 1] = { title = l.name, sub = l.err and tostring(l.err) or ("%s · %d buttons"):format(l.path, l.buttons), path = l.path }
  end
  for _, p in ipairs(e.files.midis) do midis[#midis + 1] = { title = p:match("[^/]+$"), sub = p, path = p } end
  list("SONGS", songs, x)
  list("CONTINUE A LEVEL", levels, x + colW + 40)
  list("START FROM A MIDI FILE", midis, x + 2 * (colW + 40))
  if e.status and love.timer.getTime() - e.status.t < 8 then
    love.graphics.setFont(fonts.body)
    color(ACC)
    love.graphics.printf(e.status.text, x, L.H - 40, L.MW - 80)
  end
end

------------------------------------------------------------------------
-- timeline
------------------------------------------------------------------------

local function gridLines(e, y, h)
  local L = e.L
  local g = e:gridTicks() / e.lv.ppq
  while g * e.view.ppb < 7 do g = g * 2 end
  local beat = math.floor(e:beatOfX(L.tlX) / g) * g
  local last = e:beatOfX(L.tlX + L.tlW)
  while beat <= last do
    local x = e:xOfBeat(beat)
    if x >= L.tlX then
      local bar = math.abs(beat / 4 - math.floor(beat / 4 + 0.5)) < 1e-6
      local whole = math.abs(beat - math.floor(beat + 0.5)) < 1e-6
      color(LINE, bar and 1 or whole and 0.55 or 0.25)
      love.graphics.rectangle("fill", math.floor(x), y, 1, h)
    end
    beat = beat + g
  end
end

local function drawRuler(e)
  local r, lv = e.L.ruler, e.lv
  color(PANEL)
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h)
  love.graphics.setScissor(r.x, r.y, r.w, r.h)
  -- the level's bars: a band to drag, its right edge sets the length
  local a0, a1 = e:windowAxis()
  local wx0, wx1 = e:xOfBeat(a0), e:xOfBeat(a1)
  if e.song then
    -- the song loops at its longest level
    local sx = e:xOfBeat(e:loopBeats())
    color(TEXT, 0.35)
    love.graphics.rectangle("fill", sx - 1, r.y, 2, r.h)
  end
  color(ACC, 0.22)
  love.graphics.rectangle("fill", wx0, r.y, wx1 - wx0, 12)
  color(ACC, 0.08)
  love.graphics.rectangle("fill", wx0, r.y + 12, wx1 - wx0, r.h - 12)
  color(ACC)
  love.graphics.rectangle("fill", wx1 - 2, r.y, 3, r.h)
  love.graphics.setFont(fonts.small)
  local barPx = e.view.ppb * 4
  local step = barPx >= 36 and 1 or barPx >= 12 and 4 or 16
  for bar = 0, math.ceil(e:beatOfX(r.x + r.w) / 4) do
    local x = e:xOfBeat(bar * 4)
    if x >= r.x - 1 and x < r.x + r.w and bar % step == 0 then
      color(FAINT)
      love.graphics.rectangle("fill", x, r.y + 14, 1, 12)
      color(DIM)
      love.graphics.print(tostring(bar + 1), x + 4, r.y + 13)
    end
  end
  love.graphics.setScissor()
  color(DIM)
  if e.song then
    love.graphics.print(("song bars   grid %s"):format(e:gridName()), 16, r.y + 6)
  else
    love.graphics.print(("level: bars %d-%d   grid %s"):format(lv.start_beat / 4 + 1, lv.start_beat / 4 + lv.bars, e:gridName()), 16, r.y + 6)
  end
end

-- the key a note plays through: its button's color, or grey when no button plays it
local function noteColor(e, n, owner)
  local b = owner[n.id]
  return b and Level.buttonColor(e.lv, b) or FREE
end

-- a small clickable label in a lane or the header: returns its right edge
local function chip(e, x, y, text, on, fn, c)
  love.graphics.setFont(fonts.small)
  local w = fonts.small:getWidth(text) + 14
  local r = { x = x, y = y, w = w, h = 18 }
  local mx, my = love.mouse.getPosition()
  local hot = mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h
  color(on and (c or ACC) or (hot and { 0.2, 0.22, 0.3 } or LINE))
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, 3, 3)
  if not on then
    color(FAINT)
    love.graphics.rectangle("line", r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1, 3, 3)
  end
  color(on and BG or (hot and TEXT or DIM))
  love.graphics.print(text, r.x + 7, r.y + 3)
  if fn then e.L.clickables[#e.L.clickables + 1] = { rect = r, fn = fn } end
  return x + w + 6
end

-- a song lane's header: which level, what it plays over, and its switches
local function drawLaneHead(e, lane)
  local h, lv, i = lane.head, lane.lv, lane.index
  local part = e.song.parts[i]
  color(lane.active and { 0.17, 0.15, 0.11 } or { 0.11, 0.115, 0.13 })
  love.graphics.rectangle("fill", h.x, h.y, h.w, h.h)
  if lane.active then
    color(ACC)
    love.graphics.rectangle("fill", h.x, h.y, 4, h.h)
  end
  love.graphics.setFont(fonts.body)
  color(lane.active and ACC or TEXT, lane.lane.muted and 0.5 or 1)
  local title = ("LEVEL %d  %s"):format(i, lv.name:upper())
  love.graphics.print(title, 14, h.y + 4)
  local x = math.max(L_TITLE_W, 14 + fonts.body:getWidth(title) + 16)
  local y = h.y + 3
  x = chip(e, x, y, "VO " .. (part.vo and util.basename(part.vo) or "none"), false, function() e:cycleVo(i) end)
  x = chip(e, x, y, "metronome " .. (lv.metronome or "juice"), lv.metronome == "always", function()
    if e.lane ~= i then e:activate(i) end
    e:cycleMetronome()
  end)
  x = chip(e, x, y, lane.lane.muted and "MUTED" or "mute", lane.lane.muted, function() e:toggleMute(i) end, RED)
  local prep = Level.prepare(lv)
  love.graphics.setFont(fonts.small)
  color(DIM)
  local rounds = Round.count(prep, e.J)
  local info = ("%d bar%s from bar %d of %s  ·  %d buttons, %d round%s%s%s"):format(lv.bars, lv.bars == 1 and "" or "s",
    lv.start_beat / 4 + 1, util.basename(lv.source or lv.midi), #prep.buttons, rounds, rounds == 1 and "" or "s",
    lv.exclusive and "  ·  exclusive" or "", e:laneDirty(lane.lane) and "  ·  unsaved" or "")
  love.graphics.print(info, x + 6, y + 3)
end

-- one lane: its rows, the notes (in a song, the loop again out to the song's length, hollow),
-- the button boxes, and the key names. owner/clash/shadow are the edited lane's (View.draw).
local function drawLane(e, lane, playBeat, owner, clash, shadow)
  local L, lv = e.L, lane.lv
  local active = lane.active
  if not active then
    owner = Level.membership(lv)
    clash, shadow = {}, {}
  end
  local fade = active and 1 or 0.55
  local r = lane.roll
  love.graphics.setScissor(r.x, r.y, r.w, r.h)
  for k, rr in ipairs(lane.rowRects) do
    color(PANEL, k % 2 == 0 and 0.75 or 1)
    love.graphics.rectangle("fill", rr.x, rr.y, rr.w, rr.h)
    if active and e.hoverRow == k then
      color(TEXT, 0.03)
      love.graphics.rectangle("fill", rr.x, rr.y, rr.w, rr.h)
    end
  end
  gridLines(e, r.y, r.h)
  -- outside the level's bars: dimmed
  local a0, a1 = e:windowAxis(lv)
  local wx0, wx1 = e:xOfBeat(a0), e:xOfBeat(a1)
  color(BG, 0.6)
  love.graphics.rectangle("fill", r.x, r.y, math.max(0, wx0 - r.x), r.h)
  love.graphics.rectangle("fill", wx1, r.y, math.max(0, r.x + r.w - wx1), r.h)

  local lights = e.mode == "lights"
  local Lb = Level.beats(lv)
  local wa, wz = Level.window(lv)
  -- the beat this lane is at: in a song each lane loops its own length
  local pb = playBeat
  if pb and e.song then pb = a0 + (pb - a0) % Lb end
  local off = e:offset(lv)
  local reps = e.song and math.ceil(e:loopBeats() / Lb) - 1 or 0

  -- notes (another lane: only the ones in its level)
  for _, n in ipairs(lv.notes) do
    local k = lane.rowOf[n.track * 1000 + n.key]
    local rr = k and lane.rowRects[k]
    local inWindow = n.tick >= wa and n.tick < wz
    if rr and (active or inWindow) then
      local x0 = e:xOfTick(n.tick, lv)
      local x1 = math.max(e:xOfTick(n.tick + n.len, lv), x0 + 3)
      local c = noteColor(e, n, owner)
      local beat = n.tick / lv.ppq - off
      local lit = pb and inWindow and pb >= beat and pb < beat + n.len / lv.ppq
      color(c, (0.3 + 0.7 * n.vel / 127) * (lights and 0.55 or 0.9) * fade)
      love.graphics.rectangle("fill", x0, rr.y + 4, x1 - x0, rr.h - 8, 2, 2)
      if lit then
        color({ 1, 1, 1 }, 0.7)
        love.graphics.rectangle("fill", x0, rr.y + 4, x1 - x0, rr.h - 8, 2, 2)
      end
      if active and clash[n.id] then
        color(RED)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", x0 - 1, rr.y + 3, x1 - x0 + 2, rr.h - 6, 2, 2)
      elseif active and not lights and e.sel[n.id] then
        color(ACC)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", x0 - 1, rr.y + 3, x1 - x0 + 2, rr.h - 6, 2, 2)
      elseif active and not lights and e.hoverNote == n then
        color(TEXT, 0.8)
        love.graphics.setLineWidth(1)
        love.graphics.rectangle("line", x0 - 0.5, rr.y + 3.5, x1 - x0 + 1, rr.h - 7, 2, 2)
      end
      if inWindow and reps > 0 then
        love.graphics.setLineWidth(1)
        color(c, 0.45 * fade)
        for rep = 1, reps do
          local dx = rep * Lb * e.view.ppb
          love.graphics.rectangle("line", x0 + dx + 0.5, rr.y + 4.5, x1 - x0 - 1, rr.h - 9, 2, 2)
        end
      end
    end
  end

  -- the rounds: boxes over the buttons they add (strong in the ROUNDS layer, faint elsewhere)
  local rounds = e.mode == "rounds"
  for _, rr in ipairs(lane.roundRects) do
    local r = rr.button
    local sel = active and rounds and e.selR[r.id]
    local hot = active and rounds and e.hoverRound == r
    color(ROUND, (rounds and 0.08 or 0.025) * fade)
    love.graphics.rectangle("fill", rr.x, rr.y, rr.w, rr.h, 7, 7)
    color(sel and ACC or ROUND, (rounds and (sel and 1 or 0.8) or 0.22) * fade)
    love.graphics.setLineWidth(sel and 3 or (hot and 2.5 or (rounds and 2 or 1)))
    love.graphics.rectangle("line", rr.x, rr.y, rr.w, rr.h, 7, 7)
  end

  -- the buttons: boxes over the notes they play. In the ROUNDS layer each one carries the
  -- number of the round that adds it (red: it's inside two round boxes)
  local stepOf, roundClash = {}, {}
  if rounds then
    for i, s in ipairs(Level.prepare(lv).steps) do
      for _, pb in ipairs(s.buttons) do stepOf[pb.source] = i end
    end
    local _, rc = Level.roundMembership(lv)
    roundClash = rc
  end
  love.graphics.setFont(fonts.small)
  for _, br in ipairs(lane.buttonRects) do
    local b = br.button
    local c = Level.buttonColor(lv, b)
    local sel = active and lights and e.selB[b.id]
    local hot = active and lights and e.hoverButton == b
    local silent = shadow[b]   -- other boxes already play all its notes
    local strong = lights or rounds
    color(c, (strong and 0.10 or 0.05) * fade)
    love.graphics.rectangle("fill", br.x, br.y, br.w, br.h, 5, 5)
    local edge = sel and ACC or (silent and RED or ((rounds and roundClash[b]) and RED or c))
    color(edge, (strong and (sel and 1 or (rounds and 0.6 or 0.9)) or 0.35) * fade)
    love.graphics.setLineWidth(sel and 3 or ((hot or silent) and 2.5 or 1.5))
    love.graphics.rectangle("line", br.x, br.y, br.w, br.h, 5, 5)
    if strong and br.w > 14 and br.h > 14 then
      local tag
      if rounds then
        tag = stepOf[b] and ("#" .. stepOf[b]) or "-"
        color(roundClash[b] and RED or TEXT, fade)
      else
        local count = #Level.buttonNotes(lv, b)
        tag = Level.KEYS[b.pad] .. (silent and " !" or (count > 1 and (" x" .. count) or (count == 0 and " -" or "")))
        color(sel and ACC or (silent and RED or c), fade)
      end
      love.graphics.print(tag, br.x + 4, br.y + 2)
    end
  end

  -- a box being drawn
  local d = e.drag
  if active and d and d.kind == "draw" then
    local a, z = e:rowSpanInTrack(d.row, d.y2)
    local y0, y1 = L.rowRects[a].y, L.rowRects[z].y + L.rowRects[z].h
    local x0, x1 = math.min(d.x, d.x2), math.max(d.x, d.x2)
    local c = d.boxes == "rounds" and ROUND or lv.pads[e.lastPad or 1].color
    color(c, 0.10)
    love.graphics.rectangle("fill", x0, y0 + 2, x1 - x0, y1 - y0 - 4, 5, 5)
    color(c)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", x0, y0 + 2, x1 - x0, y1 - y0 - 4, 5, 5)
  elseif active and d and d.kind == "box" then
    color(ACC, 0.12)
    love.graphics.rectangle("fill", math.min(d.x, d.x2), math.min(d.y, d.y2), math.abs(d.x2 - d.x), math.abs(d.y2 - d.y))
  end
  love.graphics.setScissor()

  -- track headers and key names
  for _, th in ipairs(lane.trackHeaders) do
    color(LINE)
    love.graphics.rectangle("fill", 0, th.y, L.tlX + L.tlW, TRACK_HEAD)
    love.graphics.setFont(fonts.small)
    color(DIM)
    local name = lv.trackNames[th.track]
    love.graphics.print(("TRACK %d%s"):format(th.track, name and ("  " .. name) or ""), 14, th.y + 3)
  end
  for k, rr in ipairs(lane.rowRects) do
    local row = lane.rows[k]
    local s = Level.sound(lv, row.track, row.key)
    love.graphics.setFont(fonts.body)
    color(active and e.hoverRow == k and TEXT or { 0.74, 0.76, 0.8 }, fade)
    love.graphics.print(("%-4s %3d"):format(Midi.noteName(row.key), row.key), 14, rr.y + (rr.h >= 34 and 4 or (rr.h - 14) / 2))
    love.graphics.setFont(fonts.small)
    if rr.h >= 34 then
      color(s and FAINT or RED)
      love.graphics.print(s and clipLeft(s.sample:match("[^/]+$"), fonts.small, L.tlX - 26) or "no sound: R, or drop a .wav", 14, rr.y + 20)
    elseif s and rr.h >= 16 then
      -- a short row: the sound's name beside the key
      color(DIM, fade)
      love.graphics.print(clipLeft(s.label or s.sample:match("[^/]+$"), fonts.small, L.tlX - 104), 96, rr.y + (rr.h - 12) / 2)
    elseif not s then
      color(RED)
      love.graphics.print("no sound", 100, rr.y + (rr.h - 12) / 2)
    end
  end

  if lane.head then drawLaneHead(e, lane) end
  -- a click anywhere on another lane edits it
  if not active then
    L.clickables[#L.clickables + 1] = { rect = lane.rect, fn = function()
      e:activate(lane.index)
      e:say(("editing level %d: %s"):format(lane.index, lv.name))
    end }
  end
end

local function drawRoll(e, playBeat, owner, clash, shadow)
  for _, lane in ipairs(e.L.lanes) do drawLane(e, lane, playBeat, owner, clash, shadow) end
end

local function drawVelocity(e, owner)
  local r = e.L.vel
  color(PANEL)
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h)
  love.graphics.setScissor(r.x, r.y, r.w, r.h)
  for _, n in ipairs(e.lv.notes) do
    local x = math.floor(e:xOfTick(n.tick))
    local h = (r.h - 4) * n.vel / 127
    local sel = e.mode == "notes" and e.sel[n.id]
    color(sel and ACC or noteColor(e, n, owner), sel and 1 or 0.75)
    love.graphics.rectangle("fill", x, r.y + r.h - 1 - h, 2, h)
  end
  love.graphics.setScissor()
  love.graphics.setFont(fonts.small)
  color(DIM)
  love.graphics.print("velocity", 16, r.y + 4)
  love.graphics.print("volume + light brightness", 16, r.y + 20)
end

------------------------------------------------------------------------
-- the board, lit as the demo will light it
------------------------------------------------------------------------

local preview = {}

local function boardRect(J)
  local L = J.layout
  local m = L.frame_padding + J.lights.glow_size * 0.5
  local S = L.board_size
  return L.board_x - S / 2 - m, L.board_y - S / 2 - m, S + 2 * m
end

function View.previewPadAt(e, x, y)
  local r = e.L.preview
  local J = e.J
  local bx, by, bs = boardRect(J)
  local k = r.w / bs
  return Pads.hit(J, bx + (x - r.x) / k, by + (y - r.y) / k)
end

local function lightsFor(e, sinceStart)
  local J, lv = e.J, e.lv
  local spb = e:spb()
  local out = {}
  for i = 1, 4 do out[i] = { color = lv.pads[i].color, level = J.lights.idle_level, press = 0, punch = 0, white = 0 } end
  if sinceStart and e.prep then
    local Lb = Level.beats(lv)
    local abs = sinceStart   -- beats on the playback timeline (it starts at the play position)
    for _, b in ipairs(e.prep.buttons) do
      for _, rep in ipairs({ 0, -1 }) do
        local start = (math.floor(abs / Lb) + rep) * Lb + b.beat
        local dt = (abs - start) * spb
        if dt >= 0 and start >= e.playFrom - 1e-6 then
          local lvl, c = Lights.button(J, b, dt, spb)
          if lvl > out[b.pad].level then out[b.pad].level, out[b.pad].color = lvl, c end
        end
      end
    end
  end
  -- a clicked pad lights the way a press does in the game: like the demo
  for _, f in ipairs(e.flashes) do
    local dt = e.time - f.at
    out[f.pad].press = math.max(out[f.pad].press, math.max(0, 1 - dt / 0.15))
    local lvl = Lights.envelope(dt, J.lights.attack_s, J.lights.hold_s, J.lights.decay_s) * J.lights.demo_level
    if lvl > out[f.pad].level then out[f.pad].level, out[f.pad].color = lvl, lv.pads[f.pad].color end
  end
  return out
end

local function drawPreview(e, sinceStart)
  local r, J = e.L.preview, e.J
  local W, H = J.display.virtual_width, J.display.virtual_height
  if not preview.screen or preview.screen.W ~= W or preview.screen.H ~= H then preview.screen = Screen.new(W, H) end
  local s = preview.screen
  s:begin(J.layout.background)
  Pads.draw(J, { pads = lightsFor(e, sinceStart) })
  love.graphics.setCanvas()
  love.graphics.pop()
  local bx, by, bs = boardRect(J)
  preview.quad = preview.quad or love.graphics.newQuad(0, 0, 1, 1, W, H)
  preview.quad:setViewport(bx, by, bs, bs, W, H)
  love.graphics.setColor(1, 1, 1)
  love.graphics.setBlendMode("alpha", "premultiplied")
  love.graphics.draw(s.canvas, preview.quad, r.x, r.y, 0, r.w / bs, r.h / bs)
  love.graphics.setBlendMode("alpha")
  love.graphics.setFont(fonts.small)
  color(DIM)
  love.graphics.print(e.mode == "lights" and next(e.selB) and "click a pad: put the selected buttons on it" or "click a pad to hear it / edit its color",
    r.x, r.y + r.h + 2)
end

------------------------------------------------------------------------
-- inspector
------------------------------------------------------------------------

local function sliderRow(e, label, value, x, y, w, set, c)
  local rect = { x = x + 18, y = y + 4, w = w - 130, h = 10 }
  love.graphics.setFont(fonts.small)
  color(DIM)
  love.graphics.print(label, x, y)
  color(LINE)
  love.graphics.rectangle("fill", rect.x, rect.y, rect.w, rect.h, 5, 5)
  color(c)
  love.graphics.rectangle("fill", rect.x, rect.y, math.max(rect.h, rect.w * value), rect.h, 5, 5)
  love.graphics.setColor(1, 1, 1)
  love.graphics.circle("fill", rect.x + rect.w * value, rect.y + rect.h / 2, 7)
  color(TEXT)
  love.graphics.print(("%.2f"):format(value), rect.x + rect.w + 10, y)
  e.L.sliders[#e.L.sliders + 1] = { rect = { x = rect.x - 6, y = rect.y - 6, w = rect.w + 12, h = rect.h + 12 }, set = set, label = label }
end

local function colorSliders(e, x, y, w, get, apply, label)
  local base = get()
  for i, name in ipairs({ "R", "G", "B" }) do
    local cc = { 0.25, 0.25, 0.25 }
    cc[i] = 0.95
    sliderRow(e, name, base[i], x, y, w, function(v)
      local c = get()
      c = { c[1], c[2], c[3] }
      c[i] = math.floor(v * 100 + 0.5) / 100
      apply(c)
    end, cc)
    y = y + 20
  end
  color(base)
  love.graphics.rectangle("fill", x + w - 52, y - 64, 52, 56, 4, 4)
  love.graphics.setFont(fonts.small)
  color(DIM)
  love.graphics.print(label, x, y + 2)
  return y + 22
end

local function lines(x, y, rows)
  for _, r in ipairs(rows) do
    love.graphics.setFont(r.big and fonts.big or fonts.body)
    if r.label then
      color(DIM)
      love.graphics.print(r.label, x, y)
      color(r.c or TEXT)
      love.graphics.print(r.text, x + 110, y)
    else
      color(r.head and ACC or (r.c or TEXT))
      love.graphics.print(r.text, x, y)
    end
    y = y + (r.big and 24 or 18)
  end
  return y
end

-- a value you click to change
local function clickField(e, x, y, label, text, fn)
  love.graphics.setFont(fonts.body)
  color(DIM)
  love.graphics.print(label, x, y)
  local w = fonts.body:getWidth(text) + 16
  local r = { x = x + 108, y = y - 2, w = w, h = 20 }
  local mx, my = love.mouse.getPosition()
  local hot = mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h
  color(hot and { 0.2, 0.22, 0.3 } or LINE)
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, 3, 3)
  color(TEXT)
  love.graphics.print(text, r.x + 8, r.y + 2)
  e.L.clickables[#e.L.clickables + 1] = { rect = r, fn = fn }
  return y + 22
end

-- four small pads in a 2x2: the current one lit; click to choose
local function padPicker(e, x, y, current, fn)
  local s = 34
  for pad = 1, 4 do
    local px = x + ((pad - 1) % 2) * (s + 6)
    local py = y + math.floor((pad - 1) / 2) * (s + 6)
    local c = e.lv.pads[pad].color
    color(c, pad == current and 0.9 or 0.18)
    love.graphics.rectangle("fill", px, py, s, s, 5, 5)
    color(pad == current and ACC or c)
    love.graphics.setLineWidth(pad == current and 2.5 or 1)
    love.graphics.rectangle("line", px, py, s, s, 5, 5)
    love.graphics.setFont(fonts.body)
    color(pad == current and BG or TEXT)
    love.graphics.print(Level.KEYS[pad], px + s / 2 - 4, py + s / 2 - 8)
    e.L.clickables[#e.L.clickables + 1] = { rect = { x = px, y = py, w = s, h = s }, fn = function() fn(pad) end }
  end
  return y + 2 * s + 10
end

local function drawInspector(e, owner, clash)
  local r, J, lv = e.L.inspector, e.J, e.lv
  e.L.nameField = nil
  local x, y, w = r.x, r.y, math.min(r.w, 600)
  local spb = e:spb()
  local selB = e:selectedButtons()
  local selN = e:selectedNotes()

  if e.mode == "lights" and #selB > 0 then
    local b = selB[1]
    local notes = Level.buttonNotes(lv, b)
    y = lines(x, y, {
      { text = #selB == 1 and ("BUTTON  ·  pad %s"):format(Level.KEYS[b.pad]) or ("%d BUTTONS"):format(#selB), head = true, big = true },
      { label = "press at", text = ("bar %s  (its light comes on; the player is judged here)"):format(e:bbt(b.start / lv.ppq)) },
      { label = "light", text = ("a tap: on %.0f ms, fades %.0f ms (juice: lights.hold_s, decay_s)"):format(J.lights.hold_s * 1000, J.lights.decay_s * 1000) },
      { label = "covers", text = ("track %d, keys %s-%s"):format(b.track, Midi.noteName(b.keyLow), Midi.noteName(b.keyHigh)) },
      { label = "plays", text = #notes == 0 and "nothing (a light-only button)" or ("%d note%s:"):format(#notes, #notes == 1 and "" or "s"), c = #notes == 0 and RED or TEXT },
    })
    local silent = false
    for _, s in ipairs(Level.shadowed(lv)) do if s == b then silent = true end end
    if silent then
      y = lines(x, y, { { text = "Plays nothing: another button already plays these notes, but this one still lights", c = RED },
        { text = "and still has to be pressed. Delete it, or press X to remove every button like it.", c = RED } })
    end
    for k = 1, math.min(#notes, 4) do
      local n = notes[k]
      local tag = clash[n.id] and "   also in another box!" or ""
      y = lines(x + 110, y, { { text = ("%s %d  at %s  vel %d%s"):format(Midi.noteName(n.key), n.key, e:bbt(n.tick / lv.ppq), n.vel, tag), c = clash[n.id] and RED or DIM } })
    end
    if #notes > 4 then y = lines(x + 110, y, { { text = ("... %d more"):format(#notes - 4), c = DIM } }) end
    y = y + 6
    local after = padPicker(e, x + 110, y, #selB == 1 and b.pad or nil, function(pad) e:assignPad(pad) end)
    love.graphics.setFont(fonts.body)
    color(DIM)
    love.graphics.print("pad", x, y + 4)
    love.graphics.setFont(fonts.small)
    love.graphics.print("click, or", x, y + 24)
    love.graphics.print("Q W A S", x, y + 38)
    y = after
    colorSliders(e, x, y, w, function()
      local m = e:selectedButtons()[1]
      return m and Level.buttonColor(lv, m) or { 1, 1, 1 }
    end, function(c)
      for _, m in ipairs(e:selectedButtons()) do m.color = c end
    end, b.color and "its own light color (0 = back to the pad's)" or "drag to give it its own light color (else the pad's)")
  elseif e.mode == "rounds" and #e:selectedRounds() > 0 then
    local selR = e:selectedRounds()
    local r = selR[1]
    local steps = Level.prepare(lv).steps
    local number
    for i, s in ipairs(steps) do if s.round == r then number = i end end
    local list = Level.roundButtons(lv, r)
    local pads = {}
    for k, b in ipairs(list) do pads[k] = Level.KEYS[b.pad] end
    y = lines(x, y, {
      { text = #selR == 1 and (number and ("ROUND %d of %d"):format(number, #steps) or "ROUND (outside the level's bars)") or ("%d ROUNDS"):format(#selR), head = true, big = true },
      { label = "adds", text = ("%d button%s at once:  %s"):format(#list, #list == 1 and "" or "s", table.concat(pads, " ")) },
      { label = "covers", text = ("bar %s to %s, track %d, keys %s-%s"):format(e:bbt(r.start / lv.ppq), e:bbt(r["end"] / lv.ppq), r.track, Midi.noteName(r.keyLow), Midi.noteName(r.keyHigh)) },
      { label = "in game", text = number and ("round %d plays rounds 1-%d: every button they add"):format(number, number) or "never: it's outside the level's bars", c = DIM },
      { label = "", text = "a button in no round box is a round of its own", c = DIM },
      { label = "", text = "F fits it to its buttons  ·  Del takes it out  ·  drag it or its edges", c = DIM },
    })
  elseif e.mode == "notes" and #selN > 0 then
    local n = selN[1]
    local b = owner[n.id]
    y = lines(x, y, {
      { text = #selN == 1 and ("NOTE  ·  %s %d"):format(Midi.noteName(n.key), n.key) or ("%d NOTES"):format(#selN), head = true, big = true },
      { label = "track", text = ("%d%s"):format(n.track, lv.trackNames[n.track] and ("  " .. lv.trackNames[n.track]) or "") },
      { label = "at", text = ("bar %s  (tick %d)"):format(e:bbt(n.tick / lv.ppq), n.tick) },
      { label = "length", text = ("%d ticks"):format(n.len) },
      { label = "velocity", text = tostring(n.vel) },
      { label = "played by", text = b and ("the button on pad %s at %s"):format(Level.KEYS[b.pad], e:bbt(b.start / lv.ppq))
        or (lv.unboxed_notes == "mute" and "no button: silent in the game" or "no button: plays along on its own"), c = b and TEXT or DIM },
      { label = "", text = "B boxes the selected notes into one button", c = DIM },
    })
  elseif e.focusedPad then
    local pad = e.focusedPad
    local count = 0
    for _, b in ipairs(lv.buttons) do if b.pad == pad then count = count + 1 end end
    y = lines(x, y, {
      { text = ("PAD %s"):format(Level.KEYS[pad]), head = true, big = true },
      { label = "buttons", text = ("%d on this pad"):format(count) },
      { label = "", text = "Esc to go back to the level", c = DIM },
    }) + 6
    colorSliders(e, x, y, w, function() return lv.pads[pad].color end, function(c) lv.pads[pad].color = c end,
      "the pad's light (buttons without their own color use it)")
  else
    local prep = Level.prepare(lv)
    local rounds = Round.count(prep, J)
    y = lines(x, y, { { text = "LEVEL", head = true, big = true } })
    love.graphics.setFont(fonts.body)
    color(DIM)
    love.graphics.print("name", x, y)
    local field = { x = x + 108, y = y - 2, w = 300, h = 20 }
    color(e.editingName and { 0.12, 0.16, 0.26 } or LINE)
    love.graphics.rectangle("fill", field.x, field.y, field.w, field.h, 3, 3)
    color(e.editingName and ACC or TEXT)
    local shown = e.editingName and (e.nameBuffer .. ((math.floor(e.time * 2) % 2 == 0) and "|" or "")) or lv.name
    love.graphics.print(shown, field.x + 6, field.y + 2)
    e.L.nameField = field
    y = y + 22
    y = lines(x, y, {
      { label = "file", text = lv.path or "(new: Ctrl+S saves it to levels/)" },
      { label = "MIDI", text = lv.midi .. (lv.notesDirty and "   (notes edited: saved beside the level)" or "") },
      { label = "tempo", text = ("%g BPM  ([ ])%s"):format(lv.bpm, lv.midiHasTempo and "" or "   no tempo in the MIDI"), c = lv.midiHasTempo and TEXT or ACC },
      { label = "bars", text = ("%d-%d of the MIDI  (drag the band on the ruler)"):format(lv.start_beat / 4 + 1, lv.start_beat / 4 + lv.bars) },
      { label = "buttons", text = ("%d in the level, %d notes in them, %d notes outside"):format(#prep.buttons, (function() local c = 0 for _, b in ipairs(prep.buttons) do c = c + #b.notes end return c end)(), #prep.free) },
      { label = "in game", text = ("%d round%s with juice.json now (flow.grow: %s)"):format(rounds, rounds == 1 and "" or "s", J.flow.grow), c = DIM },
    })
    y = clickField(e, x, y + 4, "backing", lv.backing and lv.backing.file:match("[^/]+$") or "none (click to pick)", function() e:cycleBacking() end)
    y = clickField(e, x, y, "free notes", lv.unboxed_notes == "mute" and "silent in the game" or "play along in the game", function()
      e:edit("free notes", function() lv.unboxed_notes = lv.unboxed_notes == "mute" and "play" or "mute" end)
    end)
    y = clickField(e, x, y, "exclusive", lv.exclusive and "ON: each note cuts every sound still ringing" or "off: each key cuts only its own last note", function()
      e:toggleExclusive()
    end)
    local clicks = { always = "always: clicks on every beat", count_ins = "count-ins only", off = "off: no clicks" }
    y = clickField(e, x, y, "metronome", lv.metronome and clicks[lv.metronome] or ("juice's setting (" .. J.audio.metronome .. ")"), function()
      e:cycleMetronome()
    end)
  end
end

------------------------------------------------------------------------
-- header and tools
------------------------------------------------------------------------

local function drawHeader(e, playBeat)
  local lv = e.lv
  local title = e.song and e.song.name or lv.name
  love.graphics.setFont(fonts.title)
  color(TEXT)
  love.graphics.print(title, 16, 6)
  -- the layer being edited, as two tabs
  local tx = 16 + fonts.title:getWidth(title) + 24
  for _, m in ipairs(e.LAYERS) do
    local label = e.LAYER_NAMES[m]
    local w = fonts.body:getWidth(label) + 20
    local on = e.mode == m
    color(on and ACC or LINE)
    love.graphics.rectangle("fill", tx, 8, w, 24, 4, 4)
    love.graphics.setFont(fonts.body)
    color(on and BG or DIM)
    love.graphics.print(label, tx + 10, 12)
    e.L.clickables[#e.L.clickables + 1] = { rect = { x = tx, y = 8, w = w, h = 24 }, fn = function()
      e:setMode(m)
    end }
    tx = tx + w + 6
  end
  -- exclusive: on every level, so it lives up here, lit red when on
  do
    local label = lv.exclusive and "EXCLUSIVE ON  (E)" or "EXCLUSIVE OFF  (E)"
    local ex = tx + 18
    local w = fonts.body:getWidth(label) + 28
    color(lv.exclusive and RED or LINE)
    love.graphics.rectangle("fill", ex, 6, w, 28, 5, 5)
    if not lv.exclusive then
      color(DIM)
      love.graphics.rectangle("line", ex + 0.5, 6.5, w - 1, 27, 5, 5)
    end
    love.graphics.setFont(fonts.body)
    color(lv.exclusive and BG or DIM)
    love.graphics.print(label, ex + 14, 12)
    e.L.clickables[#e.L.clickables + 1] = { rect = { x = ex, y = 6, w = w, h = 28 }, fn = function() e:toggleExclusive() end }
  end
  love.graphics.setFont(fonts.small)
  color(DIM)
  if e.song then
    -- the song: its file, tempo, which level is being edited, and the full track it ends on
    local info = ("%s   ·   %g BPM   ·   %d levels   ·   editing %d: %s   ·   then the full track:"):format(
      e.song.path, e.song.bpm, #e.lanes, e.lane, lv.name)
    love.graphics.print(info, 16, 38)
    local f = e.song.finale
    chip(e, 16 + fonts.small:getWidth(info) + 8, 35, f and util.basename(f.file) or "none (click to pick)", false, function() e:cycleFinale() end)
  else
    love.graphics.print(("Tab switches   ·   %s   ·   %g BPM   ·   %d buttons   ·   %d notes on %d track%s"):format(
      lv.path or "(new level)", lv.bpm, #lv.buttons, #lv.notes, lv.trackCount, lv.trackCount == 1 and "" or "s"), 16, 38)
  end
  local state = e:dirty() and "unsaved" or "saved"
  local t = playBeat and ("PLAY %s"):format(e:bbt(playBeat)) or ("STOP %s"):format(e:bbt(e.playhead))
  love.graphics.setFont(fonts.body)
  local right = e.L.header.w - 16
  color(e.playing and ACC or TEXT)
  love.graphics.print(t, right - fonts.body:getWidth(t), 10)
  color(e:dirty() and ACC or DIM)
  love.graphics.print(state, right - fonts.body:getWidth(t) - fonts.body:getWidth(state) - 24, 10)
  local flags = ("metronome %s · backing %s"):format(e.metronome and "on" or "off", e.backingMuted and "muted" or "on")
  love.graphics.setFont(fonts.small)
  color(DIM)
  love.graphics.print(flags, right - fonts.small:getWidth(flags), 38)
end

local function drawTools(e)
  local r = e.L.tools
  color(PANEL)
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h)
  local x, y = r.x + 16, 12
  love.graphics.setFont(fonts.small)
  for _, cmd in ipairs(e.COMMANDS) do
    if cmd.group then
      y = y + (y > 12 and 7 or 0)
      color(ACC)
      love.graphics.print(cmd.group, x, y)
      y = y + 15
    elseif not cmd.hidden then
      local off = cmd.when and e.lv and not cmd.when(e)
      color(cmd.mouse and DIM or TEXT, off and 0.4 or 1)
      love.graphics.print(cmd.label or cmd.mouse, x, y)
      color(DIM, off and 0.4 or 1)
      love.graphics.print(cmd.desc, x + 150, y)
      y = y + 14
    end
  end
  y = y + 8
  for i, c in ipairs(e.PALETTE) do
    local px = x + (i - 1) * 36
    color(c)
    love.graphics.rectangle("fill", px, y, 28, 16, 3, 3)
    color(BG)
    love.graphics.print(tostring(i), px + 10, y + 1)
  end
  if e.status and love.timer.getTime() - e.status.t < 8 then
    color(ACC)
    love.graphics.printf(e.status.text, x, r.h - 56, r.w - 32)
  end
end

------------------------------------------------------------------------

function View.draw(e)
  loadFonts()
  local W, H = love.graphics.getDimensions()
  e.L = View.layout(e, W, H)
  if not e.lv then
    drawOpen(e)
    return
  end
  local L = e.L
  local playBeat, _, sinceStart = e:playBeat()
  local owner, clash = Level.membership(e.lv)
  local shadow = {}
  for _, b in ipairs(Level.shadowed(e.lv)) do shadow[b] = true end
  drawHeader(e, playBeat)
  drawRuler(e)
  drawRoll(e, playBeat, owner, clash, shadow)
  drawVelocity(e, owner)

  local px = e:xOfBeat(playBeat or e.playhead)
  if px >= L.tlX and px <= L.tlX + L.tlW then
    color(ACC, playBeat and 0.9 or 0.45)
    love.graphics.rectangle("fill", math.floor(px), L.ruler.y, 1, L.vel.y + L.vel.h - L.ruler.y)
  end

  color(LINE)
  love.graphics.rectangle("fill", 0, L.preview.y - 10, L.MW, 1)
  drawPreview(e, sinceStart)
  drawInspector(e, owner, clash)
  drawTools(e)
end

return View
