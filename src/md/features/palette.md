# The command palette

opencode native uses the toolkit's palette (`ui.Command_Palette`), the same in every program of the family. Its design,
its prefixes, its keys and its look are the toolkit's: `ext/gui_toolkit/src/md/features/palette.md` and
`ext/gui_toolkit/docs/palette.md`. This file says what opencode native gives it (`src/palette.odin`) and why.

## The sources

| Prefix | Source | Items | Choosing |
|---|---|---|---|
| `>` | the toolkit's commands source | `COMMANDS`, as a `[]ui.Command` table, one line per command | `command_run` of the command with that id |
| `>` | the toolkit's views' moves | the views of the window the palette is over | the toolkit runs it |
| `>` | `server` ("Server commands") | the server's commands (`app.cx.slash`), group "Server" | `/name ` in the composer |
| `@` | `sessions` | the root sessions | `open_root` |
| `#` | `models`, `agents` | the models under their provider, their context size beside them; the agents but the sub-agents | `choose_model`, `choose_agent` |
| `:` | `prefs_page.palette_settings_add` on `cfg_prefs` | the settings the pages show, each with its value | the toolkit: a switch flips and the palette stays; another unfolds its control under its row (the run mode); Shift+Enter opens the settings on it |

`/` is empty: it is the Paths prefix of the shared table (the session's files, searched by the server), a later step.

## The composer's chooser

The composer's agent and model buttons open `Palette.chooser`, a second `ui.Command_Palette` with one source and no
prefix: the toolkit's chooser (no Recent, no hint row), as Jump to message. Its sources, `chooser_models` and
`chooser_agents`, are made by the same `models_source` and `agents_source` as `#`, with the prefix `.None`: one read,
one mark, one choice (`choice_take`) for both places.

- **One chooser, its source swapped.** A chooser is a palette with exactly one source. `chooser_build` removes the
  other source and adds the one asked for, then opens the palette again from an empty field. Two palettes were refused:
  two views, two states, for lists that never show together.
- **The pane is the composer's.** `chooser_toggle` keeps the index of the pane whose button opened it
  (`chooser_pane`). The chooser's marks and its choice are that pane's. The marks of `#` are the main view's.
- **Opened at the next build.** `chooser_toggle` notes the wish, as `palette_show` does; `chooser_build` runs after the
  main palette and Jump to message. A button lit while its list is shown closes it.
- **Read again at each opening.** The opening asks the server for its agents or its models again (a server that has
  just started lists its plugins' later). The answer bumps `catalog_version`, which the sources' `poll` follows.
- **The agent marked without a choice is "build"**, the server's default, as the composer's button says.

## Decisions

- **The shared table first.** Before, ocn had its own prefixes: `@` sessions and agents, `/` the server's commands,
  `#` models. Now `@` is Go to (the sessions), `#` is Choose (the models and the agents, the one in use marked), and the
  server's commands are commands (`>`, and the plain search). `/` means a path in every program.
- **The palette's command is the toolkit's.** Ctrl+K and Ctrl+Shift+P are `ui.palette_command()`, read by
  `ui.palette_keys` alone. `COMMANDS` has no `app.palette` line; the sheet of the keys (F1, the toolkit's) lists it.
- **One reader of the keys, gated as the window commands are.** `palette_build` calls `palette_keys` unless the file
  dialog holds the window's keys (`command_keyed`'s rule). An open menu holds them in the toolkit.
- **The commands' table is made once per language.** `palette_table_keep` makes it when `i18n.version()` changes.
  `disabled` is read only while the palette is open, from the commands that have an `enabled` (a few dozen calls per
  build), and a change bumps the version. The palette compares the version, never the table.
- **The sessions are answered on a chore.** There are thousands. `sessions_read` copies what a line needs into the
  answer's arena once per `sessions_ver`; a chore makes the items; `sessions_done` gives the arena to the palette. A copy
  at each build was refused: work in proportion to the data at each frame.
- **The server's commands are what ocn read at the connection** (`stream_up`). The old palette read them again at each
  opening. The composer's `/` list still reads them again when it opens (a server's plugins add theirs later), and
  `slash_forget` (called by `slash_load`) bumps the source's version.
- **Opened from outside a build too.** `palette_show` and `palette_hide` note the wish; the next `palette_build` opens or
  closes the palette over the main window. A page of the Preview takes Ctrl+K in its own events, outside a build.
- **The usage memory** is `palette_choices.txt` in `config_dir()`, opened in `main` (a test keeps it in memory). Its
  keys are `<source>:<id>`: the file of the old palette (`<kind>:<id>`) is not read.

- **A command with `checked` is a switch** (`ui.Command.toggle`): its row shows the mark that `checked` says (read for
  the rows in view, no version), and choosing it keeps the palette open. The choice still comes back to `palette_run`,
  which runs the command: the command flips its own state.
- **A session's command says the session it acts on** ("Session · <title>", `Palette_Commands_Options.details`): the
  session shown. The details are made again, with a new version, when the session shown or its title changes (one
  lookup per build while the palette is open).
- **A command can take values** (`Command.arguments`, given to the table as `ui.Command.arguments`): the palette opens
  its form, and the values come with the choice to `Command.take`. Its key and its menu lines still call `run`, which
  asks in its own way. Rename the session is one: in the palette its new title is typed in the form, not in the
  rename dialog over the palette's place; F2 and the sidebar's menu still open the dialog, and a double click on a
  title still edits it in place. The title argument starts empty: its default is read when the form opens, and a
  default that followed the session's title would be a string freed under an open form when the title changes. The
  row's detail already says the title.
- **Shift+Enter goes to the button.** A button that runs a palette command names it (`ui.act_name(box,
  "command:<id>")`): the title bar's Back, Forward, Home and bell; the header's title, figures and Stop; the main
  composer's attach, Preview and Terminal buttons; the sidebar's New session and Refresh. Only the main view's composer
  names its buttons: a command acts on the main view, and a name stated twice goes to the last one built.
- **Refused: a "Set the model" command with a closed list** (`Palette_Commands_Options.choices`). `#` lists the same
  models, the one in use marked, and chooses on Enter: the command would be a second way to the same list, one step
  longer (Enter on the command, then the list).
- **`palette_chosen` runs before the program's content** (`palette_build` at the top of `build_ui`): the run mode's
  writes are made there, so a page shows a value in the frame the palette changed it.

## What was lost, and why

- **The six last sessions with nothing typed**: the toolkit lists Recent and the commands then; `@` lists the sessions.
- **The composer's own picker** (`picker.odin`) went for the chooser. What it showed and the chooser does not:
  - **A model's tooltip** (context, output, prices, inputs, tools, thinking, release, status). A palette's row has a
    title and one detail, and no tooltip. The detail is the context size, as the picker's column was.
  - **The provider headings that fold** (Left and Right). The chooser's provider headings do not fold.
  - **The selection on the item in use at the opening.** The toolkit selects the first row; the mark shows the one in use.
  - **The popover over the button.** The chooser opens where the palette opens, at the window's top centre.
  - **The agent's colour rail and its mode** ("all"). The row says the agent's description, as under `#`.

## Subtle points

- A choice of a command is found again by its id (`command_find(c.id)`), not by `c.index`: the table can be made again
  between the ranking and the choice (a change of language).
- The sessions source's mark is the session shown; the models' is `shown_model` (the session's, or the one chosen for
  it); the agents' is `shown_agent`. A source with the prefix `.None` is the chooser's: its marks read the pane
  `chooser_pane` (`source_pane`).
- The models' answer must keep a provider's models together: the toolkit makes one heading per run of a group.
- The toolkit's palette is a view of the toolkit (`ui.PALETTE_VIEW`); `overlay_open` sees it through
  `views_hold_keys`, so the composer does not take what is typed while it is open.
