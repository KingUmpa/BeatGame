-- src/transport.lua
-- Realtime playback of the document through the mixer. Playback runs in "segments" of
-- beats: from the play position to the window end, then (with loop on) the window
-- [from, to) again and again. Each block the mixer asks for, the notes and backing that
-- fall in it are scheduled at their exact frame. Everything is read live from the bench
-- state, so edits made while playing are heard on the next pass.
--
--   local t = Transport.new(bench)
--   t:play(beat) / t:stop()
--   t:beat()      -> the beat being heard now (nil when stopped)

local Transport = {}
Transport.__index = Transport

local function round(x) return math.floor(x + 0.5) end

function Transport.new(bench)
  return setmetatable({ b = bench, playing = false }, Transport)
end

function Transport:segmentFrom(frame, b0)
  local b = self.b
  local b1
  if b.loop and b0 < b.to then b1 = b.to else b1 = math.max(b0, b:endBeat()) end
  local seg = { f = frame, b0 = b0, b1 = b1, fpb = b.fpb }
  seg.len = round((b1 - b0) * seg.fpb)
  self.segs[#self.segs + 1] = seg
  return seg
end

function Transport:play(beat)
  local b, mx = self.b, self.b.mixer
  mx:reset()
  mx:setLoop(nil)
  self.playing, self.startBeat, self.segs = true, beat, {}
  self:segmentFrom(0, beat)
  mx.onBlock = function(f0, f1) self:schedule(f0, f1) end
end

function Transport:stop()
  local mx = self.b.mixer
  mx:reset()
  mx.onBlock = nil
  self.playing = false
end

function Transport:schedule(f0, f1)
  local b, mx = self.b, self.b.mixer
  local last = self.segs[#self.segs]
  while b.loop and last.f + last.len < f1 and b.to > b.from do
    last = self:segmentFrom(last.f + last.len, b.from)
  end
  for _, seg in ipairs(self.segs) do
    if seg.f < f1 and seg.f + seg.len > f0 then
      local function frameOf(beat) return seg.f + round((beat - seg.b0) * seg.fpb) end

      for _, n in ipairs(b.doc.notes) do
        local beat = n.tick / b.doc.ppq
        if beat >= seg.b0 and beat < seg.b1 and b:audible(n.key) then
          local f = frameOf(beat)
          local s = b:sampleFor(n.key)
          if s and f >= f0 and f < f1 then
            mx:play(s.sample, f, b:gainFor(n), b.choke and n.key or nil)
          end
        end
      end

      -- the backing covers the window; enter it wherever this segment does
      if b.backing and not b.backingMuted then
        local bs, be = math.max(seg.b0, b.from), math.min(seg.b1, b.to)
        if bs < be then
          local f = frameOf(bs)
          if f >= f0 and f < f1 then
            local v = mx:play(b.backing.sample, f, b.backing.gain, nil, round((bs - b.from) * seg.fpb))
            mx:stop(v, frameOf(be))
          end
        end
      end

      if b.metronome then
        for beat = math.ceil(seg.b0), math.ceil(seg.b1) - 1 do
          local f = frameOf(beat)
          if f >= f0 and f < f1 then
            local accent = (beat % 4) == 0
            mx:play(accent and b.clicks.accent or b.clicks.click, f, 0.8)
          end
        end
      end
    end
  end
end

-- the beat being heard, from the mixer clock
function Transport:beat()
  if not self.playing then return nil end
  local f = self.b.mixer:clock()
  for _, seg in ipairs(self.segs) do
    if f < seg.f + seg.len then return seg.b0 + math.max(0, f - seg.f) / seg.fpb end
  end
  local last = self.segs[#self.segs]
  return last.b1
end

-- true once a non-looping pass has played out (plus a second of tails)
function Transport:finished()
  if not self.playing or self.b.loop then return false end
  local last = self.segs[#self.segs]
  return self.b.mixer:clock() > last.f + last.len + self.b.mixer.rate
end

return Transport
