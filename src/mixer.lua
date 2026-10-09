-- src/mixer.lua
-- Sample-accurate software mixer feeding one QueueableSource.
--
-- Source:play() only takes effect on OpenAL's next mix period, and love.update runs once a
-- frame, so notes fired that way land up to a frame plus a period late (20-40 ms, varying
-- hit to hit). Here every sample is decoded once to float at the mixer rate and the mixer
-- writes the output stream itself: a hit scheduled at frame N starts at exactly frame N.
-- The same code renders offline for --render and the tests.
--
-- The master bus runs through a lookahead peak limiter (like the limiter on an Ableton
-- master), because the chops summed onto an already-mastered backing track go over 0 dBFS.
-- Mixing runs LOOKAHEAD frames ahead of the output to feed it, so output frame N is still
-- timeline frame N.
--
--   local mx = Mixer.new{ rate = 44100 }
--   local s  = mx:loadSample(soundData)       -- float stereo at mx.rate
--   mx:setLoop(s, gain, start, stop, origin)  -- backing track, repeating from `start`
--   mx:play(s, atFrame, gain, choke, offset)  -- schedule a one-shot (atFrame >= mx.cursor),
--                                             -- optionally starting `offset` frames in
--   mx:stop(voice, atFrame)                   -- fade a voice out
--   mx.onBlock = function(from, to) end       -- called before frames [from, to) are mixed
--   mx:pump()                                 -- realtime: keep the device queue full
--   mx:clock()                                -- frame the listener is hearing now
--   mx:render(n)                              -- offline: output n frames, return float* (n*2)

local ffi = require("ffi")

local Mixer = {}
Mixer.__index = Mixer

local FADE = 256        -- frames (~6 ms) to fade out a choked voice instead of clicking
local LOOKAHEAD = 64    -- frames (~1.5 ms) the limiter sees ahead
local CEILING = 10 ^ (-0.3 / 20)

function Mixer.new(opts)
  opts = opts or {}
  local mx = setmetatable({}, Mixer)
  mx.rate = opts.rate or 44100
  mx.bufferFrames = math.max(opts.bufferFrames or 512, LOOKAHEAD)
  mx.bufferCount = opts.bufferCount or 4
  mx.voices = {}
  mx.loop = nil
  mx.loopMuted = false
  mx.voicesMuted = false
  mx.gain = opts.gain or 1
  mx.onBlock = nil
  mx.mix = ffi.new("float[?]", mx.bufferFrames * 2)
  mx.peak = 0
  mx.ring = ffi.new("float[?]", (LOOKAHEAD + 1) * 2)   -- limiter delay line
  mx.need = ffi.new("float[?]", LOOKAHEAD + 1)         -- gain each frame in it needs
  -- attack gets 99.9% of the way down within the lookahead; release over ~100 ms
  mx.attack = 1 - 0.001 ^ (1 / LOOKAHEAD)
  mx.release = 1 - math.exp(-1 / (0.1 * mx.rate))
  mx:reset()
  return mx
end

-- SoundData (any rate, mono or stereo, 8/16 bit) -> { data = float*, frames, rate }.
-- Resamples with linear interpolation when the rate differs from the mixer's.
function Mixer:loadSample(sd, name)
  local frames, channels, rate = sd:getSampleCount(), sd:getChannelCount(), sd:getSampleRate()
  local src = ffi.new("float[?]", frames * 2)
  if sd:getBitDepth() == 16 then
    local p = ffi.cast("int16_t*", sd:getFFIPointer())
    for i = 0, frames - 1 do
      local l = p[i * channels] / 32768
      src[i * 2] = l
      src[i * 2 + 1] = channels > 1 and p[i * channels + 1] / 32768 or l
    end
  else
    for i = 0, frames - 1 do
      local l = sd:getSample(i, 1)
      src[i * 2] = l
      src[i * 2 + 1] = channels > 1 and sd:getSample(i, 2) or l
    end
  end

  if rate == self.rate then
    return { data = src, frames = frames, rate = self.rate, name = name, sourceRate = rate, sourceFrames = frames, sourceChannels = channels }
  end
  local outFrames = math.floor(frames * self.rate / rate)
  local out = ffi.new("float[?]", outFrames * 2)
  local step = rate / self.rate
  for j = 0, outFrames - 1 do
    local x = j * step
    local i = math.floor(x)
    local f = x - i
    local i1 = math.min(i + 1, frames - 1)
    out[j * 2] = src[i * 2] * (1 - f) + src[i1 * 2] * f
    out[j * 2 + 1] = src[i * 2 + 1] * (1 - f) + src[i1 * 2 + 1] * f
  end
  return { data = out, frames = outFrames, rate = self.rate, name = name, sourceRate = rate, sourceFrames = frames, sourceChannels = channels }
