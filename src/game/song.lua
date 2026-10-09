-- src/game/song.lua
-- A song is levels built up one on top of another, like Simon: the player builds the first
-- level's loop note by note; clearing it locks that loop in, and it keeps playing under the
-- next level while that one is built; and so on. Each level can have a VO line for when it's
-- cleared. After the last, the full track (the finale) plays.
--
-- songs/<name>.json:
--   {
--     "format": 1, "name": "Huntin Wabbits", "bpm": 114,
--     "levels": [ { "level": "levels/huntin_wabbits_bass.json", "vo": "assets/audio/vo/nice.wav" }, ... ],
--     (a level can also have "under_gain": 0.8 -- the loops locked in under it play that much
--     quieter, on top of juice's song.locked_volume, while it is being built)
--     "finale": { "file": "...Huntin_ Wabbitz (Flip).wav", "gain": 1, "beat": 0 }
--   }
-- Every level plays at the song's BPM. The loops share one grid from the song's first beat:
-- a level n beats long plays its beat (songBeat mod n), so loops of 1, 2, 4 or 8 bars stay in
-- time with each other, and each level's beat 0 is the same moment in the music (its window
-- in its own MIDI is set in the level editor). finale.beat is where the finale track's beat 1
-- falls in the file (0 = its first frame); its lights follow that grid.
--
--   Song.list() -> { "songs/x.json", ... }
--   Song.load(path) -> { path, name, bpm, parts = { { path, level, vo, underGain } }, finale }
--   Song.toJson(song) / Song.save(song)
--   Song.loopEvents(notes, length, b0, b1, from) -> { { beat, note } }   a loop's notes in [b0, b1)
--   Song.analyze(sample, framesPerStep, offsetFrames) -> { low, high, steps }   loudness per step, 0-1
--   Song.voLines() -> the .wav files in assets/audio/vo

local json = require("lib.json")
local util = require("src.util")
local Level = require("src.game.level")

local Song = {}

Song.VO_DIR = "assets/audio/vo"
Song.LIGHT_STEPS = 8   -- finale analysis steps per beat (the lights read groups of them)

function Song.list()
  local out = {}
  for _, f in ipairs(love.filesystem.getDirectoryItems("songs")) do
    if f:match("%.json$") then out[#out + 1] = "songs/" .. f end
  end
  table.sort(out)
  return out
end

function Song.voLines()
  local out = {}
  for _, f in ipairs(love.filesystem.getDirectoryItems(Song.VO_DIR)) do
    if f:lower():match("%.wav$") then out[#out + 1] = Song.VO_DIR .. "/" .. f end
  end
  table.sort(out)
  return out
end

-- raw: the decoded song file. Levels are loaded from their files and set to the song's BPM.
function Song.normalize(raw, path)
  local song = {
    path = path,
    name = type(raw.name) == "string" and raw.name or "untitled",
    bpm = tonumber(raw.bpm),
    parts = {},
  }
  for i, e in ipairs(type(raw.levels) == "table" and raw.levels or {}) do
    local file = type(e) == "string" and e or (type(e) == "table" and e.level)
    if type(file) ~= "string" then error(("%s: level %d has no \"level\" file"):format(path or "song", i), 2) end
    local ok, lv = pcall(Level.load, file)
    if not ok then error(("%s: level %d: %s"):format(path or "song", i, tostring(lv)), 2) end
    local entry = type(e) == "table" and e or {}
    song.parts[#song.parts + 1] = { path = file, level = lv, vo = type(entry.vo) == "string" and entry.vo or nil, underGain = tonumber(entry.under_gain) }
  end
  song.bpm = song.bpm or (song.parts[1] and song.parts[1].level.bpm) or 120
  for _, p in ipairs(song.parts) do p.level.bpm = song.bpm end
  if type(raw.finale) == "table" and type(raw.finale.file) == "string" then
    song.finale = { file = raw.finale.file, gain = tonumber(raw.finale.gain) or 1, beat = tonumber(raw.finale.beat) or 0 }
  end
  return song
end

function Song.load(path)
  local text, err = util.readFile(path)
  if not text then error(err or ("cannot read " .. path), 2) end
  local raw, jerr = json.try_decode(text)
  if not raw then error(path .. ": " .. tostring(jerr), 2) end
  return Song.normalize(raw, path)
end

function Song.toJson(song)
  local out = { format = 1, name = song.name, bpm = song.bpm, levels = {} }
  for i, p in ipairs(song.parts) do out.levels[i] = { level = p.path, vo = p.vo, under_gain = p.underGain } end
  if song.finale then out.finale = { file = song.finale.file, gain = song.finale.gain, beat = song.finale.beat } end
  return json.encode(out, { indent = "  " }) .. "\n"
end

function Song.save(song)
  return util.writeFile(song.path, Song.toJson(song))
end

-- A loop's notes (Level.loopNotes) that fall in song beats [b0, b1), from beat `from` on:
-- the loop repeats every `length` beats from song beat 0.
function Song.loopEvents(notes, length, b0, b1, from)
  local out = {}
  b0 = math.max(b0, from or b0)
  if b1 <= b0 or length <= 0 then return out end
  for k = math.floor(b0 / length), math.floor(b1 / length) do
    for _, n in ipairs(notes) do
      local beat = k * length + n.beat
      if beat >= b0 and beat < b1 then out[#out + 1] = { beat = beat, note = n } end
    end
  end
  table.sort(out, function(x, y) return x.beat < y.beat end)
  return out
end

-- How loud the low end (kick, bass: under ~150 Hz) and the top (hats, snare: over ~2.5 kHz)
-- are in each step of `framesPerStep` frames from `offset`, each scaled so its 95th
-- percentile is 1. The finale's lights ride these.
function Song.analyze(s, framesPerStep, offset)
  local d, frames, rate = s.data, s.frames, s.rate or 44100
  offset = math.max(0, math.floor(offset or 0))
  local aLow = 1 - math.exp(-2 * math.pi * 150 / rate)
  local aHigh = 1 - math.exp(-2 * math.pi * 2500 / rate)
  local lp, hp = 0, 0
  local steps = math.max(0, math.floor((frames - offset) / framesPerStep))
  local low, high = {}, {}
  local f = offset
  for step = 0, steps - 1 do
    local stop = math.min(frames, math.floor(offset + (step + 1) * framesPerStep + 0.5))
    local el, eh, n = 0, 0, 0
    while f < stop do
      local x = (d[f * 2] + d[f * 2 + 1]) * 0.5
      lp = lp + aLow * (x - lp)
      hp = hp + aHigh * (x - hp)
      local h = x - hp
      el, eh, n = el + lp * lp, eh + h * h, n + 1
      f = f + 1
    end
    low[step], high[step] = math.sqrt(el / math.max(1, n)), math.sqrt(eh / math.max(1, n))
  end
  local function scale(t)
    local sorted = {}
    for i = 0, steps - 1 do sorted[#sorted + 1] = t[i] end
    table.sort(sorted)
    local ref = sorted[math.max(1, math.floor(#sorted * 0.95))] or 1
    if ref <= 0 then ref = 1 end
    for i = 0, steps - 1 do t[i] = math.min(1, t[i] / ref) end
  end
  scale(low); scale(high)
  return { low = low, high = high, steps = steps }
end

return Song
