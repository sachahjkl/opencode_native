<p align="center"><img src="assets/logo_256.png" width="128" alt="opencode native logo"></p>

<h1 align="center">opencode native</h1>

<p align="center"><b>A native desktop client for the <a href="https://opencode.ai">opencode</a> v2 server.</b></p>

<p align="center"><a href="CHANGELOG.md"><img src="https://img.shields.io/badge/version-0.2.0-fab283" alt="version 0.2.0"></a></p>

One Windows executable, 4 MB, no runtime to install: [Odin](https://odin-lang.org) on
[gui_toolkit](https://github.com/sachahjkl/gui_toolkit) (Direct3D 11, DirectWrite, a retained-state immediate-mode UI),
with a small Rust library for HTTP and images. It talks to the opencode server the desktop app already runs on the
machine, in opencode's dark palette with machined surfaces: bevelled and ridged buttons, sunken wells, carved grooves,
glowing status lamps.

    build.bat          ->  build\opencode-native.exe
    build.bat debug    ->  debug information and console output

Prebuilt binaries are attached to the [GitHub releases](https://github.com/sachahjkl/opencode_native/releases).

## What it does

- **Sessions** grouped by project folder, with the project's logo; search; running ones lit; sub-agents nested under
  the session that launched them (the active ones counted and shown first).
- **The conversation, streamed live** from the server's event stream: Markdown (headings, lists, quotes, tables, code
  blocks with a copy button), the model's reasoning (folded, unfolded or hidden), every tool call as a card (its state
  lamp, what it works on, its input and output), tokens and cost.
- **Images**: those attached to prompts and those tools hand back (screenshots, images read) as thumbnails, opened in
  a viewer; projects' logos in the sidebar, the title bar and the header. PNG, JPEG, WebP, GIF and BMP, decoded off the
  interface's thread.
- **Sub-agents**: a card for each launch (its agent, state, live activity, duration, model, tokens, cost, prompt and
  result), the result line where it came back, a strip of the running ones above the composer, a header menu of all of
  them; drill down into one and back (breadcrumb, Alt+Left).
- **The composer**: Enter or Ctrl+Enter to send (a setting), the agent and the model of the session, Stop while it runs.
- **Permission requests** answered in place (once, always, reject).
- **Settings** (Ctrl+,): accent colour, text size, zoom, density, rounding, animations, glow; how the conversation shows;
  the send key; sub-agents in the sidebar; notifications when a session finishes or asks (a toast, the taskbar button
  flashing). And what the server lets one see or change: its shell, its MCP servers (connect, disconnect), the usage
  limits and budgets of an OpenCode workspace, the saved permissions (revoke), providers, models, agents, skills,
  commands, the configuration files.
- **Desktop integration** without administrator rights: Setup installs the running copy for the user (Start menu
  shortcut with its AppUserModelID, a Settings > Apps entry, an uninstaller).

## The server

Without arguments the client uses the server of the opencode desktop app: `~/.config/opencode/service.json` gives its
port and password (Basic authentication as `opencode`). Elsewhere:

    opencode-native.exe --url=https://host[:port] --password=...

TLS is rustls, checked against the system's trust store.

## Command line

| | |
|---|---|
| `--url=...`, `--password=...` | another server |
| `--session=<id>` | open that session at start |
| `--install [--desktop]` | install this copy for the user (`%LOCALAPPDATA%\Programs\opencode-native`, Start menu, Settings > Apps) |
| `--uninstall [--quiet]` | remove it (what Settings > Apps runs) |
| `--status` | exit code 0 installed, 2 needs repair, 1 not installed |
| `--pref name=value` | set a preference for the run (names in Settings, e.g. `appearance.accent=blue`) |
| `--settings[=n]` | open the settings at start (on page n) |
| `--frames=N` | N frames of a hidden window, then exit (a check that it runs) |

Preferences live in `%APPDATA%\opencode-native\prefs.txt` (only what differs from the defaults);
`OPENCODE_NATIVE_NO_SETUP=1` never offers Setup.

## Building

Needs the Odin compiler named in `odin.version` (`dev-2026-10`), MSVC (Visual Studio or its Build Tools: `link.exe`,
`rc.exe`) and Rust (the stable toolchain of rustup, `x86_64-pc-windows-msvc`).

    git clone --recursive https://github.com/sachahjkl/opencode_native
    cd opencode_native
    build.bat

`build.bat` builds the Rust library first (`tools\build_native.ps1`, nothing when it is up to date; crates pinned by
`native\Cargo.lock`), writes the version resource's numbers, then the exe. The toolkit is the submodule
`ext\gui_toolkit`; `set GT=<folder>` builds against another copy. `build.bat logo` draws the logo again.

## Layout

| | |
|---|---|
| `src/main.odin` | window, loop, fonts, frame pacing (the toolkit's cadence model: a resize step is presented at once) |
| `src/net.odin`, `src/http.odin` | server discovery, requests on worker threads, the event stream (`ui.post`) |
| `src/model.odin` | sessions, messages, parts and projects; events applied as they stream |
| `src/views.odin`, `src/markdown.odin` | sidebar, conversation, tool cards, composer, Markdown |
| `src/subagents.odin` | sub-agent cards, results, navigation, the running strip, the sidebar tree |
| `src/images.odin` | image decoding (worker threads), the texture cache, thumbnails, the viewer, logos |
| `src/settings.odin` | preferences (`gt:config`) and the settings dialog, with the server's pages |
| `src/style.odin` | the palette and the machined surfaces |
| `src/setup.odin`, `src/desktop_windows.odin` | version, Setup dialog, install / uninstall |
| `native/occ_native` | the Rust library (C functions): ureq + rustls, image decoding |
| `res/`, `assets/` | resources of the exe (icon, version, manifest), the logo (`tools\make_logo.ps1`) |

## License

MIT, see [LICENSE](LICENSE). opencode is a project of its own ([opencode.ai](https://opencode.ai)); this client is not
affiliated with it.
