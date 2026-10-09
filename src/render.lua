-- src/render.lua
-- Offline render: runs the same mixer and song scheduling as the player, but writes the
-- output to a 16-bit WAV instead of the sound card. Useful for A/B-ing against an Ableton
-- bounce, and for checking timing sample by sample.
--
--   lovec . --render=out.wav [--song=test_a] [--loops=2] [--no-backing] [--no-chops]

local ffi = require("ffi")
local util = require("src.util")
local Mixer = require("src.mixer")
local Song = require("src.song")

local Render = {}

function Render.writeWav(path, int16, frames, rate, channels)
  local f = assert(io.open(path, "wb"))
  local bytes = frames * channels * 2
  local function u32(n) return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256) end
  local function u16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
  f:write("RIFF", u32(36 + bytes), "WAVE",
    "fmt ", u32(16), u16(1), u16(channels), u32(rate), u32(rate * channels * 2), u16(channels * 2), u16(16),
    "data", u32(bytes))
  f:write(ffi.string(int16, bytes))
  f:close()
end

function Render.main(args)
  local out = util.argValue(args, "--render", "render.wav")
  if out == true then out = "render.wav" end
  local name = util.argValue(args, "--song", "test_a")
  local loops = tonumber(util.argValue(args, "--loops", "1")) or 1

  local mixer = Mixer.new{ rate = 44100, bufferFrames = 4096 }
  local song = Song.load(require("songs." .. name), mixer)
  song:attach(mixer)
  mixer.loopMuted = util.hasArg(args, "--no-backing")
  mixer.voicesMuted = util.hasArg(args, "--no-chops")

  local total = math.floor(song.loopFrames * loops)
  local buf = ffi.new("int16_t[?]", total * 2)
  local peak, clipped, reduction = 0, 0, 1
  while mixer.rendered < total do
    local start = mixer.rendered
    local n = math.min(mixer.bufferFrames, total - start)
    local mix = mixer:render(n)
    reduction = math.min(reduction, mixer.reduction)
    for i = 0, n * 2 - 1 do
      local x = mix[i]
      if x > 1 then x = 1; clipped = clipped + 1 elseif x < -1 then x = -1; clipped = clipped + 1 end
      if math.abs(x) > peak then peak = math.abs(x) end
      buf[start * 2 + i] = x * 32767
    end
  end
  Render.writeWav(out, buf, total, mixer.rate, 2)

  print(("rendered %s: %d loop(s), %.3f s, %d hits/loop, peak %.1f dBFS, limiter max %.1f dB, %d clipped samples"):format(
    out, loops, total / mixer.rate, #song.events, 20 * math.log10(math.max(peak, 1e-9)),
    20 * math.log10(reduction), clipped))
  -- the hit list, for checking against the audio
  local list = io.open(out .. ".hits.txt", "w")
  song:eachEvent(0, total, function(e, f)
    list:write(("%d\t%.4f\t%d\t%d\t%d\n"):format(f, f / mixer.rate, e.key, e.pad.n or 0, e.vel))
  end)
  list:close()
  love.event.quit(0)
end

return Render
