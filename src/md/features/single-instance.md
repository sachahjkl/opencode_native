# One window per person, and --quit

opencode native keeps its state in one folder per person (`config_dir`): the preferences, the stores, the drafts, the
views. Two windows on that folder write over each other. A second start (the desktop file, a shortcut, a script with
`--session`) therefore does not open a second window: it hands what it asks to the window that runs, which shows it and
comes to the front, and the second start ends. An installer's `--quit` asks that window to end as Quit does. Both are the
toolkit's (`gt:instance`, `setup.Setup_Options.running` and `quit`; gui_toolkit's `src/md/features/quit.md`).

## Decisions

- **The name is the person's folder.** `instance.key("opencodenative", config_dir())`; a debug build has its own channel
  (`opencodenative.dev`), so a development window never takes a release start.
- **Any copy of the person's hands over (identity "").** An update in place keeps the file's path, but a Nix store copy
  changes it at each version: with the path as identity, the new version's start opens a second window on the same
  folder. Refused for that reason.
- **The message is the command line.** The second start sends the options that say what to show, one word each,
  separated by a NUL byte (a value can hold a new line, never a NUL), after its launcher's activation token (first word,
  marked by the byte 0x01). The owner reads them with `cli_read`: one parser for both. Paths (`--image`, `--attach`,
  `--diff`) are made absolute first: the owner runs in another folder.
- **What is handed over**: `--session`, `--search`, `--find`, `--settings`, `--add-server`, `--image`, `--attach`,
  `--diff`, `--setup`. The owner does with them what a start does (`cli_show`), except that a session opens as a new root
  (`open_root`): the start of the window has passed. A start with none of them (the desktop file) brings the window to the
  front.
- **A start that changes the run itself stays on its own**: `--url`, `--password`, `--server`, `--pref`, `--scale`,
  `--size`, `--frames`, `--font-dir` and the tools' hidden options, or `TOOLKIT_DEVTOOLS` set. Such a start neither hands
  over nor takes the name: a tool's window (shots, a check) never takes the person's starts, and a window on another
  server is the person's explicit choice, as before this work. Refused: handing `--url` to the window that runs (it
  switches the person's server without asking).
- **Served on a thread of its own** (`instance.serve_start`): the loop sleeps until its window has an event. The handler
  copies the message and posts it to the interface's thread (`ui.post`).
- **`MESSAGE_QUIT` runs the command `app.quit`**, the one Alt+F4 and the menu's Quit run: the loop ends, the drafts, the
  preferences and the stores are written. `MESSAGE_PING` does nothing: the answer alone tells `--status` that a copy runs.

## Subtle points

- The name is taken before the log starts and before the window opens: a start that hands over writes nothing and shows
  nothing. It is served only once `app_init` made the posts' queue; a second start that comes before waits (`wait_ms`).
- The name is let go right after the loop, before the long end (threads, stores). Restart (after an update too) and
  the install's launch start the new copy only at the very end, once the name is free: started earlier, the new copy
  hands its start to this window, which then ends, and nothing runs. A copy that cannot be started is then said only in
  the log: the window is gone.
- Restart starts `App.exe`, the program's place read once at the start and kept: an update on Windows moves the running
  file aside (`<exe>.old`), after which the system names the moved file, and a name read in a frame's temp memory is gone
  by main's end. Both made the restart after an update start nothing (0.62 to 0.67.1).
- An owner that does not answer (`Unresponsive`) leaves the second start on its own, with a line in its log: a window
  more is better than a start that shows nothing.
