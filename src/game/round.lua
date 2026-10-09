-- src/game/round.lua
-- One round of the memory game, laid out in beats, and the judging of the player's turn.
-- No LÖVE calls: the tests drive it directly.
--
-- A round, starting at beat `start` on the level's timeline:
--   count   flow.count_in_beats       the level's count-in (round 1; later rounds wait at
--           (flow.rest_beats)         least flow.rest_beats after the turn before)
--   demo    pattern x flow.demo_repeats   the board plays it (lights, sound), "WATCH"
--   play    open-ended                the player copies it, starting on the beat the demo
--                                     ends (the pads flash green); presses are judged
-- The turn has no set length: it ends when the sequence is complete or wrong (r:endTurn),
-- and the round finishes there. The next one starts from there (the result word shows over
-- the wait for its demo for flow.result_beats).
-- How the pattern grows (flow.grow):
--   buttons  like Simon, a step at a time: a step is a round box drawn in the level editor
--            (all its buttons at once) or a button in no round box. Round 1 is the first
--            flow.start_buttons steps, each round adds flow.buttons_per_round more, until the
--            whole loop is built. The pattern runs to the end of the bar holding its last
--            button (the whole level once every button is in).
--   bars     the first `bars` bars of the level, from flow.start_bars, growing by
--            flow.bars_per_round.
--
-- Rounds sit on a grid: with `align` (in a song the level's length in beats, so the pattern
-- stays in time with the loops locked in under it; else a bar) the count-in stretches so the
-- demo always starts on a multiple of it. The turn follows the demo straight on.
--
-- The player is judged on the sequence, not the timing: the buttons' pads in the pattern's
-- order, at any speed. One press of the right pad plays every note in its button.
--
--   local r = Round.new(prepared, J, number, start, align)   -- prepared = Level.prepare(level)
--   r:phaseAt(beat)       -> "count" | "demo" | "play" | nil, beat into it
--   r:demoButtons()       -> { { beat, button } }   each button as the demo lights it
--   r:demoNotes()         -> { { beat, note } }     every note the demo sounds
--   r:freePlayNotes()     -> { { beat, note } }     notes outside buttons, during the turn
--   r:endTurn(beat)                                 the turn is over: the round finishes there
--   local j = Round.Judge.new(r, J, bpm)   -- judging, in seconds on the level's timeline
--   j:press(pad, t)       -> { kind = "correct" | "wrong", button }
--   j:sweep(t)            -> the buttons left, once the player has stalled too long
--   j.outcome             -> nil while the turn is open, then "complete" | "wrong" | "timeout"

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
  r.phases[1] = phase("count", upTo(number == 1 and f.count_in_beats or f.rest_beats))
  r.phases[2] = phase("demo", r.beats * r.repeats)
  r.phases[3] = phase("play", math.huge)
  r.byName = {}
  for _, p in ipairs(r.phases) do r.byName[p.name] = p end
  r.finish = math.huge
  return r
end

-- the turn is over at `beat`: the sequence is complete, or the guess is wrong
function Round:endTurn(beat)
  self.byName.play.to = beat
  self.finish = beat
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

