# Changelog

All notable changes to opencode native. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project follows [semantic versioning](https://semver.org).

## [Unreleased]

## [0.24.1] - 2026-11-09

### Added

- **The server's commands as one types**: `/` at the start of the composer lists the commands whose name matches what follows it, the best first; Up and Down choose, Tab or Enter puts `/name ` in the composer, Escape closes the list. Enter on a name typed in full sends it, as before.

### Fixed

- **A long option of an agent's question goes on several lines** inside its button; it ran out of the button.

## [0.24.0] - 2026-11-09

### Fixed

- **The window on Linux moves and resizes**: dragging the title bar moves it, its edges and corners resize it (with the resize cursor), a double click on the title bar maximizes or restores it, a right click opens the compositor's window menu. Where the system draws no frame around it, it has a 1-pixel outline. (gui_toolkit 0.108.0)

## [0.23.1] - 2026-11-09

### Fixed

- **The line over the composer counts the session's commands only**: the tray showed the session's, but the line still counted every command of its folder (0.23.0).

## [0.23.0] - 2026-11-09

### Added

- **Push to the background**: a shell command that holds the session's turn goes to the background and the session goes on (`POST /api/session/:id/background`): a button beside Stop while such a command runs, `Background` on its row of the activity tray, and the command palette's "Push the running command to the background".

### Fixed

- **The Preview panel on Linux**: asked for (Ctrl+Shift+B, the palette), it says there is none on Linux and that agents can use your own browser with OpenCode Browse; a click opens its page. It said that the WebView2 runtime was missing.
- **The activity tray is the session's**: it showed every shell command of the session's folder, those of other sessions too; it shows those of the session and its sub-agents (each command says its session in `metadata.sessionID`).

## [0.22.0] - 2026-11-09

### Added

- **Attach files**: a paperclip in the composer's bar (and `Attach files` in the command palette) opens the system's dialog, several files at once; files dropped on the window are attached too. An image, a PDF or a text file goes with the prompt as a data URL, so a server on another machine gets it; another file goes in the text as its path, as before.

### Fixed

- **Paste on Linux**: an image copied in another program (a screenshot, a browser's "Copy image") is attached (gui_toolkit's PNG codec on Linux, which nothing gave before), and a pasted text or PDF file is attached instead of its path.

## [0.21.0] - 2026-11-09

### Changed

- **Every step is a command of `tools/occtools`**: `release dist` and `release publish` (what the release workflow's scripts did), `fonts_check`, `font_proposals`, `wsl_build`, `wsl_client` and `relay` in place of tools/*.mjs and tools/wsl_*.sh, which are gone; `build.sh` and `build.bat` are shortcuts of `occtools build`. The toolkit's packages are in `ext/gui_toolkit/src` (gui_toolkit 0.101.0). AGENTS.md replaces CLAUDE.md.
- **The site's steps and the DevTools client are the toolkit's** (`gt:site`, `gt:cdp`): `occtools site` keeps this site's names, address and colours and its own check (the download each system's browser is offered); its copies (tools/occtools/devtools.odin, site_meta.odin, site_check.odin and most of site.odin) are gone, and the pages it makes are the same, byte for byte. The development shell no longer has Node.
- **Setup: the toolkit's desktop package.** Install, repair, uninstall, the Start menu and Desktop shortcuts, the Settings > Apps record, the applications menu entry and its icon are gui_toolkit's `desktop` package (shared with Wren); opencode native keeps its names and marks, and the same folders, shortcut names, `.desktop` file and registry key. The install folder now has a manifest (`opencode-native-install.txt`): the uninstall removes exactly the files it lists. An install made by Setup 0.20.0 or earlier shows as one to repair: Repair rewrites it in today's form (the Linux `version` file goes), and Uninstall removes it whole.
- **NixOS: a classic install runs by itself.** nix-build makes a profile of the libraries the program needs (those of `flake.nix`), and the installed copy is patched to use it: no nix-ld. An update of that copy is patched the same way. The line about what nix-ld lacks is gone.
- **The command line's report** (`--install`, `--status`) reaches the console that started a Windows copy.
- **`occtools logo [--out folder] [--hint 0|1|2]`** draws the logo and the icon (`assets/logo*.png`, `opencode-native.ico`) on Windows and Linux, with the toolkit's paint package, in place of tools/make_logo.ps1 (GDI+, Windows only), which is gone. The same files, names and sizes; the committed ones stay (the new drawing differs from them by antialiasing only).
- **occtools runs commands and downloads with the toolkit's `toolbox` package** (`gt:toolbox`, shared with gui_toolkit's tk and Wren's tools): running a command, capturing its output, `env_with`, the SHA-256 of bytes and files. Zig is a pinned download (curl with retries, the file removed when its SHA-256 is wrong). tools/occtools/run.odin keeps only `run`, the shorthand that shows each command before it runs. The commands and their output are the same.

## [0.20.0] - 2026-11-08

### Added

- **Search in the settings**: a field above the pages; what is typed shows the matching settings of every client page (name, title, description; a page's title shows all of it), under their page's title, their controls live. Choosing a page ends the search. (gui_toolkit 0.100.0's `config.Search`)
- **Allow all permissions** (Settings > Behaviour, `permission.allow_all`, off by default): every permission a session asks is allowed once, at once, with no card, toast or flash; turned on, it allows those that wait too. What the server's rules deny stays denied.

## [0.19.1] - 2026-11-08

### Changed

- **Updates: the toolkit's update package.** The checks of a signed manifest and the placement of the new program are gui_toolkit's `update` package, shared with Wren; `src/update` keeps what opencode native is to it (its name, its signing context, its key). Manifests and signatures are the same bytes as before.

### Fixed

- **Linux: the windows say they are opencode native.** Their Wayland app_id and X11 WM_CLASS are `opencode-native`, the name of the menu entry, where they said "gui_toolkit": a task bar shows the program's icon and name. (gui_toolkit 0.99.0)

## [0.19.0] - 2026-11-08

### Added

- **Updates on Linux**: an installed copy checks, downloads and puts in place a new version as on Windows (signed manifests `update-linux-x64-<channel>.json`; the release has the program alone beside its archive).
- **NixOS**: `flake.nix` packages the release (`nix profile install github:sachahjkl/opencode_native`), with its menu entry and its icon; the libraries it opens are in its RUNPATH. On NixOS, Setup advises that package, and still makes a classic install on request: it says which libraries nix-ld lacks for it. A Nix package never updates itself.

## [0.18.4] - 2026-11-07

### Fixed

- **Memory: a long conversation no longer holds gigabytes.** Every image (a tool's screenshots, attached pictures) was kept as a texture of up to 2048 pixels, up to 96 of them whatever their size: about a gigabyte once a long conversation's pages were read. A thumbnail is now decoded at the size it is shown at (a tool's capture: 512 pixels instead of 2048), the viewer decodes the whole image when it opens, and the textures together keep within 96 MB, the ones shown longest ago going first. Images are decoded three at a time, and one no longer on screen when its turn comes is not decoded: a find over a long conversation started decoding all of them at once, and went past 14 GB.
- **Find with a needle of thousands of matches** no longer leaves hundreds of MB behind: the text outside the clip makes nothing to draw, and the buffers go back down after a peak. (gui_toolkit 0.98.0)
- **The wheel's click (autoscroll) goes up from the bottom of a conversation**: its first steps, less than a pixel a frame, were put back at the bottom the view was following, and the conversation's column read the rounding of its rows as a move of the content: the view stayed there, or broke free in a jump. (gui_toolkit 0.98.1)

## [0.18.3] - 2026-11-07

### Fixed

- **Find in a long conversation no longer freezes the window**: the messages not on screen are read a slice at each frame, not all in one, and the bar says how far it is (what was found so far and the percentage read) until it knows the count. (gui_toolkit 0.97.0)

## [0.18.2] - 2026-11-07

### Changed

- **A session's mark is its project's logo** in the sidebar, as above the conversation, when the project has one; its letter else.

## [0.18.1] - 2026-11-07

### Fixed

- **The session shown, in a light theme,** is on the sidebar's own ground a step darker, its hue and chroma kept: a pale accent read as another colour (Gruvbox's orange as pink), and a neutral of less colour than the sidebar's yellow as blue.

## [0.18.0] - 2026-11-07

### Added

- **Themes.** Seventeen, each in a dark and a light version: OpenCode and its black with another accent (Ink, Orchid, Moss, Lagoon, Rose), Monokai, Gruvbox, Dracula, Nord, Tokyo Night, Catppuccin, One Dark, Solarized, and the terminals' Campbell, Retro and Naysayer. Settings > Appearance shows each in its own colours. Every colour of the interface follows: its greys go to the theme's steps, its colours to the theme's of the nearest hue.
- **Light, dark or as the system.** The mode follows Windows' app mode by default, and changes with it at once. A light version is drawn flat.
- **Themes of your own,** in `themes.txt` beside the preferences ("Themes of your own" in Settings opens it, written with how it is read the first time): a theme can start from another and give only the colours it changes, dark and light.
- **A flat style,** lighter than the machined one: plain surfaces and thin lines, no reliefs nor halos.
- **A session's mark** in the sidebar: the first letter of its title on a colour its id picks.
- **The conversation's width by hand:** a handle each side of its column, where there is room, both moving it the same; what it is let go at is the widest wanted, and a narrower window narrows it.

### Changed

- **The accent is the theme's.** The accent preference goes: a theme with another accent is another theme.
- **The session shown in the sidebar** is a quiet ground, no rail, no border; its words keep their contrast on it in every theme (WCAG AA for the title).
- **Choices** (Inbox and Projects, the settings' options) are a sunken track with a small raised plate under the one chosen, its word lit: no more glossy accent.

### Fixed

- **The composer's buttons stay within it:** with a run going and "Send now", or a long model's name, the hint, then the send button's word, step aside when the toolbar has no room.
- **A long session's todo list shows** even when its last update is pages back: the older pages are read for it alone.

## [0.17.8] - 2026-11-07

### Added

- **A command's output begins with the command.** It is written at the head of the grid after a prompt, whole, as if typed, and scrolls with what it printed; the bar no longer shows it cut.
- **A menu on a terminal.** A right click on a shell's grid, or on a command's output, offers Copy (the selection), Paste (a shell), Select all, and for a command's output, all of it, plain. A program that takes the mouse keeps the right button; Shift and a right click open the menu all the same.
- **Paths to copy.** The folder under a conversation's title and the file a diff shows can be selected and copied.

### Changed

- **Tables share their width as a browser does.** A table wider than its place keeps each column at least as wide as its longest word, gives the columns that lack the least all they need first, and lets the long ones wrap: "client" is no longer cut into "clie" and "nt".
- **Selected text reads on its selection,** whatever its colour: a faint line (a done task) was lost on the selection's.

### Fixed

- **The sidebar's handle lets go of its colour** once dragged: it kept the keyboard's focus, and showed it as if a key had brought it there.

## [0.17.7] - 2026-11-07

### Added

- **A session's title is renamed where it is.** A double click on the title above the conversation, or on a session's row in the sidebar, makes it a field in place: Enter or a click elsewhere keeps it, Escape leaves it as it was. Above the conversation, the line is the title's while it is edited.

### Changed

- **The wheel scrolls as much as in a browser, as Windows says.** A notch moves the lines per notch of the mouse's settings, a browser's line each (100 px for three lines at 100 %). With five lines, a notch goes about three times as far as before. The terminals follow the same setting.
- **A tool's input is one well.** A long value (an `execute` call's code) sits under its name in the input's well, aligned with the short ones, not in a well of its own inside it.

### Fixed

- **A command's output can be selected and scrolled.** In the read-only view, a drag selects and Ctrl+C copies, and the wheel scrolls its grid, not the conversation behind it. Both failed when no terminal of the tabs was open.
- **Tables keep their words whole.** A column is as wide as its widest cell as it is shown (bold, code and all): no more "Befor" over "e". The header has no tinted box of its own in the table's well.
- **Tabs show as space.** Code and tools' output indented with tabs showed a missing glyph per tab.
- **The frame rate choice shows its words.** In the advanced settings, "Screen" and "Uncapped" were cut; the choice goes under its description when it is too wide beside it.

## [0.17.6] - 2026-11-07

### Changed

- The main window and the windows of their own are framed by the toolkit's own window (gui_toolkit 0.92.0): one way to pace, build and show a frame for all of them. Nothing changes on screen.
- The browser page steps aside only while a tab or a border of the dock is really held, as the press says, not as a flag remembered it.

## [0.17.5] - 2026-11-07

### Added

- **A command's output as a terminal shows it.** "Inspect" in the activity tray, under a shell call and in its menu opens it read-only: colours, scrollback, selection, live while it runs. It can go to a window of its own, and when the command ends the view says so and offers to close.

### Changed

- A long conversation costs much less to show: at 9,000 messages a frame at rest is built in 1 ms instead of 4.8, one that streams in 1.9 instead of 9.6.
- Coming back to a session puts the view where it was at once, to the pixel, however the heights of the messages around it settle.
- What the server answers is read on the request's own thread: a large page no longer stands before a click.
- A window of its own draws only when something it shows changes: a pointer passing over the main window costs it nothing.
- What a session waits on is read when the event stream could not have said it, not at each reading of the list: fewer requests.

### Fixed

- An agent at work in one folder lost its browser tools when a session of another folder was shown.
- The rounding of corners applies to everything the program draws: set to 0, buttons, fields and panels are square.
- A queued message edited just as it was delivered could reach the model twice: the server answers the same either way, so what was stored is now read back.
- The last answer of a browser tool was lost when a session of another folder opened at that moment.
- A shell could keep its old size after a resize, until the next thing it printed.
- A shell in its own window stopped hearing the keyboard once the shells were hidden, and its Close did nothing.
- A check for updates that failed said "up to date" and dropped the version on offer.
- A browser tab closed by the limit before its first page loaded stayed on "Starting the web view…".
- A redirect replaced the address being typed in the browser's own window.
- Terminal output that started with a zero byte was lost.
- Windows of their own now take the main window's density, rounding, fonts and scroll bars, and their tooltips, hidden bars and clicks no longer wait for the next movement of the mouse.
- Leaving a server closes the Delete and Rename dialogs, whose session was that server's.

## [0.17.4] - 2026-11-07

### Changed

- The Terminal runs on libghostty-vt 1.0, the first stable version of Ghostty's terminal library, built with Zig 0.17.

## [0.17.3] - 2026-11-06

### Added

- A model's tooltip in the picker says what it is: its context, output, prices, what it reads, its tools, its levels of thinking, when it came out.
- **A browser per session.** Each session has its own Preview: its pages, their history and address, open or closed. Another session shown shows its own, alive and not loaded again, and a session that never opened it has no tab. A sub-agent uses its session's browser, the home page has its own, and what was open beside a first prompt stays with the session it made.
- **Tabs in the browser.** A strip inside the panel when a session has several, + in the address row, a click to bring one, x or a middle click to close it, Ctrl+T and Ctrl+W while the panel has the keyboard, "New browser tab" and "Close browser tab" in the palette. Closing the last closes the panel, for that session.
- The agents' browser tools drive the tabs of the session that called, even out of sight: `tabs_list` says them all, `tabs_open` opens a new one, every tool takes a tab's id, and without one acts on the tab in front. An unknown id is refused.

### Changed

- While a turn runs, Enter sends the message into it and Ctrl+Enter queues it for the end of the turn. The setting `conversation.while_running` swaps them.
- The buttons of the browser and the terminal are beside the composer's Send, not in the title bar: they belong to the session.
- At most 8 pages stay alive, every session's tabs together: past that the one shown longest ago goes, its address kept, and showing it loads it again.
- The panel's window follows the session shown, with an empty panel for a session that has no browser.
- A key held in the page counts once.

## [0.17.2] - 2026-11-06

### Fixed

- The Preview in a window of its own shows the page again: 0.17.1 left it black, behind the window's surface (gui_toolkit 0.90.0).
- A shell in a window of its own no longer flickers as the window is resized: it is told its size once the size has rested, and what it paints then shows whole.

## [0.17.1] - 2026-11-06

### Fixed

- A panel in a window of its own stays stable while the window is resized: what it shows is no longer stretched and squeezed, and it is drawn at every step, as in the main window.
- Text in a dialog can be selected wherever it is, with the text cursor over it (gui_toolkit 0.88.0).

### Changed

- The site's address is [ocn.froment.software](https://ocn.froment.software); the old one leads there.
- `tools/occtools` does the rest of the project's machinery: `build`, `package`, `update`, `shots` and `site`, the same on Windows and Linux. The PowerShell, shell and Node scripts they replace are gone.

## [0.17.0] - 2026-11-06

### Added

- A panel in a window of its own, for a large screen or a second one: a shell, the Preview, the Statistics. The window button on the panel's strip, or "Open this panel in a window" in the palette. Same program, same renderer, no second start: closing the window gives the panel its tab back.

### Fixed

- The text of a diff's full view can be selected with the pointer: in a dialog, a press went to the dialog.

## [0.16.0] - 2026-11-06

### Added

- A diff in a window of its own, the whole of it: stacked, or old and new side by side, the choice kept. "Full view" and "… N more lines" under a diff open it, as does each file of "What this session changed"; Copy takes the diff. Twenty thousand lines scroll as lightly as twenty.
- `tools/occtools`, the project's machinery in one program: `check`, `live` (the real program on the real server, failures made to happen, no delay waited out), `clean`, `measure`, `film`, `ship`.

## [0.15.1] - 2026-11-06

### Changed

- On gui_toolkit 0.86.0, its state machines made explicit: what the window, the pointer, the clipboard and the fonts do in the corners of their lives.

## [0.15.0] - 2026-11-06

### Added

- **Queue a message for the end of the turn**: while a turn runs, Enter queues and Ctrl+Enter sends now (Conversation, While running swaps them). What waits stacks above the composer, in order, images included: edit it, send it now, remove it.
- **An inbox in the sidebar, by default**: what waits for you, what finished and you have not seen, what runs, the rest. Projects keeps the grouping by project.
- **Statistics are a panel**, a tab beside the browser (Ctrl+I, or the token count), with what fills the context: unfold a part, read it.
- **The model picker groups models by provider**: headers that fold, to look through them by hand; typing still goes through them all.

### Changed

- The big figures of the statistics are plain, and colour only says something.
- Schedules fit what they hold: nothing is cut, and a new one is two rows.
- The line of a run takes one line, and a sub-agent's card too when it has nothing more to say.

### Fixed

- **Pending messages all show**, with an image or not, and read as pending until they are delivered.
- **Fork from here keeps the answer clicked**, and is on tool calls too.
- **A click on the update notification does what it says**: it installs, and once installed it restarts.
- **Opening a session no longer blinks**: what was on the screen stays until the conversation is there, which then comes at once. "Loading" only shows when the server takes its time.
- **The corners of a floating panel are round**: its content covered them.
- The status bar says requests in flight once they last, not for the instant of each one.

## [0.14.0] - 2026-11-06

### Changed

- **Each shell is a tab of the dock**: one row of tabs, named after the program. Drag, split or float a shell like any panel; **+** at the end of the strip, or Ctrl+Shift+T to show and hide them all without ending any.
- **Shortcuts no longer act behind a dialog**: F1 and Ctrl+K included. Ctrl+P browses the files, Ctrl+Shift+P opens the palette.
- **What the server could not give says so where it is read**, with Try again: conversations, dialogs and settings no longer stay on "Reading…" or show an empty list that is not.
- Reads that follow an event wait for things to go quiet: a list may land about a second later, and always lands.

### Fixed

- **A prompt is not lost any more**: a failed one comes back whole, with its images and mentions, to the session it was for. A double Enter makes one session.
- **Keys no longer reach a hidden shell**, and Enter no longer runs what was typed for the composer.
- **Everything follows a change of server**: shells, Connections, Plugins, dialogs, a revert in progress. Nothing acts on one server with what came from the other.
- **Going back to a prompt says what really happened**, whatever the order of the answers, and a stage is never left without its dialog.
- **Shells come back after a network drop**, where their output stopped, and so does a connection that died in silence: it no longer shows as connected.
- **A wrong password says so**, instead of connecting forever.
- **Scrolling to the top no longer reads the whole history**, and Latest and Send win over a view coming back.
- **No more cards that stay** after a question was answered elsewhere, and answered ones do not come back.
- **The model list has no doubles**: each change of a connection added all of it again.
- **The model chosen stays shown**, and a remembered choice shows from the start.
- A login that fails to be followed offers Try again; cancelling one ends it on the server. A schedule is made once, however many clicks.
- Diffs keep lines that start with `--` or `++`. Back goes nowhere it should not. Find keeps its match when older messages arrive.
- Preview: a view that failed can be tried again, and agents are told why. Checking for updates works again after one was found, and after changing channel. Uninstalling the running copy says it will go, and it does.

## [0.13.0] - 2026-11-05

### Added

- **Sharper text at 100 %**: text is smoothed per colour stripe of the screen's pixels, on Windows and on Linux. Automatic below 150 %, as the system says; Settings, Appearance, Text smoothing chooses RGB, BGR or Grey.
- **The site says what it is when it is shared**: a card, Open Graph and Twitter tags on every page, an Atom feed of the versions, a sitemap and a manifest (`tools/site_meta.mjs`, at deployment).

### Fixed

- **Text is smooth again below 150 %**: 0.12.3 took away its smoothing across its rows, which left it hard and stepped.

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

[Unreleased]: https://github.com/sachahjkl/opencode_native/compare/v0.24.1...HEAD
[0.24.1]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.24.1
[0.24.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.24.0
[0.23.1]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.23.1
[0.23.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.23.0
[0.22.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.22.0
[0.21.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.21.0
[0.20.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.20.0
[0.19.1]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.19.1
[0.19.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.19.0
[0.18.4]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.18.4
[0.18.3]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.18.3
[0.18.2]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.18.2
[0.18.1]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.18.1
[0.18.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.18.0
[0.17.8]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.17.8
[0.17.7]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.17.7
[0.17.6]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.17.6
[0.17.5]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.17.5
[0.17.4]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.17.4
[0.17.3]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.17.3
[0.17.2]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.17.2
[0.17.1]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.17.1
[0.17.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.17.0
[0.16.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.16.0
[0.15.1]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.15.1
[0.15.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.15.0
[0.14.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.14.0
[0.13.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.13.0
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
