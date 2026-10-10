-- tests/test_game_song.lua
-- songs: levels built up one on top of another (src/game/song.lua)

local ffi = require("ffi")
local Song = require("src.game.song")
local Level = require("src.game.level")
local Round = require("src.game.round")
local Juice = require("src.config.juice")
local json = require("lib.json")
local util = require("src.util")

local tests = {}

function tests.every_song_in_songs_loads(T)
  local list = Song.list()
  T.ok(#list > 0, "no songs")
  for _, p in ipairs(list) do
    local ok, song = pcall(Song.load, p)
    T.ok(ok, p .. ": " .. tostring(song))
    T.ok(#song.parts > 0, p .. ": no levels")
    for i, part in ipairs(song.parts) do
      T.eq(part.level.bpm, song.bpm, p .. " level " .. i .. " plays at the song's BPM")
      if part.vo then T.ok(util.readFile(part.vo) ~= nil, p .. ": VO line " .. part.vo .. " is missing") end
    end
    if song.finale then T.ok(love.filesystem.getInfo(song.finale.file) ~= nil, p .. ": finale " .. song.finale.file .. " is missing") end
  end
end

function tests.huntin_wabbits_builds_bass_then_synth_then_chops(T)
  local song = Song.load("songs/huntin_wabbits.json")
  T.eq(song.bpm, 114)
  local names = {}
  for i, p in ipairs(song.parts) do names[i] = p.level.name end
  T.eq(table.concat(names, " / "), "Bass / Synth / Vocal Chops")
  T.eq(song.parts[1].level.metronome, "always", "the bass is built over the metronome")
  T.eq(song.parts[2].level.metronome, "off", "then the bass is the time")
  for _, p in ipairs(song.parts) do
    T.eq(p.level.beat_offset, 0.25, p.level.name .. ": the record's backbeat is a 16th after the MIDI's beat")
  end
  local J = Juice.defaults()
  for i, p in ipairs(song.parts) do
    local prep = Level.prepare(p.level)
    T.ok(#prep.buttons > 0, p.level.name .. " has buttons")
    T.eq(Round.count(prep, J), #prep.steps, p.level.name .. ": a round per step (a round box, or a lone button)")
    for _, s in ipairs(p.level.sounds) do T.ok(util.readFile(s.sample) ~= nil, s.sample .. " is missing") end
    T.ok(i == 1 or p.vo, "a VO line for each level")
  end
end

function tests.a_song_round_trips(T)
  local song = Song.load("songs/huntin_wabbits.json")
  local back = Song.normalize(json.decode(Song.toJson(song)), "x")
  T.eq(back.name, song.name); T.eq(back.bpm, song.bpm)
  T.eq(#back.parts, #song.parts)
  for i, p in ipairs(song.parts) do
    T.eq(back.parts[i].path, p.path); T.eq(back.parts[i].vo, p.vo); T.eq(back.parts[i].underGain, p.underGain)
  end
  T.eq(back.finale.file, song.finale.file)
  T.eq(song.parts[2].underGain, 0.8, "the bass plays 20% quieter under the synth")
  T.eq(song.parts[3].underGain, nil, "and as it is under the chops")
end

-- a locked-in loop repeats its length from song beat 0, from the beat it was locked in
function tests.locked_loops_repeat_on_the_song_grid(T)
  local notes = { { beat = 0.5 }, { beat = 3 } }
  local beats = {}
  for _, e in ipairs(Song.loopEvents(notes, 4, 6, 12, 0)) do beats[#beats + 1] = e.beat end
  T.eq(table.concat(beats, " "), "7 8.5 11")
  beats = {}
  for _, e in ipairs(Song.loopEvents(notes, 4, 6, 12, 9)) do beats[#beats + 1] = e.beat end
  T.eq(table.concat(beats, " "), "11", "nothing before it was locked in")
  T.eq(#Song.loopEvents(notes, 4, 12, 12, 0), 0)
end

-- the finale's lights: low and high loudness per step, the loud steps near 1
function tests.the_finale_is_analysed_into_low_and_high_loudness(T)
  local rate, fps = 44100, 1000
  local frames = fps * 40
  local d = ffi.new("float[?]", frames * 2)
  for f = 0, frames - 1 do
    local step = math.floor(f / fps)
    -- even steps: a 60 Hz thump; odd steps: 6 kHz hiss
    local v = step % 2 == 0 and 0.5 * math.sin(2 * math.pi * 60 * f / rate) or 0.2 * math.sin(2 * math.pi * 6000 * f / rate)
    d[f * 2], d[f * 2 + 1] = v, v
  end
  local a = Song.analyze({ data = d, frames = frames, rate = rate }, fps, 0)
  T.eq(a.steps, 40)
  T.ok(a.low[10] > 0.5 and a.low[11] < a.low[10] * 0.5, ("low end on the thumps: %.2f vs %.2f"):format(a.low[10], a.low[11]))
  T.ok(a.high[11] > 0.5 and a.high[10] < a.high[11] * 0.5, ("highs on the hiss: %.2f vs %.2f"):format(a.high[11], a.high[10]))
  for i = 0, a.steps - 1 do T.ok(a.low[i] <= 1 and a.high[i] <= 1) end
end

-- the finale is the cropped track: it starts at the breath-in, and its first bar line is beat 2
function tests.the_finale_starts_at_the_breath_in(T)
  local song = Song.load("songs/huntin_wabbits.json")
  T.ok(song.finale.file:match("full_cropped%.wav$") ~= nil, "the cropped track, not the 20-second build-up")
  T.eq(song.finale.beat, 3, "bars start at the 4th beat of the cropped track")
end

return tests
