-- src/game/game.lua
-- The beat memory game. The board plays a beat with its lights (and the level's MIDI), then
-- the pads flash green on the next beat and the player copies it on Q W / A S or with the
-- mouse. Each light is a button from the level editor; the turn is judged on the sequence,
-- not the timing: pressing the pad due next plays the MIDI notes inside its button, anything
-- else plays the pad's sound mangled (wrong_sound.*). Rounds grow the pattern like Simon, a
-- button at a time (flow.grow); failing costs a life.
--
-- What it plays: the songs in songs/ (src/game/song.lua), or with none, every level in
-- levels/ in file-name order, or one level (--level). In a song the levels build on each
-- other on one unbroken timeline: clearing a level locks its loop in (the pads strobe gold,
-- its VO line plays) and it keeps playing under the next level; after the last, the song's
-- full track plays with the pads going off in time with it.
--
-- States: title -> intro (level name) -> play (rounds; in a song, level after level) ->
-- finale (a song's full track) -> complete, or game_over.
--
-- Everything that feels like anything comes from juice.json (J), read at the moment it is
-- used, so the juice editor's sliders and hot reload act immediately.
--
--   local g = Game.new({ level = "levels/x.json" } or { song = "songs/x.json", from = 2 })   -- all optional
--   g:update(dt); g:draw(x, y, w, h)
--   g:keypressed(key) / g:keyreleased(key) / g:mousepressed(x, y) / g:mousereleased(x, y)
--   g:scenario(name)   -- the juice editor's preview buttons

local Juice = require("src.config.juice")
local Mixer = require("src.mixer")
local Synth = require("src.synth")
local Level = require("src.game.level")
local Song = require("src.game.song")
local Round = require("src.game.round")
local Lights = require("src.game.lights")
local Screen = require("src.render.screen")
local Pads = require("src.render.pads")
local Fonts = require("src.render.fonts")

local Game = {}
Game.__index = Game

local RATE = 44100
local KEYS = { q = 1, w = 2, a = 3, s = 4 }
local CHASE = { 1, 2, 4, 3 }   -- clockwise round the board: Q W S A

local function round(x) return math.floor(x + 0.5) end
local function db(x) return 10 ^ (x / 20) end

-- the lives a game starts with: rules.lives, or with 0, as many tries as it takes
local function startLives(J) return J.rules.lives > 0 and J.rules.lives or math.huge end

-- opts: level (one level file), song (one song file), from (start a song at this level, the
-- ones before it already built), autoplay (the bot plays every turn)
function Game.new(opts)
  local g = setmetatable({ opts = opts or {} }, Game)
  g.J = Juice.data
  local J = g.J
  g.mixer = Mixer.new{ rate = RATE, bufferFrames = 256, bufferCount = 4 }
  g.screen = Screen.new(J.display.virtual_width, J.display.virtual_height)
  g.clicks = {
    click = g.mixer:loadSample(Synth.click(RATE, false)),
    accent = g.mixer:loadSample(Synth.click(RATE, true)),
  }
  if g.opts.level then
    g.levels = { g.opts.level }
  else
    g.songs = g.opts.song and { g.opts.song } or Song.list()
    if #g.songs == 0 then
      g.songs = nil
      g.levels = Level.list()
    else
      g:loadSong(1)
    end
  end
  g.time = 0
  g.pads = {}
  for i = 1, 4 do g.pads[i] = { press = 0, held = false } end
  g.flashes = {}
  g.locked = {}
  if #g.levels == 0 then
    error("no levels: put level files in levels/ (the level editor makes them: run levels)")
  end
  g:toTitle()
  return g
end

------------------------------------------------------------------------
-- songs and levels
------------------------------------------------------------------------

-- Everything a song plays is decoded up front (every level's samples, the VO lines, the full
-- track) so nothing loads in the middle of it.
function Game:loadSong(index)
  self.songIndex = index
  local song = Song.load(self.songs[index])
  self.song = song
  self.levels = {}
  local fpb = RATE * 60 / song.bpm
  for i, p in ipairs(song.parts) do
    self.levels[i] = p.path
    p.prep = Level.prepare(p.level)
    p.audio = Level.loadAudio(p.level, self.mixer)
    p.notes = Level.loopNotes(p.prep)
    p.length = Level.beats(p.level)
    p.voSample = Level.loadSample(self.mixer, p.vo, true)
  end
  local f = song.finale
  if f then
    f.sample = Level.loadSample(self.mixer, f.file)
    if f.sample then
      f.beats = f.sample.frames / fpb
      f.lights = Song.analyze(f.sample, fpb / Song.LIGHT_STEPS, f.beat * fpb)
    end
  end
end

function Game:loadLevel(index)
  self.levelIndex = index
  local part = self.song and self.song.parts[index]
  if part then
    self.level, self.prep, self.audio = part.level, part.prep, part.audio
  else
    self.level = Level.load(self.levels[index])
    self.prep = Level.prepare(self.level)
    self.audio = Level.loadAudio(self.level, self.mixer)
  end
  self.spb = 60 / self.level.bpm
  self.fpb = RATE * self.spb
end

-- Every demo starts on a bar; in a song, on the level's loop length so it stays in time with the
-- loops under it. (The turn has no set length, so the next round starts wherever it ends.)
function Game:align()
  return self.song and Level.beats(self.level) or 4
end

-- silence, nothing scheduled: the pads just play their samples
function Game:idleAudio()
  self.mixer:reset()
  self.mixer:setLoop(nil)
  self.mixer.onBlock = nil
  self.mixer.paused = false
  self.timeline = false
  self.celebrate, self.finale, self.finaleAt, self.finaleVoice = nil, nil, nil, nil
end

function Game:toTitle()
  if self.songs and self.songIndex ~= 1 then self:loadSong(1) end
  self:loadLevel(1)
  self:idleAudio()
  self.state = "title"
  self.score, self.combo = 0, 0
  self.lives = startLives(self.J)
  self.rounds, self.round, self.judge = {}, nil, nil
  self.locked = {}
  self:setStatus("BEAT EM UP", "text")
end

function Game:startLevel(index)
  self:loadLevel(index)
  self:idleAudio()
  self.state = "intro"
  self.introT = 0
  self.rounds, self.round, self.judge = {}, nil, nil
  self:setStatus(self.level.name, "text")
  -- in a song the level's name shows over its count-in instead: no silent title card first
  if self.song then self:beginTimeline(1) end
end

function Game:newGame()
  self.score, self.combo = 0, 0
  self.lives = startLives(self.J)
  self.locked = {}
  local from = self.song and math.max(1, math.min(tonumber(self.opts.from) or 1, #self.levels)) or 1
  -- starting part-way into a song: the levels before are already built
  for i = 1, from - 1 do self.locked[#self.locked + 1] = { part = self.song.parts[i], from = 0 } end
  self:startLevel(from)
end

-- the level's backing track, from `atBeat`; in a song it comes in there but stays on the
-- song's grid (its first frame lines up with song beat 0), like the loops
function Game:startBacking(atBeat)
  if self.audio.backing then
    self.mixer:setLoop(self.audio.backing, 1, round(atBeat * self.fpb), nil, self.song and 0 or nil)
  else
    self.mixer:setLoop(nil)
  end
end

-- the timeline starts: round 1 (or `number`) at beat 0, the backing, any locked loops. It
-- starts playing at the count-in: in a song the round's first stretch up to the loop grid is
-- skipped. A startBeat drops into the middle of it instead (the juice editor's scenarios).
function Game:beginTimeline(number, startBeat)
  self.state = "play"
  self.rounds = { Round.new(self.prep, self.J, number or 1, 0, self:align()) }
  self.round = self.rounds[1]
  self.judge = Round.Judge.new(self.round, self.J, self.level.bpm)
  self.pending = nil
  self.celebrate, self.finale, self.finaleAt, self.finaleVoice = nil, nil, nil, nil
  self.resultUntil = nil
  startBeat = startBeat or math.max(0, self.round.byName.demo.from - (self.round.number == 1 and self.J.flow.count_in_beats or 0))
  self.mixer:reset(round(startBeat * self.fpb))
  self.mixer.paused = false
  self:startBacking(self.song and self.round.byName.demo.from or 0)
  self.mixer.onBlock = function(f0, f1) self:schedule(f0, f1) end
  self.timeline = true
  self.autoplayRound = nil
end

-- in a song: the next level starts at `beat` on the same timeline, the loops still playing
function Game:continueLevel(index, beat)
  self:loadLevel(index)
  self.rounds = { Round.new(self.prep, self.J, 1, beat, self:align()) }
  self.round = self.rounds[1]
  self.judge = Round.Judge.new(self.round, self.J, self.level.bpm)
  self:startBacking(self.round.byName.demo.from)
end

------------------------------------------------------------------------
-- audio
------------------------------------------------------------------------

function Game:sampleGain(vel)
  local A = self.J.audio
  return A.sample_volume * (1 - A.velocity_sensitivity * (1 - (vel or 100) / 127))
end

-- one MIDI note through its sample (a level's sounds: track + key -> .wav). A key cuts its
-- own previous note, like a Simpler pad with Retrigger; in an exclusive level any note cuts
-- every other (Level.choke). `lv` and `audio` default to the level being played; locked-in
-- loops pass their own. offset: start that many frames into the sample.
function Game:playNote(n, atFrame, gainScale, fx, lv, audio, offset)
  lv, audio = lv or self.level, audio or self.audio
  local s = audio.get(n.track, n.key)
  if s then self.mixer:play(s, atFrame, self:sampleGain(n.vel) * (gainScale or 1), Level.choke(lv, n.track, n.key), offset or 0, fx) end
end

-- a button's notes, keeping their spacing, its start at atFrame (default: right now)
function Game:playButton(b, atFrame)
  atFrame = atFrame or self.mixer.cursor
  for _, n in ipairs(b.notes) do
    self:playNote(n, atFrame + round((n.beat - b.beat) * self.fpb))
  end
end

-- the button a pad stands for away from the turn (free play, wrong presses): its nearest
-- button in this round, else its first in the level
function Game:padButton(pad)
  local best, bestD
  if self.timeline and self.round then
    local beat = self:heard() / self.spb
    for _, e in ipairs(self.round:playButtons()) do
      if e.button.pad == pad and #e.button.notes > 0 then
        local d = math.abs(e.beat - beat)
        if not bestD or d < bestD then best, bestD = e.button, d end
      end
    end
  end
  if not best then
    for _, b in ipairs(self.prep.buttons) do
      if b.pad == pad and #b.notes > 0 then best = b; break end
    end
  end
  return best
end

function Game:padNote(pad)
  local b = self:padButton(pad)
  return b and b.notes[1]
end

function Game:playPad(pad, wrong)
  local n = self:padNote(pad)
  if not n then return end
  local W = self.J.wrong_sound
  if wrong and W.enabled then
    self:playNote(n, nil, db(W.volume_db), {
      rate = 2 ^ (W.pitch_semitones / 12), lowpass = W.lowpass_hz, q = W.resonance, drive = W.drive,
    })
  else
    self:playNote(n)
  end
end

-- A level locked in at song beat `from`: its loop plays from there on. Notes already due
-- before the mixer got here (the turn is judged a moment after it ends) start now, part-way
-- in: the latest one per choke group, as the loop would have it.
function Game:lockIn(part, from)
  self.locked[#self.locked + 1] = { part = part, from = from }
  local mx = self.mixer
  local now = mx.cursor / self.fpb
  local latest = {}
  for _, e in ipairs(Song.loopEvents(part.notes, part.length, from, now, from)) do
    latest[Level.choke(part.level, e.note.track, e.note.key)] = e
  end
  for _, e in pairs(latest) do
    local f = round(e.beat * self.fpb)
    self:playNote(e.note, mx.cursor, self:lockedGain(e.beat), nil, part.level, part.audio, mx.cursor - f)
  end
end

-- How loud a locked-in loop plays at song beat `beat`: song.locked_volume under a level being
-- built, so the new part is center stage (times that level's under_gain in the song file);
-- full during a level's gold celebration.
function Game:lockedGain(beat)
  local c = self.celebrate
  if c and beat >= c.from and beat < c.to then return 1 end
  local part = self.song and self.song.parts[self.levelIndex]
  return self.J.song.locked_volume * (part and part.underGain or 1)
end

-- where the music's beat falls on the timeline: the level's beat_offset after each whole beat
-- (the clicks, the turn's flashes and the gold strobe keep to it)
function Game:beatOffset()
  return self.level.beat_offset or 0
end

-- mixer.onBlock: clicks, the demo's notes, the notes no button plays during the turn, and
-- the loops locked in under this level
function Game:schedule(f0, f1)
  local J, mx = self.J, self.mixer
  local b0, b1 = f0 / self.fpb, f1 / self.fpb
  local mode = self.level.metronome or J.audio.metronome
  local quietFrom = self.celebrate and self.celebrate.from or math.huge
  local off = self:beatOffset()
  for _, r in ipairs(self.rounds) do
    if r.finish > b0 and r.start < b1 then
      if mode ~= "off" then
        for k = math.ceil(b0 - off), math.ceil(math.min(b1, quietFrom) - off) - 1 do
          local beat = k + off
          local phase = r:phaseAt(beat)
          if phase and (mode == "always" or phase == "count") then
            mx:play(k % 4 == 0 and self.clicks.accent or self.clicks.click, round(beat * self.fpb), J.audio.click_volume)
          end
        end
      end
      if J.flow.demo_sound then
        for _, e in ipairs(r:demoNotes()) do
          if e.beat >= b0 and e.beat < b1 then self:playNote(e.note, round(e.beat * self.fpb)) end
        end
      end
      for _, e in ipairs(r:freePlayNotes()) do
        if e.beat >= b0 and e.beat < b1 then self:playNote(e.note, round(e.beat * self.fpb)) end
      end
    end
  end
  local stop = math.min(b1, self.finaleAt or math.huge)
  for _, lk in ipairs(self.locked) do
    local p = lk.part
    for _, e in ipairs(Song.loopEvents(p.notes, p.length, b0, stop, lk.from)) do
      self:playNote(e.note, round(e.beat * self.fpb), self:lockedGain(e.beat), nil, p.level, p.audio)
    end
  end
end

-- seconds on the level's timeline that the player is hearing right now
function Game:heard()
  return self.mixer:clock() / RATE - self.J.timing.audio_offset_ms / 1000
end

------------------------------------------------------------------------
-- feedback
------------------------------------------------------------------------

function Game:setStatus(text, colorKey, sub)
  if not self.status or self.status.text ~= text then
    self.status = { text = text, colorKey = colorKey or "text", at = self.time }
  end
  self.status.colorKey = colorKey or "text"
  self.status.sub = sub
end

-- A press lights its pad exactly as the demo lights that button: the same tap (color, time
-- on, fade, velocity brightness), from the moment of the press. (lights.correct_white
-- and feel.hit_punch add a flash and a pop on top; both 0 by default.)
function Game:pulse(pad, button)
  local Li = self.J.lights
  local b = button or { beat = 0, endBeat = 0, color = self.level.pads[pad].color, vel = 100 }
  local hold = Lights.hold(self.J)
  self.flashes[#self.flashes + 1] = { pad = pad, kind = "light", at = self.time, button = b,
    dur = Li.attack_s + hold + Li.decay_s }
  if self.J.feel.hit_punch > 0 then self.pads[pad].punchAt = self.time end
end

function Game:flash(pad, kind, color)
  local Li = self.J.lights
  local f = { pad = pad, kind = kind, at = self.time, color = color }
  if kind == "wrong" then
    f.dur, f.color = Li.wrong_s, Li.wrong_color
  elseif kind == "miss" then
    f.dur, f.color = Li.miss_s, Li.miss_color
  elseif kind == "fail" then
    f.dur, f.color = Li.fail_s, Li.wrong_color
  end
  self.flashes[#self.flashes + 1] = f
end

function Game:shake()
  self.shakeAt = self.time
end

------------------------------------------------------------------------
-- input
------------------------------------------------------------------------

function Game:multiplier()
  local S = self.J.scoring
  return math.min(S.combo_max, 1 + math.floor(self.combo / S.combo_step))
end

-- a pad is struck (key, mouse, or the autoplay bot)
function Game:hit(pad)
  self.pads[pad].downAt = self.time
  local t = self:heard()
  local judging = self.state == "play" and self.judge and not self.round.resolved and self.judge:open(t)
  if not judging then
    -- outside the player's turn the pads are just an instrument
    self:playPad(pad)
    self:pulse(pad, self:padButton(pad))
    return
  end
  local h = self.judge:press(pad, t)
  if h.kind == "wrong" then
    self:playPad(pad, true)
    self.combo = 0
    self:flash(pad, "wrong")
    self:shake()
  else
    self:playButton(h.button)
    self.combo = self.combo + 1
    self.score = self.score + self.J.scoring.correct * self:multiplier()
    self:pulse(pad, h.button)
  end
  return h
end

function Game:press(pad)
  self.pads[pad].held = true
  self:hit(pad)
end

function Game:release(pad)
  self.pads[pad].held = false
end

function Game:keypressed(key)
  local pad = KEYS[key]
  if pad then return self:press(pad) end
  if key == "space" or key == "return" then
    if self.state == "title" or self.state == "game_over" or self.state == "complete" then self:newGame()
    elseif self.state == "finale" then self:finish() end
  elseif key == "p" and (self.state == "play" or self.state == "finale") then
    self.mixer:setPaused(not self.mixer.paused)
  elseif key == "escape" and self.state ~= "title" then
    self:toTitle()
    return true
  end
end

function Game:keyreleased(key)
  local pad = KEYS[key]
  if pad then self:release(pad) end
end

function Game:mousepressed(x, y)
  local vx, vy = self.screen:toVirtual(x, y)
  local pad = Pads.hit(self.J, vx, vy)
  if pad then
    self.mousePad = pad
    self:press(pad)
    return true
  end
  return false
end

function Game:mousereleased()
  if self.mousePad then self:release(self.mousePad) end
  self.mousePad = nil
end

------------------------------------------------------------------------
-- rounds
------------------------------------------------------------------------

-- The turn is over (the sequence complete, the guess wrong, or given up): the round finishes
-- there and the next is laid out from there, its demo on the next bar (in a song, the loop
-- grid) at least flow.rest_beats on.
function Game:resolveRound()
  local r, j, J = self.round, self.judge, self.J
  r.resolved = true
  r:endTurn(j.endT / self.spb)
  local passed = j:passed()
  local total = Round.count(self.prep, J)
  -- nothing can be scheduled before what the mixer has already mixed
  local from = math.max(r.finish, self.mixer.cursor / self.fpb)
  self.resultUntil = r.finish + J.flow.result_beats
  -- a wrong guess: all four pads flash red
  if not passed then
    for i = 1, 4 do self:flash(i, "fail") end
  end
  if passed or J.rules.on_fail == "continue" then
    -- a sloppy round carries on too (on_fail = continue): it just doesn't earn the round bonus
    if passed then self.score = self.score + J.scoring.round_bonus end
    if r.number >= total then
      self.score = self.score + J.scoring.level_bonus
      self:levelCleared(r)
    else
      if passed then
        self:setStatus(j.counts.wrong == 0 and "PERFECT!" or "NICE!", "good")
      else
        self:setStatus("KEEP GOING", "text")
      end
      self.pending = { kind = "round", at = r.finish, round = Round.new(self.prep, J, r.number + 1, from, self:align()) }
    end
  else
    self.lives = self.lives - 1
    self.combo = 0
    if self.lives <= 0 then
      self:setStatus("GAME OVER", "bad")
      self.pending = { kind = "game_over", at = r.finish + J.flow.result_beats }
    else
      self:setStatus("TRY AGAIN", "bad")
      local number = J.rules.on_fail == "restart_level" and 1 or r.number
      self.pending = { kind = "round", at = r.finish, round = Round.new(self.prep, J, number, from, self:align()) }
      self.pending.round.retry = true
    end
  end
  local nextRound = self.pending.round
  if nextRound then table.insert(self.rounds, nextRound) end
  -- only the rounds that can still sound or light are kept
  while #self.rounds > 3 do table.remove(self.rounds, 1) end
end

-- The whole loop is built. From the end of the turn the pads strobe gold for song.clear_beats;
-- in a song the loop locks in (it plays on under everything after), the level's VO line comes
-- in, and then the next level starts on the same timeline, or after the last, the finale.
function Game:levelCleared(r)
  local J = self.J
  local at = r.finish
  local to = at + J.song.clear_beats
  if self.song and self.levelIndex < #self.levels then
    -- the next level's count-in follows straight on, so the gold runs on to where that
    -- count-in has to start for its demo to land on the next level's loop grid
    local L, count = self.song.parts[self.levelIndex + 1].length, J.flow.count_in_beats
    to = math.ceil((to + count) / L - 1e-9) * L - count
  end
  self.celebrate = { from = at, to = to }
  local part = self.song and self.song.parts[self.levelIndex]
  self:setStatus("LEVEL CLEAR!", "accent", part and (self.level.name:upper() .. " LOCKED IN") or nil)
  if not part then
    self.pending = { kind = "level_clear", at = self.celebrate.to }
    return
  end
  self:lockIn(part, at)
  if part.voSample then
    self.mixer:play(part.voSample, round((at + J.song.vo_beat) * self.fpb), J.song.vo_volume)
  end
  local to = self.celebrate.to
  if self.levelIndex < #self.levels then
    self.pending = { kind = "next_level", at = to }
  elseif self.song.finale and self.song.finale.sample then
    -- the full track comes in where the celebration ends; the loops stop there
    self.finaleAt = to
    local f = round(to * self.fpb)
    self.finaleVoice = self.mixer:play(self.song.finale.sample, f, J.song.finale_volume * self.song.finale.gain)
    if self.mixer.loop then self.mixer.loop.stop = f end
    self.pending = { kind = "finale", at = to }
  else
    self.pending = { kind = "song_done", at = to }
  end
end

-- the finale (or a song with none) is over: on to the next song, or done
function Game:finish()
  if self.songs and self.songIndex < #self.songs then
    self:loadSong(self.songIndex + 1)
    self.locked = {}
    self:startLevel(1)
    return
  end
  self:idleAudio()
  self.state = "complete"
  self:setStatus("ALL CLEAR!", "accent")
end

function Game:advance(beat)
  local p = self.pending
  if not p or beat < p.at then return end
  self.pending = nil
  if p.kind == "round" then
    self.round = p.round
    self.judge = Round.Judge.new(self.round, self.J, self.level.bpm)
  elseif p.kind == "next_level" then
    self:continueLevel(self.levelIndex + 1, p.at)
  elseif p.kind == "finale" then
    self.state = "finale"
    self.finale = { from = p.at, to = p.at + self.song.finale.beats }
  elseif p.kind == "song_done" then
    self:finish()
  elseif p.kind == "level_clear" then
    if self.levelIndex < #self.levels then
      self:startLevel(self.levelIndex + 1)
    else
      self:idleAudio()
      self.state = "complete"
      self:setStatus("ALL CLEAR!", "accent")
    end
  elseif p.kind == "game_over" then
    self:idleAudio()
    self.state = "game_over"
    self:setStatus("GAME OVER", "bad")
  end
end

-- The bot plays the sequence back in time, as the demo had it ("perfect"), or "sloppy": a
-- wrong pad before the second button, then it forgets the rest after the second, so the
-- grace runs out (with only two buttons it finishes, one mistake down).
function Game:autoplay(t)
  local mode = self.autoplayRound == self.round and self.autoplayMode or ((self.J.debug.autoplay or self.opts.autoplay) and "perfect")
  if not mode or not self.judge then return end
  self.botNext = self.botNext or 1
  local e = self.judge.expected[self.botNext]
  if not e or t < e.t then return end
  if mode == "sloppy" and self.botNext == 2 and not self.botSlipped then
    self.botSlipped = true
    self:hit(e.pad % 4 + 1)
    return
  end
  if mode == "sloppy" and self.botNext == 3 then return end
  self.botNext = self.botNext + 1
  self:hit(e.pad)
end

------------------------------------------------------------------------
-- frame
------------------------------------------------------------------------

function Game:update(dt)
  local J = self.J
  self.time = self.time + dt
  local mx = self.mixer
  mx.gain = J.audio.master_volume
  if mx.loop then mx.loop.gain = J.audio.backing_volume * (self.level.backing and self.level.backing.gain or 1) end
  if self.finaleVoice then self.finaleVoice.gain = J.song.finale_volume * (self.song and self.song.finale and self.song.finale.gain or 1) end
  mx:pump()

  for i = 1, 4 do
    local p = self.pads[i]
    local down = p.held or (p.downAt and self.time - p.downAt < 0.08)
    local target = down and 1 or 0
    local tc = down and J.pads.press_in_s or J.pads.press_out_s
    p.press = tc <= 0 and target or p.press + (target - p.press) * math.min(1, dt / tc)
  end
  for i = #self.flashes, 1, -1 do
    if self.time - self.flashes[i].at > self.flashes[i].dur then table.remove(self.flashes, i) end
  end

  if self.state == "intro" then
    self.introT = self.introT + dt
    if self.song then
      self:setStatus(self.level.name:upper(), "text", ("%s  ·  LEVEL %d OF %d"):format(self.song.name:upper(), self.levelIndex, #self.levels))
    else
      self:setStatus(self.level.name, "text", ("LEVEL %d"):format(self.levelIndex))
    end
    if self.introT >= J.flow.title_s then self:beginTimeline(1) end
  elseif self.state == "title" then
    self:setStatus("BEAT EM UP", "text", self.song and (self.song.name:upper() .. "  ·  press SPACE to start") or "press SPACE to start")
  elseif self.state == "game_over" then
    self:setStatus("GAME OVER", "bad", ("score %d · SPACE to play again"):format(self.score))
  elseif self.state == "complete" then
    self:setStatus("ALL CLEAR!", "accent", ("score %d · SPACE to play again"):format(self.score))
  elseif self.state == "finale" and not mx.paused then
    self:setStatus("YOU BUILT IT!", "accent", self.song.name:upper())
    if self:heard() / self.spb >= self.finale.to then self:finish() end
  elseif self.state == "play" and not mx.paused then
    local t = self:heard()
    local beat = t / self.spb
    local r = self.round
    if not r.resolved then
      if self.botNext and self.botRound ~= r then self.botNext, self.botRound, self.botSlipped = 1, r, nil end
      self.botRound = r
      self:autoplay(t)
      -- the player stalled: the pads that were due go red
      for _, e in ipairs(self.judge:sweep(t)) do
        if e.group == self.judge.next then self:flash(e.pad, "miss") end
        self.combo = 0
        self:shake()
      end
      if self.judge:done() then self:resolveRound() end
      local phase = r:phaseAt(beat)
      local celebrating = self.celebrate and beat < self.celebrate.to
      if celebrating or (self.resultUntil and beat < self.resultUntil) then
        -- the gold strobe, or the last round's result, is still up
      elseif phase == "count" and r.number == 1 and self.song and not r.retry then
        self:setStatus(self.level.name:upper(), "text", ("LEVEL %d OF %d"):format(self.levelIndex, #self.levels))
      elseif phase == "count" or phase == "demo" then
        self:setStatus("WATCH", "text")
      elseif phase == "play" then
        self:setStatus("YOUR TURN", "accent")
      end
    end
    self:advance(beat)
  end
end

------------------------------------------------------------------------
-- lights
------------------------------------------------------------------------

-- the gold strobe after a level is cleared: a flash every 1/song.clear_flashes_per_beat of a
-- beat chasing round the board, all four at once (and whiter) on the beat. It comes on the
-- moment the turn ends, which can be between beats, so it keeps to the music's beats.
function Game:celebrationLights(out, beat)
  local c = self.celebrate
  if not c or beat < c.from or beat >= c.to then return false end
  local S = self.J.song
  local per = S.clear_flashes_per_beat
  beat = beat - self:beatOffset()
  local step = math.floor(beat * per)
  local env = (1 - (beat * per - step)) ^ 2
  local onBeat = step % per == 0
  local beatEnv = (1 - math.min(1, (beat - math.floor(beat)) * 4)) ^ 2
  for i = 1, 4 do
    local hit = onBeat or CHASE[step % 4 + 1] == i or CHASE[(step + 2) % 4 + 1] == i
    local o = out[i]
    o.color = S.clear_color
    o.level = S.clear_glow + (hit and env * (S.clear_level - S.clear_glow) or 0)
    o.white = onBeat and S.clear_white * env or 0
    o.pop = S.clear_punch * beatEnv
    o.tint = S.tint
  end
  return true
end

-- The finale: the bottom pads (A S) ride the track's low end, swapping on 8th notes; the top
-- pads (Q W) ride its highs, swapping every step; both of a row light together when it's loud.
-- Each pad wears a level pad color, turning one place round the board each bar; every bar
-- starts with a white flash on all four. song.finale_react sets how much loudness counts.
function Game:finaleLights(out, beat)
  local f, S = self.finale, self.J.song
  local fin = self.song.finale
  local mb = beat - f.from - fin.beat
  if mb < 0 or not fin.lights then return end
  local per = S.finale_steps_per_beat
  local step = math.floor(mb * per)
  local env = (1 - (mb * per - step)) ^ 2
  local A, K = fin.lights, Song.LIGHT_STEPS
  local function loud(t)
    local m = 0
    for k = math.floor(step * K / per), math.floor((step + 1) * K / per) - 1 do m = math.max(m, t[k] or 0) end
    return (1 - S.finale_react) + S.finale_react * m
  end
  local lo, hi = loud(A.low), loud(A.high)
  local bar = math.floor(mb / 4)
  local eighth = math.floor(mb * 2)
  local lit = {
    [1] = (step % 2 == 0 or hi > 0.85) and hi or 0,
    [2] = (step % 2 == 1 or hi > 0.85) and hi or 0,
    [3] = (eighth % 2 == 0 or lo > 0.85) and lo or 0,
    [4] = (eighth % 2 == 1 or lo > 0.85) and lo or 0,
  }
  local downbeat = mb % 4 < 1 / per
  for i = 1, 4 do
    local o = out[i]
    o.color = self.level.pads[(i + bar - 1) % 4 + 1].color
    o.tint = S.tint
    o.level = math.max(o.level, S.finale_level * env * lit[i])
    if downbeat then
      o.level = math.max(o.level, S.finale_level * env)
      o.white = S.finale_white * env
    end
  end
end

-- what every pad's LED shows right now: { color, level, press, punch, white, pop }
function Game:lightState()
  local J = self.J
  local Li = J.lights
  local out = {}
  for i = 1, 4 do
    local c = self.level.pads[i].color
    out[i] = { color = c, level = Li.idle_level, press = self.pads[i].press, white = 0, punch = 0, pop = 0 }
    if self.state == "title" and Li.breathe then
      out[i].level = Li.idle_level + 0.35 * (0.5 + 0.5 * math.sin(self.time * Li.breathe_speed * 2 * math.pi + i * 1.7))
    end
    local p = self.pads[i]
    if p.punchAt then
      local k = 1 - (self.time - p.punchAt) / math.max(0.001, J.feel.punch_s)
      out[i].punch = k > 0 and k * k or 0
    end
  end
  local function offer(pad, color, level, white)
    if level > out[pad].level then
      out[pad].level, out[pad].color, out[pad].white = level, color, white or 0
    end
  end

  if self.timeline then
    local t = self:heard()
    local beat = t / self.spb
    if self.state == "finale" then
      self:finaleLights(out, beat)
    elseif not self:celebrationLights(out, beat) then
      -- the demo, on the beat the player hears
      for _, r in ipairs(self.rounds) do
        for _, e in ipairs(r:demoButtons()) do
          local dt = t - e.beat * self.spb
          if dt >= 0 and dt < 16 then
            local lvl, color = Lights.button(J, e.button, dt, self.spb)
            if lvl > 0 then offer(e.button.pad, color, lvl) end
          end
        end
      end
      -- your turn: all four flash green on its first beat (the first click from where the
      -- demo ends), then pulse dimly on every beat until it's over (each a tap, like a
      -- button's light)
      local r = self.round
      local play = r and not r.resolved and r.byName.play
      local off = self:beatOffset()
      local first = play and math.ceil(play.from - off - 1e-9) + off
      if first and beat >= first then
        local n = math.floor(beat - first)
        local env = Lights.envelope(t - (first + n) * self.spb, Li.attack_s, Lights.hold(J), Li.decay_s)
        local lvl = env * (n == 0 and Li.turn_level or Li.turn_pulse_level)
        for i = 1, 4 do offer(i, Li.turn_color, lvl) end
      end
    end
  end

  for i = 1, 4 do
    if self.pads[i].held or self.pads[i].press > 0.5 then offer(i, self.level.pads[i].color, Li.press_level) end
  end
  for _, f in ipairs(self.flashes) do
    local dt = self.time - f.at
    if f.kind == "light" then
      local lvl, color = Lights.button(J, f.button, dt, self.spb)
      if lvl > 0 then offer(f.pad, color, lvl, Li.correct_white * math.min(1, lvl)) end
    else
      local k = 1 - dt / f.dur
      if k > 0 then offer(f.pad, f.color or self.level.pads[f.pad].color, k) end
    end
  end
  return out
end

------------------------------------------------------------------------
-- drawing
------------------------------------------------------------------------

local function text(font, s, x, y, w, align, color, alpha)
  love.graphics.setFont(font)
  love.graphics.setColor(color[1], color[2], color[3], alpha or 1)
  love.graphics.printf(s, x, y, w, align or "center")
end

function Game:drawHud()
  local J = self.J
  local L, T = J.layout, J.type
  local W = self.screen.W
  local big = Fonts.get(T.font, T.hud_size)
  local small = Fonts.get(T.label_font, T.hint_size)

  if self.state ~= "title" then
    text(big, tostring(self.score), L.hud_margin, L.title_y - 6, 400, "left", L.accent_color)
    local m = self:multiplier()
    if m > 1 then text(small, "x" .. m, L.hud_margin, L.title_y + T.hud_size + 2, 400, "left", L.accent_color) end
    -- lives, right (none when there are none to lose: on_fail = continue, or lives = 0)
    local r = T.hud_size * 0.3
    for i = 1, J.rules.on_fail == "continue" and 0 or J.rules.lives do
      local x = W - L.hud_margin - (J.rules.lives - i) * r * 3 - r
      local y = L.title_y - 6 + T.hud_size * 0.55
      if i <= self.lives then
        love.graphics.setColor(L.text_color)
        love.graphics.circle("fill", x, y, r)
      else
        love.graphics.setColor(L.dim_color)
        love.graphics.setLineWidth(2)
        love.graphics.circle("line", x, y, r)
      end
    end
  end

  -- song, level and round, top center
  if self.state == "play" or self.state == "intro" or self.state == "finale" then
    local s = self.level.name
    if self.song then s = self.song.name .. "   ·   " .. s end
    if self.state == "finale" then
      s = self.song.name .. "   ·   THE FULL TRACK"
    elseif self.round then
      s = ("%s   ·   ROUND %d / %d"):format(s, self.round.number, Round.count(self.prep, J))
    end
    local font = Fonts.get(T.label_font, T.title_size)
    text(font, s:upper(), 0, L.title_y, W, "center", L.dim_color)
    -- in a song, a pip per level: gold once built, ringed while being built
    if self.song then
      local n, r = #self.levels, 5
      local y = L.title_y + font:getHeight() + 8
      for i = 1, n do
        local x = W / 2 + (i - (n + 1) / 2) * 18
        local built = false
        for _, lk in ipairs(self.locked) do if lk.part == self.song.parts[i] then built = true end end
        if built then
          love.graphics.setColor(J.song.clear_color)
          love.graphics.circle("fill", x, y, r)
        else
          love.graphics.setColor(i == self.levelIndex and L.accent_color or L.dim_color)
          love.graphics.setLineWidth(i == self.levelIndex and 2 or 1)
          love.graphics.circle("line", x, y, r)
        end
      end
    end
  end

  -- the status word, popping in when it changes
  local st = self.status
  if st then
    local age = self.time - st.at
    local pop = 1 + J.feel.status_pop * math.max(0, 1 - age / math.max(0.001, J.feel.status_pop_s)) ^ 2
    local font = Fonts.get(T.font, T.status_size)
    local c = L[st.colorKey .. "_color"] or L.text_color
    love.graphics.push()
    love.graphics.translate(W / 2, L.status_y + font:getHeight() / 2)
    love.graphics.scale(pop)
    text(font, st.text, -W / 2, -font:getHeight() / 2, W, "center", c)
    love.graphics.pop()
    if st.sub then
      text(Fonts.get(T.label_font, T.title_size), st.sub, 0, L.status_y + font:getHeight() + 4, W, "center", L.accent_color)
    end
  end

  if L.show_hint then
    local hint = self.state == "finale" and "SPACE to finish  ·  the pads still play" or "Q  W  /  A  S   or click the pads"
    text(small, hint, 0, L.hint_y, W, "center", L.dim_color)
  end
  if self.mixer.paused then
    text(Fonts.get(T.font, T.status_size), "PAUSED", 0, J.layout.board_y - T.status_size / 2, W, "center", L.text_color)
  end
end

function Game:draw(x, y, w, h)
  local J = self.J
  self.screen:setViewport(x or 0, y or 0, w or love.graphics.getWidth(), h or love.graphics.getHeight())
  self.screen:begin(J.layout.background)

  local sx, sy = 0, 0
  if self.shakeAt then
    local k = 1 - (self.time - self.shakeAt) / math.max(0.001, J.feel.shake_s)
    if k > 0 then
      local a = J.feel.shake_px * k * k
      sx, sy = math.sin(self.time * 91) * a, math.cos(self.time * 77) * a * 0.6
    end
  end
  Pads.draw(J, { pads = self:lightState(), shakeX = sx, shakeY = sy })
  self:drawHud()

  self.screen:finish()
end

------------------------------------------------------------------------
-- juice editor scenarios: drop the game straight into a moment and show it
------------------------------------------------------------------------

-- the turn judged at once, as it starts: the whole sequence right, or a wrong guess
function Game:forceResult(pass)
  local r, j = self.round, self.judge
  for _, e in ipairs(j.expected) do e.state = pass and "correct" or nil end
  j.counts.correct = pass and #j.expected or 0
  j.counts.wrong = pass and 0 or self.J.rules.mistakes_allowed + 1
  j.outcome, j.endT = pass and "complete" or "wrong", j.startT
  self:resolveRound()
  return r
end

Game.SCENARIOS = {
  { id = "title", name = "Title" },
  { id = "intro", name = "Level intro" },
  { id = "watch", name = "Watch (demo)" },
  { id = "turn", name = "Your turn" },
  { id = "autoplay", name = "Autoplay turn" },
  { id = "sloppy", name = "Sloppy turn" },
  { id = "clear", name = "Round clear" },
  { id = "level_clear", name = "Level clear (gold)" },
  { id = "fail", name = "Round fail" },
  { id = "game_over", name = "Game over" },
  { id = "finale", name = "Finale" },
  -- the song's last round, played by the bot, straight through the gold into the finale and out
  { id = "final_round", name = "Play final round", through = true },
}

function Game:scenario(id)
  self.flashes = {}
  self.autoplayRound, self.autoplayMode, self.botNext = nil, nil, nil
  if id == "title" then
    self:toTitle()
    return
  end
  self.score, self.combo = 1250, 6
  self.lives = startLives(self.J)
  self.locked = {}
  self:loadLevel(math.min(self.levelIndex or 1, #self.levels))
  if id == "intro" then
    self:startLevel(self.levelIndex)
    return
  end
  if id == "finale" then
    local f = self.song and self.song.finale
    if not (f and f.sample) then return self:toTitle() end
    self:loadLevel(#self.levels)
    self:beginTimeline(1)
    self.rounds, self.round, self.judge = {}, nil, nil
    self.mixer.onBlock = nil
    self.mixer:setLoop(nil)
    self.finaleVoice = self.mixer:play(f.sample, 0, self.J.song.finale_volume * f.gain)
    self.state = "finale"
    self.finale = { from = 0, to = f.beats }
    return
  end
  if id == "final_round" then
    if not (self.song and self.song.finale and self.song.finale.sample) then return self:toTitle() end
    -- the earlier levels are built and looping; the last level is on its last round, bot at the pads
    local last = #self.levels
    for i = 1, last - 1 do self.locked[#self.locked + 1] = { part = self.song.parts[i], from = 0 } end
    self:loadLevel(last)
    self:beginTimeline(Round.count(self.prep, self.J))
    self.autoplayRound, self.autoplayMode, self.botNext, self.botRound = self.round, "perfect", 1, self.round
    self.botSlipped = nil
    return
  end
  if id == "level_clear" then
    -- the level's last round, judged as passed the moment the turn ends
    local last = Round.count(self.prep, self.J)
    self:beginTimeline(last)
    self:beginTimeline(last, self.round.byName.play.from)
    self:forceResult(true)
    return
  end
  -- the sloppy bot needs three buttons to forget the third
  local number = id == "sloppy" and math.min(3, Round.count(self.prep, self.J)) or 1
  self:beginTimeline(number)
  local r = self.round
  if id == "watch" then return end
  if id == "turn" or id == "autoplay" or id == "sloppy" then
    -- from the demo's last beat, so the green flash lands
    self:beginTimeline(number, r.byName.play.from - 1)
    if id ~= "turn" then
      self.autoplayRound, self.autoplayMode, self.botNext, self.botRound = self.round, id == "autoplay" and "perfect" or "sloppy", 1, self.round
      self.botSlipped = nil
    end
    return
  end
  -- results: the turn judged as it starts, so the result word shows over the wait for the
  -- next round's demo
  self:beginTimeline(1, r.byName.play.from)
  if id == "clear" then
    self:forceResult(true)
  elseif id == "fail" then
    self:forceResult(false)
  elseif id == "game_over" then
    self.lives = 1
    self:forceResult(false)
  end
end

-- audition one pad: clean or wrong, with its light, for the juice editor
function Game:audition(pad, wrong)
  self.pads[pad].downAt = self.time
  self:playPad(pad, wrong)
  if wrong then
    self:flash(pad, "wrong")
    self:shake()
  else
    self:pulse(pad, self:padButton(pad))
  end
end

return Game