end

-- The backing track: plays from timeline frame `start` (default 0), repeating, until
-- frame `stop` (default never). `origin` (default `start`) is the frame its first frame lines
-- up with: a loop that comes in late can still be in phase with the timeline's beat 0.
function Mixer:setLoop(sample, gain, start, stop, origin)
  self.loop = sample and { sample = sample, gain = gain or 1, start = start or 0, stop = stop or math.huge, origin = origin or start or 0 } or nil
end

-- Schedule a one-shot. A chokeGroup cuts any earlier voice in the same group at atFrame,
-- the way Simpler's Retrigger cuts a pad's previous hit. The same sample struck twice on one
-- frame in one group (two keys of a chord sharing a sample) is one hit, not twice as loud.
function Mixer:play(sample, atFrame, gain, chokeGroup, offset, fx)
  atFrame = math.max(atFrame or self.cursor, self.cursor)
  if chokeGroup ~= nil then
    if not fx and (offset or 0) == 0 then
      for _, v in ipairs(self.voices) do
        if v.choke == chokeGroup and v.s == sample and v.start == atFrame and not v.fx and v.offset == 0 then
          v.gain = math.max(v.gain, gain or 1)
          return v
        end
      end
    end
    for _, v in ipairs(self.voices) do
      if v.choke == chokeGroup and v.start < atFrame and (not v.stopAt or v.stopAt > atFrame) then
        v.stopAt = atFrame
      end
    end
  end
  -- offset: start this many frames into the sample
  local v = { s = sample, start = atFrame, gain = gain or 1, choke = chokeGroup, offset = offset or 0 }
  if fx then v.fx = self:prepareFx(fx) end
  self.voices[#self.voices + 1] = v
  return v
end

-- Per-voice processing, for the "wrong hit" sound:
--   rate      playback speed; 2^(semitones/12) shifts pitch (and length) like a tape
--   lowpass   cutoff in Hz of a 12 dB/octave resonant low-pass (RBJ biquad), q its resonance
--   drive     tanh distortion, 1 = clean; unity gain for quiet audio, so it adds grit
--             and squashes peaks but never makes the sound louder
function Mixer:prepareFx(fx)
  local p = { rate = fx.rate or 1, drive = fx.drive or 1, zl1 = 0, zl2 = 0, zr1 = 0, zr2 = 0 }
  if fx.lowpass and fx.lowpass < self.rate * 0.45 then
    local w0 = 2 * math.pi * fx.lowpass / self.rate
    local alpha = math.sin(w0) / (2 * (fx.q or 0.707))
    local c = math.cos(w0)
    local a0 = 1 + alpha
    p.b0, p.b1, p.b2 = (1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0
    p.a1, p.a2 = -2 * c / a0, (1 - alpha) / a0
  end
  p.driveNorm = 1 / p.drive
  return p
end

-- Fade a voice out from atFrame (default: as soon as possible).
function Mixer:stop(v, atFrame)
  atFrame = math.max(atFrame or self.cursor, self.cursor)
  if not v.stopAt or v.stopAt > atFrame then v.stopAt = atFrame end
end

-- Mix timeline frames [cursor, cursor + n) into self.mix, pre-limiter, and advance the cursor.
function Mixer:mixRaw(n)
  local from, to = self.cursor, self.cursor + n
  if self.onBlock then self.onBlock(from, to) end

  local out = self.mix
  for i = 0, n * 2 - 1 do out[i] = 0 end

  local loop = self.loop
  if loop and not self.loopMuted then
    local d, len, g = loop.sample.data, loop.sample.frames, loop.gain
    local a, b = math.max(from, loop.start), math.min(to, loop.stop)
    local p = (a - loop.origin) % len
    for i = a - from, b - from - 1 do
      out[i * 2] = out[i * 2] + d[p * 2] * g
      out[i * 2 + 1] = out[i * 2 + 1] + d[p * 2 + 1] * g
      p = p + 1
      if p == len then p = 0 end
    end
  end

  local keep = {}
  for _, v in ipairs(self.voices) do
    local s = v.s
    local stopEnd = v.stopAt and (v.stopAt + FADE) or math.huge
    local vEnd
    if v.fx then
      vEnd = self:mixFxVoice(v, out, from, to, stopEnd)
    else
      vEnd = math.min(v.start + s.frames - v.offset, stopEnd)
      if not self.voicesMuted then
        local a, b = math.max(from, v.start), math.min(to, vEnd)
        local d, g, start, stopAt = s.data, v.gain, v.start - v.offset, v.stopAt
        for f = a, b - 1 do
          local gf = g
          if stopAt and f >= stopAt then gf = g * (1 - (f - stopAt) / FADE) end
          local i, j = (f - from) * 2, (f - start) * 2
          out[i] = out[i] + d[j] * gf
          out[i + 1] = out[i + 1] + d[j + 1] * gf
        end
      end
    end
    if vEnd > to then keep[#keep + 1] = v end
  end
  self.voices = keep
  self.cursor = to
  return out
end

-- The slow path for a voice with fx: fractional read position (linear interpolation),
-- then the filter and the drive, both stateful across blocks. Returns where the voice ends.
function Mixer:mixFxVoice(v, out, from, to, stopEnd)
  local s, fx = v.s, v.fx
  local rate = fx.rate
  local last = math.floor((s.frames - 2 - v.offset) / rate)
  local vEnd = math.min(v.start + last + 1, stopEnd)
  if self.voicesMuted then return vEnd end
  local a, b = math.max(from, v.start), math.min(to, vEnd)
  local d, g, stopAt = s.data, v.gain, v.stopAt
  local b0, b1, b2, a1, a2 = fx.b0, fx.b1, fx.b2, fx.a1, fx.a2
  local zl1, zl2, zr1, zr2 = fx.zl1, fx.zl2, fx.zr1, fx.zr2
  local drive, norm = fx.drive, fx.driveNorm
  local tanh, floor = math.tanh, math.floor
  for f = a, b - 1 do
    local pos = v.offset + (f - v.start) * rate
    local i = floor(pos)
    local t = pos - i
    local j = i * 2
    local l = d[j] + (d[j + 2] - d[j]) * t
    local r = d[j + 1] + (d[j + 3] - d[j + 1]) * t
    if b0 then
      local yl = b0 * l + zl1
      zl1 = b1 * l - a1 * yl + zl2
      zl2 = b2 * l - a2 * yl
      local yr = b0 * r + zr1
      zr1 = b1 * r - a1 * yr + zr2
      zr2 = b2 * r - a2 * yr
      l, r = yl, yr
    end
    if drive > 1 then
      l, r = tanh(l * drive) * norm, tanh(r * drive) * norm
    end
    local gf = g
    if stopAt and f >= stopAt then gf = g * (1 - (f - stopAt) / FADE) end
    local o = (f - from) * 2
    out[o] = out[o] + l * gf
    out[o + 1] = out[o + 1] + r * gf
  end
  fx.zl1, fx.zl2, fx.zr1, fx.zr2 = zl1, zl2, zr1, zr2
  return vEnd
end

-- Run n frames of self.mix through master gain and the limiter, in place. The limiter
-- delays by LOOKAHEAD frames: each frame out is the one that went in LOOKAHEAD frames ago,
-- scaled by a gain that has had those frames to settle on the lowest gain any of them needs.
function Mixer:limit(n)
  local out, ring, need, L = self.mix, self.ring, self.need, LOOKAHEAD
  local g, pos, gain, over = self.gain, self.ringPos, self.limGain, self.overCount
  local attack, release, peak, minGain = self.attack, self.release, 0, 1
  for i = 0, n - 1 do
    local l, r = out[i * 2] * g, out[i * 2 + 1] * g
    local p = math.max(math.abs(l), math.abs(r))
    local req = p > CEILING and CEILING / p or 1
    if need[pos] < 1 then over = over - 1 end
    if req < 1 then over = over + 1 end
    ring[pos * 2], ring[pos * 2 + 1], need[pos] = l, r, req
    pos = pos + 1
    if pos > L then pos = 0 end

    local target = 1
    if over > 0 then
      for k = 0, L do
        if need[k] < target then target = need[k] end
      end
    end
    if target < gain then
      gain = gain + (target - gain) * attack
    else
      gain = gain + (target - gain) * release
    end
    -- the attack curve is exponential, so make sure the frame leaving now fits
    if need[pos] < gain then gain = need[pos] end
    if gain < minGain then minGain = gain end

    local ol, orr = ring[pos * 2] * gain, ring[pos * 2 + 1] * gain
    out[i * 2], out[i * 2 + 1] = ol, orr
    local a = math.max(math.abs(ol), math.abs(orr))
    if a > peak then peak = a end
  end
  self.ringPos, self.limGain, self.overCount = pos, gain, over
  self.peak, self.reduction = peak, minGain
  return out
end

-- Produce the next n output frames (n <= bufferFrames): float* of n*2, output frame
-- self.rendered onward.
function Mixer:mixBlock(n)
  if not self.primed then
    self.primed = true
    self:mixRaw(LOOKAHEAD)
    self:limit(LOOKAHEAD)   -- fills the delay line; its output is the silence before frame 0
  end
  self:mixRaw(n)
  local out = self:limit(n)
  self.rendered = self.rendered + n
  return out
end

-- Offline: output n frames and return the float buffer.
function Mixer:render(n)
  return self:mixBlock(math.min(n or self.bufferFrames, self.bufferFrames))
end

------------------------------------------------------------------------
-- realtime output
------------------------------------------------------------------------

function Mixer:pump()
  if not self.source then
    self.source = love.audio.newQueueableSource(self.rate, 16, 2, self.bufferCount)
    self.out = love.sound.newSoundData(self.bufferFrames, self.rate, 16, 2)
    self.outPtr = ffi.cast("int16_t*", self.out:getFFIPointer())
    self.queuedAt = {}   -- timeline frame each queued buffer starts at, oldest first
  end
  if self.paused then return end

  self:prune()
  while self.source:getFreeBufferCount() > 0 do
    local out, dst = self:mixBlock(self.bufferFrames), self.outPtr
    for i = 0, self.bufferFrames * 2 - 1 do
      local x = out[i]
      if x > 1 then x = 1 elseif x < -1 then x = -1 end
      dst[i] = x * 32767
    end
    self.queuedAt[#self.queuedAt + 1] = self.rendered - self.bufferFrames
    self.source:queue(self.out)
  end
  if not self.source:isPlaying() then self.source:play() end
end

-- Forget buffers LÖVE has taken back from OpenAL (they show up as free buffers).
function Mixer:prune()
  local inQueue = self.bufferCount - self.source:getFreeBufferCount()
  while #self.queuedAt > inQueue do table.remove(self.queuedAt, 1) end
end

-- The frame being heard. For a queueable source, tell() counts from the head of OpenAL's
-- queue (finished-but-not-yet-reclaimed buffers included) and only moves once per OpenAL
-- mix period (~20 ms), so this adds the wall time since it last moved, and never steps
-- back by less than 50 ms (small reorderings between tell() and the free-buffer count).
function Mixer:clock()
  if not self.source or #self.queuedAt == 0 then return self.rendered end
  self:prune()
  if #self.queuedAt == 0 then return self.rendered end
  local raw = self.queuedAt[1] + self.source:tell("samples")
  local now = love.timer.getTime()
  if raw ~= self.rawClock then self.rawClock, self.rawAt = raw, now end
  local est = raw
  if not self.paused then est = raw + math.min(now - self.rawAt, 0.05) * self.rate end
  local last = self.lastClock
  if last and est < last and last - est < self.rate * 0.05 then est = last end
  self.lastClock = est
  return est
end

-- Seconds between a live hit (scheduled at the cursor) and hearing it.
function Mixer:latency()
  return (self.cursor - self:clock()) / self.rate
end

function Mixer:setPaused(p)
  self.paused = p
  self.rawAt = love.timer.getTime()
  if self.source then
    if p then self.source:pause() else self.source:play() end
  end
end

-- Back to frame 0 with nothing playing.
-- Silence everything and restart the timeline at `frame` (default 0); starting part-way in
-- is how the juice editor drops straight into the middle of a round.
function Mixer:reset(frame)
  frame = frame or 0
  if self.source then self.source:stop() end
  self.queuedAt = {}
  self.voices = {}
  self.rendered = frame   -- next frame to output
  self.cursor = frame     -- next timeline frame to mix (runs LOOKAHEAD ahead once primed)
  self.primed = false
  self.lastClock, self.rawClock = nil, nil
  for i = 0, LOOKAHEAD do
    self.ring[i * 2], self.ring[i * 2 + 1], self.need[i] = 0, 0, 1
  end
  self.ringPos, self.limGain, self.overCount, self.reduction = 0, 1, 0, 1
end

return Mixer
