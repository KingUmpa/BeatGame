-- src/export.lua
-- Renders a level, or a song's levels layered, to WAV through the game's own mixer: every MIDI
-- note in each level's stretch through its sample at its velocity, each level looping its own
-- length on the song's grid, a backing track if asked for, the same choke and limiter, volumes
-- from juice.json's audio section. Files go to exports/.
--
--   lovec . --export                       the first song (else the first level), with and without backing
--   Ctrl+E in the level editor             the open level or song, with and without backing
--
--   Export.level(level, J, { backing = true, passes = 1 }) -> path, seconds
--   Export.song(song, J, { backing = true, beats = 32 }) -> path, seconds

local ffi = require("ffi")
local util = require("src.util")
local Mixer = require("src.mixer")
local Level = require("src.game.level")

local Export = {}

local RATE = 44100
local TAIL_S = 1.5   -- let the last hits ring out after the end

local function writeWav(path, pcm, frames)
  local f, err = io.open(path, "wb")
  if not f then return nil, err end
  local bytes = frames * 4
  local function u32(n) return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256) end
  local function u16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
  f:write("RIFF", u32(36 + bytes), "WAVE",
    "fmt ", u32(16), u16(1), u16(2), u32(RATE), u32(RATE * 4), u16(4), u16(16),
    "data", u32(bytes))
  f:write(ffi.string(pcm, bytes))
  f:close()
  return true
end

local function slug(s)
  return (s:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end

-- levels layered, each looping its own length from beat 0, for `beats` beats at `bpm`
local function render(levels, bpm, beats, J, opts)
  local A = J.audio
  local mx = Mixer.new{ rate = RATE, bufferFrames = 4096 }
  mx.gain = A.master_volume
  local fpb = RATE * 60 / bpm
  local songFrames = math.floor(beats * fpb + 0.5)
  local total = songFrames + math.floor(TAIL_S * RATE)

  local hits = {}
  for _, lv in ipairs(levels) do
    local audio = Level.loadAudio(lv, mx)
    if opts.backing and audio.backing and not mx.loop then
      mx:setLoop(audio.backing, A.backing_volume * (lv.backing and lv.backing.gain or 1), 0, songFrames)
    end
    local a, z = Level.window(lv)
    local L = Level.beats(lv)
    for rep = 0, math.ceil(beats / L) - 1 do
      for _, n in ipairs(lv.notes) do
        local s = audio.get(n.track, n.key)
        local beat = rep * L + (n.tick - a) / lv.ppq
        if n.tick >= a and n.tick < z and s and beat < beats then
          hits[#hits + 1] = { f = math.floor(beat * fpb + 0.5), n = n, s = s, lv = lv }
        end
      end
    end
  end
  table.sort(hits, function(x, y) return x.f < y.f end)
  local nextHit = 1
  mx.onBlock = function(_, f1)
    while hits[nextHit] and hits[nextHit].f < f1 do
      local h = hits[nextHit]
      local gain = A.sample_volume * (1 - A.velocity_sensitivity * (1 - h.n.vel / 127))
      mx:play(h.s, h.f, gain, Level.choke(h.lv, h.n.track, h.n.key))
      nextHit = nextHit + 1
    end
  end

  local pcm = ffi.new("int16_t[?]", total * 2)
  while mx.rendered < total do
    local start = mx.rendered
    local n = math.min(mx.bufferFrames, total - start)
    local out = mx:render(n)
    for i = 0, n * 2 - 1 do
      pcm[start * 2 + i] = math.max(-1, math.min(1, out[i])) * 32767
    end
  end

  local rel = ("exports/%s_%s.wav"):format(opts.name, opts.backing and "with_backing" or "without_backing")
  local ok, err = writeWav(util.projectDir() .. "/" .. rel, pcm, total)
  if not ok then return nil, err end
  return rel, total / RATE
end

-- opts: backing (bool), passes (times through the pattern), name (file name stem)
function Export.level(lv, J, opts)
  opts = opts or {}
  return render({ lv }, lv.bpm, Level.beats(lv) * (opts.passes or 1), J,
    { backing = opts.backing, name = opts.name or slug(lv.name) })
end

-- every level of the song at once, as it sounds once they're all built: `beats` long
-- (default: 8 bars, or longer to fit the longest loop whole)
function Export.song(song, J, opts)
  opts = opts or {}
  local levels, longest = {}, 4
  for i, p in ipairs(song.parts) do
    levels[i] = p.level
    longest = math.max(longest, Level.beats(p.level))
  end
  local beats = opts.beats or math.ceil(32 / longest) * longest
  return render(levels, song.bpm, beats, J, { backing = opts.backing, name = opts.name or slug(song.name) })
end

-- with no songs: the first level's MIDI from where that level starts, for as many whole bars
-- as its backing loop runs (else to the end of the MIDI)
function Export.firstLevel()
  local list = Level.list()
  if #list == 0 then return nil, "no levels" end
  local lv = Level.load(list[1])
  local bars = math.floor((lv.lengthBeats - lv.start_beat) / 4)
  if lv.backing then
    local info = require("src.wave").fileInfo(util.readFile(lv.backing.file))
    if info and info.seconds then bars = math.floor(info.seconds * lv.bpm / 60 / 4 + 0.5) end
  end
  lv.bars = math.max(1, bars)
  lv.name = "song"
  return lv
end

function Export.main(J)
  local Song = require("src.game.song")
  local songs = Song.list()
  for _, backing in ipairs({ true, false }) do
    local rel, secs
    if #songs > 0 then
      rel, secs = Export.song(Song.load(songs[1]), J, { backing = backing })
    else
      local lv, err = Export.firstLevel()
      if not lv then print("export failed: " .. err); return false end
      rel, secs = Export.level(lv, J, { backing = backing, name = "song" })
    end
    print(rel and ("wrote %s (%.2f s)"):format(rel, secs) or ("failed: " .. tostring(secs)))
  end
  return true
end

return Export
