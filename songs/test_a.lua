-- songs/test_a.lua
-- The "All I Do Is Think About You" vocal chops from Keep Getting Joy.als, played from the
-- exported MIDI clip over the 8-bar "No Samples" instrumental loop. Files: assets/.
--
-- Where the mapping comes from:
--   * The .mid is the arrangement clip "All I Do Is Think About You" (84 notes) exported
--     from the .als. Ableton writes no tempo into clip exports; the set runs at 114 BPM.
--   * In the .als the keys are Drum Rack pads (slices of the vocal mp3, Simpler one-shot,
--     Retrigger on, Vel > Vol 35%). Only four keys are used: 69, 71, 74, 76.
--   * "source/notes/Sequence Ordering and Timing.docx" gives the order 1 2 2 1 2 1 3 4 1 2 2 1 2 1 3 0,
--     which is the clip from beat 16 on with 69=1, 71=2, 76=3, 74=4, so chop_N is
--     sample N.
--   * Beats 16-48 of the clip are that 2-bar pattern four times: exactly the 8-bar loop.

local chop = "assets/audio/samples/vocal_chops/chop_"

return {
  title = "Keep Getting Joy / All I Do Is Think About You",
  bpm = 114,
  backing = {
    file = "assets/audio/songs/huntin_wabbits/instrumental_loop.wav",
    gain = 1.0,
  },
  midi = { file = "assets/midi/vocal_chops_loop.mid", from = 16, to = 48 },
  offset = 0,
  velocity = 0.35,
  choke = true,
  gain = 1.0,
  pads = {
    [69] = { n = 1, label = "Slice 22", file = chop .. "1.wav" },
    [71] = { n = 2, label = "Slice 36", file = chop .. "2.wav" },
    [76] = { n = 3, label = "Slice 17", file = chop .. "3.wav" },
    [74] = { n = 4, label = "Slice 39", file = chop .. "4.wav" },
  },
}
