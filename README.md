# BeatEmUp

A beat memory game in LÖVE 11.5. A 2x2 drum pad (grey rubber pads with RGB lights under
them) demos a beat with its lights; then you play it back on **Q W / A S** or with the mouse.

Each light is a **button** programmed over the level's MIDI. You copy the **sequence**, at
your own speed: a press of the pad that's next plays the MIDI notes inside that button,
whether that's one note or several. A press of any other pad sounds mangled: pitched down,
low-passed and distorted.

A **song** is levels built up one on top of another, like Simon: you build the first level's
loop a button at a time; clearing it locks that loop in and it keeps playing under the next
level while you build that one. After the last level the song's full track plays.

There are three programs:

- **The game.**
- **The juice editor**: game feel, stored in `juice.json`.
- **The level editor**: a MIDI track plus the buttons programmed over it, stored in
  `levels/*.json` (each next to its own `.mid`). It also shows a song's levels all at once.

## Where files live

| Folder | What |
|---|---|
| `songs/` | song definitions (`<name>.json`): the levels in order, VO lines, finale |
| `levels/` | level files: `<name>.json` + its `.mid` (written by the level editor) |
| `assets/audio/songs/<song>/` | the song's tracks: `full_cropped.wav` (the finale), `full.wav` (the whole track), `instrumental.wav`, `instrumental_loop.wav` (a level's backing) |
| `assets/audio/samples/<set>/` | the one-shot sounds keys play (`bass/`, `synth/`, `vocal_chops/`) |
| `assets/audio/vo/` | the voice-over lines |
| `assets/midi/` | source MIDI loops a new level starts from |
| `source/` | not used by the game: Ableton sets, notes |
| `exports/` | `run export` output |

## Run it

Double-click, or `run <mode>` from a Command Prompt in this folder:

| | |
|---|---|
| `run.bat` | the game: the songs in `songs/` |
| `run play --song=songs/huntin_wabbits.json --from=3` | one song, starting at its level 3 (levels 1-2 already built) |
| `juice.bat` (`run juice`) | the juice editor |
| `levels.bat` (`run levels`) | the level editor (`run levels <song.json, level.json or file.mid>` opens one) |
| `run export` | the first song, every level looping together, as WAVs in `exports\`, with and without backing |
| `run test` | unit tests |
| `run package -Version 0.1` | Windows and Mac builds for play testers, in `dist\` (see below) |

The launcher finds LÖVE (PATH, Program Files, `..\CounterCatch\tools\cache`) or downloads
11.5.

## The game

**Controls**

| Key | Does |
|---|---|
| Q W / A S, or click | the four pads |
| Space | start (during the finale: finish) |
| P | pause |
| Esc | back to the title, then quit |
| F11 | fullscreen |

**A round**, in beats on the level's tempo:

1. **Count-in** (the level's name): only before a level's first round, `flow.count_in_beats`.
2. **The demo** (WATCH): the board plays the pattern with its lights, and its sound unless
   `flow.demo_sound` is off.
3. **Your turn** (YOUR TURN): on the beat the demo ends, all four pads flash green
   (`lights.turn_*`), then pulse green at 10% on every beat until your turn is over. It lasts
   as long as you take: it ends when the sequence is complete, or wrong (see Judging).

The next round's demo starts on the next bar at least `flow.rest_beats` after your turn (in a
song, on the loop grid); the result (PERFECT!, NICE!, KEEP GOING) shows for
`flow.result_beats` beats.

**The pattern grows like Simon** (`flow.grow = buttons`): each round adds the next step until
the whole loop is built. A step is a **round** drawn in the level editor (all the buttons inside
it at once) or a button in no round (on its own), so with no rounds drawn a level has a round
per button. (`flow.start_buttons` and `flow.buttons_per_round` set how many steps the first
round has and each adds.) The pattern runs to the end of the bar its last button is in. (`flow.grow = bars` grows it a bar at a time instead: `flow.start_bars`,
`flow.bars_per_round`.)

**A song** (`songs/*.json`) plays its levels in order on one unbroken timeline:

- **Level 1** is built over the metronome (each level sets its own: `"metronome": "always"`).
  The clicks go where the record's beat is, which needn't be where the MIDI's is: a level's
  `"beat_offset"` (in beats) moves the clicks, the turn's green flashes and the gold strobe
  that far after the MIDI's beat. Every level made from the Huntin Wabbits loops has 0.25,
  because the backing's snare lands a 16th after the MIDI's beats 2 and 4.
- **Clearing a level** strobes the pads gold in time with the beat (`song.clear_*` in the
  juice editor), plays that level's VO line, and **locks its loop in**: from then on it plays
  under everything, and the next level starts on the same beat grid with no break.
- **Later levels** are built over the loops already locked in (no metronome), which play at
  `song.locked_volume` (60%) so the part being built is center stage; during a level's gold
  celebration its loop plays at full volume. A level can turn the loops under it down further
  with `"under_gain"` on its entry in the song file (Huntin Wabbits: 0.8 under the Synth, so
  the bass plays at 48% there).
- **After the last level** the song's full track plays from its start and the pads go off in
  time with it: the bottom pads ride its low end, the top pads its highs, a white flash on
  every bar (`song.finale_*`). The pads still play. Space finishes.

The loops stay in time because they share one grid from the song's first beat: a level n beats
long always plays its beat (song beat mod n), and each round's demo starts on a multiple of
the level's length (after your turn the next demo waits for the grid; a cleared level's gold
runs on until the next level's count-in lands on it). So a 1-bar level over a 2-bar loop lines
up the way it would in Ableton. A level is locked in the moment you finish it, on the beat its
loop has reached by then.

A level's samples start where their sound starts: silence at the front of a `.wav` (bounces
often carry 100 ms of it) is skipped, so a press sounds the moment it lands.

**Judging.**

- **What counts:** the order, not the timing. Press the buttons' pads in the order the demo
  lit them, as fast or slow as you like. Buttons that start within `timing.together_ms` of
  each other (they light together) can go in either order. A press up to `timing.early_ms`
  before the green flash already counts.
- **Correct:** the pad that's next plays its button's notes, keeping their spacing.
  Finishing the sequence is PERFECT!, or NICE! if a wrong press was forgiven.
- **Wrong:** any other pad is a wrong press and plays that pad's sound mangled. You carry on
  from where you were; one more than `rules.mistakes_allowed` (1) and the guess is wrong.
- **Too slow:** you have `flow.wait_beats` (16) from the green flash to start. Once you've
  started, stalling gives the guess up: `flow.grace_beats` (4) past when the next button
  would be due if you were playing in time. The pad that was due flashes red.
- **A wrong guess** flashes all four pads red (`lights.fail_s`) and you play that round again
  (TRY AGAIN, `rules.on_fail = retry_round`): the same demo, the same sequence, until you get
  it. You never move on without getting it right. There are no lives (`rules.lives = 0`);
  set lives to bring back game over. (`restart_level` sends you back to the level's first
  round instead; `continue` carries on to the next round anyway, just scoring less.)
- **Notes outside every button** play along on their own (once, from the green flash, until
  your turn is over), or stay silent; that's a per-level setting.
- **Exclusive** (per level): normally a key cuts only its own previous note. With
  exclusive on, the moment any note triggers it cuts every sound still ringing: demo,
  your presses, wrong hits and free notes alike. Notes on the same tick still sound
  together (two keys sharing one sample sound once). It never cuts another level's loop.
- **The backing track** keeps going under all of it.

**Bluetooth headphones** delay what you hear by 150-250 ms. Set `timing.audio_offset_ms`
in the juice editor so the lights and the judging line up with what you hear.

## The juice editor

This works like CounterCatch's Juice tuner.

- **Left: controls.** Every `juice.json` key, in tabs. LOOK holds Layout, Type, Pads and
  Lights; GAME holds Timing, Flow, Rules, Scoring, Wrong Sound, Feel, Audio and Song; META holds
  Display, Hot Reload and Debug.
  - Type to filter by key name.
  - Hover a key for what it does.
  - Mouse wheel over a slider nudges it one step.
  - Orange keys need a restart.
- **Right: the real game, live.**
  - Scenario buttons drop it into a moment and replay it: title, level intro, the demo,
    your turn, an autoplayed turn, a sloppy turn (a wrong press, then it stalls part-way and
    the grace runs out), round clear, level clear (the gold strobe, then the next level), round fail,
    game over, the finale, and **Play final round**: the song's last round played by the bot,
    through the gold strobe into the finale and out, then again (the whole ending without
    playing the game).
  - **HEAR** plays each pad clean or wrong, so the Wrong Sound sliders can be heard as they
    move.
  - Clicking the pads in the preview plays them.
- **Saving.** SAVE writes `juice.json`. A running game reloads it by itself
  (`hot_reload`). LAUNCH GAME starts one.

Keys worth knowing:

| Key | Does |
|---|---|
| `flow.wait_beats` | how long the player has to start their turn (0 = forever) |
| `flow.grace_beats` | how long they can stall part-way through before the guess counts as wrong |
| `wrong_sound.*` | `pitch_semitones`, `lowpass_hz`, `resonance` (how much it rings/grates), `drive` (grit, never louder), `volume_db` |
| `lights.*` | glow size and strength, light leaking round the edges, attack/hold/decay, velocity -> brightness, feedback colors, the green "your turn" flash and pulse (`turn_*`) |
| `pads.*` | the rubber's grey, translucency (how much the light shows through), press squash |
| `flow.*` | count-in, demo repeats, the turn's wait and grace, how the pattern grows (`grow`: Simon-style buttons, or bars) |
| `song.*` | the gold celebration (length, color, flashes per beat, pop), the VO line's volume and beat, the finale's lights |
| `rules.*` | mistakes allowed, what a wrong guess does (`on_fail`: retry, restart, carry on), lives (0 = no game over) |

## The level editor

**Opening.** The open screen lists your songs, your levels (to carry on with one) and every
`.mid` under `assets/midi/` (to start a new one). You can also drop any of them onto the window,
or run `run levels <file>`.

**A song** opens as a lane per level, one above the other, all on one time axis from each
level's first beat, so what plays together lines up:

- **Click a lane** (or PgUp / PgDn) to edit that level; everything below works on it. The
  others are dimmer.
- **Each lane's header** shows the level's VO line (click to pick another; you hear it), its
  metronome (click to step through always / count-ins / off / juice's setting) and a mute
  switch for listening.
- **A level shorter than the song** repeats out to the song's length, drawn hollow.
- **Space** plays every level together, each looping its own length, as they sound once built.
- **[ ]** changes the BPM of the song and every level in it.
- **The header** picks the full track the song ends on (click it).
- **Ctrl+S** saves every level you changed and the song; **F5** plays the song from the
  level you're editing, the ones above it already built; **Ctrl+E** exports every level
  together.
- **Undo** remembers which level each change was in and goes back there.

**The roll** shows the whole MIDI: a row per key, grouped by track. The level's bars are the
band on the ruler: drag the band to move it, drag its end to change the length. Tab steps
through three layers, NOTES -> LIGHTS -> ROUNDS, each a box over the one before (buttons over
notes, rounds over buttons):

- **LIGHTS (buttons).**
  - **Draw a box.** Drag across notes on a track and the box tightens to the notes it
    caught. A box can never reach into another track.
  - **Pick its pad.** Click the box, then press **Q W A S** or click a pad in the board
    preview.
  - **Edit it.** Drag the box to move it, or drag its edges to change its start and end.
    The start is when the button is tapped: its light comes on and the player is judged
    there. The end only decides which notes the box takes in; every light is the same tap
    (`lights.hold_s`, then `lights.decay_s`).
  - **Keys:**
    - **F** fits a box to its notes.
    - **B** boxes the notes you selected in the NOTES layer.
    - **Ctrl+B** makes one button per note, as a starting point.
  - **Colors:** **1-8** give a button its own color (or a pad, if no button is selected).
    **0** puts a button back to its pad's color. R G B sliders are in the inspector.
  - **Warnings:** notes caught by two boxes show red.
- **ROUNDS (the build-up).** How the game builds the level up, a round at a time.
  - **Drag around buttons** and they become one round: the game adds them all at once. The
    box tightens to the buttons that start inside it.
  - **A button in no round** is a round of its own, so you only box what should come together.
  - **Every button shows the number of the round that adds it** (`#3`); rounds play in the
    order of their first button. Red means a button is inside two round boxes.
  - **Edit:** click a round to see what it adds, drag it or its edges, F fits it to its
    buttons, Del takes it out (its buttons go back to a round each).
  - The lane header and the inspector show how many rounds the level has.
- **NOTES (the MIDI).** Select, drag (to other keys on the same track only), nudge, change
  length and velocity, quantize (Shift+Q), add (double-click), delete.

Everything can be undone.

**Sounds.** Each key's sound is a `.wav`. Drop one onto the key's row, or press **R** over
the row to step through the WAVs in `assets/audio/samples/`. Click a key's name to hear it.

**Level settings** (inspector, with nothing selected): name, BPM `[ ]`, backing track,
whether notes outside buttons play along, exclusive, metronome (the clicks under this level in
the game: always, count-ins only, off, or juice's `audio.metronome`). `"beat_offset"` is set in
the sidecar only; the editor's metronome (K) follows it.

**EXCLUSIVE** is the big toggle in the header, next to the layer tabs (or press **E**). It
lights red when it's on, and you can flip it while the level loops to hear the difference.
It's saved as `"exclusive": true` in the sidecar.

**Files**

| Key | Does |
|---|---|
| Ctrl+S | save: writes `levels/<name>.json` (the sidecar: buttons, pads, sounds, lights) and `levels/<name>.mid` (the MIDI, with your note edits), and the sidecar links to that MIDI. The MIDI you started from is never changed. |
| Ctrl+O | back to the open screen |
| F5 | play this level in the game |
| Ctrl+E | export the level as WAVs, with and without backing |

The tools panel on the right lists every key and mouse action.

## Songs

A song is `songs/<name>.json`: its name, BPM, its levels in order (each with the VO line it
plays when cleared) and the full track it ends on (`"beat"`: where that track's beat 1
falls, 0 = its first frame). The game plays the songs in file-name order; with no songs it
plays every level in `levels/` in file-name order.

**Huntin Wabbits** (`songs/huntin_wabbits.json`, 114 BPM):

| Level | File | What | Buttons to start from |
|---|---|---|---|
| 1 Bass | `huntin_wabbits_bass` | `assets/midi/bass_loop.mid` (8 bars): A2 / D3 / F2 on `Bass_A` / `Bass_D` / `Bass_F`. Exclusive, metronome always, VO "nice" | bars 1-2, one per note (10) |
| 2 Synth | `huntin_wabbits_synth` | `assets/midi/synth_loop.mid` (8 bars): F1 G1 A1 B1 C2 D2 E2 on `F` `DG` `A` `B` `C` `DG` `E`. Exclusive, no metronome, VO "great" | bars 1-2, one per note, the G+D chord as one (5) |
| 3 Vocal Chops | `01_huntin_wabbits` | the chops level from before, no metronome, still over the No Samples backing. VO "amazing" | yours |

Then the finale: `assets/audio/songs/huntin_wabbits/full_cropped.wav` (about 315 beats). It is the
full track (`full.wav`) cut at its beat 25, 13.28 s in, a quiet dip in the build-up (the singer
breathes in at beat 37), so most of the 20 seconds of build-up are skipped. The cut is on the track's
beat grid (it runs at exactly 114 BPM, its beat 0 at 0.12 s) with a 20 ms fade-in, and
`"beat": 3` in the song file puts the first bar line, where the finale's lights start, on beat 4
of the file.

The bass and synth samples are in `assets/audio/samples/bass/` and `synth/`. There is no D synth sample, so D2
plays `synth/DG.wav` too; `A_Shaped.wav` isn't used yet (R over a key's row picks it).

## Levels

A level is a sidecar `levels/<name>.json` plus its MIDI `levels/<name>.mid`. These are the
test levels from before songs; with a song in `songs/` the game plays the song instead:

| Level | Bars of the clip | Buttons |
|---|---|---|
| `01_huntin_wabbits` | bar 5 (the pattern's 1st bar) | programmed by hand in the level editor (now Huntin Wabbits' level 3) |
| `02_all_i_do` | bars 5-6: the docx sequence | one per note (15) |
| `03_think_about_you` | bars 5-8 | 24 presses for 30 notes: each `W W` pair is one W button and each `E4 D4` pair is one A button |

All three use these files:

- **MIDI:** a copy of `assets/midi/vocal_chops_loop.mid`.
- **Sounds:** keys 69 / 71 / 76 / 74 play `assets/audio/samples/vocal_chops/chop_1..4.wav`.
- **Backing:** `assets/audio/songs/huntin_wabbits/instrumental_loop.wav` (the No Samples loop), at 114 BPM.

The notes keep their live timing (around the 16th offbeats); Shift+Q in the NOTES layer
quantizes them.

## Package for play testers

```
run package -Version 0.1
```

(`dist\package.ps1`, brought over from CounterCatch.) It writes, in `dist\`:

- `BeatEmUp-0.1-win64.zip`: `BeatEmUp.exe` with LÖVE fused in, its DLLs, `alsoft.ini` (the
  low-latency audio settings) and LÖVE's license (its LGPL parts ask for it). Testers unzip
  and double-click the exe; if SmartScreen warns, More info -> Run anyway.
- `BeatEmUp-0.1-macos.zip`: `BeatEmUp.app`, fused zip-to-zip so the bundle keeps its
  permissions and links. Unsigned, it comes with `Open BeatEmUp.terminal`: double-clicked
  (Terminal asks to open it: Open), it clears macOS's download flag and starts the game.
  Signed, the zip is just the app.

No README in either: just what it takes to launch the game.
- `BeatEmUp.love`: the game alone, for anyone with LÖVE 11.5.

The game inside is the code, `juice.json`, the songs and levels, and only the audio they use
(`dist\build_love.py`), so the rest of `assets/audio` and `source/` stay out. The app icon is
`assets/images/icon.png`, drawn from the game's own pads by `lovec . --run=dist/make_icon.lua`.

Needs Python 3 with Pillow (`py -m pip install pillow`). LÖVE for Windows and Mac is taken from
`dist\cache\`, else CounterCatch's `tools\cache\`, else downloaded.

**Signing the Mac build** (so it opens with no prompts): put a Developer ID Application
certificate and an App Store Connect API key in `dist\signing\` (`developer_id.cer`,
`developer_id_key.pem`, `AuthKey.p8`, `notary.txt`, the same files CounterCatch uses), or pass
`-SignDir <folder>`. The script then signs and notarizes it with Apple (`dist\sign_mac.py`;
needs Windows Developer Mode). `-NoNotarize` signs without sending it to Apple.

## Code map

| | |
|---|---|
| `main.lua`, `conf.lua` | entry, modes, the ~1 ms input/audio loop, low-latency OpenAL (`alsoft.ini`) |
| `juice.json`, `src/config/` | the tunables: schema (types, ranges, descriptions) and loader (validate, clamp, hot reload, write) |
| `src/game/game.lua` | the game: states, songs (lock-in, celebration, finale), audio scheduling, judging, lights, HUD, editor scenarios |
| `src/game/song.lua` | songs: the file, locked-in loops on the song grid, the finale's loudness analysis |
| `src/game/round.lua` | a round's layout in beats (Simon growth, the loop grid) and the judging of buttons (no LÖVE, tested) |
| `src/game/level.lua` | levels: the sidecar + MIDI, buttons and the notes in them, sounds, save |
| `src/game/lights.lua` | how a button lights its pad (shared by the game and the level editor) |
| `src/render/pads.lua` | the board: pads, LEDs, halo, press |
| `src/mixer.lua` | sample-accurate mixer, limiter, per-voice pitch / low-pass / drive |
| `src/midi.lua` | MIDI reader / writer (format 0 and 1) |
| `src/export.lua` | WAV export (`run export`, Ctrl+E) |
| `src/tools/juice_ui.lua` | the juice editor |
| `src/tools/level_editor.lua`, `level_view.lua` | the level editor (a level, or a song's levels as lanes) |
