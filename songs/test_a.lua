-- songs/test_a.lua
-- The "All I Do Is Think About You" vocal chops from Keep Getting Joy.als, played from the
-- exported MIDI clip over the 8-bar "No Samples" instrumental loop. Files: Inputs/test_a/.
--
-- Where the mapping comes from:
--   * The .mid is the arrangement clip "All I Do Is Think About You" (84 notes) exported
--     from the .als. Ableton writes no tempo into clip exports; the set runs at 114 BPM.
--   * In the .als the keys are Drum Rack pads (slices of the vocal mp3, Simpler one-shot,
--     Retrigger on, Vel > Vol 35%). Only four keys are used: 69, 71, 74, 76.
--   * "Sequence Ordering and Timing.docx" gives the order 1 2 2 1 2 1 3 4 1 2 2 1 2 1 3 0,
--     which is the clip from beat 16 on with 69=1, 71=2, 76=3, 74=4, so bounce -N is
--     sample N.
--   * Beats 16-48 of the clip are that 2-bar pattern four times: exactly the 8-bar loop.

local dir = "Inputs/test_a/"
local bounce = dir .. "samples/Samples/Bounce 14-Audio "

return {
  title = "Keep Getting Joy / All I Do Is Think About You",
  bpm = 114,
  backing = {
    file = dir .. "samples/Background Tracks/Huntin_ Wabbitz (Flip)_Instrumental_Clip_No_Samples_Loop.wav",
    gain = 1.0,
  },
  midi = { file = dir .. "midi/Sample_MIDI_Loop.mid", from = 16, to = 48 },
  offset = 0,
  velocity = 0.35,
  choke = true,
  gain = 1.0,
  pads = {
    [69] = { n = 1, label = "Slice 22", file = bounce .. "[2026-09-28 194840]-1.wav" },
    [71] = { n = 2, label = "Slice 36", file = bounce .. "[2026-09-28 194847]-2.wav" },
    [76] = { n = 3, label = "Slice 17", file = bounce .. "[2026-09-28 194853]-3.wav" },
    [74] = { n = 4, label = "Slice 39", file = bounce .. "[2026-09-28 194856]-4.wav" },
  },
}
