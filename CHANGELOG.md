# Changelog

All notable changes to opencode native. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project follows [semantic versioning](https://semver.org).

## [Unreleased]

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

[Unreleased]: https://github.com/sachahjkl/opencode_native/compare/v0.9.0...HEAD
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
