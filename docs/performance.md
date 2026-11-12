# Performance

What the program costs on its heavy cases, what changed, and what was measured and left.

## How it is measured

`src/bench_test.odin` makes the App as `main` does, on an offscreen window driven by the toolkit's `testkit/session` (its
input, its clock), with no server: 400 sessions in 12 project folders (a fifth of them sub-agents) and a conversation of 150
turns (a prompt; an answer with its reasoning, four tool calls and Markdown: headings, lists, code, a table, a quote). As a
test it checks what each case must do (the view at the bottom builds the last answer and not the first, the sidebar builds
the sessions it shows and the last one once scrolled to it, typing and streaming land, find reads every message and then builds what is near). With
`-define:OCN_BENCH=true` it runs 300 frames of each case on the GPU and prints the medians of the frame's steps
(`App.times`: the builds, the drawing into the draw lists, the submission):

    odin build src -build-mode:test -collection:gt=ext/gui_toolkit/src -o:speed -define:OCN_BENCH=true -define:ODIN_TEST_THREADS=1 -out:build/bench.exe
    build\bench.exe

| case | what each frame does |
|---|---|
| idle | nothing: the conversation at its bottom |
| stream | the last answer grows by a delta (a new paragraph every 8) |
| type | a character typed in the composer |
| scroll | three notches of the wheel up the conversation |
| palette | the palette open, a character typed |
| pal_slips | the palette at rest on words typed with slips that find few (`frmae pacnig`), 300 models: the pointer moves a pixel |
| pal_all | the palette at rest on `@`: every session found |
| term_out | a command's output open in its grid, a line in colour coming at each frame |
| term_rest | the same grid at rest (a frame the program draws only when something moves) |
| find | the find bar open, its needle typed |
| search | the sidebar's search typed |

1600 x 1000, Windows 11, 16 logical cores, a machine busy with other work. A base and a new build are run alternately, 5
times each; the numbers are the median of the runs' medians, the range in brackets, milliseconds per frame. Samples come
from a sampler of the test's thread written for the occasion (1 ms, the stack walked with `RtlVirtualUnwind`, named with
DbgHelp afterwards), not kept.

Start-up: `opencode-native --frames=1` prints how long the first frame took from the start of `main`
(`--url=http://127.0.0.1:1`, nothing to connect to; on a desktop of its own: `wrentool desktop`), 15 runs of each build
alternated.

With `-define:OCN_PROFILE=true` (and `-debug`) the bench also samples its own thread at 1 kHz (`src/profile_test.odin`): for each
case the functions samples fell in, those on the stack, and the five last frames of the commonest stacks. The GPU's time of
each step comes from `render.set_gpu_profile`.

    odin build src -build-mode:test -collection:gt=ext/gui_toolkit/src -o:speed -debug -define:OCN_BENCH=true -define:OCN_PROFILE=true -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=ocn.a_long_conversation_builds_what_is_seen -out:build/bench.exe

An offscreen window has no frame slots: the bench's frames go back to back. Slept through 16 ms between frames, the same work measures
about twice as long, its caches cold and the clock down: that is the machine, not the frame. On a real screen expect the higher number.

The sampler is not free: under it `find` read 91 ms and `search` 7 ms where they take 41 and 2.6. Read its shares, not its times, and
take times with it off.

## Where a frame goes (gui_toolkit 0.80.0, the same since)

CPU per frame (build, draw, submission) in milliseconds, medians of 3 runs before and 4 after, sampler off, 1600 x 1000, RTX 4070
SUPER. The budget at 180 Hz is 5.5 ms.

| case | 0.78.0 | 0.80.0 | range after |
|---|---|---|---|
| idle | 1.65 | 1.30 | 1.29-1.35 |
| stream | 2.3 | 1.9 | 1.7-2.0 |
| type | 2.5 | 2.4 | 2.3-2.6 |
| scroll | 2.2 | 2.2 | 2.1-2.3 |
| palette | 2.2 | 2.2 | 1.9-2.5 |
| tray | 2.1 | 1.7 | 1.4-1.9 |
| menu | 2.2 | 1.8 | 1.5-2.0 |
| search | 2.6 | 2.3 | 2.2-2.6 |
| find | 41 | 2.2 | 1.9-2.6 |

Runs of one program differ by as much as 0.5 ms outside `idle`: a smaller difference is not one, and only `idle`, `stream` and `find`
moved beyond that. The GPU takes 0.2 to 1 ms and is not what limits a frame, nor is the layout.

What was found and done, by what it brought:

