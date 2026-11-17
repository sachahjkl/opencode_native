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
| `#` | `agents` | the agents but the sub-agents | `choose_agent` |
| `:` | `prefs_page.palette_settings_add` on `cfg_prefs` | the settings the pages show, each with its value | the toolkit: a switch flips and the palette stays; another unfolds its control under its row (the run mode); Shift+Enter opens the settings on it |

`/` is empty: it is the Paths prefix of the shared table (the session's files, searched by the server), a later step.

## The composer's buttons

**The model button says the model as the lists say it**: "provider/name" (`model_label`, the one maker of a model's
label: Set the model's list, the models' chooser and the button). The name alone was ambiguous: two providers serve
models of one name. The label is long, so the button cuts it in its middle (`ui.elide` `.Middle`, the provider's start
and the name's end show) past `COMPOSER_MODEL_MAX_EM`, and past `COMPOSER_MODEL_NARROW_EM` once the toolbar has folded
to its glyphs (`composer_fit` 3); cut, its tip says it whole. A cap, not the room left: the toolbar folds by what went
past its end, and a label sized to the room would never go past.

**What the model button opens is a preference**, `composer.model_picker` (Behaviour page): **Form** (the default) or
**List**. Both set the model of the composer's pane and read the same list (`model_choices`).

- **Form: Set the model's form** — the palette's own way, the same as its command, its key and its menu line.
- **List: the models' chooser** — the chooser of the agent button on the models (`Chooser_Kind.Models`). One step and
  no command around it, the model in use marked and each model's context size beside it. It was the button's way until
  the form replaced it; it came back as a choice because a list of models that opens on itself, with their sizes, is
  quicker to read than the form's for a person who changes models often.

Form opens Set the model's form (`model_form_open`, then `ui.palette_open_form` in `palette_choose`):
the main palette, straight on the command's list of models, with no list of commands under it. Escape at it closes
the palette; the button pressed again closes it too; it is lit while the form is open for its pane.

- **The form sets the model of the pane whose button opened it** (`model_pane`: `model_for`, the pane + 1, set when
  the form opens, the main view's again when the palette closes). A panel's composer (`/btw`) sets its own session's
  model through the same form; from the list of commands, its key or its menu line, the form is the main view's. One
  form, one list, one way to set a model: a second chooser for a panel's composer was refused.
- **Opened at the build of the pane's window.** A palette is a view over the window it opens in: `model_form_open`
  notes the pane (`model_due`), and `palette_choose` opens the form in the build of that pane's window. A panel in a
  window of its own calls `palette_choose` at the top of its build, so its form opens over it and its choice is taken
  there (the main window may not build meanwhile).
- **What can act is read before the opening.** `disabled` is kept only while the palette is open; `palette_choose`
  makes the table current first, so a form that can act now opens (the toolkit refuses a disabled command).
- **The models are read again at each opening** (a server that has just started lists its plugins' later). The form
  reads its list when it opens: the answer shows at the next opening.

**The agent button, and the model button on List, open `Palette.chooser`**, a second `ui.Command_Palette` with one
source and no prefix: the toolkit's chooser (no Recent, no hint row). Its agents' source,
`chooser_agents`, is made by the same `agents_source` as `#`, with the prefix `.None`: one read, one mark, one choice
(`choice_take`) for both places. Its models' source, `chooser_models`, is the chooser's alone; its rows are
`model_choices`' labels and values, so the chooser and the form list the same models under the same words.

- **One chooser, its source swapped.** A chooser is a palette with exactly one source. `chooser_build` removes the
  other source and adds the one asked for, then opens the palette again from an empty field. Two palettes were refused:
  two views, two states, for lists that never show together.
- **The pane is the composer's.** `chooser_toggle` keeps the index of the pane whose button opened it
  (`chooser_pane`). The chooser's marks and its choice are that pane's: a panel's (`/btw`) button sets its own
  session's model, on List as on Form. The marks of `#` are the main view's.
- **Opened at the next build.** `chooser_toggle` notes the wish, as `palette_show` does; `chooser_build` runs after the
  main palette, and at the top of a panel's own window's build. A button lit while its list is
  shown closes it.
- **Read again at each opening.** The opening asks the server for its agents or its models again. The answer bumps
  `catalog_version`, which the sources' `poll` follows.
- **The agent marked without a choice is "build"**, the server's default, as the composer's button says.

## Decisions

- **The shared table first.** Before, ocn had its own prefixes: `@` sessions and agents, `/` the server's commands,
  `#` models. Now `@` is Go to (the sessions), `#` is Choose (its one source, the agents, names it; the one in use
  marked), and the
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
  rename dialog over the palette's place; F2 and the sidebar's menu still open the dialog (the sidebar's menu renames
  a session that is not shown), and a double click on a title still edits it in place.
- **A form starts from the value in use** (`Command.initial`, given to the toolkit as
  `Palette_Commands_Options.initial`): Rename's field holds the session's title, Set the model's list has the model
  in use selected. The toolkit reads it once per argument when the form opens and copies it, so ocn keeps nothing.
- **Set the model is a command with a closed list** (`Command.choices`, given as `Palette_Commands_Options.choices`):
  the models the server lists, "provider/name", the value `provider/id`. Enter sets the model of `model_pane`
  (`model_choose`). It replaces the models of `#`: one list in the palette. `model_choices` makes the list in the temp
  allocator: the toolkit reads it once when the step opens and keeps a copy, so ocn keeps none. Its key and its menu
  line (`run`) open its form, whatever `composer.model_picker` says: the preference is the button's.
- **Shift+Enter goes to the button.** A button that runs a palette command names it (`ui.act_name(box,
  "command:<id>")`): the title bar's Back, Forward, Home and bell; the header's title, figures and Stop; the main
  composer's attach, model, Preview and Terminal buttons and its activity strip; the sidebar's New session, Refresh
  and Settings; the server strip's add button; the free limit's Connect provider. Only the main view's composer
  names its buttons: a command acts on the main view, and a name stated twice goes to the last one built.
- **`palette_chosen` runs before the program's content** (`palette_choose`, from `palette_build` at the top of
  `build_ui`, and at the top of a panel's own window's build): the run mode's writes are made there, so a page shows
  a value in the frame the palette changed it.

## What was lost, and why

- **The six last sessions with nothing typed**: the toolkit lists Recent and the commands then; `@` lists the sessions.
- **The composer's own picker** (`picker.odin`) went for the chooser, and the form came beside it. What the picker
  showed and they do not:
  - **A model's tooltip** (context, output, prices, inputs, tools, thinking, release, status). A row of the form's list
    has its label only; a row of the chooser, its label and its context size.
  - **The provider headings.** Both lists are one level: "provider/name", found by either. A heading over rows that
    start with its provider would say it twice.
  - **The popover over the button.** The form and the chooser open where the palette opens, at the window's top centre.
  - **The agent's colour rail and its mode** ("all"). The row says the agent's description, as under `#`.

## Subtle points

- A choice of a command is found again by its id (`command_find(c.id)`), not by `c.index`: the table can be made again
  between the ranking and the choice (a change of language).
- The sessions source's mark is the session shown; the agents' is `shown_agent`; the chooser's models', `shown_model`.
  A source with the prefix `.None` is the chooser's: its marks read the pane `chooser_pane` (`source_pane`).
- Set the model's first value is `shown_model` of `model_pane` (the session's, or the one chosen for it). `model_for`
  is set before `palette_open_form`, which reads the first value.
- The toolkit's palette is a view of the toolkit (`ui.PALETTE_VIEW`); `overlay_open` sees it through
  `views_hold_keys`, so the composer does not take what is typed while it is open.
