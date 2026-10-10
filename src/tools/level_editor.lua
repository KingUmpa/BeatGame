-- src/tools/level_editor.lua
-- The LEVEL editor: a MIDI track and the buttons (lights) programmed over it.
--
-- Three layers, Tab steps through them, each a box over the one below:
--   NOTES   the MIDI itself: move, nudge, change velocity, add, delete notes
--   LIGHTS  the buttons: boxes drawn over the notes. A box covers one track, a stretch of
--           time and a range of keys; one press of its pad plays every note inside it, and
--           the player is judged on pressing when the box starts (its light comes on).
--           Draw a box by dragging, click it, press Q W A S to put it on a pad.
--   ROUNDS  how the game builds the level up: boxes drawn over the buttons. Each round adds
--           every button inside it at once; a button in no round is a round of its own.
--
-- It opens a MIDI file (to start a level) or a level file (to carry on with one): from the
-- open screen, by dropping a file on the window, or `run levels <file>`. Ctrl+S writes the
-- level file (levels/<name>.json, the sidecar with the buttons, sounds and lights) and the
-- MIDI next to it (levels/<name>.mid), which the sidecar links to. The game reads only these.
--
-- It also opens a song (songs/*.json, src/game/song.lua): every level of it at once, one lane
-- above the other on one time axis from each level's first beat, so what plays together
-- lines up. Click a lane to edit that level; Space plays them all, each looping its own
-- length, as they sound once built. Ctrl+S saves every changed level and the song.
--
-- self.lanes holds what's open (one lane for a single level); self.lv is the lane being
-- edited, and all the editing below works on it.
--
-- src/tools/level_view.lua draws it.

local util = require("src.util")
local Juice = require("src.config.juice")
local Level = require("src.game.level")
local Song = require("src.game.song")
local Midi = require("src.midi")
local Mixer = require("src.mixer")
local Synth = require("src.synth")
local View = require("src.tools.level_view")

local E = {}
E.__index = E

local RATE = 44100
E.GRIDS = { { 1, "1/4" }, { 1 / 2, "1/8" }, { 1 / 4, "1/16" }, { 1 / 8, "1/32" }, { 1 / 16, "1/64" } }
E.PALETTE = {
  { 1.00, 0.20, 0.15 }, { 1.00, 0.55, 0.12 }, { 1.00, 0.90, 0.20 }, { 0.25, 0.95, 0.45 },
  { 0.15, 0.85, 0.95 }, { 0.20, 0.45, 1.00 }, { 0.65, 0.30, 1.00 }, { 1.00, 1.00, 1.00 },
}
local PAD_KEYS = { q = 1, w = 2, a = 3, s = 4 }

local function round(x) return math.floor(x + 0.5) end

------------------------------------------------------------------------
-- files
------------------------------------------------------------------------

local function scan(dir, ext, out, maxSize)
  for _, f in ipairs(love.filesystem.getDirectoryItems(dir)) do
    local p = dir .. "/" .. f
    local info = love.filesystem.getInfo(p)
    if info and info.type == "directory" then scan(p, ext, out, maxSize)
    elseif info and f:lower():match("%." .. ext .. "$") and (not maxSize or info.size < maxSize) then out[#out + 1] = p end
  end
  return out
end

function E:refreshFiles()
  self.files = { levels = {}, songs = {}, midis = scan("assets/midi", "mid", {}) }
  for _, p in ipairs(Level.list()) do
    local ok, lv = pcall(Level.load, p)
    self.files.levels[#self.files.levels + 1] = { path = p, name = ok and lv.name or "(can't read)", buttons = ok and #lv.buttons or 0, err = not ok and lv or nil }
  end
  for _, p in ipairs(Song.list()) do
    local ok, song = pcall(Song.load, p)
    local names = {}
    if ok then for i, part in ipairs(song.parts) do names[i] = part.level.name end end
    self.files.songs[#self.files.songs + 1] = { path = p, name = ok and song.name or "(can't read)", levels = table.concat(names, " > "), err = not ok and song or nil }
  end
  table.sort(self.files.midis)
  self.samplePool = scan("assets/audio/samples", "wav", {})
  self.backingPool = {}
  scan("assets/audio/songs", "wav", self.backingPool)
  self.voPool = Song.voLines()
end

function E:openScreen()
  self:stop()
  self.lv, self.lanes, self.song = nil, nil, nil
  self:refreshFiles()
end

-- what's open: lanes = { { lv, audio, muted, saved } }, the first one being edited
function E:setLanes(levels, song)
  self:stop()
  self.song = song
  self.lanes = {}
  for i, lv in ipairs(levels) do
    self.lanes[i] = { lv = lv, audio = Level.loadAudio(lv, self.mixer), muted = false }
    self.lanes[i].saved = self:laneKey(self.lanes[i])
  end
  self.songSaved = song and Song.toJson(song)
  self.undoStack, self.redoStack = {}, {}
  self:activate(1)
  self.playhead = song and 0 or self.lv.start_beat
  self.fit = true
end

function E:setLevel(lv) self:setLanes({ lv }, nil) end

-- edit lane i (in a song: the level in that lane)
function E:activate(i)
  local ln = self.lanes[i]
  self.lane = i
  self.lv, self.audio = ln.lv, ln.audio
  self.sel, self.selB, self.selR = {}, {}, {}
  self.focusedPad = nil
  self.editingName = false
  self:refreshRows()
end

function E:openSong(path)
  local ok, song = pcall(Song.load, path)
  if not ok then return self:say("can't open " .. path .. ": " .. tostring(song)) end
  local levels = {}
  for i, p in ipairs(song.parts) do levels[i] = p.level end
  if #levels == 0 then return self:say(path .. " has no levels") end
  self:setLanes(levels, song)
  self.mode = "lights"
  self:say(("song %s: %d levels, click a lane to edit it"):format(song.name, #levels))
end

local function isSongFile(path)
  local text = util.readFile(path)
  local raw = text and require("lib.json").try_decode(text)
  return type(raw) == "table" and type(raw.levels) == "table"
end

function E:openPath(path)
  local ok, lvOrErr
  if path:lower():match("%.json$") and isSongFile(path) then
    return self:openSong(path)
  elseif path:lower():match("%.json$") then
    ok, lvOrErr = pcall(Level.load, path)
  else
    ok, lvOrErr = pcall(Level.fromMidi, path)
  end
  if not ok then return self:say("can't open " .. path .. ": " .. tostring(lvOrErr)) end
  self:setLevel(lvOrErr)
  if lvOrErr.path then
    self:say("continuing " .. path)
  else
    self.mode = "lights"
    self:say(("new level from %s%s"):format(util.basename(path),
      lvOrErr.midiHasTempo and "" or " · no tempo in the MIDI: set the BPM with [ ]"))
  end
end

function E.load(args)
  local self = setmetatable({}, E)
  love.window.setMode(1600, 920, { resizable = true, minwidth = 1200, minheight = 720, vsync = 0, msaa = 4 })
  love.window.setTitle("BeatEmUp - LEVEL editor")
  self.J = Juice.data
  self.mixer = Mixer.new{ rate = RATE, bufferFrames = 256, bufferCount = 4 }
  self.clicks = { click = self.mixer:loadSample(Synth.click(RATE, false)), accent = self.mixer:loadSample(Synth.click(RATE, true)) }
  self.grid = 3
  self.mode = "lights"
  self.metronome, self.backingMuted = false, false
  self.view = { beat0 = 0, ppb = 100 }
  self.flashes = {}
  self.time = 0
  self:refreshFiles()
  local first
  for _, a in ipairs(args or {}) do
    if a:lower():match("%.json$") or a:lower():match("%.midi?$") then first = a end
  end
  local lvArg = util.argValue(args, "--level", nil)
  first = first or (lvArg ~= true and lvArg or nil)
  if first then self:openPath(first) end
  return self
end

------------------------------------------------------------------------
-- helpers
------------------------------------------------------------------------

function E:say(text) self.status = { text = text, t = love.timer.getTime() } end
function E:spb() return 60 / self.lv.bpm end
function E:gridTicks() return self.lv.ppq * E.GRIDS[self.grid][1] end
function E:gridName() return E.GRIDS[self.grid][2] end

-- The time axis: a single level shows its MIDI's own beats; a song shows beats from each
-- level's first beat (offset = its start in its MIDI), so its lanes line up.
function E:offset(lv) return self.song and (lv or self.lv).start_beat or 0 end

-- where a level's bars sit on the axis
function E:windowAxis(lv)
  lv = lv or self.lv
  local a = lv.start_beat - self:offset(lv)
  return a, a + Level.beats(lv)
end

-- beats playback loops over: the level, or in a song its longest level (the others repeat inside it)
function E:loopBeats()
  if not self.song then return Level.beats(self.lv) end
  local n = 4
  for _, ln in ipairs(self.lanes) do n = math.max(n, Level.beats(ln.lv)) end
  return n
end

function E:laneKey(ln)
  return Level.toJson(ln.lv) .. (ln.lv.notesDirty and "*" or "")
end

function E:laneDirty(ln) return self:laneKey(ln) ~= ln.saved end

function E:dirty()
  if not self.lanes then return false end
  for _, ln in ipairs(self.lanes) do if self:laneDirty(ln) then return true end end
  return self.song ~= nil and Song.toJson(self.song) ~= self.songSaved
end

-- after a lane's sounds change
function E:reloadAudio()
  self.audio = Level.loadAudio(self.lv, self.mixer)
  self.lanes[self.lane].audio = self.audio
end

function E:bbt(beat)
  local ppq = self.lv.ppq
  local tick = round(beat * ppq)
  local bar = math.floor(tick / (4 * ppq))
  local inBar = tick - bar * 4 * ppq
  return ("%d.%d.%02d"):format(bar + 1, math.floor(inBar / ppq) + 1, inBar % ppq)
end

function E:refreshRows()
  self.rows = Level.rows(self.lv)
  if #self.rows == 0 then self.rows = { { track = 1, key = 60 } } end
  self.rowOf = {}
  for i, r in ipairs(self.rows) do self.rowOf[r.track * 1000 + r.key] = i end
end

function E:noteById(id)
  for _, n in ipairs(self.lv.notes) do if n.id == id then return n end end
end

function E:buttonById(id)
  for _, b in ipairs(self.lv.buttons) do if b.id == id then return b end end
end

function E:selectedNotes()
  local out = {}
  for _, n in ipairs(self.lv.notes) do if self.sel[n.id] then out[#out + 1] = n end end
  return out
end

function E:selectedButtons()
  local out = {}
  for _, b in ipairs(self.lv.buttons) do if self.selB[b.id] then out[#out + 1] = b end end
  return out
end

function E:roundById(id)
  for _, r in ipairs(self.lv.rounds) do if r.id == id then return r end end
end

function E:selectedRounds()
  local out = {}
  for _, r in ipairs(self.lv.rounds) do if self.selR[r.id] then out[#out + 1] = r end end
  return out
end

-- the boxes a drag works on: buttons (LIGHTS) or rounds (ROUNDS)
function E:boxById(kind, id)
  if kind == "rounds" then return self:roundById(id) end
  return self:buttonById(id)
end

function E:trackRows(track)
  local out = {}
  for i, r in ipairs(self.rows) do if r.track == track then out[#out + 1] = i end end
  return out
end

------------------------------------------------------------------------
-- undo: a snapshot of everything editable in the lane being edited (and, in a song, the
-- song's own settings). Each step remembers its lane; undoing it goes back to that lane.
------------------------------------------------------------------------

local FIELDS = { "name", "bpm", "start_beat", "bars", "unboxed_notes", "exclusive", "metronome", "backing", "pads", "sounds", "buttons", "rounds", "notes", "nextNoteId", "nextButtonId", "nextRoundId", "notesDirty" }

function E:snapshot()
  local s = {}
  for _, f in ipairs(FIELDS) do s[f] = util.deepcopy(self.lv[f]) end
  if self.song then
    s.song = { name = self.song.name, bpm = self.song.bpm, finale = util.deepcopy(self.song.finale), vo = {} }
    for i, p in ipairs(self.song.parts) do s.song.vo[i] = p.vo end
  end
  return s
end

function E:restore(s)
  for _, f in ipairs(FIELDS) do self.lv[f] = util.deepcopy(s[f]) end
  if self.song and s.song then
    self.song.name, self.song.bpm, self.song.finale = s.song.name, s.song.bpm, util.deepcopy(s.song.finale)
    for i, p in ipairs(self.song.parts) do p.vo = s.song.vo[i] end
    for _, ln in ipairs(self.lanes) do ln.lv.bpm = self.song.bpm end
  end
end

function E:begin(label)
  table.insert(self.undoStack, { label = label, lane = self.lane, state = self:snapshot() })
  if #self.undoStack > 200 then table.remove(self.undoStack, 1) end
  self.redoStack = {}
end

function E:touch(notesChanged)
  local lv = self.lv
  if notesChanged then
    for _, n in ipairs(lv.notes) do
      n.tick = math.max(0, round(n.tick))
      n.len = math.max(1, round(n.len))
      n.vel = util.clamp(round(n.vel), 1, 127)
    end
    Level.sortNotes(lv)
    lv.notesDirty = true
  end
  for _, list in ipairs({ lv.buttons, lv.rounds }) do
    for _, b in ipairs(list) do
      b.start = math.max(0, round(b.start))
      b["end"] = math.max(b.start + 1, round(b["end"]))
    end
  end
  Level.sortButtons(lv)
  Level.sortRounds(lv)
  self:refreshRows()
end

function E:edit(label, fn, notesChanged)
  self:begin(label)
  fn()
  self:touch(notesChanged)
  self:say(label)
end

local function swap(self, from, to, verb)
  local step = table.remove(from)
  if not step then return self:say("nothing to " .. verb) end
  if step.lane and step.lane ~= self.lane and self.lanes[step.lane] then self:activate(step.lane) end
  table.insert(to, { label = step.label, lane = self.lane, state = self:snapshot() })
  self:restore(step.state)
  self:refreshRows()
  for id in pairs(self.sel) do if not self:noteById(id) then self.sel[id] = nil end end
  for id in pairs(self.selB) do if not self:buttonById(id) then self.selB[id] = nil end end
  for id in pairs(self.selR) do if not self:roundById(id) then self.selR[id] = nil end end
  self:reloadAudio()
  self:say(verb .. ": " .. step.label)
end

function E:undo() swap(self, self.undoStack, self.redoStack, "undo") end
function E:redo() swap(self, self.redoStack, self.undoStack, "redo") end

------------------------------------------------------------------------
-- NOTES layer
------------------------------------------------------------------------

function E:editNotes(label, fn)
  local list = self:selectedNotes()
  if #list == 0 then return self:say("no notes selected (NOTES layer: Tab)") end
  self:edit(("%s (%d note%s)"):format(label, #list, #list == 1 and "" or "s"), function()
    for _, n in ipairs(list) do fn(n) end
  end, true)
end

-- up/down walks a note through its own track's rows
function E:moveRow(n, dir)
  local i = self.rowOf[n.track * 1000 + n.key]
  local j = i and i + dir
  if j and self.rows[j] and self.rows[j].track == n.track then n.key = self.rows[j].key end
end

function E:addNote(tick, row)
  local g = self:gridTicks()
  local lv = self.lv
  local n = { id = lv.nextNoteId, track = row.track, key = row.key, tick = math.floor(tick / g) * g, len = g, vel = 100, ch = 0 }
  lv.nextNoteId = lv.nextNoteId + 1
  self:edit("add note", function() table.insert(lv.notes, n) end, true)
  self.sel = { [n.id] = true }
end

function E:deleteNotes()
  local list = self:selectedNotes()
  if #list == 0 then return end
  self:edit(("delete %d note%s"):format(#list, #list == 1 and "" or "s"), function()
    local keep = {}
    for _, n in ipairs(self.lv.notes) do if not self.sel[n.id] then keep[#keep + 1] = n end end
    self.lv.notes = keep
  end, true)
  self.sel = {}
end

function E:quantize(strength)
  local g = self:gridTicks()
  self:editNotes(("quantize %d%% to %s"):format(strength * 100, self:gridName()), function(n)
    n.tick = n.tick + (round(n.tick / g) * g - n.tick) * strength
  end)
end

------------------------------------------------------------------------
-- LIGHTS layer
------------------------------------------------------------------------

function E:editButtons(label, fn)
  local list = self:selectedButtons()
  if #list == 0 then return self:say("no buttons selected (click one)") end
  self:edit(("%s (%d button%s)"):format(label, #list, #list == 1 and "" or "s"), function()
    for _, b in ipairs(list) do fn(b) end
  end)
end

-- the selected buttons onto a pad; with none selected, just pick that pad (its color, its sound)
function E:assignPad(pad)
  if self.mode == "lights" and next(self.selB) then
    self:editButtons("onto pad " .. Level.KEYS[pad], function(b) b.pad = pad end)
    self.lastPad = pad
  else
    self.focusedPad = pad
    self:audition(pad)
  end
end

function E:deleteButtons()
  local list = self:selectedButtons()
  if #list == 0 then return end
  self:edit(("delete %d button%s"):format(#list, #list == 1 and "" or "s"), function()
    local keep = {}
    for _, b in ipairs(self.lv.buttons) do if not self.selB[b.id] then keep[#keep + 1] = b end end
    self.lv.buttons = keep
  end)
  self.selB = {}
end

function E:fitButtons()
  self:editButtons("fit to its notes", function(b) Level.fitButton(self.lv, b) end)
end

-- b takes over its notes: boxes it makes redundant go (inside the current undo step)
function E:replaceUnder(b)
  local gone = Level.coveredBy(self.lv, b)
  Level.removeButtons(self.lv, gone)
  for _, o in ipairs(gone) do self.selB[o.id] = nil end
  return #gone
end

local function replacedNote(n)
  return n > 0 and (" (replaced %d button%s under it)"):format(n, n == 1 and "" or "s") or ""
end

-- remove the boxes that play nothing because other boxes already play all their notes
function E:removeShadowed()
  local list = Level.shadowed(self.lv)
  if #list == 0 then return self:say("no buttons are hidden under others") end
  self:edit(("removed %d button%s that played nothing"):format(#list, #list == 1 and "" or "s"), function()
    Level.removeButtons(self.lv, list)
  end)
  self.selB = {}
end

-- one box around the selected notes (they must share a track)
function E:boxSelection()
  local list = self:selectedNotes()
  if #list == 0 then return self:say("select notes first (NOTES layer), then B") end
  local track = list[1].track
  for _, n in ipairs(list) do
    if n.track ~= track then return self:say("a button can only cover one track") end
  end
  local b, replaced
  self:edit(("box %d note%s into one button"):format(#list, #list == 1 and "" or "s"), function()
    local s, e, lo, hi = math.huge, 0, 127, 0
    for _, n in ipairs(list) do
      s, e = math.min(s, n.tick), math.max(e, n.tick + n.len)
      lo, hi = math.min(lo, n.key), math.max(hi, n.key)
    end
    b = Level.newButton(self.lv, { track = track, pad = self.lastPad or 1, start = s, ["end"] = e, keyLow = lo, keyHigh = hi })
    replaced = self:replaceUnder(b)
  end)
  self.mode, self.sel, self.selB = "lights", {}, { [b.id] = true }
  if replaced > 0 then self:say(("boxed %d notes into one button%s"):format(#list, replacedNote(replaced))) end
end

-- A starting point for a new level: one button per unboxed note in the level's stretch, on
-- the pad its key ranks for (the most used key -> Q, next -> W, ...)
function E:buttonPerNote()
  local lv = self.lv
  local a, z = Level.window(lv)
  local owner = Level.membership(lv)
  local counts, order = {}, {}
  for _, n in ipairs(lv.notes) do
    if n.tick >= a and n.tick < z then
      local k = n.track * 1000 + n.key
      if not counts[k] then counts[k] = 0; order[#order + 1] = k end
      counts[k] = counts[k] + 1
    end
  end
  table.sort(order, function(x, y) return counts[x] > counts[y] end)
  local padOf = {}
  for i, k in ipairs(order) do padOf[k] = (i - 1) % 4 + 1 end
  local made = 0
  self:edit("a button for every note", function()
    for _, n in ipairs(lv.notes) do
      if n.tick >= a and n.tick < z and not owner[n.id] then
        Level.newButton(lv, { track = n.track, pad = padOf[n.track * 1000 + n.key], start = n.tick, ["end"] = n.tick + n.len, keyLow = n.key, keyHigh = n.key })
        made = made + 1
      end
    end
  end)
  self:say(("made %d buttons (notes already in a box were skipped)"):format(made))
end

-- a palette color onto the selected buttons, or onto the picked pad
function E:applyColor(c)
  local list = self:selectedButtons()
  if #list > 0 then
    self:edit(c and "button light color" or "button back to its pad's color", function()
      for _, b in ipairs(list) do b.color = c and util.deepcopy(c) or nil end
    end)
    return
  end
  local pad = self.focusedPad
  if not pad then return self:say("select buttons, or click a pad in the preview") end
  if not c then return self:say("pads always have a color") end
  self:edit(("pad %s light color"):format(Level.KEYS[pad]), function() self.lv.pads[pad].color = util.deepcopy(c) end)
end

------------------------------------------------------------------------
-- ROUNDS layer
------------------------------------------------------------------------

function E:editRounds(label, fn)
  local list = self:selectedRounds()
  if #list == 0 then return self:say("no rounds selected (click one)") end
  self:edit(("%s (%d round%s)"):format(label, #list, #list == 1 and "" or "s"), function()
    for _, r in ipairs(list) do fn(r) end
  end)
end

-- r takes over its buttons: rounds it makes redundant go (inside the current undo step)
function E:replaceRoundsUnder(r)
  local gone = Level.roundsCoveredBy(self.lv, r)
  Level.removeRounds(self.lv, gone)
  for _, o in ipairs(gone) do self.selR[o.id] = nil end
  return #gone
end

local function replacedRoundsNote(n)
  return n > 0 and (" (replaced %d round%s under it)"):format(n, n == 1 and "" or "s") or ""
end

-- a round from a box dragged over the roll (track, ticks, keys): the buttons starting inside
-- it, the box tightened round them
function E:makeRound(track, t0, t1, keyLow, keyHigh)
  local box = { track = track, start = round(t0), ["end"] = math.max(round(t1), round(t0) + 1), keyLow = keyLow, keyHigh = keyHigh }
  if #Level.roundButtons(self.lv, box) == 0 then return self:say("no buttons start inside that box") end
  local r, replaced
  self:edit("make a round", function()
    r = Level.newRound(self.lv, box)
    Level.fitRound(self.lv, r)
    replaced = self:replaceRoundsUnder(r)
  end)
  self.selR = { [r.id] = true }
  self:say(("made a round of %d buttons%s"):format(#Level.roundButtons(self.lv, r), replacedRoundsNote(replaced)))
end

function E:deleteRounds()
  local list = self:selectedRounds()
  if #list == 0 then return end
  self:edit(("delete %d round%s (their buttons are rounds of their own again)"):format(#list, #list == 1 and "" or "s"), function()
    Level.removeRounds(self.lv, list)
  end)
  self.selR = {}
end

function E:fitRounds()
  self:editRounds("fit to its buttons", function(r) Level.fitRound(self.lv, r) end)
end

------------------------------------------------------------------------
-- sounds and level settings
------------------------------------------------------------------------

function E:cycleSound(row)
  local pool = self.samplePool
  if #pool == 0 then return self:say("no .wav files under assets/audio/samples/") end
  local cur = Level.sound(self.lv, row.track, row.key)
  local i = 0
  for k, p in ipairs(pool) do if cur and p == cur.sample then i = k end end
  local nextFile = pool[i % #pool + 1]
  self:edit(("%s -> %s"):format(Midi.noteName(row.key), util.basename(nextFile)), function()
    Level.setSound(self.lv, row.track, row.key, nextFile)
  end)
  self:reloadAudio()
  self:playRow(row)
end

function E:cycleBacking()
  local pool = self.backingPool
  local cur = self.lv.backing and self.lv.backing.file
  local i = 0
  for k, p in ipairs(pool) do if p == cur then i = k end end
  local nextFile = pool[i + 1]   -- after the last one: no backing
  self:edit("backing", function() self.lv.backing = nextFile and { file = nextFile, gain = 1 } or nil end)
  self:reloadAudio()
end

-- exclusive: each MIDI note cuts every sound still ringing (Level.choke). Takes effect on the
-- next note, so it can be flipped while the level loops.
function E:toggleExclusive()
  self:edit(self.lv.exclusive and "exclusive off" or "exclusive on", function() self.lv.exclusive = not self.lv.exclusive end)
end

-- the clicks under this level in the game: juice's audio.metronome, or its own
local METRONOME_CYCLE = { [false] = "always", always = "count_ins", count_ins = "off", off = false }
function E:cycleMetronome()
  local nextMode = METRONOME_CYCLE[self.lv.metronome or false] or nil
  self:edit("metronome: " .. (nextMode or "juice's setting"), function() self.lv.metronome = nextMode or nil end)
end

function E:setBpm(bpm)
  bpm = math.max(20, bpm)
  self:edit("bpm", function()
    self.lv.bpm = bpm
    if self.song then
      self.song.bpm = bpm
      for _, ln in ipairs(self.lanes) do ln.lv.bpm = bpm end
    end
  end)
  if self.playing then self:play() end
end

-- in a song: the VO line lane i's level plays when it's cleared (then none, then round again)
function E:cycleVo(i)
  local part = self.song.parts[i]
  local pool = self.voPool
  local k = 0
  for j, p in ipairs(pool) do if p == part.vo then k = j end end
  local nextFile = pool[k + 1]
  self:edit(("level %d VO: %s"):format(i, nextFile and util.basename(nextFile) or "none"), function() part.vo = nextFile end)
  local s = nextFile and Level.loadSample(self.mixer, nextFile, true)
  if s then self.mixer:play(s, nil, self.J.song.vo_volume) end
end

-- in a song: the full track played after the last level (the .wavs under assets/audio/songs/)
function E:cycleFinale()
  local pool = self.backingPool
  local cur = self.song.finale and self.song.finale.file
  local k = 0
  for j, p in ipairs(pool) do if p == cur then k = j end end
  local nextFile = pool[k + 1]
  self:edit("finale: " .. (nextFile and util.basename(nextFile) or "none"), function()
    self.song.finale = nextFile and { file = nextFile, gain = 1, beat = 0 } or nil
  end)
end

function E:toggleMute(i)
  local ln = self.lanes[i]
  ln.muted = not ln.muted
  self:say(("%s %s"):format(ln.lv.name, ln.muted and "muted" or "back in"))
end

------------------------------------------------------------------------
-- playback: the level's stretch on a loop (in a song every level at once, each looping its
-- own length), lit as the demo would light the level being edited
------------------------------------------------------------------------

function E:playRow(row)
  local s = self.audio.get(row.track, row.key)
  if s then self.mixer:play(s, nil, 1, Level.choke(self.lv, row.track, row.key)) end
end

function E:audition(pad)
  local prep = Level.prepare(self.lv)
  for _, b in ipairs(prep.buttons) do
    if b.pad == pad and b.notes[1] then
      local n = b.notes[1]
      local s = self.audio.get(n.track, n.key)
      if s then self.mixer:play(s, nil, 1, Level.choke(self.lv, n.track, n.key)) end
      break
    end
  end
  self.flashes[#self.flashes + 1] = { pad = pad, at = self.time }
end

-- each lane's notes, for playback: rebuilt every frame while playing, so edits are heard
function E:prepareLanes()
  for _, ln in ipairs(self.lanes) do
    ln.prep = Level.prepare(ln.lv)
    ln.notes = Level.loopNotes(ln.prep)
  end
  self.prep = self.lanes[self.lane].prep
end

function E:play()
  local fpb = RATE * self:spb()
  local rel = util.clamp(self.playhead - (self.song and 0 or self.lv.start_beat), 0, self:loopBeats() - 1e-6)
  self.mixer:reset(round(rel * fpb))
  self.mixer.paused = false
  if self.audio.backing and not self.backingMuted then
    self.mixer:setLoop(self.audio.backing, self.J.audio.backing_volume * (self.lv.backing and self.lv.backing.gain or 1), 0)
  else
    self.mixer:setLoop(nil)
  end
  self:prepareLanes()
  self.mixer.onBlock = function(f0, f1) self:schedule(f0, f1) end
  self.playing = true
  self.playFrom = rel
end

function E:stop()
  if not self.mixer then return end
  self.mixer:reset()
  self.mixer:setLoop(nil)
  self.mixer.onBlock = nil
  self.playing = false
end

-- timeline beat 0 is every level's first beat; each lane repeats its own length from there
function E:schedule(f0, f1)
  local fpb = RATE * self:spb()
  local b0, b1 = f0 / fpb, f1 / fpb
  local A = self.J.audio
  for _, ln in ipairs(self.lanes) do
    if not ln.muted and ln.notes then
      for _, e in ipairs(Song.loopEvents(ln.notes, Level.beats(ln.lv), b0, b1)) do
        local n = e.note
        local s = ln.audio.get(n.track, n.key)
        if s then
          self.mixer:play(s, round(e.beat * fpb), A.sample_volume * (1 - A.velocity_sensitivity * (1 - n.vel / 127)), Level.choke(ln.lv, n.track, n.key))
        end
      end
    end
  end
  if self.metronome then
    -- on the music's beat, as in the game (the level's beat_offset)
    local off = self.lv.beat_offset or 0
    for k = math.ceil(b0 - off), math.ceil(b1 - off) - 1 do
      self.mixer:play(k % 4 == 0 and self.clicks.accent or self.clicks.click, round((k + off) * fpb), A.click_volume)
    end
  end
end

-- the beat being heard: on the time axis, within the loop, and since play
function E:playBeat()
  if not self.playing then return nil end
  local b = self.mixer:clock() / (RATE * self:spb())
  local rel = b % self:loopBeats()
  return (self.song and 0 or self.lv.start_beat) + rel, rel, b
end

------------------------------------------------------------------------
-- save / launch / export
------------------------------------------------------------------------

local function slug(s)
  return (s:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end

function E:save()
  if self.song then return self:saveSong() end
  local lv = self.lv
  local path = lv.path
  if not path then
    local name = slug(lv.name)
    path = ("levels/%02d_%s.json"):format(#Level.list() + 1, name ~= "" and name or "level")
  end
  local ok, err = Level.save(lv, path)
  if not ok then return self:say("save failed: " .. tostring(err)) end
  self.lanes[1].saved = self:laneKey(self.lanes[1])
  self:say(("saved %s (buttons, sounds, lights) and %s (the MIDI)"):format(path, lv.midi))
end

-- every level that changed (each with its MIDI), and the song file
function E:saveSong()
  local wrote = {}
  for _, ln in ipairs(self.lanes) do
    if self:laneDirty(ln) then
      local ok, err = Level.save(ln.lv, ln.lv.path)
      if not ok then return self:say("save failed: " .. tostring(err)) end
      ln.saved = self:laneKey(ln)
      wrote[#wrote + 1] = ln.lv.path
    end
  end
  local text = Song.toJson(self.song)
  if text ~= self.songSaved then
    local ok, err = Song.save(self.song)
    if not ok then return self:say("save failed: " .. tostring(err)) end
    self.songSaved = text
    wrote[#wrote + 1] = self.song.path
  end
  self:say(#wrote == 0 and "nothing to save" or ("saved " .. table.concat(wrote, ", ")))
end

-- the game on this level; in a song, the song from the level being edited (the ones before
-- it already built)
function E:launchGame()
  if not self.lv.path or self:dirty() then self:save() end
  local exe = love.filesystem.getExecutablePath():gsub("lovec%.exe$", "love.exe")
  local args = self.song and ("--song=%s --from=%d"):format(self.song.path, self.lane) or ("--level=" .. self.lv.path)
  local cmd = love.system.getOS() == "Windows" and ('start "" "%s" "%s" %s') or ('"%s" "%s" %s &')
  os.execute(cmd:format(exe, util.projectDir(), args))
  self:say("launched the game: " .. args)
end

function E:export()
  local Export = require("src.export")
  local out = {}
  for _, backing in ipairs({ true, false }) do
    local rel, err
    if self.song then
      rel, err = Export.song(self.song, self.J, { backing = backing })
    else
      rel, err = Export.level(self.lv, self.J, { backing = backing })
    end
    out[#out + 1] = rel or ("failed: " .. tostring(err))
  end
  self:say("exported " .. table.concat(out, " and "))
end

------------------------------------------------------------------------
-- commands: every key binding, listed in the tools panel exactly as defined here
------------------------------------------------------------------------

local function inLights(self) return self.mode == "lights" end
local function inRounds(self) return self.mode == "rounds" end

E.LAYERS = { "notes", "lights", "rounds" }
E.LAYER_NAMES = { lights = "LIGHTS (buttons)", rounds = "ROUNDS", notes = "NOTES (MIDI)" }

function E:setMode(m)
  if self.mode ~= m then self.mode, self.sel, self.selB, self.selR = m, {}, {}, {} end
end

local function nudge(s, d)
  if inLights(s) then
    s:editButtons("nudge", function(b) b.start, b["end"] = b.start + d, b["end"] + d end)
  elseif inRounds(s) then
    s:editRounds("nudge", function(r) r.start, r["end"] = r.start + d, r["end"] + d end)
  else
    s:editNotes("nudge", function(n) n.tick = n.tick + d end)
  end
end

E.COMMANDS = {
  { group = "LAYERS" },
  { keys = { "tab" }, label = "Tab", desc = "NOTES / LIGHTS / ROUNDS", run = function(s)
    local i = 1
    for k, m in ipairs(E.LAYERS) do if m == s.mode then i = k end end
    s:setMode(E.LAYERS[i % #E.LAYERS + 1])
    s:say(E.LAYER_NAMES[s.mode] .. " layer")
  end },
  { mouse = "click a lane (song)", desc = "edit that level" },
  { keys = { "pageup", "pagedown" }, label = "PgUp PgDn", desc = "level above / below", run = function(s, k)
    local i = s.lane + (k == "pageup" and -1 or 1)
    if s.lanes[i] then s:activate(i); s:say(("editing level %d: %s"):format(i, s.lv.name)) end
  end },

  { group = "LIGHTS (buttons)" },
  { mouse = "drag on a track", desc = "draw a button box" },
  { mouse = "click / Shift+click", desc = "select a button" },
  { mouse = "drag a button", desc = "move it (Alt = ticks)" },
  { mouse = "drag its edges", desc = "start / end" },
  { keys = { "q", "w", "a", "s" }, label = "Q W A S", desc = "selected -> that pad", run = function(s, k) s:assignPad(PAD_KEYS[k]) end, when = inLights },
  { keys = { "f" }, label = "F", desc = "fit box to its notes", run = function(s) s:fitButtons() end, when = inLights },
  { keys = { "x" }, label = "X", desc = "remove red (silent) buttons", run = function(s) s:removeShadowed() end, when = inLights },
  { keys = { "b" }, label = "B", desc = "box the selected notes", run = function(s) s:boxSelection() end },
  { keys = { "ctrl+b" }, label = "Ctrl+B", desc = "a button for every note", run = function(s) s:buttonPerNote() end },
  { keys = { "1", "2", "3", "4", "5", "6", "7", "8" }, label = "1 - 8", desc = "light color (button / pad)", run = function(s, k) s:applyColor(E.PALETTE[tonumber(k)]) end },
  { keys = { "0" }, label = "0", desc = "button back to pad color", run = function(s) s:applyColor(nil) end },

  { group = "ROUNDS (the build-up)" },
  { mouse = "drag around buttons", desc = "make them one round" },
  { mouse = "drag a round / edges", desc = "move it / start, end" },
  { keys = { "f" }, label = "F", desc = "fit round to its buttons", run = function(s) s:fitRounds() end, when = inRounds },

  { group = "NOTES (the MIDI)" },
  { mouse = "click / drag empty", desc = "select / box select" },
  { mouse = "drag note / its end", desc = "move / length" },
  { mouse = "double-click", desc = "add a note" },
  { keys = { "left", "right" }, label = "Left Right", desc = "nudge one grid step", run = function(s, k) nudge(s, (k == "left" and -1 or 1) * s:gridTicks()) end },
  { keys = { "shift+left", "shift+right" }, label = "Shift+Left Right", desc = "nudge one tick", run = function(s, k) nudge(s, k == "shift+left" and -1 or 1) end },
  { keys = { "up", "down" }, label = "Up Down", desc = "notes to the next key", run = function(s, k)
    if s.mode == "notes" then s:editNotes("move key", function(n) s:moveRow(n, k == "up" and -1 or 1) end) end
  end },
  { keys = { "=", "kp+", "-", "kp-" }, label = "+ -", desc = "velocity +/- 8", run = function(s, k)
    s:editNotes("velocity", function(n) n.vel = n.vel + (k:find("-", 1, true) and -8 or 8) end) end },
  { keys = { "shift+q" }, label = "Shift+Q", desc = "quantize notes to grid", run = function(s) s:quantize(1) end },

  { group = "BOTH" },
  { keys = { "delete", "backspace" }, label = "Del", desc = "delete selected", run = function(s)
    if inLights(s) then s:deleteButtons() elseif inRounds(s) then s:deleteRounds() else s:deleteNotes() end end },
  { keys = { "ctrl+a" }, label = "Ctrl+A", desc = "select all", run = function(s)
    if inLights(s) then for _, b in ipairs(s.lv.buttons) do s.selB[b.id] = true end
    elseif inRounds(s) then for _, r in ipairs(s.lv.rounds) do s.selR[r.id] = true end
    else for _, n in ipairs(s.lv.notes) do s.sel[n.id] = true end end
  end },
  { keys = { "escape" }, label = "Esc", desc = "select none", run = function(s) s.sel, s.selB, s.selR, s.focusedPad = {}, {}, {}, nil end },
  { keys = { "ctrl+z" }, label = "Ctrl+Z", desc = "undo", run = function(s) s:undo() end },
  { keys = { "ctrl+y", "ctrl+shift+z" }, label = "Ctrl+Y", desc = "redo", run = function(s) s:redo() end },

  { group = "PLAY / VIEW" },
  { keys = { "space" }, label = "Space", desc = "play / stop (loops)", run = function(s) if s.playing then s:stop() else s:play() end end },
  { keys = { "k" }, label = "K", desc = "metronome", run = function(s) s.metronome = not s.metronome end },
  { keys = { "m" }, label = "M", desc = "mute backing", run = function(s) s.backingMuted = not s.backingMuted; if s.playing then s:play() end end },
  { mouse = "click ruler", desc = "set the playhead" },
  { mouse = "click a key's name", desc = "hear its sound" },
  { mouse = "drop a .wav on a key", desc = "that key's sound" },
  { keys = { "r" }, label = "R", desc = "key under mouse -> next .wav", run = function(s)
    if s.hoverRow then s:cycleSound(s.rows[s.hoverRow]) else s:say("hover a key row first") end end },
  { mouse = "drag the level band", desc = "which bars are the level" },
  { mouse = "wheel / Shift+wheel", desc = "zoom / scroll" },
  { keys = { "home" }, label = "Home", desc = "fit the level", run = function(s) s.fit = true end },
  { keys = { "g" }, label = "G / Shift+G", desc = "grid finer / coarser", run = function(s) s.grid = math.min(#E.GRIDS, s.grid + 1) end },
  { keys = { "shift+g" }, hidden = true, run = function(s) s.grid = math.max(1, s.grid - 1) end },
  { keys = { "[", "]" }, label = "[ ]", desc = "BPM -/+ 1 (every level)", run = function(s, k)
    s:setBpm(s.lv.bpm + (k == "[" and -1 or 1)) end },
  { keys = { "e" }, label = "E", desc = "exclusive: note cuts all others", run = function(s) s:toggleExclusive() end },

  { group = "FILE" },
  { keys = { "ctrl+s" }, label = "Ctrl+S", desc = "save (song: every level)", run = function(s) s:save() end },
  { keys = { "ctrl+o" }, label = "Ctrl+O", desc = "open another", run = function(s) s:openScreen() end },
  { keys = { "f5" }, label = "F5", desc = "play it in the game", run = function(s) s:launchGame() end },
  { keys = { "ctrl+e" }, label = "Ctrl+E", desc = "export WAVs (+/- backing)", run = function(s) s:export() end },
}

local function chord(key)
  local parts = {}
  if love.keyboard.isDown("lctrl", "rctrl") then parts[#parts + 1] = "ctrl" end
  if love.keyboard.isDown("lshift", "rshift") then parts[#parts + 1] = "shift" end
  if love.keyboard.isDown("lalt", "ralt") then parts[#parts + 1] = "alt" end
  parts[#parts + 1] = key
  return table.concat(parts, "+")
end

local REPEATS = { left = true, right = true, up = true, down = true, ["="] = true, ["-"] = true, ["kp+"] = true, ["kp-"] = true }

function E:keypressed(key, isrepeat)
  if not self.lv then
    if key == "escape" then love.event.quit() end
    return
  end
  if self.editingName then return self:nameKey(key) end
  if isrepeat and not REPEATS[key] then return end
  local c = chord(key)
  for _, cmd in ipairs(E.COMMANDS) do
    if not cmd.when or cmd.when(self) then
      for _, k in ipairs(cmd.keys or {}) do
        if k == c then return cmd.run(self, c) end
      end
    end
  end
  -- in the NOTES layer Q W A S are free: they audition the pads
  if PAD_KEYS[c] then self:audition(PAD_KEYS[c]) end
end

function E:nameKey(key)
  if key == "return" or key == "kpenter" then
    local name = self.nameBuffer
    self.editingName = false
    if name ~= "" and name ~= self.lv.name then self:edit("rename", function() self.lv.name = name end) end
  elseif key == "escape" then
    self.editingName = false
  elseif key == "backspace" then
    self.nameBuffer = self.nameBuffer:sub(1, -2)
  end
end

function E:textinput(t)
  if self.editingName then self.nameBuffer = self.nameBuffer .. t end
end

-- a path inside the project is stored relative to it, so the level keeps working if the
-- folder moves
local function projectRelative(path)
  local root = util.projectDir():gsub("\\", "/"):lower()
  local p = path:gsub("\\", "/")
  if p:lower():sub(1, #root + 1) == root .. "/" then return p:sub(#root + 2) end
  return p
end

function E:filedropped(file)
  local path = file:getFilename()
  local lower = path:lower()
  if lower:match("%.json$") or lower:match("%.midi?$") then
    self:openPath(path)
  elseif lower:match("%.wav$") and self.lv then
    -- onto a key row: that key's sound (in a song, the lane it lands on is the one edited)
    local mx, my = love.mouse.getPosition()
    for _, lane in ipairs(self.L.lanes or {}) do
      local r = lane.rect
      if not lane.active and mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h then
        self:activate(lane.index)
        self.L = View.layout(self, love.graphics.getDimensions())
      end
    end
    local i = self:rowAt(my)
    if not i then return self:say("drop the .wav onto a key's row to give that key its sound") end
    local row = self.rows[i]
    local rel = projectRelative(path)
    self:edit(("%s -> %s"):format(Midi.noteName(row.key), util.basename(rel)), function() Level.setSound(self.lv, row.track, row.key, rel) end)
    self:reloadAudio()
    self:playRow(row)
  else
    self:say("drop a .mid (to start a level), a level .json (to continue one), or a .wav onto a key")
  end
end

------------------------------------------------------------------------
-- mouse
------------------------------------------------------------------------

-- x <-> beats on the time axis; ticks are a level's own MIDI ticks (default: the one being edited)
function E:beatOfX(x) return self.view.beat0 + (x - self.L.tlX) / self.view.ppb end
function E:xOfBeat(b) return self.L.tlX + (b - self.view.beat0) * self.view.ppb end
function E:xOfTick(t, lv)
  lv = lv or self.lv
  return self:xOfBeat(t / lv.ppq - self:offset(lv))
end
function E:tickOfX(x) return (self:beatOfX(x) + self:offset()) * self.lv.ppq end

local function inside(x, y, r)
  return r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

function E:rowAt(y)
  for i, r in ipairs(self.L.rowRects or {}) do
    if y >= r.y and y < r.y + r.h then return i end
  end
end

function E:noteAt(x, y)
  local i = self:rowAt(y)
  if not i then return nil end
  local row = self.rows[i]
  for k = #self.lv.notes, 1, -1 do
    local n = self.lv.notes[k]
    if n.track == row.track and n.key == row.key then
      local x0 = self:xOfTick(n.tick)
      local x1 = math.max(self:xOfTick(n.tick + n.len), x0 + 6)
      if x >= x0 and x <= x1 then return n, x >= x1 - 5 and x1 - x0 > 10 end
    end
  end
end

-- the box under the mouse, and whether the mouse is on its start or end edge
local function boxAt(rects, x, y)
  for k = #(rects or {}), 1, -1 do
    local r = rects[k]
    if inside(x, y, r) then
      local edge
      if r.w > 16 and x < r.x + 6 then edge = "start" elseif r.w > 16 and x > r.x + r.w - 6 then edge = "end" end
      return r.button, edge
    end
  end
end

function E:buttonAt(x, y) return boxAt(self.L.buttonRects, x, y) end
function E:roundAt(x, y) return boxAt(self.L.roundRects, x, y) end

function E:snapDelta(ticks)
  if love.keyboard.isDown("lalt", "ralt") then return round(ticks) end
  local g = self:gridTicks()
  return round(ticks / g) * g
end

function E:snapTick(tick)
  if love.keyboard.isDown("lalt", "ralt") then return round(tick) end
  local g = self:gridTicks()
  return round(tick / g) * g
end

function E:mousepressed(x, y, button, presses)
  if not self.lv then
    for _, item in ipairs(self.L.openItems or {}) do
      if inside(x, y, item.rect) then return self:openPath(item.path) end
    end
    return
  end
  local L = self.L
  self.drag = nil
  if self.editingName and not inside(x, y, L.nameField) then self:nameKey("return") end
  if button == 2 or button == 3 then
    self.drag = { kind = "pan", x = x, beat0 = self.view.beat0 }
    return
  end
  if button ~= 1 then return end
  local shift = love.keyboard.isDown("lshift", "rshift")

  if L.nameField and inside(x, y, L.nameField) then
    self.editingName, self.nameBuffer = true, self.lv.name
    return
  end
  for _, c in ipairs(L.clickables or {}) do
    if inside(x, y, c.rect) then return c.fn() end
  end
  for _, s in ipairs(L.sliders or {}) do
    if inside(x, y, s.rect) then
      self:begin(s.label)
      self.drag = { kind = "slider", slider = s }
      self:dragTo(x, y)
      return
    end
  end
  if inside(x, y, L.preview) then
    local pad = View.previewPadAt(self, x, y)
    if pad then self:assignPad(pad) end
    return
  end
  if inside(x, y, L.rowLabels) then
    local i = self:rowAt(y)
    if i then self:playRow(self.rows[i]) end
    return
  end
  if inside(x, y, L.ruler) then
    local a0, a1 = self:windowAxis()
    local wx0, wx1 = self:xOfBeat(a0), self:xOfBeat(a1)
    if math.abs(x - wx1) < 7 then
      self:begin("level length")
      self.drag = { kind = "window_end" }
    elseif x > wx0 and x < wx1 and y < L.ruler.y + 12 then
      self:begin("move the level")
      self.drag = { kind = "window", x = x, start = self.lv.start_beat }
    else
      self.drag = { kind = "playhead" }
      self:dragTo(x, y)
    end
    return
  end
  if inside(x, y, L.vel) and self.mode == "notes" then
    local best, bestD
    for _, n in ipairs(self.lv.notes) do
      local d = math.abs(self:xOfTick(n.tick) - x)
      if d < 6 and (not bestD or d < bestD) then best, bestD = n, d end
    end
    if best then
      if not self.sel[best.id] then self.sel = { [best.id] = true } end
      local orig = {}
      for _, n in ipairs(self:selectedNotes()) do orig[n.id] = n.vel end
      self:begin("velocity")
      self.drag = { kind = "vel", y = y, orig = orig }
    end
    return
  end
  if not inside(x, y, L.roll) then return end

  if self.mode == "lights" or self.mode == "rounds" then
    -- boxes: buttons over notes, or rounds over buttons
    local rounds = self.mode == "rounds"
    local boxes = rounds and "rounds" or "buttons"
    local sel = rounds and self.selR or self.selB
    local b, edge
    if rounds then b, edge = self:roundAt(x, y) else b, edge = self:buttonAt(x, y) end
    if b then
      if shift then
        sel[b.id] = not sel[b.id] or nil
        return
      end
      if not sel[b.id] then
        sel = { [b.id] = true }
        if rounds then self.selR = sel else self.selB = sel end
      end
      local orig = {}
      for _, sb in ipairs(rounds and self:selectedRounds() or self:selectedButtons()) do
        orig[sb.id] = { start = sb.start, ["end"] = sb["end"], keyLow = sb.keyLow, keyHigh = sb.keyHigh }
      end
      self.drag = { kind = edge and ("b_" .. edge) or "b_move", boxes = boxes, x = x, y = y, beat = self:beatOfX(x), orig = orig, row = self:rowAt(y), started = false }
      return
    end
    local i = self:rowAt(y)
    if not shift then
      if rounds then self.selR = {} else self.selB = {} end
    end
    if i then self.drag = { kind = "draw", boxes = boxes, x = x, y = y, x2 = x, y2 = y, row = i, track = self.rows[i].track } end
    return
  end

  local n, onEnd = self:noteAt(x, y)
  if n then
    if shift then
      self.sel[n.id] = not self.sel[n.id] or nil
      return
    end
    if not self.sel[n.id] then self.sel = { [n.id] = true } end
    local orig = {}
    for _, m in ipairs(self:selectedNotes()) do orig[m.id] = { tick = m.tick, key = m.key, len = m.len, row = self.rowOf[m.track * 1000 + m.key] } end
    self.drag = { kind = onEnd and "len" or "move", x = x, y = y, beat = self:beatOfX(x), row = self:rowAt(y), orig = orig, started = false }
    return
  end
  if presses and presses >= 2 then
    local i = self:rowAt(y)
    if i then self:addNote(self:tickOfX(x), self.rows[i]) end
    return
  end
  if not shift then self.sel = {} end
  self.drag = { kind = "box", x = x, y = y, x2 = x, y2 = y }
end

-- the rows a drag from row i to height y covers, kept inside row i's track
function E:rowSpanInTrack(i, y)
  local track = self.rows[i].track
  local j = self:rowAt(y)
  local rows = self:trackRows(track)
  if not j or self.rows[j].track ~= track then
    j = (y < self.L.rowRects[i].y) and rows[1] or rows[#rows]
  end
  return math.min(i, j), math.max(i, j)
end

function E:dragTo(x, y)
  local d = self.drag
  if not d then return end
  local lv = self.lv
  local ppq = lv and lv.ppq
  if d.kind == "pan" then
    self.view.beat0 = d.beat0 - (x - d.x) / self.view.ppb
  elseif d.kind == "playhead" then
    local beat = self:beatOfX(x)
    if not love.keyboard.isDown("lalt", "ralt") then
      local g = E.GRIDS[self.grid][1]
      beat = round(beat / g) * g
    end
    local a0 = self:windowAxis()
    self.playhead = util.clamp(beat, a0, a0 + self:loopBeats() - 1e-6)
  elseif d.kind == "window" then
    -- in a song the band stays at the lane's first beat and the MIDI slides under it
    lv.start_beat = math.max(0, d.start + round((self:beatOfX(x) - self:beatOfX(d.x)) / 4) * 4 * (self.song and -1 or 1))
    self.playhead = self:windowAxis()
  elseif d.kind == "window_end" then
    lv.bars = math.max(1, round((self:beatOfX(x) - self:windowAxis()) / 4))
  elseif d.kind == "slider" then
    d.slider.set(util.clamp01((x - d.slider.rect.x) / d.slider.rect.w))
  elseif d.kind == "draw" or d.kind == "box" then
    d.x2, d.y2 = x, y
  elseif d.kind == "vel" then
    local dv = -(y - d.y) / self.L.vel.h * 127
    for id, v in pairs(d.orig) do
      local n = self:noteById(id)
      if n then n.vel = util.clamp(round(v + dv), 1, 127) end
    end
  elseif d.kind == "move" or d.kind == "len" then
    if not d.started then
      if math.abs(x - d.x) < 3 and math.abs(y - d.y) < 3 then return end
      d.started = true
      self:begin(d.kind == "move" and "move notes" or "note length")
    end
    local dt = self:snapDelta((self:beatOfX(x) - d.beat) * ppq)
    local here = self:rowAt(y)
    local shift = (here and d.row) and (here - d.row) or 0
    for id, o in pairs(d.orig) do
      local n = self:noteById(id)
      if n then
        if d.kind == "move" then
          n.tick = math.max(0, o.tick + dt)
          -- notes change key only within their own track
          local j = o.row and (o.row + shift)
          if j and self.rows[j] and self.rows[j].track == n.track then n.key = self.rows[j].key end
        else
          n.len = math.max(1, o.len + dt)
        end
      end
    end
  elseif d.kind == "b_move" or d.kind == "b_start" or d.kind == "b_end" then
    if not d.started then
      if math.abs(x - d.x) < 3 and math.abs(y - d.y) < 3 then return end
      d.started = true
      local what = d.boxes == "rounds" and "round" or "button"
      self:begin(d.kind == "b_move" and ("move " .. what) or ("resize " .. what))
    end
    local dt = self:snapDelta((self:beatOfX(x) - d.beat) * ppq)
    local here = self:rowAt(y)
    local shift = (here and d.row) and (here - d.row) or 0
    for id, o in pairs(d.orig) do
      local b = self:boxById(d.boxes, id)
      if b then
        if d.kind == "b_move" then
          local start = math.max(0, o.start + dt)
          b.start, b["end"] = start, start + (o["end"] - o.start)
          -- up/down shifts its keys by whole rows, inside its own track
          local hi = self.rowOf[b.track * 1000 + o.keyHigh]
          local lo = self.rowOf[b.track * 1000 + o.keyLow]
          if hi and lo then
            local nhi, nlo = self.rows[hi + shift], self.rows[lo + shift]
            if nhi and nlo and nhi.track == b.track and nlo.track == b.track then
              b.keyHigh, b.keyLow = nhi.key, nlo.key
            end
          end
        elseif d.kind == "b_start" then
          b.start = math.min(o.start + dt, o["end"] - 1)
        else
          b["end"] = math.max(o["end"] + dt, o.start + 1)
        end
      end
    end
  end
end

function E:mousereleased()
  local d = self.drag
  self.drag = nil
  if not d or not self.lv then return end
  local lv = self.lv
  if d.kind == "box" then
    local x0, x1 = math.min(d.x, d.x2), math.max(d.x, d.x2)
    local y0, y1 = math.min(d.y, d.y2), math.max(d.y, d.y2)
    for _, n in ipairs(lv.notes) do
      local r = self.L.rowRects[self.rowOf[n.track * 1000 + n.key]]
      local nx0 = self:xOfTick(n.tick)
      local nx1 = math.max(self:xOfTick(n.tick + n.len), nx0 + 6)
      if r and nx1 >= x0 and nx0 <= x1 and r.y + r.h >= y0 and r.y <= y1 then self.sel[n.id] = true end
    end
  elseif d.kind == "draw" and d.boxes == "rounds" then
    if math.abs(d.x2 - d.x) < 4 then return end
    local a, z = self:rowSpanInTrack(d.row, d.y2)
    self:makeRound(d.track, self:tickOfX(math.min(d.x, d.x2)), self:tickOfX(math.max(d.x, d.x2)), self.rows[z].key, self.rows[a].key)
  elseif d.kind == "draw" then
    if math.abs(d.x2 - d.x) < 4 then return end
    local a, z = self:rowSpanInTrack(d.row, d.y2)
    local t0 = self:snapTick(self:tickOfX(math.min(d.x, d.x2)))
    local t1 = self:snapTick(self:tickOfX(math.max(d.x, d.x2)))
    local b, empty, replaced
    self:edit("draw a button", function()
      b = Level.newButton(lv, { track = d.track, pad = self.lastPad or 1, start = t0, ["end"] = math.max(t1, t0 + 1),
        keyLow = self.rows[z].key, keyHigh = self.rows[a].key })
      -- tighten around the notes it caught; an empty box stays as drawn (a light with no sound)
      empty = not Level.fitButton(lv, b)
      replaced = self:replaceUnder(b)
    end)
    if empty then self:say("this button has no notes: it will light but play nothing")
    else self:say("drew a button" .. replacedNote(replaced)) end
    self.selB = { [b.id] = true }
  elseif (d.kind == "move" or d.kind == "len") and d.started then
    self:touch(true)
  elseif (d.kind == "b_move" or d.kind == "b_start" or d.kind == "b_end") and d.started then
    -- still the drag's undo step: the boxes it now covers are replaced
    local replaced = 0
    for id in pairs(d.orig) do
      local b = self:boxById(d.boxes, id)
      if b then replaced = replaced + (d.boxes == "rounds" and self:replaceRoundsUnder(b) or self:replaceUnder(b)) end
    end
    self:touch()
    self:say((d.kind == "b_move" and "moved" or "resized") .. (d.boxes == "rounds" and replacedRoundsNote(replaced) or replacedNote(replaced)))
  elseif d.kind == "vel" then
    self:touch(true)
  elseif d.kind == "slider" or d.kind == "window" or d.kind == "window_end" then
    self:touch()
  end
end

function E:mousemoved(x, y)
  self:dragTo(x, y)
end

function E:wheelmoved(_, wy)
  if not self.lv then return end
  local mx, my = love.mouse.getPosition()
  local L = self.L
  if my >= L.ruler.y and my < L.vel.y + L.vel.h and mx >= L.tlX then
    if love.keyboard.isDown("lshift", "rshift") then
      self.view.beat0 = self.view.beat0 - wy * 40 / self.view.ppb
    else
      local beat = self:beatOfX(mx)
      self.view.ppb = util.clamp(self.view.ppb * 1.15 ^ wy, 4, 3000)
      self.view.beat0 = beat - (mx - L.tlX) / self.view.ppb
    end
  end
end

------------------------------------------------------------------------
-- frame
------------------------------------------------------------------------

function E:update(dt)
  self.time = self.time + dt
  self.mixer.gain = self.J.audio.master_volume
  self.mixer:pump()
  -- the view lays the screen out when it draws; until the first draw, do it here
  if not self.L or (self.lv and not self.L.tlW) then
    local W, H = love.graphics.getDimensions()
    self.L = View.layout(self, W, H)
  end
  if not self.lv then return end
  if self.fit then
    local span = self:loopBeats()
    self.view.ppb = self.L.tlW / (span * 1.12)
    self.view.beat0 = self:windowAxis() - span * 0.06
    self.fit = false
  end
  if self.playing then self:prepareLanes() end
  local mx, my = love.mouse.getPosition()
  self.hoverRow, self.hoverNote, self.hoverButton, self.hoverRound = nil, nil, nil, nil
  if inside(mx, my, self.L.roll) or inside(mx, my, self.L.rowLabels) then
    self.hoverRow = self:rowAt(my)
    if self.mode == "lights" then self.hoverButton = self:buttonAt(mx, my)
    elseif self.mode == "rounds" then self.hoverRound = self:roundAt(mx, my)
    else self.hoverNote = self:noteAt(mx, my) end
  end
  for i = #self.flashes, 1, -1 do
    if self.time - self.flashes[i].at > 0.6 then table.remove(self.flashes, i) end
  end
end

function E:draw()
  View.draw(self)
end

return E
