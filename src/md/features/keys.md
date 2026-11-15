# Keys: the toolkit's keymap over COMMANDS

opencode native reads its commands' keys through the toolkit's keymap (`ui.Keymap`; gui_toolkit's
`src/md/features/keymap.md`). A person sets a key in the palette (Ctrl+Enter on a command) or an alias (Alt+Enter); the
two standard settings `keys.custom` and `keys.aliases` keep them (`Standard_Set.Keys`, on the Keys page). This file says
what opencode native decides on top of it.

## Decisions

- **One keymap, `app.keymap`.** `app_init` points the main window's state at it (`ui.keymap_use`); the views' own
  windows read their owner's. `prefs_init` gives it to `standard_watch` (`Standard_Targets.keymap`), which reads the two
  settings into it and writes the palette's changes back.
- **The toolkit's table is the palette's.** `palette_table_keep` makes `Palette.table` (`[]ui.Command`, one for one
  with `COMMANDS`) and makes its ids known (`ui.keymap_known`) before the first key is read. `commands_keys` reads each
  command with `ui.command_pressed` on its line: a person's key replaces the command's own, or takes that chord from
  another command. Its own reading of `key` and `mods` went.
- **A command's own keys are chords** (`Command.keys: []ui.Chord`). The text shown is the keymap's, in the language in
  use: the help (`help_view`), the main menu, the sidebar's and the selection's menus read `command_shortcut`. A text
  written beside a command was refused: it said the old key once a person changed it.
- **Keys read elsewhere** (`Command.keys_elsewhere`): Ctrl+T and Ctrl+W are the Preview's while its address bar has the
  keyboard (elsewhere a shell's, or nothing in the composer); the conversation's zoom keys are its zone's (outside it
  they zoom the interface); Alt+F4 is the system's. Their own keys are shown (the palette, the help, the menus) and not
  read by `commands_keys`; a person's key on one of them is read as any.
- **Ctrl+F is a key of `session.find`.** `find_keys` read it alone before; now a person's key moves it. The main view's
  rule stays: the command can act only while the keyboard is not in a panel (`can_find`, chat-panes.md).
- **Every id is its own.** Two commands had the same id (`session.background`, `session.copy_id`): the keymap and the
  usage memory took them as one. The second "Copy the session ID" went (the first copies and says so); "Send running
  tools to the background" is `session.tools_background`. A test runs `ui.command_ids_check`.

## Subtle points

- `command_pressed` with `disabled` takes no key, but a person's key on that command still keeps its chord from the
  others: a command whose own keys are read elsewhere passes `disabled` until the person binds it.
- The server's commands (`>` "Server commands") are a source of their own, not `ui.Command`s: they take no key.
