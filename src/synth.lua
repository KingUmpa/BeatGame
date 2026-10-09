-- src/synth.lua
-- Sounds made in code: the metronome click.
-- Each returns a SoundData for Mixer:loadSample.

local Synth = {}

function Synth.click(rate, accent)
  local len = math.floor(rate * 0.06)
  local sd = love.sound.newSoundData(len, rate, 16, 1)
  local freq = accent and 1760 or 1320
  for i = 0, len - 1 do
    local t = i / rate
    sd:setSample(i, math.sin(2 * math.pi * freq * t) * math.exp(-t / 0.012) * (accent and 0.55 or 0.4))
  end
  return sd
end

return Synth
