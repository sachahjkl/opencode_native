<p align="center"><img src="assets/logo_256.png" width="128" alt="opencode native logo"></p>

<h1 align="center">opencode native</h1>

<p align="center"><b>A native desktop client for the <a href="https://opencode.ai">opencode</a> v2 server, for Windows and Linux.</b></p>

<p align="center"><i>An independent project: it is not built by the OpenCode team, and it is not affiliated with them in any way.</i></p>

<p align="center">
<a href="CHANGELOG.md"><img src="https://img.shields.io/badge/version-0.29.0-fab283" alt="version 0.29.0"></a>
<a href="https://ocn.froment.software/"><img src="https://img.shields.io/badge/site-ocn.froment.software-56b6c2" alt="site"></a>
</p>

![A conversation: the tool calls on their timeline, sub-agents at work, the agent's reasoning](docs/screenshots/subagents.png)

One program, no runtime to install, written in [Odin](https://odin-lang.org) on [gui_toolkit](https://github.com/sachahjkl/gui_toolkit),
with a small Rust library for HTTP and images. It draws with Direct3D 11 on Windows and Vulkan on Linux. It talks to the opencode
server running on this computer (or any other), in opencode's dark palette with machined surfaces: bevelled and ridged buttons, sunken
wells, carved grooves, and lamps only where something is live.

    build.bat          ->  build\opencode-native.exe     (Windows)
    ./build.sh         ->  build/opencode-native         (Linux)

Prebuilt programs for Windows x64 and Linux x64 are attached to the [GitHub releases](https://github.com/sachahjkl/opencode_native/releases);
the [site](https://ocn.froment.software/) shows them. On NixOS, install the Nix package instead (`flake.nix` builds it
from the sources, with its menu entry and its icon); `nix profile upgrade opencode_native` updates it:

    nix profile add git+https://github.com/sachahjkl/opencode_native

The address is `git+https://`, not `github:`: the build needs the gui_toolkit submodule, and GitHub's archives, which
`github:` fetches, never hold submodules.

## Screenshots

| | |
|---|---|
| ![A conversation: Markdown tables, the answer of an agent](docs/screenshots/conversation.png) | ![Find in the conversation: the matches lit, the current one brighter](docs/screenshots/find.png) |
| **The conversation**: Markdown, code, tokens per answer | **Find** (Ctrl+F): every match lit, Enter / F3 to the next one |
| ![The command palette, commands listed](docs/screenshots/palette.png) | ![An edit shown as a diff](docs/screenshots/diff.png) |
| **The palette** (Ctrl+K): commands, sessions, agents, models, switches | **A diff** for what edits a file: line numbers, what changed in a line |
| ![The tray under the composer, the todo list](docs/screenshots/activity.png) | ![Settings: updates](docs/screenshots/updates.png) |
| **What runs in the background** (Down from the composer, Ctrl+J) | **Updates**: signed, stable or beta |
| ![The conversation of a sub-agent: where it comes from, the way back](docs/screenshots/subagent-session.png) | ![The model picker, searched as one types](docs/screenshots/picker.png) |
| **A sub-agent's own conversation**: the breadcrumb, Back | **The model picker**: subsequence search ("sonnet"), the matched letters lit |
| ![Session statistics](docs/screenshots/statistics.png) | ![Settings: the themes, each in its own colours](docs/screenshots/settings.png) |
| **Statistics** (click the token count): totals, context window, time, tools, models, the project | **Themes**: twenty, dark and light or as the system, machined or flat, and your own in themes.txt |
| ![Gruvbox, light](docs/screenshots/theme-gruvbox-light.png) | ![Nord, flat](docs/screenshots/theme-nord-flat.png) |
| **Gruvbox**, its light version | **Nord** in the flat style: plain surfaces, thin lines |
| ![Retro: a black that holds, colours that pop](docs/screenshots/theme-retro.png) | ![The conversation](docs/screenshots/conversation.png) |
| **Retro**: a black that holds, colours that pop | **OpenCode**, its own black and peach |
| ![An image in the viewer, zoomed in](docs/screenshots/viewer.png) | ![On Linux](docs/screenshots/linux.png) |
| **The image viewer**: zoom where the pointer is, drag to move | **On Linux** (Wayland, Vulkan): the same program |
| ![The terminal panel under the conversation](docs/screenshots/terminal.png) | ![@ in the composer, the files of the folder proposed](docs/screenshots/mention.png) |
| **A terminal** (Ctrl+Shift+T): Ghostty's emulation, the shells of the server | **@** names a file or a sub-agent, as you type |
| ![The files of the session's folder, one of them read](docs/screenshots/files.png) | ![Settings: the integrations of the server](docs/screenshots/connections.png) |
| **The files of a session** (Ctrl+P): browse, search, read, mention | **Connections**: every integration of the server, several accounts of each |

## What it does

- **A typeface of its own**, built into the program: Hanken Grotesk for the interface, Newsreader for the answers, DM Mono
  for code. Settings > Appearance goes back to the system's faces. Below 150 % text is smoothed per colour stripe of the screen's
  pixels, on Windows and on Linux, as the system says; Text smoothing chooses RGB, BGR or grey.
- **Sessions** grouped by project folder, with the project's logo; search; running ones lit; sub-agents nested under
  the session that launched them (the active ones counted and shown first).
- **The conversation, streamed live** from the server's event stream: Markdown (headings, lists, quotes, tables as
  aligned grids, code blocks with a copy button), the model's reasoning (folded, unfolded or hidden), the tool calls on a
  timeline (a carved rail through a run of calls, a lamp on the one running, a pip on the finished ones, their input and
  output in wells), tokens and cost. Switching sessions lands on the bottom at once. Scrolling up reads earlier messages by itself, a line
  showing the ones on their way if you get there first; Page Up and Page Down scroll it from anywhere, the arrows, Home and
  End when no field has the keyboard.
- **Images**: those attached to prompts and those tools hand back (screenshots, images read) as thumbnails, opened in
  a viewer as large as the picture (resized by its edges, its size kept) that zooms where the pointer is and moves by a drag
  or the arrows, within limits, and copies the image (right click, Ctrl+C); projects' logos in the sidebar, the title bar and the header. PNG, JPEG, WebP, GIF and BMP, decoded off the
  interface's thread.
- **Sub-agents**: a card for each launch (its agent, state, live activity, duration, model, tokens, cost, prompt and
  result), the result line where it came back, a strip of the running ones above the composer, a header menu of all of
  them; drill down into one and back (breadcrumb, Alt+Left).
- **The composer**: Enter or Ctrl+Enter to send (a setting), the agent and the model of the session in pickers searched
  as one types (subsequence matching, the matched letters lit, the keyboard or the wheel), Stop while it runs. Files
  go with a prompt by the paperclip, a paste or a drop on the window: images, PDF and text files are attached.
- **Several servers**: this computer's (found by itself), others added from the status bar's server menu (a name, an
  address, a password), `--url`; switch from the menu. Another computer's server is named in the title bar.
- **Find in the conversation** (Ctrl+F): every match of the text shown lit, the current one brighter and scrolled into
  view; Enter or F3 for the next, Shift+Enter or Shift+F3 for the previous, Escape to close.
- **An inbox in the sidebar**: what waits for you first, then what finished and you have not seen, what runs, the rest. The grouping by project is one click away.
- **The command palette** (Ctrl+K, Ctrl+Shift+P): commands, sessions, agents, models, the server's commands and the switches of the
  settings in one field, narrowed by `>` `@` `/` `#` `:`. F1 lists the keys.
- **Tool calls by what they do**: a diff for what edits a file, the lines of a file, matches under their file, a command and its
  output, a checklist.
- **What runs in the background**: a tray under the composer (Down, Ctrl+J) with the sub-agents, the shell commands and the whole
  todo list; Enter opens, Delete stops.
- **The Preview panel** (Ctrl+Shift+B, Windows): a browser for each session, with tabs, beside the conversation, in a dock; agents drive it through the MCP server
  `preview` the client hosts.
- **Updates** (Windows, Linux): channels `stable` and `beta`, signed manifests, nothing installed without you ([docs/updates.md](docs/updates.md)).
- **Back and Forward**, as in a browser: buttons in the title bar, Alt+Left and Alt+Right, the side buttons of the mouse. The view goes
  back to the very place it was read. The logo goes home.
- **What an agent asks**: its questions and any form of the server over the composer, one question at a time, in tabs, then a review.
  The sidebar lights a session that waits for you, a sub-agent's question comes up in its parent.
- **Permission requests** answered in place (once, always, reject).
- **A terminal** with Ghostty's emulation (libghostty-vt): each shell of the server a tab of the dock or a window of its own, wherever it runs, kept when the program closes.
- **Schedules** that wake a session, **artifacts** of a folder, **plugins** of the server. The server's experimental options are turned on by default, in its configuration, on this computer.
- **Connections**: the integrations of the server, connected with a key, a browser login or what is on the machine; several accounts of each.
- **Messages wait in view**: while a turn runs, Enter queues a message for its end and Ctrl+Enter sends it now. What waits is listed above the composer, in order: edit it, send it now, remove it.
- **`@` in the composer** names a file or a sub-agent. **Browse the files** of a session (Ctrl+P), search them, read them, mention one.
- **Go back to a prompt**, its files restored, after seeing which. What a session or a prompt changed, file by file.
- **Move a session** to another folder, **export** it to a file and **import** it, with or without its text.
- **Statistics of a session** (its token count in the header, Ctrl+I): tokens in, out, reasoning, cache reads and
  writes, cost, cache hits, the context the last step filled against the model's window, time and pace, tool calls by
  tool (failures counted), models, its sub-agents, and the whole project's totals from the server.
- **Settings** (Ctrl+,): the theme (17 of them, each dark and light, as the system or always one; themes of your own in `themes.txt`) and the style (machined or flat), the fonts of the interface, the answers and code (built in, the system's, or any installed one, in a searched picker), text size, zoom, density, rounding, animations, smooth scrolling, scroll bars that hide, glow; how the conversation shows;
  the send key; sub-agents in the sidebar; notifications when a session finishes or asks. And what the server lets one see
  or change: its shell, its MCP servers (connect, disconnect), the usage limits and budgets of an OpenCode workspace, the
  saved permissions (revoke), providers, models, agents, skills, commands, the configuration files.
- **Desktop integration** without administrator rights: Setup installs the running copy for the user, and opens by itself to offer an upgrade when a newer copy starts over an older install. On Windows: a
  Start menu shortcut with its AppUserModelID, a Settings > Apps entry, an uninstaller. On Linux: `~/.local/share`, an
  entry in the applications menu and its icon. In the install folder a manifest (`opencode-native-install.txt`) lists the
  version and the files placed: the uninstall removes exactly these. On NixOS, Setup advises the Nix package, and still makes a
  classic install on request: nix-build makes a profile of the libraries it needs, and the installed copy runs with it.
  A copy that runs from the Nix store is never offered an install or an update. An install made by Setup 0.20.0 or
  earlier shows as one to repair: Repair (or Uninstall) handles it in one click. The `desktop` package of gui_toolkit does
  the work.

## The server

Without arguments the client uses this computer's opencode server: where the background service runs
(`~/.local/state/opencode/service.json`, what `opencode service status` prints), else what `~/.config/opencode/service.json`
asks for; with its password (Basic authentication as `opencode`). Until it answers, the client looks again every few seconds. Others: the status bar's server menu (saved in
`servers.txt` beside the preferences), or

    opencode-native --url=https://host[:port] --password=...

TLS is rustls, checked against the system's trust store.

## Command line

| | |
|---|---|
| `--url=...`, `--password=...` | another server |
| `--server=<name>` | a saved server at start |
| `--session=<id>` | open that session at start |
| `--search=<text>` | the sidebar's search, filled at start |
| `--install [--desktop]` | install this copy for the user, or repair the install (Windows: `%LOCALAPPDATA%\Programs\opencode-native`, Start menu, Settings > Apps; Linux: `~/.local/share/opencode-native`, the applications menu, the icon); `--desktop` adds a shortcut on the Desktop |
| `--uninstall [--quiet]` | remove it (it asks first unless `--quiet`); the files of a copy that runs go when it ends |
| `--status` | prints the state and the installed program; exit code 0 installed, 2 needs repair, 1 not installed |
| `--setup` | open Setup at start |
| `--add-server` | open the dialog that adds a server at start |
| `--find=<text>` | open the find bar (Ctrl+F) with that text |
| `--scale=<factor>` | the interface's scale whatever the screen's (`1`: 100 %; screenshots) |
| `--size=<w>x<h>` | the window's size in pixels (screenshots) |
| `--image=<file>` | open the image viewer on a file |
| `--font-dir=<folder>` | try faces from files, nothing installed (`occtools font_proposals`) |
| `--pref name=value` | set a preference for the run (names in Settings, e.g. `appearance.theme=Nord`) |
| `--settings[=n]` | open the settings at start (on page n) |
| `--frames=N` | N frames of a hidden window, then exit (a check that it runs; it says how long the first frame took) |

Preferences live in `%APPDATA%\opencode-native\prefs.txt` on Windows, `~/.config/opencode-native/prefs.txt` on Linux (only
what differs from the defaults), the servers in `servers.txt` beside them;
`OPENCODE_NATIVE_NO_SETUP=1` never offers Setup. `TOOLKIT_DEVTOOLS=<port>` lets a script drive the window over the Chrome
DevTools Protocol on 127.0.0.1, and Chrome's own DevTools inspect it (gui_toolkit's docs/devtools.md): for development only,
since a program on this computer can then type into a session.

## Building

    git clone --recursive https://github.com/sachahjkl/opencode_native
    cd opencode_native

**Windows**: the Odin compiler named in `odin.version` (`dev-2026-11a`), MSVC (Visual Studio or its Build Tools:
`link.exe`, `rc.exe`) and Rust (stable, `x86_64-pc-windows-msvc`), then `build.bat`.

**Linux with Nix**: `nix develop -c ./build.sh` (`flake.nix`: the Odin, wgpu-native and libraries the CI uses).

**Linux**: the same Odin, wgpu-native's static library in its vendor folder (`odin run ext/gui_toolkit/tools/tk -- fetch_wgpu`),
clang, fontconfig's headers and Rust (stable), then `./build.sh`. At run time: Vulkan, libxkbcommon, fontconfig, and
Wayland or X11; libxcb-cursor for the theme's cursors on X11, an emoji font for color emoji.

Both are shortcuts of `odin run tools/occtools -collection:gt=ext/gui_toolkit/src -out:build/occtools -keep-executable -- build`:
every step is a command of `tools/occtools` (`help` lists them; `AGENTS.md`). The build makes the Rust library first (nothing when it is up to date; crates pinned by
`native/Cargo.lock`; on Linux it carries the toolkit's text backend), then the program. The toolkit is the submodule
`ext/gui_toolkit`; `GT=<folder>` builds against another copy, `OUT=<file>` writes the program elsewhere.

## Layout

| | |
|---|---|
| `src/main.odin` | window, loop, fonts, frame pacing (the toolkit's cadence model: a resize step is presented at once) |
| `src/net.odin`, `src/http.odin` | requests on worker threads, the event stream (`ui.post`) |
| `src/servers.odin` | the servers: discovery, the saved ones, connections, the menu and the dialog |
| `src/model.odin` | sessions, messages, parts and projects; events applied as they stream |
| `src/views.odin`, `src/markdown.odin` | sidebar, conversation, the tool timeline, composer, Markdown |
| `src/picker.odin` | the agent and model pickers |
| `src/subagents.odin` | sub-agent cards, results, navigation, the running strip, the sidebar tree |
| `src/images.odin` | image decoding (worker threads), the texture cache, thumbnails, the viewer, logos |
| `src/settings.odin` | preferences (`gt:config`) and the settings dialog, with the server's pages |
| `src/stats.odin` | the statistics of a session and of its project |
| `src/style.odin` | the palette, the icons, the machined surfaces |
| `src/setup.odin`, `src/desktop*.odin`, `src/os_*.odin` | version, Setup dialog, install / uninstall; what each system is asked |
| `native/occ_native` | the Rust library (C functions): ureq + rustls, image decoding (and the text backend on Linux) |
| `src/bench_test.odin` | the heavy cases in the test's process (a long conversation, hundreds of sessions); timed with `-define:OCC_BENCH=true` ([docs/performance.md](docs/performance.md)) |
| `site/` | the GitHub Pages site |
| `tools/` | `occtools`, the project's machinery (`occtools help`): the build, the packages, the signed manifests, the pictures of the README and the site (`occtools shots`, over the DevTools protocol; `--linux-build` builds the Linux one in WSL with `flake.nix`), and what makes the site's pages (`occtools site build site _site`: its changelog, its classic pages, what a page says when it is shared, on the toolkit's `site` package; `occtools site check` in a real browser), the logo and the icon of `assets/` (`occtools logo`, the toolkit's paint package); the DevTools client is the toolkit's `cdp` package, and `doc_check` the toolkit's `tk doc_check --root . --extra ext/gui_toolkit` |
| `res/`, `assets/` | resources of the exe (icon, version, manifest), the logo, Lucide (`assets/fonts`, ISC) |

## License

MIT, see [LICENSE](LICENSE). Hanken Grotesk, Newsreader and DM Mono: SIL Open Font License, see `assets/fonts/*-LICENSE.txt`. Lucide's icons: ISC, see [assets/fonts/LUCIDE-LICENSE.txt](assets/fonts/LUCIDE-LICENSE.txt).
opencode is a project of its own ([opencode.ai](https://opencode.ai)). This client is not built by the OpenCode team and is not affiliated with them in any way. Its logo is its own.
