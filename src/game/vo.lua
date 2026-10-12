-- src/game/vo.lua
-- The voice: the spoken lines that stand in for the screen, one .wav each in
-- assets/audio/vo/ (<name>.wav). A line with no file is simply not said.
--
-- The mixer turns everything else down while a line is said (voice.over, mixer.duck): summed
-- onto the music at full level the two overdrive the master limiter and the voice crunches.
--
-- Lines never talk over each other: one asked for while another is still playing waits for
-- it to end, or (given `late`) is dropped if by then it would come too late to mean anything.
--
--   local vo = Vo.new(mixer)
--   vo:say("perfect", gain)                    -- now, or as soon as the voice is free
--   vo:say("watch", gain, atFrame, lateFrames) -- at a frame; dropped if it would slip more
--   vo:play(sample, gain, atFrame, lateFrames) -- the same for a sample loaded elsewhere
--   vo:has("locked_bass")
--   vo:clear()                                 -- after mixer:reset(): nothing is playing
--   vo:aside("paused", volume)                 -- not through the mixer (it is paused)
--   Vo.slug("Vocal Chops")                     -- "vocal_chops": a level or song name in a file name

local util = require("src.util")
local Level = require("src.game.level")

local Vo = {}
Vo.__index = Vo

Vo.DIR = "assets/audio/vo/"
local GAP = 0.08   -- seconds of air between two lines

function Vo.slug(name)
  return (tostring(name):lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end

function Vo.new(mixer)
  return setmetatable({ mixer = mixer, busyUntil = 0, asides = {} }, Vo)
end

function Vo:sample(name)
  return Level.loadSample(self.mixer, Vo.DIR .. name .. ".wav", true)
end

function Vo:has(name)
  return love.filesystem.getInfo(Vo.DIR .. name .. ".wav") ~= nil
end

function Vo:clear()
  self.busyUntil = 0
end

-- returns the frame the line ends on, or nil if it was not said
function Vo:play(sample, gain, atFrame, lateFrames)
  if not sample then return nil end
  local mx = self.mixer
  local want = math.max(atFrame or mx.cursor, mx.cursor)
  local start = math.max(want, self.busyUntil + math.floor(GAP * mx.rate))
  if lateFrames and start - want > lateFrames then return nil end
  mx:play(sample, start, gain).over = true
  self.busyUntil = start + sample.frames
  return self.busyUntil
end

function Vo:say(name, gain, atFrame, lateFrames)
  if not self:has(name) then return nil end
  return self:play(self:sample(name), gain, atFrame, lateFrames)
end

function Vo:aside(name, volume)
  if not (love.audio and self:has(name)) then return end
  if self.asides[name] == nil then
    local ok, src = pcall(function()
      local file = Vo.DIR .. name .. ".wav"
      return love.audio.newSource(love.sound.newSoundData(love.filesystem.newFileData(assert(util.readFile(file)), name .. ".wav")))
    end)
    self.asides[name] = ok and src or false
  end
  local src = self.asides[name]
  if not src then return end
  for _, other in pairs(self.asides) do if other then other:stop() end end
  src:setVolume(math.max(0, math.min(1, volume or 1)))
  src:play()
end

return Vo
