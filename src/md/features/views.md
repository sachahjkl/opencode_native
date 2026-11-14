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
`overlay_open`; a menu, the picker and the file dialog still keep the keys while they are open. A window command needs
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

## The image viewer

As a dialog it hugs its picture: its size is asked at each build (`ui.view_size`), from the share of the window the
person chose (`conversation.image_viewer_size`) and its header's height. Its grips set that share, kept when they are
let go, for the next pictures too. Docked, floating or in a window of its own, the picture fits the room it is given.
