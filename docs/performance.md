# Performance

What the program costs on its heavy cases, what changed, and what was measured and left.

## How it is measured

`src/bench_test.odin` makes the App as `main` does, on an offscreen window driven by the toolkit's `testkit/session` (its
input, its clock), with no server: 400 sessions in 12 project folders (a fifth of them sub-agents) and a conversation of 150
turns (a prompt; an answer with its reasoning, four tool calls and Markdown: headings, lists, code, a table, a quote). As a
test it checks what each case must do (the view at the bottom builds the last answer and not the first, the sidebar builds
the sessions it shows and the last one once scrolled to it, typing and streaming land, find builds every message). With
`-define:OCC_BENCH=true` it runs 300 frames of each case on the GPU and prints the medians of the frame's steps
(`App.times`: the builds, the drawing into the draw lists, the submission):

    odin build src -build-mode:test -collection:gt=ext/gui_toolkit -o:speed -define:OCC_BENCH=true -define:ODIN_TEST_THREADS=1 -out:build/bench.exe
    build\bench.exe

| case | what each frame does |
|---|---|
| idle | nothing: the conversation at its bottom |
| stream | the last answer grows by a delta (a new paragraph every 8) |
| type | a character typed in the composer |
| scroll | three notches of the wheel up the conversation |
| find | the find bar open, its needle typed (every message built) |
| search | the sidebar's search typed |

1600 x 1000, Windows 11, 16 logical cores, a machine busy with other work. A base and a new build are run alternately, 5
times each; the numbers are the median of the runs' medians, the range in brackets, milliseconds per frame. Samples come
from a sampler of the test's thread written for the occasion (1 ms, the stack walked with `RtlVirtualUnwind`, named with
DbgHelp afterwards), not kept.

Start-up: `opencode-native --frames=1` prints how long the first frame took from the start of `main`
(`--url=http://127.0.0.1:1`, nothing to connect to; on a desktop of its own: `wrentool desktop`), 15 runs of each build
alternated.

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