- **The palette at rest** (2026-11, Linux, offscreen, `-o:speed`): `pal_slips` 15.9 ms a frame, `pal_all` 7.7, `palette` 4.9.
  Each frame matched and ranked every item again (the search for slips allocated for each word of each item it did not
  find) and built every row it found, two hundred at most. The list is now made when what it lists changes (`palette_stamp`,
  `ui.rank`'s version), and only the rows in view are built (`ui.vlist`): 3.1, 3.1 and 3.0 ms.

- **Find** built every message at every frame, because the search reads what is built. It reads it once now, when the needle rests
  (`ui.find_sweep`: 80 to 110 ms, once, 80 ms after the last key), and stays lazy between; the indices are those of the sweep.
- **Truncated text** was measured rune by rune at every frame, each rune through the shaper and its ink box: `font::glyph` was 27 % of
  the samples at rest. Where a text is cut is kept now. `ui.draw_box_text` went from 38 to 12 % of a frame.
- **`render.pace_frame` makes the slot's wait**, which it worked out and dropped, and the app's own wait is gone. Input is not what it
  limits: `platform.wait_slot` reads it as it comes, and a key or a button ends the wait. It is the output that is chosen
  (`advanced.frame_rate`: the screen, a most, above the screen too, or uncapped; frames are made when there is something to draw). No gain on a 60 Hz screen, where the swap chain paces. It must come after
  the swap chain's wait: before, the two add up, 40 frames a second instead of 60 under a pointer at 1 kHz.

Tried and left:

- The registry behind `preview_available` and `SystemParametersInfo` behind `animations_on`, asked at every frame, are kept now, for
  nothing measurable: four alternate runs with and without, idle 1.87 and 1.86 ms. An earlier profile read 3.9 ms: the sampler then
  allocated with the thread stopped.
- A cache of shaped runs: with truncation gone, `font::shape_run` and `font::word_match` are 5 % of a frame at rest, 0.05 ms, less than
  a run's noise, for memory and another thing to invalidate.

The profile at rest is flat now, nothing over 5 %: `draw::glyph_run`, `ui::build_box`, then the driver. Small names are not to be
trusted: the linker folds identical procedures, `marshal_struct_fields` in these profiles is not JSON being written. `_extendhfsf2` (a
software half float) has no unwind data: its caller is not known.

The start: `app_init` and connecting take 4 ms; the wait is the device (about 300 ms on its thread here), and the first run of a new
program compiles its shaders (`render` 870 ms at that first frame, 5 ms after).

## What changed

1. **The sidebar is a lazy column** (`sessions_list`, `group_header`): a group's header and each session are items of the
   toolkit's lazy column, as the conversation's messages are; only those near the view are built, the others stand as their
   height. Every session was built and drawn at every frame, and the drawing of each truncated title measured it again glyph
   by glyph (`ui.draw_box_text` -> `truncate` -> `font.glyph`, a DirectWrite ink box per character: 42 % of the samples).

   | case | before | after |
   |---|---|---|
   | idle | 8.39 (8.31-8.49) | 1.55 (1.54-1.57) |
   | stream | 10.95 (10.49-11.26) | 2.44 (2.43-2.48) |
   | type | 11.07 (10.45-12.06) | 2.54 (2.51-2.59) |
   | scroll | 10.45 (10.22-10.93) | 2.44 (2.29-2.53) |
   | search | 10.37 (10.09-11.07) | 3.16 (2.65-3.25) |
   | find | 62.3 (58.9-64.8) | 57.6 (47.7-62.9) |

   The frame's temporary memory went from 7 MB to 2 MB: under the temporary allocator's first block (4 MB), so no block is
   mapped and freed at each frame any more (`memory_block_alloc` was 20 % of the samples before).
2. **The graphics device is made while the program starts** (`render.preload_device`, gui_toolkit 0.63.0), and the fonts
   load before the renderer (`fonts_init`) so that they overlap it: the driver's load is 160 ms of a 200 ms start. First frame
   199.9 (194.1-212.5) -> 183.3 (178.2-192.9) ms.

From the toolkit's versions since 0.61.0, with nothing to do here: the caret of the composer wakes the loop at its flips only
(0.62.0: a focused composer drew each picture of the caret twice); runs of glyphs looked up once (`draw.glyph_run`, 0.64.0)
and the word cache's shared lock (0.64.0) count where threads draw or shape at once, which this program does not (one thread
builds and draws): nothing to measure here; menus are denser and scroll (0.69.0).

## Measured and not kept

- **Truncation from one shaping** (`ui/draw_ui.odin` `truncate` in the toolkit: the clusters of one `font.shape` of the text
  instead of a `font.glyph` per character): idle 1.56 -> 1.07, stream 2.44 -> 1.53, type 2.49 -> 1.66, scroll 2.36 -> 1.70,
  search 2.60 -> 1.86 ms (5 runs alternated). A change of the toolkit: it comes with a release of it.
- **Find** builds every message while its bar is open (the toolkit's find reads the text the layout placed): 45 to 60 ms a
  frame on 150 turns, two thirds of it building. Building only what is seen would need the matches counted from the messages'
  text and the match's message built whatever (`lazy_item(always)`): not done.
