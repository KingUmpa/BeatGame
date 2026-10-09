-- src/song.lua
-- A song = a backing track + MIDI notes + a map from MIDI key to sample. The backing track
-- is the clock: timeline frame 0 is its first frame, and when it loops the notes loop with it.
--
--   local song = Song.load(require("songs.test_a"), mixer)
--   song:attach(mixer)                        -- mixer.onBlock schedules the notes
--   song:eachEvent(fromFrame, toFrame, fn)    -- fn(event, frame) for every hit in range
--   song:beatAt(frame)                        -- timeline frame -> beats from the start
--
-- Definition fields (see songs/test_a.lua):
--   bpm         tempo; defaults to the MIDI file's tempo (Ableton clip exports have none)
--   backing     { file, gain }; optional
--   midi        { file, from, to }: the beat window of the file that plays; `from` lands on
--               the backing track's frame 0
--   loop        true: the backing and notes repeat (default when there is a backing track)
--   loopBeats   loop length when there is no backing track (default to - from)
--   offset      beats added to every note (nudge to line up)
--   velocity    how much MIDI velocity scales volume, 0..1 (Simpler's "Vel > Vol")
--   choke       true: a pad cuts its own previous hit (Simpler's Retrigger)
--   pads        { [key] = { n, file, label, gain } }

local util = require("src.util")
local Midi = require("src.midi")

local Song = {}
Song.__index = Song

local function loadSound(path)
  local bytes, err = util.readFile(path)
  if not bytes then error(err, 3) end
  return love.sound.newSoundData(love.filesystem.newFileData(bytes, util.basename(path)))
end

function Song.load(def, mixer)
  local song = setmetatable({ def = def, title = def.title or "untitled" }, Song)
  song.rate = mixer.rate

  local m = Midi.load(def.midi.file)
  song.midiInfo = m
  song.bpm = def.bpm or m.bpm
  song.framesPerBeat = song.rate * 60 / song.bpm
  song.offset = def.offset or 0
  song.velocity = def.velocity or 0
  song.choke = def.choke ~= false
  song.gain = def.gain or 1

  if def.backing then
    song.backing = mixer:loadSample(loadSound(def.backing.file), util.basename(def.backing.file))
    song.backingGain = def.backing.gain or 1
  end
  song.loop = def.loop
  if song.loop == nil then song.loop = song.backing ~= nil end

  local from = def.midi.from or 0
  local to = def.midi.to or m.lengthBeats
  -- loop length comes from the audio when there is a backing track, so the notes stay
  -- locked to it across repeats even if its length is a hair off whole beats
  if song.backing then
    song.loopFrames = song.backing.frames
  else
    song.loopFrames = math.floor((def.loopBeats or (to - from)) * song.framesPerBeat + 0.5)
  end
  song.loopBeats = song.loopFrames / song.framesPerBeat

  song.pads, song.padList = {}, {}
  for key, p in pairs(def.pads) do
    local pad = {
      key = key, n = p.n, label = p.label or "", gain = p.gain or 1,
      file = p.file, name = Midi.noteName(key),
      sample = mixer:loadSample(loadSound(p.file), util.basename(p.file)),
      flash = 0, hits = 0,
    }
    song.pads[key] = pad
    song.padList[#song.padList + 1] = pad
  end
  table.sort(song.padList, function(a, b) return (a.n or a.key) < (b.n or b.key) end)
  for i, pad in ipairs(song.padList) do pad.row = i end

  song.events, song.unmapped = {}, {}
  for _, n in ipairs(m.notes) do
    if n.beat >= from and n.beat < to then
      if song.pads[n.key] then
        song.events[#song.events + 1] = {
          beat = n.beat - from, lenBeats = n.lenBeats, key = n.key, vel = n.vel, pad = song.pads[n.key],
        }
      else
        song.unmapped[n.key] = (song.unmapped[n.key] or 0) + 1
      end
    end
  end
  return song
end

function Song:frameOf(event, rep)
  return rep * self.loopFrames + math.floor((event.beat + self.offset) * self.framesPerBeat + 0.5)
end

function Song:beatAt(frame)
  return frame / self.framesPerBeat
end

-- Every hit whose frame falls in [from, to), in time order, across loop repeats.
function Song:eachEvent(from, to, fn)
  if to <= from then return end
  local r0, r1 = 0, 0
  if self.loop then
    r0 = math.max(0, math.floor(from / self.loopFrames) - 1)
    r1 = math.floor(to / self.loopFrames) + 1
  end
  for rep = r0, r1 do
    for _, e in ipairs(self.events) do
      local f = self:frameOf(e, rep)
      if f >= from and f < to then fn(e, f) end
    end
  end
end

function Song:gainFor(event)
  local v = event.vel / 127
  return self.gain * event.pad.gain * (1 - self.velocity * (1 - v))
end

function Song:attach(mixer)
  if self.backing then mixer:setLoop(self.backing, self.backingGain) end
  mixer.onBlock = function(from, to)
    self:eachEvent(from, to, function(e, f)
      mixer:play(e.pad.sample, f, self:gainFor(e), self.choke and e.key or nil)
    end)
  end
end

return Song
