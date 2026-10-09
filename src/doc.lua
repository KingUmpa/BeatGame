-- src/doc.lua
-- The editable MIDI document: notes with stable ids, undo/redo, and the bytes they encode
-- to. No LÖVE calls, so the tests drive it directly.
--
--   local doc = Doc.new(Midi.parse(bytes))
--   doc:edit("nudge", function() ... change doc.notes ... end)   -- one undo step
--   doc:begin("drag") ... doc:touch() ... doc:touch()           -- one step over many changes
--   doc:undo() / doc:redo()
--   doc:bytes()      -> what saving writes (Midi.encode of the current notes)
--   doc:file()       -> Midi.parse(doc:bytes()): the events exactly as they would be saved
--   doc:changed(n)   -> "moved" / "velocity" / "length" / "key" / "added" / nil vs the original
--   doc.removed      -> original notes no longer in the document
--
-- A note: { id, tick, len, key, vel, ch, offVel }. doc.notes stays sorted by tick.

local Midi = require("src.midi")

local Doc = {}
Doc.__index = Doc

local function copyNote(n)
  return { id = n.id, tick = n.tick, len = n.len, key = n.key, vel = n.vel, ch = n.ch, offVel = n.offVel }
end

local function copyAll(list)
  local out = {}
  for i, n in ipairs(list) do out[i] = copyNote(n) end
  return out
end

function Doc.new(m)
  local doc = setmetatable({ ppq = m.ppq, metas = m.metas, source = m }, Doc)
  doc.notes, doc.original = {}, {}
  for i, n in ipairs(m.notes) do
    local note = { id = i, tick = n.tick, len = n.len, key = n.key, vel = n.vel, ch = n.ch, offVel = n.offVel or 64 }
    doc.notes[i] = note
    doc.original[i] = copyNote(note)
  end
  doc.nextId = #m.notes + 1
  doc.undoStack, doc.redoStack = {}, {}
  doc.version, doc.savedVersion = 0, 0
  doc:refresh()
  return doc
end

function Doc:sort()
  table.sort(self.notes, function(a, b)
    if a.tick ~= b.tick then return a.tick < b.tick end
    if a.key ~= b.key then return a.key < b.key end
    return a.id < b.id
  end)
end

-- rebuild lookups and the removed list after any change
function Doc:refresh()
  self:sort()
  self.byId = {}
  for _, n in ipairs(self.notes) do self.byId[n.id] = n end
  self.removed = {}
  for id, o in pairs(self.original) do
    if not self.byId[id] then self.removed[#self.removed + 1] = o end
  end
  self.cache = nil
end

-- An undo step can span many changes (a mouse drag): begin() saves the state to go back
-- to, touch() publishes each change. edit() does both around one function.
function Doc:begin(label)
  table.insert(self.undoStack, { label = label, notes = copyAll(self.notes), nextId = self.nextId })
  if #self.undoStack > 200 then table.remove(self.undoStack, 1) end
  self.redoStack = {}
end

function Doc:touch()
  for _, n in ipairs(self.notes) do
    n.tick = math.max(0, math.floor(n.tick + 0.5))
    n.len = math.max(1, math.floor(n.len + 0.5))
    n.vel = math.max(1, math.min(127, math.floor(n.vel + 0.5)))
    n.key = math.max(0, math.min(127, n.key))
  end
  self.version = self.version + 1
  self:refresh()
end

function Doc:edit(label, fn)
  self:begin(label)
  fn(self)
  self:touch()
  return label
end

local function swap(self, from, to)
  local step = table.remove(from)
  if not step then return nil end
  table.insert(to, { label = step.label, notes = copyAll(self.notes), nextId = self.nextId })
  self.notes, self.nextId = step.notes, step.nextId
  self.version = self.version + 1
  self:refresh()
  return step.label
end

function Doc:undo() return swap(self, self.undoStack, self.redoStack) end
function Doc:redo() return swap(self, self.redoStack, self.undoStack) end

function Doc:dirty() return self.version ~= self.savedVersion end

function Doc:add(tick, key, len, vel, ch)
  local n = { id = self.nextId, tick = tick, len = len, key = key, vel = vel, ch = ch or 0, offVel = 64 }
  self.nextId = self.nextId + 1
  self.notes[#self.notes + 1] = n
  return n
end

function Doc:remove(ids)
  local keep = {}
  for _, n in ipairs(self.notes) do
    if not ids[n.id] then keep[#keep + 1] = n end
  end
  self.notes = keep
end

function Doc:changed(n)
  local o = self.original[n.id]
  if not o then return "added" end
  if o.tick ~= n.tick then return "moved" end
  if o.key ~= n.key then return "key" end
  if o.len ~= n.len then return "length" end
  if o.vel ~= n.vel then return "velocity" end
  return nil
end

function Doc:bytes()
  self.cache = self.cache or {}
  if not self.cache.bytes then
    self.cache.bytes = Midi.encode({ ppq = self.ppq, metas = self.metas, notes = self.notes })
  end
  return self.cache.bytes
end

-- the saved-file view, with each note's on/off events found by id
function Doc:file()
  self.cache = self.cache or {}
  if not self.cache.file then
    local f = Midi.parse(self:bytes())
    -- Midi.parse sorts notes by tick then key, the same order as doc.notes
    f.eventsOf = {}
    for i, n in ipairs(f.notes) do
      local mine = self.notes[i]
      if mine then f.eventsOf[mine.id] = { on = n.on, off = n.off } end
      if n.on then n.on.noteId = mine and mine.id end
      if n.off then n.off.noteId = mine and mine.id end
    end
    self.cache.file = f
  end
  return self.cache.file
end

function Doc:lengthTicks()
  local last = 0
  for _, n in ipairs(self.notes) do last = math.max(last, n.tick + n.len) end
  return last
end

return Doc
