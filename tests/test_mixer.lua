-- tests/test_mixer.lua

local Mixer = require("src.mixer")

-- a stereo 16-bit SoundData from a function of frame index
local function sound(frames, rate, fn)
  local sd = love.sound.newSoundData(frames, rate, 16, 2)
  for i = 0, frames - 1 do
    local v = fn(i)
    sd:setSample(i, 1, v)
    sd:setSample(i, 2, v)
  end
  return sd
end

-- mix `frames` frames and return the left channel as a Lua array indexed by frame
local function run(mx, frames)
  local left = {}
  while mx.rendered < frames do
    local start = mx.rendered
    local n = math.min(mx.bufferFrames, frames - start)
    local out = mx:render(n)
    for i = 0, n - 1 do left[start + i] = out[i * 2] end
  end
  return left
end

local tests = {}

function tests.hit_starts_on_its_exact_frame(T)
  local mx = Mixer.new{ rate = 44100, bufferFrames = 256 }
  local click = mx:loadSample(sound(8, 44100, function(i) return i == 0 and 0.5 or 0 end))
  mx:play(click, 1000, 1.0)        -- 1000 is mid-block (256-frame blocks)
  local left = run(mx, 2048)
  T.near(left[999], 0, 1e-9)
  T.near(left[1000], 0.5, 1e-4)
  T.near(left[1001], 0, 1e-9)
end

function tests.on_block_schedules_inside_the_block(T)
  local mx = Mixer.new{ rate = 44100, bufferFrames = 256 }
  local click = mx:loadSample(sound(4, 44100, function(i) return i == 0 and 0.25 or 0 end))
  local wanted = { 10, 300, 777 }
  mx.onBlock = function(from, to)
    for _, f in ipairs(wanted) do
      if f >= from and f < to then mx:play(click, f, 1) end
    end
  end
  local left = run(mx, 1024)
  for _, f in ipairs(wanted) do T.near(left[f], 0.25, 1e-4, "frame " .. f) end
  T.near(left[11], 0, 1e-9)
end