-- the free notes play once from the start of the turn, as they would under the pattern, and
-- stop when the turn is over; the buttons' notes wait for the player
function Round:freePlayNotes()
  local out = {}
  if self.prepared.unboxed == "mute" then return out end
  local play = self.byName.play
  for _, n in ipairs(self.free) do
    if play.from + n.beat < play.to then out[#out + 1] = { beat = play.from + n.beat, note = n } end
  end
  return out
end

-- where each button of the turn would be due, played in time: { beat (absolute), button }
function Round:playButtons()
  local out = {}
  local play = self.byName.play
  for _, b in ipairs(self.buttons) do out[#out + 1] = { beat = play.from + b.beat, button = b } end
  return out
end

------------------------------------------------------------------------
-- judging
------------------------------------------------------------------------

-- The turn is the sequence: the buttons' pads in the pattern's order, at any speed. Buttons
-- starting within timing.together_ms of each other light together in the demo, so they can be
-- pressed in either order.
--   * A press of a pad that's due next is correct (it plays that button's notes); any other
--     press is wrong. More than rules.mistakes_allowed wrong presses and the guess is wrong
--     (with rules.extra_press_is_mistake off they only sound wrong).
--   * The player has flow.wait_beats from the turn's first beat to start (0 = as long as they
--     like); a press timing.early_ms before that beat already counts.
--   * Once started, stalling gives the guess up: flow.grace_beats past when the next button
--     would be due if they were playing in time, the buttons left are misses.
-- The turn is over the moment the sequence is complete, wrong or given up (j.outcome, at
-- j.endT, in seconds on the level's timeline).

local Judge = {}
Judge.__index = Judge
Round.Judge = Judge

function Judge.new(round, J, bpm)
  local spb = 60 / bpm
  local j = setmetatable({ round = round, J = J, expected = {}, groups = {}, hits = {}, spb = spb, next = 1 }, Judge)
  local due = round:playButtons()
  table.sort(due, function(x, y)
    if x.beat ~= y.beat then return x.beat < y.beat end
    return x.button.pad < y.button.pad
  end)
  local together = J.timing.together_ms / 1000
  for _, d in ipairs(due) do
    -- t: when it would be due, played in time
    local e = { t = d.beat * spb, pad = d.button.pad, button = d.button, state = nil }
    local g = j.groups[#j.groups]
    if not g or e.t - g.t > together then
      g = { t = e.t }
      j.groups[#j.groups + 1] = g
    end
    g[#g + 1] = e
    e.group = #j.groups
    j.expected[#j.expected + 1] = e
  end
  j.counts = { correct = 0, wrong = 0, miss = 0 }
  j.startT = round.byName.play.from * spb
  local wait = J.flow.wait_beats
  j.deadline = wait > 0 and j.startT + wait * spb or math.huge
  if #j.groups == 0 then j.outcome, j.endT = "complete", j.startT end
  return j
end

local function finished(g)
  for _, e in ipairs(g) do if not e.state then return false end end
  return true
end

-- a press during the turn: correct if its pad is due next, else wrong
function Judge:press(pad, t)
  local J = self.J
  local g = self.groups[self.next]
  local e
  for _, x in ipairs(g) do
    if not x.state and x.pad == pad then e = x; break end
  end
  local hit = { kind = e and "correct" or "wrong", button = e and e.button, expected = e, t = t, pad = pad }
  self.counts[hit.kind] = self.counts[hit.kind] + 1
  self.hits[#self.hits + 1] = hit
  local grace = J.flow.grace_beats * self.spb
  if e then e.state = "correct" end
  if e and finished(g) then
    self.next = self.next + 1
    local after = self.groups[self.next]
    if not after then
      self.outcome, self.endT = "complete", t
      return hit
    end
    -- a step done: the player has until the next one would be due in time, and the grace
    self.deadline = t + (after.t - g.t) + grace
  else
    self.deadline = math.max(self.deadline, t + grace)
  end
  if self:mistakes() > J.rules.mistakes_allowed then self.outcome, self.endT = "wrong", t end
  return hit
end

-- Past the deadline (never started, or stalled part-way) the guess is given up there: the
-- buttons left are misses, returned in order (those of group j.next were the ones due).
function Judge:sweep(t)
  if self.outcome or t <= self.deadline then return {} end
  self.outcome, self.endT = "timeout", self.deadline
  local missed = {}
  for _, e in ipairs(self.expected) do
    if not e.state then
      e.state = "miss"
      missed[#missed + 1] = e
    end
  end
  self.counts.miss = self.counts.miss + #missed
  return missed
end

function Judge:mistakes()
  local wrong = self.J.rules.extra_press_is_mistake and self.counts.wrong or 0
  return wrong + self.counts.miss
end

function Judge:done()
  return self.outcome ~= nil
end

function Judge:passed()
  return self.outcome == "complete"
end

-- presses are judged from timing.early_ms before the turn's first beat until it's over (a
-- press past the deadline is too late, though sweep hasn't given the guess up yet)
function Judge:open(t)
  return not self.outcome and t >= self.startT - self.J.timing.early_ms / 1000 and t <= self.deadline
end

return Round
