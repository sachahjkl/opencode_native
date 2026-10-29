# Changelog

## [Unreleased]

### Fixed

- The carved line under the title bar was half covered by the sidebar, whose rounded corner also notched it: the lines
  between regions now have a box as thick as they are drawn (more than 2 px when the display is scaled), and the
  sidebar and the conversation have square corners.
- Dialogs hid the window behind them (an opaque backdrop): it shows through now, blurred and darkened.
- Setup: once installed, four buttons overflowed the dialog; what is left is Close and Open installed copy.

### Added

- `--setup` opens the Setup dialog at start.

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