function tests.choke_fades_the_earlier_voice_out(T)
  local mx = Mixer.new{ rate = 44100, bufferFrames = 512 }
  local dc = mx:loadSample(sound(4000, 44100, function() return 0.25 end))
  mx:play(dc, 0, 1, "pad")
  mx:play(dc, 1000, 1, "pad")
  local left = run(mx, 3000)
  T.near(left[999], 0.25, 1e-4, "only the first voice before the second hit")
  T.near(left[1000], 0.5, 1e-4, "both at the hit, fade just starting")
  T.near(left[1000 + 256], 0.25, 1e-4, "first voice gone after the fade")
  T.eq(#mx.voices, 1)
end

function tests.limiter_holds_the_ceiling_and_leaves_quiet_audio_alone(T)
  local mx = Mixer.new{ rate = 44100, bufferFrames = 512 }
  local dc = mx:loadSample(sound(20000, 44100, function(i) return i % 2 == 0 and 0.8 or -0.8 end))
  mx:play(dc, 2000, 1)
  mx:play(dc, 2000, 1)   -- 1.6 summed
  local left = run(mx, 8000)
  local peak = 0
  for f = 0, 7999 do peak = math.max(peak, math.abs(left[f])) end
  T.ok(peak <= 10 ^ (-0.3 / 20) + 1e-3, "peak " .. peak .. " over the -0.3 dBFS ceiling")
  T.near(math.abs(left[2000]), 0.966, 0.01, "already down at the first loud frame (lookahead)")
  T.near(math.abs(left[1999]), 0, 1e-9, "silence before the hit stays silence")

  local quiet = Mixer.new{ rate = 44100, bufferFrames = 512 }
  local s = quiet:loadSample(sound(1000, 44100, function(i) return (i % 100) / 200 end))
  quiet:play(s, 0, 1)
  local q = run(quiet, 1000)
  for _, f in ipairs({ 0, 50, 99, 150, 999 }) do T.near(q[f], (f % 100) / 200, 1e-4, "frame " .. f) end
end

-- an exclusive level: different samples, one group; a voice on the same frame isn't cut
function tests.shared_choke_cuts_a_different_sample(T)
  local mx = Mixer.new{ rate = 44100, bufferFrames = 512 }
  local a = mx:loadSample(sound(4000, 44100, function() return 0.25 end))
  local b = mx:loadSample(sound(4000, 44100, function() return 0.125 end))
  mx:play(a, 0, 1, "exclusive")
  mx:play(b, 0, 1, "exclusive")
  mx:play(b, 1000, 1, "exclusive")
  local left = run(mx, 2000)
  T.near(left[500], 0.375, 1e-4, "same-frame notes sound together")
  T.near(left[1500], 0.125, 1e-4, "only the newest note after the fade")
end

-- two keys of a chord sharing one sample, struck together in one group: one hit, not double
function tests.one_sample_twice_on_a_frame_in_a_group_is_one_hit(T)
  local mx = Mixer.new{ rate = 44100, bufferFrames = 512 }
  local a = mx:loadSample(sound(4000, 44100, function() return 0.25 end))
  mx:play(a, 100, 1, "g")
  mx:play(a, 100, 0.5, "g")
  T.eq(#mx.voices, 1)
  T.near(run(mx, 1000)[500], 0.25, 1e-4)
  local mx2 = Mixer.new{ rate = 44100, bufferFrames = 512 }
  local b = mx2:loadSample(sound(4000, 44100, function() return 0.25 end))
  mx2:play(b, 100, 1, "g")
  mx2:play(b, 100, 1, "h")
  T.near(run(mx2, 1000)[500], 0.5, 1e-4, "different groups still sum")
end

function tests.without_choke_voices_overlap(T)
  local mx = Mixer.new{ rate = 44100, bufferFrames = 512 }
  local dc = mx:loadSample(sound(4000, 44100, function() return 0.25 end))
  mx:play(dc, 0, 1)
  mx:play(dc, 1000, 1)
  local left = run(mx, 2000)
  T.near(left[1500], 0.5, 1e-4)
end

function tests.resamples_48k_to_mixer_rate(T)
  local mx = Mixer.new{ rate = 44100 }
  local s = mx:loadSample(sound(48000, 48000, function(i) return (i % 480) / 480 * 0.5 end))
  T.eq(s.frames, 44100)
  T.eq(s.sourceRate, 48000)
end

function tests.backing_loops_seamlessly(T)
  local mx = Mixer.new{ rate = 44100, bufferFrames = 256 }
  local ramp = mx:loadSample(sound(300, 44100, function(i) return i / 1000 end))
  mx:setLoop(ramp, 1)
  local left = run(mx, 1024)
  for _, f in ipairs({ 0, 299, 300, 301, 599, 600, 1000 }) do
    T.near(left[f], (f % 300) / 1000, 1e-4, "frame " .. f)
  end
end

-- the wrong-hit processing

local function rms(left, a, b)
  local s = 0
  for f = a, b - 1 do s = s + left[f] ^ 2 end
  return math.sqrt(s / (b - a))
end

function tests.pitch_down_plays_longer_and_reads_between_frames(T)
  local mx = Mixer.new{ rate = 44100, bufferFrames = 256 }
  local ramp = mx:loadSample(sound(1000, 44100, function(i) return i / 2000 end))
  mx:play(ramp, 0, 1, nil, 0, { rate = 0.5 })   -- an octave down
  local left = run(mx, 2200)
  T.near(left[1], 0.00025, 1e-4, "halfway between frames 0 and 1")
  T.near(left[1000], 0.25, 1e-3, "frame 1000 plays sample 500")
  T.near(left[1999], 0, 1e-9, "ended after twice the length")
end

function tests.lowpass_cuts_highs_and_keeps_lows(T)
  local mx = Mixer.new{ rate = 44100, bufferFrames = 256 }
  -- a 9 kHz tone and a 100 Hz tone, through a 500 Hz low-pass
  local hi = mx:loadSample(sound(4410, 44100, function(i) return 0.4 * math.sin(2 * math.pi * 9000 * i / 44100) end))
  local lo = mx:loadSample(sound(4410, 44100, function(i) return 0.4 * math.sin(2 * math.pi * 100 * i / 44100) end))
  mx:play(hi, 0, 1, nil, 0, { lowpass = 500, q = 0.707 })
  local a = run(mx, 4410)
  local mx2 = Mixer.new{ rate = 44100, bufferFrames = 256 }
  mx2:play(mx2:loadSample(sound(4410, 44100, function(i) return 0.4 * math.sin(2 * math.pi * 100 * i / 44100) end)), 0, 1, nil, 0, { lowpass = 500, q = 0.707 })
  local b = run(mx2, 4410)
  T.ok(rms(a, 2000, 4400) < 0.005, "9 kHz down to " .. rms(a, 2000, 4400))
  T.ok(rms(b, 2000, 4400) > 0.25, "100 Hz kept at " .. rms(b, 2000, 4400))
  T.ok(lo ~= nil)
end

function tests.drive_squashes_loud_audio(T)
  local mx = Mixer.new{ rate = 44100, bufferFrames = 256 }
  local s = mx:loadSample(sound(500, 44100, function(i) return i % 2 == 0 and 0.5 or -0.5 end))
  mx:play(s, 0, 1, nil, 0, { drive = 20 })
  local left = run(mx, 400)
  -- tanh(20 * 0.5) / 20: flattened to a square, and never louder than it went in
  T.near(math.abs(left[10]), 1 / 20, 1e-3, "squashed")
  local quiet = Mixer.new{ rate = 44100, bufferFrames = 256 }
  quiet:play(quiet:loadSample(sound(500, 44100, function() return 0.001 end)), 0, 1, nil, 0, { drive = 20 })
  T.near(run(quiet, 400)[10], 0.001, 5e-5, "quiet audio passes at unity (16-bit rounding aside)")
end

return tests
