-- src/game/round.lua
-- One round of the memory game, laid out in beats, and the judging of the player's turn.
-- No LÖVE calls: the tests drive it directly.
--
-- A round, starting at beat `start` on the level's timeline:
--   count   flow.count_in_beats       the level's count-in (round 1 only; later rounds follow
--                                     straight on from the turn before)
--   demo    pattern x flow.demo_repeats   the board plays it (lights, sound), "WATCH"
--   gap     flow.gap_beats            countdown to the player's turn
--   play    pattern length            the player copies it; presses are judged
-- The round finishes as the turn ends, and the next one starts there: its demo begins at once
-- (the result word shows over it for flow.result_beats).
-- How the pattern grows (flow.grow):
--   buttons  like Simon, a step at a time: a step is a round box drawn in the level editor
--            (all its buttons at once) or a button in no round box. Round 1 is the first
--            flow.start_buttons steps, each round adds flow.buttons_per_round more, until the
--            whole loop is built. The pattern runs to the end of the bar holding its last
--            button (the whole level once every button is in).
--   bars     the first `bars` bars of the level, from flow.start_bars, growing by
--            flow.bars_per_round.
--
-- In a song, rounds sit on the loop grid: with `align` (the level's length in beats) the
-- count-in and the countdown stretch so the demo and the turn always start on a multiple of
-- it, which keeps the pattern in time with the loops locked in under it. The countdown is
-- the last flow.gap_beats of the stretched gap.
--
-- The player is judged on buttons, not notes: one press of the right pad when a button's
-- light comes on (its start) plays every note in it.
--
--   local r = Round.new(prepared, J, number, start, align)   -- prepared = Level.prepare(level)
--   r:phaseAt(beat)       -> "count" | "demo" | "gap" | "play" | nil, beat into it
--   r:demoButtons()       -> { { beat, button } }   each button as the demo lights it
--   r:demoNotes()         -> { { beat, note } }     every note the demo sounds
--   r:freePlayNotes()     -> { { beat, note } }     notes outside buttons, during the turn
--   local j = Round.Judge.new(r, J, bpm)   -- judging, in seconds on the level's timeline
--   j:press(pad, t)       -> { kind = "perfect" | "good" | "wrong", button, errMs }
--   j:sweep(t)            -> buttons that just became misses

local Round = {}
Round.__index = Round

function Round.barsFor(levelBars, J, number)
  local f = J.flow
  if f.bars_per_round == 0 then return levelBars end
  return math.min(levelBars, f.start_bars + (number - 1) * f.bars_per_round)
end

-- steps in round `number` (grow = buttons)
function Round.buttonsFor(total, J, number)
  local f = J.flow
  return math.min(total, f.start_buttons + (number - 1) * f.buttons_per_round)
end

-- the steps a level is built up in: Level.prepare's, or else one per button
function Round.steps(prepared)
  if prepared.steps then return prepared.steps end
  local out = {}
  for i, b in ipairs(prepared.buttons) do out[i] = { beat = b.beat, buttons = { b } } end
  return out
end

-- rounds in a level. prepared: Level.prepare(level) (its .bars, .buttons and .steps)
function Round.count(prepared, J)
  local f = J.flow
  if f.grow == "buttons" then
    local n = #Round.steps(prepared)
    if n <= f.start_buttons then return 1 end
    return 1 + math.ceil((n - f.start_buttons) / f.buttons_per_round)
  end
  if f.bars_per_round == 0 or f.start_bars >= prepared.bars then return 1 end
  return 1 + math.ceil((prepared.bars - f.start_bars) / f.bars_per_round)
end

-- prepared: Level.prepare(level), plus .bars and .unboxed ("play" | "mute")
function Round.new(prepared, J, number, start, align)
  local f = J.flow
  local r = setmetatable({ prepared = prepared, number = number, start = start, align = align }, Round)
  r.buttons, r.free = {}, {}
  if f.grow == "buttons" then
    local steps = Round.steps(prepared)
    local n = Round.buttonsFor(#steps, J, number)
    local inRound, last = {}, -1
    for i = 1, n do
      for _, b in ipairs(steps[i].buttons) do
        inRound[b] = true
        last = math.max(last, b.beat)
      end
    end
    for _, b in ipairs(prepared.buttons) do if inRound[b] then r.buttons[#r.buttons + 1] = b end end
    r.bars = (n >= #steps or last < 0) and prepared.bars or math.min(prepared.bars, math.floor(last / 4) + 1)
    r.beats = r.bars * 4
  else
    r.bars = Round.barsFor(prepared.bars, J, number)
    r.beats = r.bars * 4
    for _, b in ipairs(prepared.buttons) do if b.beat < r.beats then r.buttons[#r.buttons + 1] = b end end
  end
  for _, n in ipairs(prepared.free) do if n.beat < r.beats then r.free[#r.free + 1] = n end end
  r.repeats = f.demo_repeats
  local beat = start
  local function phase(name, len)
    local p = { name = name, from = beat, to = beat + len }
    beat = beat + len
    return p
  end
  -- with align: how far to stretch a phase of at least `len` so the next one starts on the grid
  local function upTo(len)
    if not align or align <= 0 then return len end
    return math.ceil((beat + len) / align - 1e-9) * align - beat
  end
  r.phases = {}
  r.phases[1] = phase("count", upTo(number == 1 and f.count_in_beats or 0))
  r.phases[2] = phase("demo", r.beats * r.repeats)
  r.phases[3] = phase("gap", upTo(f.gap_beats))
  r.phases[4] = phase("play", r.beats)
  r.byName = {}
  for _, p in ipairs(r.phases) do r.byName[p.name] = p end
  r.finish = beat
  return r
end

function Round:phaseAt(beat)
  for _, p in ipairs(self.phases) do
    if beat >= p.from and beat < p.to then return p.name, beat - p.from, p end
  end
  return nil
end

function Round:demoButtons()
  local out = {}
  local demo = self.byName.demo
  for rep = 0, self.repeats - 1 do
    for _, b in ipairs(self.buttons) do
      out[#out + 1] = { beat = demo.from + rep * self.beats + b.beat, button = b }
    end
  end
  return out
end

-- the demo sounds the whole pattern: every button's notes, and the free notes unless muted
function Round:demoNotes()
  local out = {}
  local demo = self.byName.demo
  for rep = 0, self.repeats - 1 do
    local base = demo.from + rep * self.beats
    for _, b in ipairs(self.buttons) do
      for _, n in ipairs(b.notes) do out[#out + 1] = { beat = base + n.beat, note = n } end
    end
    if self.prepared.unboxed ~= "mute" then
      for _, n in ipairs(self.free) do out[#out + 1] = { beat = base + n.beat, note = n } end
    end
  end
  return out
end

-- during the turn the free notes keep playing; the buttons' notes wait for the player
function Round:freePlayNotes()
  local out = {}
  if self.prepared.unboxed == "mute" then return out end
  local play = self.byName.play
  for _, n in ipairs(self.free) do out[#out + 1] = { beat = play.from + n.beat, note = n } end
  return out
end

-- where each button of the turn is due: { beat (absolute), button }
function Round:playButtons()
  local out = {}
  local play = self.byName.play
  for _, b in ipairs(self.buttons) do out[#out + 1] = { beat = play.from + b.beat, button = b } end
  return out
end

------------------------------------------------------------------------
-- judging
------------------------------------------------------------------------

local Judge = {}
Judge.__index = Judge
Round.Judge = Judge

function Judge.new(round, J, bpm)
  local spb = 60 / bpm
  local j = setmetatable({ round = round, J = J, expected = {}, hits = {}, spb = spb }, Judge)
  for _, e in ipairs(round:playButtons()) do
    j.expected[#j.expected + 1] = { t = e.beat * spb, pad = e.button.pad, button = e.button, state = nil }
  end
  j.counts = { perfect = 0, good = 0, wrong = 0, miss = 0 }
  j.playFrom = round.byName.play.from * spb
  j.playTo = round.byName.play.to * spb
  return j
end

-- the press, judged: the nearest unplayed button on this pad within the leeway is hit;
-- anything else is a wrong hit
function Judge:press(pad, t)
  local window = self.J.timing.good_ms / 1000
  local best, bestErr
  for _, e in ipairs(self.expected) do
    if not e.state and e.pad == pad then
      local err = t - e.t
      if math.abs(err) <= window and (not best or math.abs(err) < math.abs(bestErr)) then best, bestErr = e, err end
    end
  end
  local hit
  if best then
    local errMs = bestErr * 1000
    best.state = math.abs(errMs) <= self.J.timing.perfect_ms and "perfect" or "good"
    best.err = errMs
    hit = { kind = best.state, button = best.button, expected = best, errMs = errMs, t = t, pad = pad }
  else
    hit = { kind = "wrong", t = t, pad = pad }
  end
  self.counts[hit.kind] = self.counts[hit.kind] + 1
  self.hits[#self.hits + 1] = hit
  return hit
end

-- buttons now too late to hit
function Judge:sweep(t)
  local window = self.J.timing.good_ms / 1000
  local missed = {}
  for _, e in ipairs(self.expected) do
    if not e.state and t > e.t + window then
      e.state = "miss"
      self.counts.miss = self.counts.miss + 1
      missed[#missed + 1] = e
    end
  end
  return missed
end

function Judge:mistakes()
  local wrong = self.J.rules.extra_press_is_mistake and self.counts.wrong or 0
  return wrong + self.counts.miss
end

function Judge:done(t)
  return t > self.playTo + self.J.timing.good_ms / 1000
end

function Judge:passed()
  return self:mistakes() <= self.J.rules.mistakes_allowed
end

function Judge:open(t)
  local w = self.J.timing.good_ms / 1000
  return t >= self.playFrom - w and t <= self.playTo + w
end

return Round
