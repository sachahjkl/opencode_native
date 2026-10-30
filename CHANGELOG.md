# Changelog

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

First version: sessions grouped by folder, the conversation streamed from the event stream with Markdown, reasoning and
tool cards, the composer with the agent and the model, permission requests, the integrated title bar.
