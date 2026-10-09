-- src/bench.lua
-- The MIDI workbench: one song's MIDI, its note -> sample map and its audio, laid out so
-- every number in the chain can be seen, heard and changed. This file holds the state, the
-- command list (which is also the on-screen tool list), mouse editing, the offline render
-- of the window and saving. src/view.lua draws it.

local ffi = require("ffi")
local util = require("src.util")
local Midi = require("src.midi")
local Doc = require("src.doc")
local Mixer = require("src.mixer")
local Song = require("src.song")
local Wave = require("src.wave")
local Transport = require("src.transport")
local Synth = require("src.synth")
local Render = require("src.render")
local View = require("src.view")

local B = {}
B.__index = B

local RATE = 44100
local GRIDS = { { 1, "1/4" }, { 1 / 2, "1/8" }, { 1 / 4, "1/16" }, { 1 / 8, "1/32" }, { 1 / 16, "1/64" } }
local SENS = { 0, 0.35, 1 }

local function round(x) return math.floor(x + 0.5) end

------------------------------------------------------------------------
-- loading
------------------------------------------------------------------------

local function fileInfo(path)
  local ok, info = pcall(function() return Wave.fileInfo(util.readFile(path)) end)
  return ok and info or nil
end

function B:loadSong(name)
  if self.transport then self.transport:stop() end
  package.loaded["songs." .. name] = nil
  self.songName = name
  self.def = require("songs." .. name)
  self.song = Song.load(self.def, self.mixer)
  self.midiPath = self.def.midi.file
  self.midi = self.song.midiInfo
  self.doc = Doc.new(self.midi)
  self.bpm = self.song.bpm
  self.fpb = RATE * 60 / self.bpm
  self.from = self.def.midi.from or 0
  self.to = self.def.midi.to or self.midi.lengthBeats
  self.choke = self.song.choke
  self.velSens = self.song.velocity

  self.backing = nil
  if self.song.backing then
    self.backing = {
      sample = self.song.backing, gain = self.song.backingGain, peaks = Wave.peaks(self.song.backing),
      file = self.def.backing.file, name = util.basename(self.def.backing.file), info = fileInfo(self.def.backing.file),
    }
  end

  -- the sample pool: every file the song maps, in pad order; keys point into it
  self.samples, self.keyMap = {}, {}
  for _, pad in ipairs(self.song.padList) do
    local s = {
      n = pad.n or #self.samples + 1, file = pad.file, name = util.basename(pad.file), label = pad.label,
      sample = pad.sample, peaks = Wave.peaks(pad.sample), audible = Wave.audibleFrames(pad.sample),
      info = fileInfo(pad.file),
    }
    self.samples[#self.samples + 1] = s
    self.keyMap[pad.key] = #self.samples
  end

  -- one lane per key that has notes or a sample, highest key on top like a piano roll
  local keys = {}
  for key in pairs(self.keyMap) do keys[key] = true end
  for _, n in ipairs(self.doc.notes) do keys[n.key] = true end
  self.lanes = {}
  for key in pairs(keys) do self.lanes[#self.lanes + 1] = { key = key, name = Midi.noteName(key) } end
  table.sort(self.lanes, function(a, b) return a.key > b.key end)
  self.laneOf = {}
  for i, l in ipairs(self.lanes) do self.laneOf[l.key] = i end

  self.sel = {}
  self.playhead = self.from
  self.eventScroll = 0
  self.fit = "window"
  self.out = nil
  self:say(("loaded songs/%s.lua"):format(name))
end

function B.load(args)
  local self = setmetatable({}, B)
  self.mixer = Mixer.new{ rate = RATE, bufferFrames = 256, bufferCount = 4 }
  self.clicks = {
    click = self.mixer:loadSample(Synth.click(RATE, false)),
    accent = self.mixer:loadSample(Synth.click(RATE, true)),
  }
  self.grid = 3
  self.loop, self.metronome, self.backingMuted = true, false, false
  self.showDev, self.showTails = true, true
  self.view = { beat0 = 0, ppb = 40 }
  self.transport = Transport.new(self)
  self:loadSong(util.argValue(args, "--song", "test_a"))
  return self
end

------------------------------------------------------------------------
-- what the transport and the view ask
------------------------------------------------------------------------

function B:gridTicks() return self.doc.ppq * GRIDS[self.grid][1] end
function B:gridName() return GRIDS[self.grid][2] end
function B:endBeat() return math.max(self.doc:lengthTicks() / self.doc.ppq, self.to) end
function B:sampleFor(key) return self.samples[self.keyMap[key] or -1] end

function B:gainFor(n)
  return 1 - self.velSens * (1 - n.vel / 127)
end

function B:audible(key)
  local anySolo = false
  for _, l in ipairs(self.lanes) do anySolo = anySolo or l.solo end
  local l = self.lanes[self.laneOf[key] or -1]
  if not l then return true end
  if anySolo then return l.solo end
  return not l.mute
end

function B:say(text)
  self.status = { text = text, t = love.timer.getTime() }
end

-- beat <-> bar.beat.tick
function B:bbt(beat)
  local ppq = self.doc.ppq
  local tick = round(beat * ppq)
  local bar = math.floor(tick / (4 * ppq))
  local inBar = tick - bar * 4 * ppq
  return ("%d.%d.%02d"):format(bar + 1, math.floor(inBar / ppq) + 1, inBar % ppq)
end

-- how far a tick sits from the nearest grid line, in ticks
function B:deviation(tick)
  local g = self:gridTicks()
  return tick - round(tick / g) * g
end

function B:msOfTicks(t) return t / self.doc.ppq * 60 / self.bpm * 1000 end

function B:selectedList()
  local list = {}
  for _, n in ipairs(self.doc.notes) do
    if self.sel[n.id] then list[#list + 1] = n end
  end
  return list
end

-- the lane a key command applies to: under the mouse, else the first selected note's
function B:focusLane()
  if self.hoverLane then return self.lanes[self.hoverLane] end
  local first = self:selectedList()[1]
  return first and self.lanes[self.laneOf[first.key]]
end

-- where each note's one-shot stops: the sample's audible end, or the next hit on its key
function B:tailEnd(n)
  local s = self:sampleFor(n.key)
  if not s then return n.tick, nil end
  local ends = n.tick + s.audible / self.fpb * self.doc.ppq
  if self.choke then
    for _, m in ipairs(self.doc.notes) do
      if m.key == n.key and m.tick > n.tick then
        if m.tick < ends then return m.tick, m end
        break
      end
    end
  end
  return ends, nil
end

------------------------------------------------------------------------
-- offline render of the window: the output strip and Ctrl+E
------------------------------------------------------------------------

function B:renderKey()
  local parts = { self.doc.version, self.from, self.to, self.bpm, tostring(self.choke), self.velSens, tostring(self.backingMuted) }
  for _, l in ipairs(self.lanes) do parts[#parts + 1] = l.key .. ":" .. (self.keyMap[l.key] or 0) .. (l.mute and "m" or "") .. (l.solo and "s" or "") end
  return table.concat(parts, "|")
end

function B:renderWindow()
  local mx = Mixer.new{ rate = RATE, bufferFrames = 256 }
  local frames = math.max(256, round((self.to - self.from) * self.fpb))
  if self.backing and not self.backingMuted then mx:setLoop(self.backing.sample, self.backing.gain, 0, frames) end
  local hits = {}
  for _, n in ipairs(self.doc.notes) do
    local beat = n.tick / self.doc.ppq
    local s = self:sampleFor(n.key)
    if beat >= self.from and beat < self.to and s and self:audible(n.key) then
      hits[#hits + 1] = { f = round((beat - self.from) * self.fpb), n = n, s = s }
    end
  end
  table.sort(hits, function(a, b) return a.f < b.f end)
  local nextHit = 1
  mx.onBlock = function(_, f1)
    while hits[nextHit] and hits[nextHit].f < f1 do
      local h = hits[nextHit]
      mx:play(h.s.sample, h.f, self:gainFor(h.n), self.choke and h.n.key or nil)
      nextHit = nextHit + 1
    end
  end
  local buf = ffi.new("float[?]", frames * 2)
  local blocks = math.ceil(frames / 256)
  local gr = ffi.new("float[?]", blocks)
  local grMin = 1
  for blk = 0, blocks - 1 do
    local n = math.min(256, frames - blk * 256)
    local out = mx:render(n)
    ffi.copy(buf + blk * 512, out, n * 2 * 4)
    gr[blk] = mx.reduction
    grMin = math.min(grMin, mx.reduction)
  end
  local sample = { data = buf, frames = frames }
  self.out = { sample = sample, peaks = Wave.peaks(sample), gr = gr, blocks = blocks, grMin = grMin, hits = hits, key = self:renderKey() }
end

-- gain reduction (linear) the limiter applied at a window frame
function B:grAt(frame)
  if not self.out then return 1 end
  local blk = math.floor(frame / 256)
  if blk < 0 or blk >= self.out.blocks then return 1 end
  return self.out.gr[blk]
end

------------------------------------------------------------------------
-- editing
------------------------------------------------------------------------

local function selectedIds(self)
  local ids = {}
  for id in pairs(self.sel) do ids[id] = true end
  return ids
end

function B:editSelected(label, fn)
  local list = self:selectedList()
  if #list == 0 then self:say("nothing selected"); return end
  self.doc:edit(label, function()
    for _, n in ipairs(list) do fn(n) end
  end)
  self:say(("%s: %d note%s"):format(label, #list, #list == 1 and "" or "s"))
end

function B:nudge(ticks)
  self:editSelected(("nudge %+d ticks"):format(ticks), function(n) n.tick = n.tick + ticks end)
end

function B:moveLanes(dir)
  self:editSelected(dir < 0 and "move up a lane" or "move down a lane", function(n)
    local i = math.max(1, math.min(#self.lanes, self.laneOf[n.key] + dir))
    n.key = self.lanes[i].key
  end)
end

function B:velocity(d)
  self:editSelected(("velocity %+d"):format(d), function(n) n.vel = n.vel + d end)
end

function B:quantize(strength)
  local g = self:gridTicks()
  self:editSelected(("quantize %d%% to %s"):format(strength * 100, self:gridName()), function(n)
    n.tick = n.tick + (round(n.tick / g) * g - n.tick) * strength
  end)
end

function B:deleteSelected()
  local ids = selectedIds(self)
  if not next(ids) then return end
  local count = #self:selectedList()
  self.doc:edit("delete", function(doc) doc:remove(ids) end)
  self.sel = {}
  self:say(("deleted %d note%s"):format(count, count == 1 and "" or "s"))
end

function B:addNote(tick, key)
  local g = self:gridTicks()
  local id
  self.doc:edit("add note", function(doc)
    id = doc:add(math.floor(tick / g) * g, key, g, 100, 0).id
  end)
  self.sel = { [id] = true }
  self:say(("added %s at %s"):format(Midi.noteName(key), self:bbt(self.doc.byId[id].tick / self.doc.ppq)))
end

function B:undo()
  local label = self.doc:undo()
  self:say(label and ("undo: " .. label) or "nothing to undo")
  self:pruneSelection()
end

function B:redo()
  local label = self.doc:redo()
  self:say(label and ("redo: " .. label) or "nothing to redo")
  self:pruneSelection()
end

function B:pruneSelection()
  for id in pairs(self.sel) do
    if not self.doc.byId[id] then self.sel[id] = nil end
  end
end

------------------------------------------------------------------------
-- files
------------------------------------------------------------------------

-- the project folder: wherever songs/ really lives (the game folder, or the working
-- directory when the code is run from somewhere else)
local function root()
  return love.filesystem.getRealDirectory("songs") or "."
end

local function writeFile(path, data)
  local f, err = io.open(path, "wb")
  if not f then return nil, err end
  f:write(data)
  f:close()
  return true
end

function B:save()
  local base = self.songName:gsub("_edit$", "")
  local midiRel = "edits/" .. base .. ".mid"
  local songRel = "songs/" .. base .. "_edit.lua"
  local bytes = self.doc:bytes()
  local ok, err = writeFile(root() .. "/" .. midiRel, bytes)
  if not ok then self:say("save failed: " .. tostring(err)); return end

  local lines = {
    ("-- %s"):format(songRel),
    ("-- Written by the workbench (Ctrl+S) from songs/%s.lua. The MIDI is %s."):format(self.songName, midiRel),
    "return {",
    ("  title = %q,"):format((self.def.title or base):gsub(" %(edit%)$", "") .. " (edit)"),
    ("  bpm = %s,"):format(self.bpm),
  }
  if self.backing then
    lines[#lines + 1] = ("  backing = { file = %q, gain = %s },"):format(self.backing.file, self.backing.gain)
  end
  lines[#lines + 1] = ("  midi = { file = %q, from = %s, to = %s },"):format(midiRel, self.from, self.to)
  lines[#lines + 1] = "  offset = 0,"
  lines[#lines + 1] = ("  velocity = %s,"):format(self.velSens)
  lines[#lines + 1] = ("  choke = %s,"):format(tostring(self.choke))
  lines[#lines + 1] = "  pads = {"
  local keys = {}
  for key in pairs(self.keyMap) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local s = self.samples[self.keyMap[key]]
    lines[#lines + 1] = ("    [%d] = { n = %d, label = %q, file = %q },"):format(key, s.n, s.label or "", s.file)
  end
  lines[#lines + 1] = "  },"
  lines[#lines + 1] = "}"
  ok, err = writeFile(root() .. "/" .. songRel, table.concat(lines, "\n") .. "\n")
  if not ok then self:say("save failed: " .. tostring(err)); return end
  self.doc.savedVersion = self.doc.version
  self:say(("saved %s (%d bytes) and %s"):format(midiRel, #bytes, songRel))
end

function B:exportWav()
  if not self.out or self.out.key ~= self:renderKey() then self:renderWindow() end
  local s = self.out.sample
  local pcm = ffi.new("int16_t[?]", s.frames * 2)
  for i = 0, s.frames * 2 - 1 do
    pcm[i] = math.max(-1, math.min(1, s.data[i])) * 32767
  end
  local rel = "edits/" .. self.songName:gsub("_edit$", "") .. "_window.wav"
  local ok, err = pcall(Render.writeWav, root() .. "/" .. rel, pcm, s.frames, RATE, 2)
  self:say(ok and ("exported %s (%.3f s)"):format(rel, s.frames / RATE) or ("export failed: " .. tostring(err)))
end

function B:revert()
  self:loadSong(self.songName)
  self:say("reloaded from disk; edits discarded")
end

function B:nextSong()
  local names = {}
  for _, f in ipairs(love.filesystem.getDirectoryItems("songs")) do
    local name = f:match("^(.+)%.lua$")
    if name then names[#names + 1] = name end
  end
  table.sort(names)
  for i, name in ipairs(names) do
    if name == self.songName then
      self:loadSong(names[i % #names + 1])
      return
    end
  end
end

------------------------------------------------------------------------
-- commands: every key binding, listed in the tools panel exactly as defined here
------------------------------------------------------------------------

local function togglePlay(self)
  if self.transport.playing then
    self.transport:stop()
  else
    self.transport:play(self.playhead)
  end
end

local function laneToggle(self, field)
  local l = self:focusLane()
  if not l then self:say("hover a lane first"); return end
  l[field] = not l[field]
  self:say(("%s %s %s"):format(l.name, field, l[field] and "on" or "off"))
end

B.COMMANDS = {
  { group = "PLAY" },
  { keys = { "space" }, label = "Space", desc = "play / stop from the playhead", run = togglePlay },
  { keys = { "l" }, label = "L", desc = "loop the window", run = function(s) s.loop = not s.loop; s:say("loop " .. (s.loop and "on" or "off")) end },
  { keys = { "k" }, label = "K", desc = "metronome", run = function(s) s.metronome = not s.metronome end },
  { keys = { "b" }, label = "B", desc = "mute backing", run = function(s) s.backingMuted = not s.backingMuted end },
  { keys = { "m" }, label = "M", desc = "mute lane", run = function(s) laneToggle(s, "mute") end },
  { keys = { "s" }, label = "S", desc = "solo lane", run = function(s) laneToggle(s, "solo") end },
  { keys = { "home" }, label = "Home", desc = "playhead to window start", run = function(s) s.playhead = s.from end },
  { mouse = "click ruler", desc = "set playhead (Alt = off grid)" },
  { mouse = "click lane name", desc = "hear its sample" },

  { group = "EDIT" },
  { mouse = "click", desc = "select a note" },
  { mouse = "Shift+click", desc = "toggle in selection" },
  { mouse = "drag empty", desc = "box select" },
  { mouse = "drag note", desc = "move in grid steps" },
  { mouse = "Alt+drag note", desc = "move in single ticks" },
  { mouse = "drag note end", desc = "length" },
  { mouse = "drag velocity", desc = "velocity of the selection" },
  { mouse = "double-click", desc = "add a note" },
  { keys = { "left", "right" }, label = "Left Right", desc = "nudge one grid step", run = function(s, key) s:nudge((key == "left" and -1 or 1) * s:gridTicks()) end },
  { keys = { "shift+left", "shift+right" }, label = "Shift+Left Right", desc = "nudge one tick", run = function(s, key) s:nudge(key == "shift+left" and -1 or 1) end },
  { keys = { "up", "down" }, label = "Up Down", desc = "move to next lane (key)", run = function(s, key) s:moveLanes(key == "up" and -1 or 1) end },
  { keys = { "=", "+", "kp+", "-", "kp-" }, label = "+ -", desc = "velocity +/- 8", run = function(s, key) s:velocity((key:find("-", 1, true) and -1 or 1) * 8) end },
  { keys = { "shift+=", "shift+-" }, label = "Shift + -", desc = "velocity +/- 1", run = function(s, key) s:velocity(key == "shift+-" and -1 or 1) end },
  { keys = { "q" }, label = "Q", desc = "quantize to grid", run = function(s) s:quantize(1) end },
  { keys = { "shift+q" }, label = "Shift+Q", desc = "quantize 50%", run = function(s) s:quantize(0.5) end },
  { keys = { "delete", "backspace" }, label = "Del", desc = "delete", run = function(s) s:deleteSelected() end },
  { keys = { "ctrl+a" }, label = "Ctrl+A", desc = "select all", run = function(s) for _, n in ipairs(s.doc.notes) do s.sel[n.id] = true end end },
  { keys = { "escape" }, label = "Esc", desc = "select none", run = function(s) s.sel = {} end },
  { keys = { "ctrl+z" }, label = "Ctrl+Z", desc = "undo", run = function(s) s:undo() end },
  { keys = { "ctrl+y", "ctrl+shift+z" }, label = "Ctrl+Y", desc = "redo", run = function(s) s:redo() end },

  { group = "VIEW" },
  { mouse = "wheel", desc = "zoom at the mouse" },
  { mouse = "Shift+wheel", desc = "scroll (or right-drag)" },
  { keys = { "f" }, label = "F", desc = "fit the whole file", run = function(s) s.fit = "file" end },
  { keys = { "w" }, label = "W", desc = "fit the window", run = function(s) s.fit = "window" end },
  { keys = { "g" }, label = "G / Shift+G", desc = "grid finer / coarser", run = function(s) s.grid = math.min(#GRIDS, s.grid + 1) end },
  { keys = { "shift+g" }, hidden = true, run = function(s) s.grid = math.max(1, s.grid - 1) end },
  { keys = { "d" }, label = "D", desc = "timing vs grid markers", run = function(s) s.showDev = not s.showDev end },
  { keys = { "t" }, label = "T", desc = "one-shot tails", run = function(s) s.showTails = not s.showTails end },

  { group = "MAP" },
  { mouse = "drag window edge", desc = "loop window (on the ruler)" },
  { keys = { "r" }, label = "R", desc = "lane's key -> next sample", run = function(s)
    local l = s:focusLane()
    if not l then s:say("hover a lane first"); return end
    s.keyMap[l.key] = ((s.keyMap[l.key] or 0) % #s.samples) + 1
    s:say(("key %d -> %s"):format(l.key, s.samples[s.keyMap[l.key]].name))
  end },
  { keys = { "c" }, label = "C", desc = "choke (Simpler Retrigger)", run = function(s) s.choke = not s.choke end },
  { keys = { "v" }, label = "V", desc = "velocity -> volume 0/35/100%", run = function(s)
    local i = 1
    for k, v in ipairs(SENS) do if math.abs(v - s.velSens) < 1e-6 then i = k end end
    s.velSens = SENS[i % #SENS + 1]
  end },
  { keys = { "[", "]" }, label = "[ ]", desc = "BPM -/+1 (backing stays put)", run = function(s, key)
    s.bpm = s.bpm + (key == "[" and -1 or 1)
    s.fpb = RATE * 60 / s.bpm
    s:say(("%g BPM: notes move against the backing"):format(s.bpm))
  end },

  { group = "FILE" },
  { keys = { "ctrl+s" }, label = "Ctrl+S", desc = "save .mid + song to edits/", run = function(s) s:save() end },
  { keys = { "ctrl+e" }, label = "Ctrl+E", desc = "export the window as WAV", run = function(s) s:exportWav() end },
  { keys = { "ctrl+r" }, label = "Ctrl+R", desc = "revert to file", run = function(s) s:revert() end },
  { keys = { "ctrl+o" }, label = "Ctrl+O", desc = "next song in songs/", run = function(s) s:nextSong() end },
}

local function chord(key)
  local parts = {}
  if love.keyboard.isDown("lctrl", "rctrl") then parts[#parts + 1] = "ctrl" end
  if love.keyboard.isDown("lshift", "rshift") then parts[#parts + 1] = "shift" end
  if love.keyboard.isDown("lalt", "ralt") then parts[#parts + 1] = "alt" end
  parts[#parts + 1] = key
  return table.concat(parts, "+")
end

function B:keypressed(key)
  local c = chord(key)
  for _, cmd in ipairs(B.COMMANDS) do
    for _, k in ipairs(cmd.keys or {}) do
      if k == c then
        cmd.run(self, c)
        return
      end
    end
  end
end

------------------------------------------------------------------------
-- mouse
------------------------------------------------------------------------

function B:beatOfX(x) return self.view.beat0 + (x - self.L.tlX) / self.view.ppb end
function B:xOfBeat(beat) return self.L.tlX + (beat - self.view.beat0) * self.view.ppb end
function B:xOfTick(tick) return self:xOfBeat(tick / self.doc.ppq) end

local function inside(x, y, r)
  return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

-- note under the mouse, and whether it is on the note's end (length handle)
function B:noteAt(x, y)
  local L = self.L
  if not inside(x, y, L.lanes) then return nil end
  local lane = math.floor((y - L.lanes.y) / L.rowH) + 1
  local key = self.lanes[lane] and self.lanes[lane].key
  for i = #self.doc.notes, 1, -1 do
    local n = self.doc.notes[i]
    if n.key == key then
      local x0, x1 = self:xOfTick(n.tick), self:xOfTick(n.tick + n.len)
      x1 = math.max(x1, x0 + 6)
      if x >= x0 and x <= x1 then return n, x >= x1 - 5 and x1 - x0 > 10 end
    end
  end
  return nil
end

function B:snapDelta(ticks)
  if love.keyboard.isDown("lalt", "ralt") then return round(ticks) end
  local g = self:gridTicks()
  return round(ticks / g) * g
end

function B:mousepressed(x, y, button, presses)
  local L = self.L
  self.drag = nil
  if button == 2 or button == 3 then
    self.drag = { kind = "pan", x = x, beat0 = self.view.beat0 }
    return
  end
  if button ~= 1 then return end
  local shift = love.keyboard.isDown("lshift", "rshift")

  if inside(x, y, L.events) then
    self:clickEvents(x, y)
    return
  end

  -- lane names: audition
  if inside(x, y, L.laneLabels) then
    local lane = self.lanes[math.floor((y - L.lanes.y) / L.rowH) + 1]
    local s = lane and self:sampleFor(lane.key)
    if s then self.mixer:play(s.sample, nil, 1) end
    return
  end

  if inside(x, y, L.ruler) then
    local fx, tx = self:xOfBeat(self.from), self:xOfBeat(self.to)
    if math.abs(x - fx) < 6 then self.drag = { kind = "window", edge = "from" }; return end
    if math.abs(x - tx) < 6 then self.drag = { kind = "window", edge = "to" }; return end
    self.drag = { kind = "playhead" }
    self:dragTo(x, y)
    return
  end

  if inside(x, y, L.vel) then
    local best, bestD
    for _, n in ipairs(self.doc.notes) do
      local d = math.abs(self:xOfTick(n.tick) - x)
      if d < 6 and (not bestD or d < bestD) then best, bestD = n, d end
    end
    if best then
      if not self.sel[best.id] then self.sel = { [best.id] = true } end
      local orig = {}
      for _, n in ipairs(self:selectedList()) do orig[n.id] = n.vel end
      self.doc:begin("velocity")
      self.drag = { kind = "vel", y = y, orig = orig, moved = false }
    end
    return
  end

  if inside(x, y, L.lanes) then
    local n, onEnd = self:noteAt(x, y)
    if n then
      if shift then
        self.sel[n.id] = not self.sel[n.id] or nil
        return
      end
      if not self.sel[n.id] then self.sel = { [n.id] = true } end
      local orig = {}
      for _, m in ipairs(self:selectedList()) do orig[m.id] = { tick = m.tick, key = m.key, len = m.len, lane = self.laneOf[m.key] } end
      self.drag = { kind = onEnd and "length" or "move", x = x, y = y, beat = self:beatOfX(x), orig = orig, started = false }
      return
    end
    if presses >= 2 then
      local lane = self.lanes[math.floor((y - L.lanes.y) / L.rowH) + 1]
      if lane then self:addNote(self:beatOfX(x) * self.doc.ppq, lane.key) end
      return
    end
    if not shift then self.sel = {} end
    self.drag = { kind = "box", x = x, y = y, x2 = x, y2 = y }
    return
  end
end

function B:dragTo(x, y)
  local d = self.drag
  if not d then return end
  local ppq = self.doc.ppq
  if d.kind == "pan" then
    self.view.beat0 = d.beat0 - (x - d.x) / self.view.ppb
  elseif d.kind == "playhead" then
    local beat = self:beatOfX(x)
    if not love.keyboard.isDown("lalt", "ralt") then
      local g = GRIDS[self.grid][1]
      beat = round(beat / g) * g
    end
    self.playhead = math.max(0, beat)
  elseif d.kind == "window" then
    local beat = math.max(0, round(self:beatOfX(x)))
    if d.edge == "from" then self.from = math.min(beat, self.to - 1) else self.to = math.max(beat, self.from + 1) end
  elseif d.kind == "box" then
    d.x2, d.y2 = x, y
  elseif d.kind == "vel" then
    local dv = -(y - d.y) / self.L.vel.h * 127
    for id, v in pairs(d.orig) do
      local n = self.doc.byId[id]
      if n then n.vel = v + dv end
    end
    d.moved = true
    self.doc:touch()
  elseif d.kind == "move" or d.kind == "length" then
    if not d.started then
      if math.abs(x - d.x) < 3 and math.abs(y - d.y) < 3 then return end
      d.started = true
      self.doc:begin(d.kind == "move" and "move" or "length")
    end
    local dt = self:snapDelta((self:beatOfX(x) - d.beat) * ppq)
    local dl = round((y - d.y) / self.L.rowH)
    for id, o in pairs(d.orig) do
      local n = self.doc.byId[id]
      if n then
        if d.kind == "move" then
          n.tick = o.tick + dt
          n.key = self.lanes[math.max(1, math.min(#self.lanes, o.lane + dl))].key
        else
          n.len = math.max(1, o.len + dt)
        end
      end
    end
    self.doc:touch()
  end
end

function B:mousereleased(x, y)
  local d = self.drag
  self.drag = nil
  if not d then return end
  if d.kind == "box" then
    local x0, x1 = math.min(d.x, d.x2), math.max(d.x, d.x2)
    local y0, y1 = math.min(d.y, d.y2), math.max(d.y, d.y2)
    for _, n in ipairs(self.doc.notes) do
      local lane = self.laneOf[n.key]
      local ny = self.L.lanes.y + (lane - 1) * self.L.rowH
      local nx0, nx1 = self:xOfTick(n.tick), math.max(self:xOfTick(n.tick + n.len), self:xOfTick(n.tick) + 6)
      if nx1 >= x0 and nx0 <= x1 and ny + self.L.rowH >= y0 and ny <= y1 then self.sel[n.id] = true end
    end
  elseif d.kind == "vel" and not d.moved then
    self.doc:undo()   -- a click without a drag changed nothing; drop the empty undo step
    self.doc.redoStack = {}
  elseif (d.kind == "move" or d.kind == "length") and d.started then
    self:say(("%s: %d note%s"):format(d.kind, #self:selectedList(), #self:selectedList() == 1 and "" or "s"))
  elseif d.kind == "window" then
    self:say(("window %s - %s (%g beats)"):format(self:bbt(self.from), self:bbt(self.to), self.to - self.from))
  end
end

function B:wheelmoved(_, wy)
  local mx, my = love.mouse.getPosition()
  local L = self.L
  if inside(mx, my, L.events) then
    self.eventScroll = math.max(0, self.eventScroll - wy * 3)
    self.eventFollow = false
    return
  end
  if my >= L.ruler.y and my < L.out.y + L.out.h and mx >= L.tlX then
    if love.keyboard.isDown("lshift", "rshift") then
      self.view.beat0 = self.view.beat0 - wy * 40 / self.view.ppb
    else
      local beat = self:beatOfX(mx)
      self.view.ppb = math.max(3, math.min(3000, self.view.ppb * 1.15 ^ wy))
      self.view.beat0 = beat - (mx - L.tlX) / self.view.ppb
    end
  end
end

function B:mousemoved(x, y)
  self.mouseX, self.mouseY = x, y
  self:dragTo(x, y)
end

------------------------------------------------------------------------
-- frame
------------------------------------------------------------------------

function B:update(dt)
  self.mixer:pump()
  if self.transport:finished() then self.transport:stop() end

  local W, H = love.graphics.getDimensions()
  self.L = View.layout(self, W, H)
  if self.fit then
    local a, b = self.from, self.to
    if self.fit == "file" then a, b = 0, self:endBeat() end
    local span = math.max(1, b - a)
    self.view.ppb = self.L.tlW / (span * 1.04)
    self.view.beat0 = a - span * 0.02
    self.fit = nil
  end

  local mx, my = love.mouse.getPosition()
  self.hoverNote, self.hoverLane = nil, nil
  if inside(mx, my, self.L.lanes) or inside(mx, my, self.L.laneLabels) then
    self.hoverLane = math.floor((my - self.L.lanes.y) / self.L.rowH) + 1
    if not self.lanes[self.hoverLane] then self.hoverLane = nil end
    self.hoverNote = self:noteAt(mx, my)
  end
  self.hoverEvent = View.eventAt(self, mx, my)
  if self.hoverEvent and self.hoverEvent.noteId then self.hoverNote = self.doc.byId[self.hoverEvent.noteId] end

  -- re-render the output strip once edits settle (not mid-drag)
  if not self.drag and (not self.out or self.out.key ~= self:renderKey()) then
    self.renderAt = self.renderAt or love.timer.getTime() + 0.1
    if love.timer.getTime() >= self.renderAt then
      self:renderWindow()
      self.renderAt = nil
    end
  end
end

function B:clickEvents(x, y)
  local ev = View.eventAt(self, x, y)
  if ev and ev.noteId then
    if love.keyboard.isDown("lshift", "rshift") then self.sel[ev.noteId] = true else self.sel = { [ev.noteId] = true } end
    return true
  end
  return false
end

function B:draw()
  View.draw(self)
end

return B
