# Changelog

All notable changes to opencode native. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project follows [semantic versioning](https://semver.org).

## [Unreleased]

## [0.12.3] - 2026-11-05

### Fixed

- **No more dots under the letters** on a screen at 100 %: round letters left a stray pixel below the line at some sizes and in some faces.
  Below 150 %, text is now smoothed along its rows only.

### Changed

- The home page says it is an independent project right under its name, where it is seen.

## [0.12.2] - 2026-11-05

### Changed

- **A logo of its own**: a silver bolt, its edge in the accent you chose. The name says native everywhere.
- An independent project, not affiliated with the OpenCode team: said wherever it presents itself.

### Fixed

- **Opening or closing a panel keeps your place** in the conversation.
- **The bottom of a conversation stays put while a run works**: the throbber's line no longer jumps at each step.

## [0.12.1] - 2026-11-05

### Changed

- **The server's experimental options are on by default.** At each connection to a server of this computer, the switches its schema
  offers and its global configuration does not mention are added to that file, comments kept; the server sees them at once. The list is
  the server's own. What you set there stays, a `false` too. Settings, Advanced turns this off.
- What a server no longer offers leaves the interface: its command, its entry in the menus.

## [0.12.0] - 2026-11-05

### Added

- **A terminal** (Ctrl+Shift+T), a panel like the others: the shells of the server, wherever it runs, in tabs, in the folder of the session.
  Emulation is Ghostty's, through libghostty-vt: colours, styles, scrollback, what programs ask of a terminal. The keys go to the shell
  while it has the focus, Ctrl+K and Escape included; Ctrl+Shift+C and V copy and paste, the wheel goes through the history, the mouse
  selects, or goes to the program that asks for it. A shell outlives the program and comes back when the panel opens; closing its tab
  ends it.

### Changed

- The dock shows only the panels that are open.
- Building needs nothing more: Zig and Ghostty, pinned, are fetched into `build/vt` the first time.

## [0.11.9] - 2026-11-05

### Added

- **Schedules of a session**: a prompt that wakes it once, in a while or at a time, every so often or on a cron. Pause, resume, delete
  after asking; when the next one is due, how many are left, how the last one went. What the server refuses is said in the dialog.
- **Artifacts of a folder**: what agents published, its files read here, opened in the browser, deleted after asking. A file of an
  artifact can only go under its own folder.
- **Plugins**, a page of the settings: those installed, what they do, why one failed; check for updates, update. The server's own are
  folded.

Schedules and artifacts are experimental on the server: where its configuration leaves them off, the dialogs say which option turns them on.

## [0.11.8] - 2026-11-05

### Added

- **Connections**, a page of the settings and a command of the palette: the 238 integrations of the server, those connected first, found
  by name. Connect one with a key, a login in the browser, what is on the machine or a command, with the questions of each way: a login
  shows its instructions and its code, follows itself without drawing a frame, and ends with the settings. Several accounts of one
  integration: choose the one in use, rename, remove after asking. A connection that must sign in again says so. What is connected
  brings its models.
- A key goes from its masked field to the server and is forgotten; of the credentials, only which is active is read.

## [0.11.7] - 2026-11-05

### Added

- **`@` in the composer** names a file of the session's folder, or a sub-agent: the list follows what is typed, Up and Down move in it,
  Enter or Tab chooses, Escape closes it and leaves the run alone. The file goes with the prompt, read by the server, even on another
  machine.
- **Browse the files** (Ctrl+P): the folders of the session, a search, a file to read, its path to copy, Mention in the prompt. A file
  that is no text says so, a long one shows its beginning and says how much.

## [0.11.6] - 2026-11-05

### Added

- **Go back to a prompt**, from its right click. The files it would restore are shown, written back already as the server does it: Go back
  keeps it so and drops what came after, the prompt returning to the composer; Cancel, Escape or a click outside put the files back. If
  the program dies in between, the session brings the dialog back when opened. In a folder without snapshots it says only the
  conversation goes back.
- **What a session changed**, from its first prompt to its last, and what one prompt changed, each file with its diff.
- **Move a session to another folder**, from its right click or the palette.
- **Export a session to a file and import it**, on this machine or another; an export without the text, to share the shape of a session.
  A session already here is opened rather than refused.

### Fixed

- A diff from git no longer shows its `diff --git` and `index` lines.

## [0.11.5] - 2026-11-05

### Added

- **What an agent asks.** The `question` tool and any form of the server: choices, your own words, numbers, switches, several choices,
  links, fields that depend on others. One question at a time, in tabs, then a review and Send; a single question goes as soon as it
  is picked. A run that asked used to wait for ever, with nothing on screen.
- **The sidebar lights a session that waits for you**, on a question or a permission, a sub-agent's too; they are found again at start.

### Changed

- A sub-agent's question comes up in the conversation of its parent.
- What a session waits for stays known when another one is opened.

## [0.11.4] - 2026-11-05

### Added

- **Back and Forward**: a history of where one has been, as in a browser: buttons in the title bar, Alt+Left and Alt+Right, the side
  buttons of the mouse; the sessions and the home page, however they were reached.
- **The view goes back to where it was read**, to the pixel, reading older pages again if it must; a conversation left at its end
  comes back at its end.
- **The logo and the wordmark go home**, as on any site.

### Changed

- gui_toolkit 0.83.0.

## [0.11.3] - 2026-11-05

### Changed

- gui_toolkit 0.82.0.
- **Esc stops the run** when nothing else takes it (a dialog, the find bar, a menu: they close first). Ctrl+Esc still does.
- **`advanced.frame_rate` is the most frames a second, above the screen too**: 120 on a 60 Hz screen is up to 120 while something moves,
  none at rest. The screen shows the newest: not smoother, but quicker to answer. Before, it stayed at the screen's rate.
- **The click of the wheel scrolls five to ten times faster**, with Wren's curve.

### Fixed

- **What was sent during a run that is interrupted goes next.** It stayed in the server's inbox until the next prompt, and went glued to
  it: it looked lost. It now starts a run at once, in the order it was sent.

## [0.11.2] - 2026-11-05

### Changed

- gui_toolkit 0.81.0.
- **The dialogs fit the window**: Settings, Statistics and Keyboard shortcuts open larger, centered, and never leave the window. Drag
  an edge or a corner to resize them, double click it to go back; the size is kept from one run to the next (`layout.dialogs`).
- In a narrow Settings dialog the list of pages shows its icons alone. Keyboard shortcuts scrolls.

## [0.11.1] - 2026-11-05

### Changed

- gui_toolkit 0.80.0.
- **Find no longer rebuilds the conversation at every frame**: it reads it once when the needle rests, then stays lazy. On 150
  answers a frame while finding goes from 40 ms to about 2 ms, and typing in the field is no longer held up.
- A frame at rest costs a fifth less, 1.65 -> 1.3 ms, and everything that shows a truncated title gains as much: where a text is cut
  is kept, it was measured again at every frame.
- The site and the README: the palette, a diff, the tray, updates; every picture taken again.

### Added

- `advanced.frame_rate` (Settings > Advanced): how many frames go out while something moves: as the screen takes them, a ceiling, or
  uncapped. What you type and click is read at once whatever it says.

### Fixed

- A long jump up (a match of Find, Home) no longer ends at the bottom when the first page arrives on the way.

## [0.11.0] - 2026-11-05

### Added

- **The command palette** (Ctrl+K, Ctrl+P): commands, sessions, agents, models, the server's commands and the switches of the
  preferences in one field, narrowed by `>` `@` `/` `#` `:`; what was chosen before comes first. One table of commands
  (`src/commands.odin`) feeds the keyboard, the palette and the shortcuts' dialog (F1). `/name` in the composer runs a command of
  the server.
- **The composer's history**: Up and Down go through what was sent, the session's prompts first, then the others'; what was being
  typed comes back past the newest one or on Escape.
- **What runs in the background**: Down from the composer (or Ctrl+J) opens a tray under it: the sub-agents and the shell
  commands of the session's folder, each with the tail of what it prints, and the whole todo list. Enter opens, Delete stops.
- **Tool calls by what they do**: a diff for what edits a file (the server's patch, else made with `core:diff`), with line numbers
  and what changed in a line marked, shown even folded; the lines of a file, matches under their file, a command and its
  output, a checklist; the input of the others as keys and values, never as raw JSON.
- **The Preview panel** (Ctrl+Shift+B): a web page beside the conversation in a dock whose layout is kept; WebView2 on Windows,
  its profile apart from the user's browser. `localhost` links open there.
- **The agents' browser tools**: the client hosts an MCP server, `preview`, on the server's client-mcp socket: open a page, read it,
  click, fill, run a script, read its console, take a picture. It follows the folder of the session shown (`browser.tools`).
- **The home page**: where to start, what runs, the latest sessions (`general.start`).
- **Updates** (Windows): channels `stable` and `beta`, manifests signed with Ed25519, the channel in what is signed; downloaded,
  checked and put in place from the status bar. See docs/updates.md.
- **Right clicks**: on a prompt, an answer, a tool call and the composer. Rename and fork a session.
- **Paste** an image or files in the composer. **A click of the wheel** scrolls by the pointer.
- **Two zooms**: the conversation's (Ctrl + = - 0, Ctrl and the wheel over it) and the interface's (Ctrl + Shift + = - 0, Ctrl and
  the wheel elsewhere).
- A new session starts with the agent and the model chosen last, from one run to the next.
- `appearance.throbber`: a board that spells what the agent does, dots in orbit, the scanner, or nothing.
- `advanced.fps`: the frame rate and what a frame costs, in the status bar.
- **Quote a passage**: select text in an answer, then the chip, the right click or Ctrl+Q: it goes in the composer as a quote.
- **Latest**: a pill over the composer when the conversation is more than a screen from its end; a click goes back there.
- A text that names an action does it: the hints under the composer are clickable.
- Settings: the pages **Updates** (version, channel, check now) and **Advanced** (the agents' browser tools, FPS, the settings'
  folder).

### Changed

- gui_toolkit 0.78.0.
- The list of the settings' pages scrolls: it no longer leaves the dialog in a short window.
- The window opens on the home page; `general.start` = `last` opens the latest session.

### Fixed

- What follows the pointer without a button held (a row lit in a menu) came late on a variable refresh screen that Windows reports
  at 60 Hz: such frames now run at the screen's top rate (16.7 to 6 ms between two frames on a 180 Hz screen).

## [0.10.0] - 2026-11-03

### Added

- `src/bench_test.odin`: the program on its heavy cases in the test's process, no server (a conversation of 150 answers,
  400 sessions); `-define:OCC_BENCH=true` times them. docs/performance.md: what was measured.

### Changed

- **Built with Odin dev-2026-11** (`odin.version`, the CI's archives pinned by SHA-256, `flake.nix`): `core:image`'s pixels are
  a `[dynamic]u8`.
- gui_toolkit 0.70.0: menus are denser and scroll when taller than the window; threads shaping text share the word cache's lock.
- **The sidebar builds the sessions it shows** (a lazy column, as the conversation): with 400 sessions a frame took 8.4 ms,
  now 1.6 ms; typing, scrolling and a streamed answer 10 to 11 ms, now 2.4 to 2.5 ms (docs/performance.md).
- **A faster start**: the graphics device is made while the rest starts, the fonts load meanwhile (first frame 200 -> 183 ms).
  `--frames=N` says how long the first frame took.

## [0.9.0] - 2026-11-01

### Added

- `flake.nix`: `nix develop -c ./build.sh` builds on Linux with the Odin, wgpu-native and libraries the CI uses; `tools/screenshots.mjs
  --linux-build` takes the Linux picture from this tree, no release needed.
- **On Linux, color emoji**: from the system's emoji font, COLR or CBDT.
- **On Linux, cursors**: from the user's theme, on X11 and on Wayland.
- **On Linux, fractional scaling on Wayland**: at 150 % the window is drawn at 150 %, not at 200 % and shrunk.

### Changed

- gui_toolkit 0.61.0.

## [0.8.2] - 2026-11-01

### Changed

- gui_toolkit 0.60.2.

### Fixed

- **Command line arguments keep every character on Windows**: `--search=Łódź` arrived as `L�dz`, and paths and passwords
  outside the system's code page were damaged the same way.

## [0.8.1] - 2026-11-01

### Changed

- gui_toolkit 0.60.1.

### Fixed

- **Find in code**: a match in inline code showed only as a line at each end, the code's background over it. The selection
  had the same fault.
- **Find is legible**: the letters of a match are dark, on stronger backgrounds (contrast about 9 on the current match, 7 on
  the others, against 1.8 and 2.9 for code).

## [0.8.0] - 2026-11-01

### Added

- `tools/font_proposals.mjs` tries typefaces in the real client (`--font-dir=<folder>`, nothing installed);
  `tools/check_embedded_fonts.mjs` checks that a build holds its fonts.

### Changed

- **A typeface of its own**: Hanken Grotesk for the interface, Newsreader for the answers, DM Mono for code, built into the
  program, so it looks the same on Windows and Linux. Settings > Appearance goes back to the system's faces (Font, Mono font:
  System; Prose font: As the interface). Characters outside Latin come from the system's fonts.
- gui_toolkit 0.60.0.

### Fixed

- **Answers keep an even line height**: inline code no longer pushes its line apart.

## [0.7.0] - 2026-11-01

### Added

- **Zoom and pan in the image viewer**: the wheel zooms where the pointer is, a drag or the arrows move the picture, + - 0 and
  buttons, a double click between fit and 100 %. From half of what fits up to 8 times its pixels. A click no longer closes it.
- **Scroll bars hide** unless the pointer is over what they scroll, or the keyboard just scrolled it (a setting, on by default).
- **An older installed copy is offered an upgrade**: Setup opens at the start of a newer copy, once per version.
- `tools/screenshots.mjs` regenerates every picture of the README and the site over the DevTools protocol, the mouse and the
  windows in front left alone; `--linux` takes the Linux one from a release's build in WSL (`tools/wsl_client.sh`).
  `--size=<w>x<h>` sets the window's size in pixels, `--image=<file>` opens the viewer on a file.

### Changed

- gui_toolkit 0.59.0.

### Fixed

- **The join of the sidebar, its splitter and the bars**: one carved line, from the title bar down through the status bar, no doubled borders or gaps.

## [0.6.0] - 2026-10-31

### Changed

- **The sub-agent card and the strip above the composer are redesigned**: neutral plates, colour only on the state mark, the
  details in one quiet line.
- **Saved server passwords are no longer stored in clear**: DPAPI on Windows; on Linux the Secret Service, else `servers.txt` at
  mode 0600, with a note in the server dialog. Older files are converted at start, and older versions cannot read them afterwards.
- **Folded reasoning and collapsed results read as text**, without Markdown marks.
- **Text sizes follow one named scale**, with small differences in some labels.
- **The Tool lines slider reaches 1000**, as the setting does.
- **Notifications appear at the top right**: at the bottom they covered Send.

### Fixed

- **The password of this computer's server is no longer sent** to the server named by `--url`.
- **A link in a conversation could run a program**: only http, https and mailto links open now; anything else says so.
- **The app could read freed memory** when opening a sub-agent during a frame, and when sending a new session after changing
  server.
- **Messages from the app never appeared**: its toasts were never drawn.
- **One failed request no longer disables Send**: the status follows the event stream.
- **A prompt that could not be sent comes back** to the composer, ahead of anything typed since.
- **Reading a long session again no longer grows the memory**, and answers from an earlier read of the settings no longer add
  rows twice.
- **A title or a text with `##` is shown whole.**
- **Tabbing to a slider no longer rewrites a setting.**
- **Failed saves say so**, and a failed update puts the installed program back.
- **An `https://` address in `service.json` is used as https.**
- **Linux, from gui_toolkit 0.58**: copy and paste and drag and drop on X11, input during an animation on Wayland, key repeat. A
  resize no longer stretches the window, and the sizes of thin lines follow the scale.

## [0.5.6] - 2026-10-31

### Fixed

- **Closing Chrome's DevTools** could leave the program on freed memory: its edits could stay, and it could hang. Only with
  `TOOLKIT_DEVTOOLS=<port>` (gui_toolkit 0.57.1).

## [0.5.5] - 2026-10-31

### Added

- **Chrome's DevTools on the window**, with `TOOLKIT_DEVTOOLS=<port>`: the interface's boxes in Elements, their colours and sizes
  edited live, what a screen reader gets for each (gui_toolkit 0.57).

## [0.5.4] - 2026-10-31

### Added

- **The keyboard scrolls the conversation**: Page Up and Page Down from anywhere, the composer too; the arrows, Home and End
  when no text field has the keyboard.

### Changed

- **Endless scrolling**: scrolling up reads earlier messages by itself, in place of the "Load earlier messages" button.
  A line shows them on their way if you reach the top first, and what is on screen stays where it is when they arrive.
- **A reload keeps the pages already read** (F5, the end of a run). It used to go back to the last page.

### Fixed

- **Earlier messages could not be read** on the current server: it refused the request (`Cursor cannot be combined with
  order`).
- **The scroll bar jumped up and down at the bottom of a conversation**, without end, after coming back to a session: events
  that draw nothing changed the conversation's height at every frame (gui_toolkit 0.56.2).

## [0.5.3] - 2026-10-30

### Added

- **Timelines of the window**, with `TOOLKIT_DEVTOOLS=<port>` and gui_toolkit's `tools/cdp.mjs`: a run kept whole, each
  action with its time and a picture, as one page to share, then played back and compared (gui_toolkit 0.56).

### Fixed

- **Screen readers**: the images of a conversation had no name, and were not announced at all.
- **A screenshot over the DevTools Protocol** took two seconds and froze the window; 66 ms now, measured on a window of
  2310x1505 (gui_toolkit 0.56.1).

## [0.5.2] - 2026-10-30

### Added

- **The window driven by a script**: `TOOLKIT_DEVTOOLS=<port>` serves it over the Chrome DevTools Protocol on 127.0.0.1,
  for tests and tools: clicks, keys, screenshots, the accessibility tree, without the machine's mouse. Off unless asked
  for, and a web page cannot use it (gui_toolkit 0.55.0).

### Changed

- **A frame less between input and screen**: 34 ms instead of 48, measured from a key to the screen (gui_toolkit 0.55.0).
- **Long conversations**: the toolkit's lazy column replaces the app's own. Items not built stand as estimates and the
  view stays on what it shows, so a change of width no longer builds every message again.

### Fixed

- **Screen readers**: the accent colours, sliders and switches of the settings, their reset buttons and the sidebar's
  splitter had no name; the colours and the splitter were not announced at all.

## [0.5.1] - 2026-10-30

### Fixed

- **A long conversation no longer slows every frame**: only the messages near the view are built, the others stand as a
  space of their measured height (all are built again when the column's width changes, and while finding). Sweeping the
  pointer over the sessions of a long conversation drew about 21 frames a second; 60 now, measured.
- **The dialogs' close cross** sits clear of the scroll bar along a scrolling dialog's right edge.

## [0.5.0] - 2026-10-30

### Added

- **Find in the conversation** (Ctrl+F): a bar over the conversation's top-right corner; every match of the text shown
  (Markdown, code, tool outputs, sub-agent cards) lit, the current one brighter and scrolled into view; Enter or F3 for
  the next, Shift+Enter or Shift+F3 for the previous, Escape or the cross to close. `--find=<text>` opens it at start.
  (gui_toolkit 0.53.0: find in page.)
- **Smooth scrolling** (Settings > Appearance, on by default): the wheel glides even when Windows turns animations off,
  where every notch used to jump (gui_toolkit 0.54.0).

### Changed

- **Fields show their edge** when they are not focused: a lit rim around the composer, the searches and the dialogs'
  fields, which the accent replaces under the focus.

## [0.4.3] - 2026-10-30

### Fixed

- **This computer's server is found where it runs**: the background service's own state
  (`~/.local/state/opencode/service.json`, what `opencode service status` prints) comes before its configuration, whose
  port may be stale or absent. While it does not answer, the client looks again every few seconds and reconnects when
  the address changed (a service started later, or on another port).
- **The dialog that adds a server** was stretched down to the window's height (labels sized as a percentage inside rows
  sized by their content): it fits its fields again, and its hint is no longer cut.

### Added

- `--add-server` opens that dialog at start.

## [0.4.2] - 2026-10-30

### Added

- **A close cross** in the top-right corner of the dialogs (Settings, Statistics, Setup, a server, an image), as well as
  Escape and a click outside.

### Fixed

- **The segmented choices** (Settings): the selected label and the others sit on the same line (gui_toolkit 0.52.0).

## [0.4.1] - 2026-10-30

### Added

- **Fonts in Settings > Appearance**: the interface's face and the code's, each "automatic" (the system's usual one),
  "built in" (Roboto, Inconsolata: in the program) or any installed family, chosen in a picker searched as one types.

### Changed

- **The icons are Lucide everywhere**, embedded in the program: Windows no longer depends on Segoe Fluent Icons, and the
  icons look the same on every system.

## [0.4.0] - 2026-10-29

### Added

- **Linux** (x64): the same program, built by `build.sh` (Vulkan through wgpu-native, the toolkit's native text backend
  in the Rust library, Lucide icons, fontconfig's fonts); Setup installs it in `~/.local/share` with an applications menu
  entry and its icon; preferences in `~/.config/opencode-native`. CI and releases build Windows and Linux.
- **Several servers**: the status bar's server is a menu (switch, add, edit, remove; a password field that shows bullets),
  saved in `servers.txt`; each connection has its own client and event stream, and switching drops what was read from the
  last one. Another computer's server is named in the title bar. `--server=<name>`.
- **Pickers searched as one types** for the agent and the model: subsequence matching ("cs5" finds Claude Sonnet 5, the
  provider counts too), the matched letters lit, the keyboard, the wheel (smooth), the current one checked.
- **A timeline of tool calls**: a carved rail through a run of calls, across the steps that go on from each other; a lamp
  only on the running call, a pip on the finished ones (red when it failed). Consecutive steps of the same agent and model
  share one header (a rail in the agent's colour). Work going on: a slot with a sweeping glint.
- `--setup` opens the Setup dialog at start; `build.bat` / `build.sh` take `OUT=<file>`.

### Changed

- Fewer lamps and calmer glows: finished sub-agents and the connected state are pips; accent buttons glow only under the
  pointer; halos about half as strong.

### Fixed

- Opening a session showed it at its top for a moment, then scrolled down: it lands at its bottom in the frame it arrives.
- Holding a splitter or a scrollbar on a high refresh rate screen was paced like a window at rest (the cadence's Drag
  state now: shown at once on a variable refresh screen).
- The composer showed a horizontal scrollbar (toolkit: a wrapped editor measured its width from the last layout).
- The carved line under the title bar was half covered by the sidebar, whose rounded corner also notched it: the lines
  between regions now have a box as thick as they are drawn (more than 2 px when the display is scaled), and the
  sidebar and the conversation have square corners.
- Dialogs hid the window behind them (an opaque backdrop): it shows through now, blurred and darkened.
- Setup: once installed, four buttons overflowed the dialog; what is left is Close and Open installed copy.

## [0.3.0] - 2026-10-29

### Added

- **Statistics of a session**: the header's token count (and Ctrl+I, the menu) opens them: totals in tiles (tokens in,
  out, reasoning, cost, cache hits), the context the last step filled against the model's window, tokens in detail, time
  (created, last change, the model at work, output pace), tool calls by tool with failures, models, sub-agents, and the
  project's totals from the server (sessions, sub-agents, prompts, steps, tokens, cost, active days, streak, tools with
  their median duration, models).
- **Markdown tables** as grids: columns as wide as their cells, the header row bold on a tint, alignments from the
  separator row, alternate rows shaded (they were shown as raw text in a code block).
- Screenshots in the README; `--search=<text>` fills the sidebar's search at start, `--stats` opens the statistics.

### Fixed

- Dragging the conversation's scrollbar moved nothing while it followed its bottom (the drag, applied before the build,
  was undone by the following).
- The halo of a lit button reached the carved edge above it and darkened under it (tighter now).

### Changed

- CI: actions/checkout v7, actions/cache v6, actions/upload-artifact v7 (Node 24); the MSVC environment is set by a
  step of the setup action (vcvars64 through vswhere) instead of ilammy/msvc-dev-cmd, whose releases still run on Node 20.

## [0.2.0] - 2026-10-29

### Added

- **Sub-agents**: a card for each launch (state lamp, agent, description, duration, model, tool calls, tokens, cost;
  unfolded: the session's facts, the prompt, the result in Markdown); the result line where it came back; drill down into
  a sub-agent and back (breadcrumb, Back, Alt+Left, the banner of its conversation); the running ones first and lit: their
  count in the header, a strip above the composer with what each does now, the finished ones dimmed and folded; the
  sidebar lists a session's sub-agents under it.
- **Images**: thumbnails of the images attached to prompts and of those tools hand back, a viewer; projects' logos in the
  sidebar, the title bar and the header. Decoded by the Rust library (PNG, JPEG, WebP, GIF, BMP) on worker threads.
- **Settings** (Ctrl+,): appearance (accent, text size, zoom, density, rounding, animations, glow), the conversation
  (column width, reasoning, tools unfolded, output lines, page size, following, usage, clock), the send key, sub-agents in
  the sidebar, notifications (a toast, the taskbar flashing); the server's pages: shell, MCP servers, usage and budgets,
  saved permissions, providers, models, agents, skills, commands, configuration files.
- **Desktop integration**: an icon and a version resource; Setup installs the copy for the user (Start menu shortcut with
  its AppUserModelID, a Settings > Apps entry, uninstall), `--install`, `--uninstall`, `--status`.
- HTTP over a Rust library (ureq, rustls with the system's trust store): `https` servers work.

### Fixed

- A window being resized no longer shows its last frame stretched: the resize step is presented at once and the swap
  chain keeps the monitor's size (the toolkit's cadence model and fixed surface).
- Opening or closing a tool card keeps it under the pointer; the conversation stops following its bottom.
- The "+" of a folder of the sidebar could not be clicked (it vanished when the pointer reached it).

## [0.1.0] - 2026-10-29

### Added

- First version: sessions grouped by folder, the conversation streamed from the event stream with Markdown, reasoning and
  tool cards, the composer with the agent and the model, permission requests, the integrated title bar.

[Unreleased]: https://github.com/sachahjkl/opencode_native/compare/v0.12.3...HEAD
[0.12.3]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.12.3
[0.12.2]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.12.2
[0.12.1]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.12.1
[0.12.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.12.0
[0.11.9]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.11.9
[0.11.8]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.11.8
[0.11.7]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.11.7
[0.11.6]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.11.6
[0.11.5]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.11.5
[0.11.4]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.11.4
[0.11.3]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.11.3
[0.11.2]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.11.2
[0.11.1]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.11.1
[0.11.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.11.0
[0.10.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.10.0
[0.9.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.9.0
[0.8.2]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.8.2
[0.8.1]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.8.1
[0.8.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.8.0
[0.7.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.7.0
[0.6.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.6.0
[0.5.6]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.5.6
[0.5.5]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.5.5
[0.5.4]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.5.4
[0.5.3]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.5.3
[0.5.2]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.5.2
[0.5.1]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.5.1
[0.5.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.5.0
[0.4.3]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.4.3
[0.4.2]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.4.2
[0.4.1]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.4.1
[0.4.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.4.0
[0.3.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.3.0
[0.2.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.2.0
