# Views in opencode native

The dialogs and the panels are gui_toolkit's views (its `docs/views.md`, its intent `src/md/features/views.md`). This
file records what opencode native decided on top of them.

## What is a view, what is content

- The conversation is the window's content: `views_frame` goes around it, under the title bar and above the status bar.
  The views dock at its edges, not at the window's: the bars stay whole.
- Views: the sessions' sidebar (home Panel left, open at the first start), the Preview and the Statistics (home Panel
  right: one stack, a tab each), the shells (home Panel bottom, an instance per shell, named by the server's id; the
  instance `""` stands there while there is no shell), each command's output (home Dialog, an instance per command),
  every dialog (`window_views.odin` declares them all).
- The ready-made views of the toolkit: the question before a session is deleted (`confirm_open`), its new title
  (`prompt_open`), the install's dialog.

## The shells' strip

The shells' stack always has its tab strip (`tabs_always`), one shell or several, as a terminal has: its tab says which
shell it is, its "+" (`new_tab`, "New terminal") makes another. Floating or in a window of its own, a shell has no strip:
its header has the "+". The grid's own menu does not repeat it. A new shell is made by the server (`term_create`, an
answer later): its view opens when the answer comes, not during the "+"'s call, so it opens where the shells' memory says
(the last place a shell was docked), not by the toolkit's rule that puts what the call opens in its stack.

The Preview and the Statistics have no `tabs_always`. The old dock drew a strip over every stack, the Preview's alone
too, as a dock's leaf must; the user's rule for the views is that a panel alone adds no chrome. The Preview has its own
strip of browser tabs: a second strip over it would say "Preview" twice. Both open, they share a stack and its strip.

## The program's state says what is open

`Preview.open`, `Stats_View.open`, `Terminals.open`, an output's being alive and the state machine of Changes
(`Changes_State`) stay the truth: what opens or closes them opens or closes the view at once. The user's close of a view
comes back as its answer, read at the start of each build of the main window (`views_answers`), and closes it in the
program's state. Refused: the view's being open as the only truth. The Preview's `open` is per session (a parked
browser stays open, out of sight), and a test without a build must see a panel open the moment it is asked.

## The palette

The command palette stays the program's own view (`COMMANDS_VIEW`): it lists sessions, agents, models, the server's
commands and settings, narrowed by a first character, which the toolkit's palette does not. It lists the moves of the
views (`ui.View_Commands` of the window it is opened over) beside the commands. A move chosen is made in the next build
of the main window (`palette_answer`): not while views are built. The help (F1) stays the program's own view too: it
lists the composer's keys, which are no commands.

## The window's commands over a dialog

The palette, the keys, the settings and quit are the window's (`scope = .Window` in `COMMANDS`). Their keys work over
every view shown as a dialog: the settings are one, and the palette lists the settings. `command_keyed` lets them through
`overlay_open`; a menu and the file dialog still keep the keys while they are open (the composer's chooser is a
palette: a view, as the palette). A window command needs
no `over`: it works over a dialog already. The toolkit's `ui.chord_pressed` takes their keys from wherever the focus is.

## A shell's input

The grid of a shell (and of a command's output) must read its input before the interface does: Ctrl+K, Escape,
Ctrl+= are the shell's when it has the keyboard. This is the one exception to the window's commands: a shell gets
Ctrl+K, Ctrl+Shift+P, F1 and Ctrl+, too, and Ctrl+Shift+T alone comes through, to hide the shells from inside them. Every window's `input` hook takes them out (`term_events`): the main
window's, and a view's window's, which is the main window's hook (host.view_windows gives it). Each window gives its
input to the grids built in it (`Term.built_in`); the pointer to the grid in front at the event's own position
(`ui.pointer_on_at`). In a view's window the hook does nothing else: the main window's own work (the conversation's
zoom, the drops, the side buttons of the mouse) stays the main window's.

## The Preview's page

The page is a child window of the system's. It follows the panel to another window at once (`View_Options.moved`, at
a move and at an opening straight into a window), because the window it leaves may close before the frame ends; the
panel closed, it goes back to the main window first (`preview_home`). It is placed after the frames of every window
(`frame`: `preview_after_frames`), where its panel was laid out. It steps aside while a floating view or a dialog is
over it (`ui.view_occluders`), while a dialog's scrim dims its window, a menu or the file browser is open there.

## A dialog opens with its answer

A dialog whose content comes from the server or a worker calls `ui.view_not_ready` while that answer is on its way. Its
dialog stays unseen for 100 ms at most, then shows what it holds. It opens with what was read and at its size.
Otherwise it shows "Reading…" and grows or swaps a moment later.

- **One signal for every reading.** `read_shown` notes a reading still on its way (`read_pending`). A view that shows
  readings calls `dialog_reads(app, v)` at the top of its build. The settings, the schedules, the artifacts, What this
  session changed, and the Statistics put in a dialog use it. Refused: a check per page of what it reads. The pages are
  the toolkit's callbacks with no view, and a list kept apart from `read_shown` goes stale.
- **The others say it themselves.** These dialogs call `view_not_ready` directly:
  - Pairing waits for its code.
  - What you missed waits for the report of the card shown.
  - The diagram viewer waits for a layout in the direction chosen before.
  - The image viewer waits for its picture and for the build after it asks for its size. `ui.view_size` takes effect in
    the next build, and a dialog of a known size shows in its first build.
- **What a person starts keeps its own state.** Go back's "Reading…" while the server writes the files back, a
  direction chosen in the open viewer, Try again: the dialog is shown already, and the words say what goes on.
- **Not the shells.** A shell's view is a panel by default, and making a shell is the server starting a process. Its
  "Making a shell…" is what a person waits for.

## A dialog summoned by a key

Every view that a command's own key opens has `View_Options.quick` (70 ms fade): the settings, What you missed, the
Statistics, the shells, the Preview, the sidebar. It acts only when the view is a dialog. The toolkit's palettes (the
commands, Jump to message, the composer's chooser) have it already. The keys sheet (F1), the rename question (F2) and the
file browser (Ctrl+P) are the toolkit's views, which have no `quick` yet.

## The image viewer

As a dialog it opens around its picture: its size is asked at each build (`ui.view_size`), from the share of the window
the person chose (`conversation.image_viewer_size`), its header's height and its border. In every presentation the
picture's area is all the body leaves above the bar, and the picture fits it (`ui.preview`, which clips it to the area).

- **The size the person gives it with its grips is kept.** The toolkit keeps a dialog's resized size until the size
  asked changes. The viewer stops asking once the person resizes it (`Image_Viewer.grown`). The share saved is what
  the picture takes when it fits the area of that size, for the next pictures.
- **Refused: the picture's own box, sized from the share.** Its box kept its height when the person made the dialog
  taller, and ran past the dialog's edge when the share made it wider than the dialog: the two sizes disagreed as soon
  as the share reached its most and the person kept dragging.
- **A new picture is a new opening.** The record of a viewer still open keeps the person's size; the first build after
  `image_view_open` asks for the kind's size once, so the asked size changes and the person's size goes.
