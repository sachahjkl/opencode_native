# Conversation panes, and /btw

`/btw <question>` asks something aside without leaving the conversation: it forks the session, sends the question
there, and shows the fork in a panel on the right, while the session stays shown and live on the left. The fork is a
conversation like any other: it is continued in the panel, with the same composer, and closing the panel leaves it a
session of the sidebar.

## The abstraction: a pane

The program showed one conversation: `App.chat`, its view state, `App.composer`, and the request lifetimes, the
answers' handlers, the events, the scroll machine, the queue and the drafts were bound to it. A second conversation
bolted on beside it would duplicate each of them, or special-case "btw" in each.

A **pane** (`Chat_Pane`) is what one shown conversation needs: its `Chat`, its view state (scroll, find, prompt
rail), its composer (text, attachments, mentions, history, queue, drafts' place), its reading (`remote.Remote`) and
the lifetime of its requests. The window has a list of panes; the main view is pane 0, `/btw`'s panel another.
Everything that read `app.chat` or `app.composer` reads the pane it is given.

- **Requests** carry the pane they are for (`Request.pane`, its mark and its chat's generation): an answer for a pane
  that moved on or closed is dropped, as an answer for a conversation left was.
- **Events** are applied to every pane that shows their session (two panes can show the same one: two arenas).
- **The composer is the same widget** in each pane: Enter, Steer and Queue, Alt+Enter, Escape twice, `@`, `/`, the
  history, attachments. A pane's composer has its own text; the drafts stay keyed by session.
- **The keyboard** is the focused pane's: its composer, its Escape, its Page Up and Down. Typing with nothing focused
  goes to the main pane's composer.

## Zoom

- **Each pane is a zoom zone** of the toolkit (`Chat_Pane.zone`, `ui.zoom_zone`), keyed by the session it shows. Its
  memory is `App.session_zooms`, shared by every pane: the same session in two panes is one zoom; two sessions, two
  zooms. The memory's default is the preference `appearance.content_zoom`; Ctrl+0 forgets the session's zoom, so it
  follows the preference again.
- **The zone is the pane's whole column** (`###main`), not the messages' scroll box: the zoom keys follow the keyboard
  focus, which is mostly in the composer, under the messages. Focus elsewhere (the sidebar, a dialog): the keys zoom the
  interface. There is one set of keys; Ctrl+Shift+= is Ctrl++ on AZERTY, not the interface's.
- **The home page** is built in the same column, so it stays in the zone, with an empty key: its own zoom, not
  remembered. Zooming the home page no longer changes the preference.
- The palette's "Zoom in the conversation" acts on the main pane's zone. "Zoom in the interface" has no keys of its
  own: the same keys zoom the interface where the focus is outside a zone.

## /btw

- `/btw <text>` (a client command, in the `/` list and the palette): fork the shown session at its last message (a
  run in progress: before the answer that streams), title the fork `btw: <first words>`, send as its first prompt a
  short preamble (an aside of the conversation: answer briefly; change no file unless asked) and the text.
- The preamble is sent with the prompt and not shown: the pane shows the person's text.
- The fork opens in a pane presented as a right panel (`BTW_VIEW`, the toolkit's views: it can float or have a window
  of its own). The main composer keeps the keyboard; a click in the panel continues there.
- Closing the panel closes the pane; the fork stays in the sidebar. "Open in the main view" shows it on the left.

## Refused

- A small composer for the panel: the aside is a conversation, and a lesser composer is a lesser one.
- A second `App.chat` beside the first, with its own handlers: every feature would need its "btw" copy.
- Reusing the fork of "Fork the session": it opens the fork in the main view and puts the prompt in the main composer.

## Layer 1 decisions

- **A fixed array** of `PANES_MAX` panes in `App`, `MAIN_PANE` the main view, a slot `shown` or not. A request's worker reads
  its pane's mark from another thread at any time (`req_unwanted`); a slot never moves nor dies, so no lock and no count of
  references guard it. A request carries the slot and the mark: a pane closed, or opened again in the same slot, moved its
  mark and its chat's generation, and what was asked for the old one is dropped. A list of pointers needed both.
- **Requests**: `request(..., pane = p)`; none named is the main view's (the sidebar, the commands, the palette name no
  pane). An answer finds its pane by `req_pane`. Jobs on threads and dialogs keep the pane too (an attachment, the file
  browser): the pane's slot is stable.
- **What is keyed by session or part stays in `App`**: the drafts (`App.drafts`, see "One session in both panes"), the parts opened (`App.expanded`: a part's
  id names one part of one session; the stats panel uses it too). The restore clock of a way back is the pane's view state.
- **The main view's own features keep `main_pane`**: the history (Back, Forward), the sidebar, the commands, the palette,
  the title bar, the activity tray, the statistics, "What you missed", `open_chat` and the home page's folder. They act
  on the main view; Layer 2 decides which of them a panel has (the context menu became the pane's).

## Layer 2 decisions: the panel

- **One panel, one pane**: `App.btw` is the slot of the pane `BTW_VIEW` shows (0: none). A second `/btw` shows its fork
  in the same pane. Several asides at once would need a view instance per pane; nothing asks for it yet.
- **`pane_show` and `pane_close`** (chat_pane.odin): a pane other than the main view shows a session as `open_chat` does,
  without what is the main view's (Back and Forward, the last session kept, the activity, What you missed). Closing it
  keeps its composer's text in the session's draft, frees its slot and moves its mark: what was asked for it is dropped.
- **The panel's title is its tab**: `BTW_VIEW` has `tabs_always`, its tab says the fork's title (`ui.view_title`), the
  strip carries "Open in the main view" (`ui.view_header_tools`). The body has no header of its own: a second title
  would say the same thing twice. Floating or in a window of its own, the view's header says it.
- **The same build**: `conversation(app, pane, em, width)` builds both; the panel gives its room (`ui.view_room`). What is
  the main view's stays out of the panel: the session header, the column's handles (they set a preference), the
  activity strip and tray, Find (the toolkit has one find per window: two panes would take it from each other).
- **A pane needs no width of its own** (`.Fits_Width` on `###main`, and on the composer's bar, which folds by itself:
  `composer_fit`). A pane sizes its column and its dock in pixels from the width it had. Counted as what it needs (the
  toolkit's least width), that width never shrank: the panel kept its width and went past the window's edge.
- **The keyboard's pane** (`keys_pane`): the panel's when the focus is in its view, else the main view's. Page Up and
  Down scroll that pane only. Each composer reads its own keys (Enter, Escape twice, `@`, `/`, the history) while it
  has the focus; typing with nothing focused goes to the main composer. The armed stop is cleared only by the pane
  that shows its session.
- **A right click records its pane** (`Ctx_Target.pane`): the message, its fork, "Edit in the composer", the composer's
  own menu act on that pane. A selection's quote goes to the pane under the pointer when it was made.
- **A dropped file** goes to the composer of the pane under the pointer (`pane_at`); in a window of its own the panel
  has no drop (the main window's drop only).
- **A right click in the panel's window of its own** opens its menu there (see "The panel in a window of its own").
- **What was global and is the pane's**: the throbber's word (two runs would flip one board between their words), the
  Mermaid width (the column of the pane that builds it: `md_config` carries the pane), the "Latest" pill's animation.
- **The session deleted** closes the panel that shows it; a server switch closes it too (its session is the old
  server's).

## The panel in a window of its own

A window of its own has its own `ui.State`: its own menus, popovers, tooltips, selection and boxes. A menu opened in
one State and built in another is never shown: the program's menus were noted where the press was and built at the
end of the main window's build, so a right click in the panel's window showed nothing.

- **A menu or a popover opens and is built in the window the press was in.** `pane_window` is the State a pane is
  built in: the panel's window when the panel has one, else the main window. `built_state` is the State being built.
- **What each window builds last** (`window_overlays`: the context menu and the quote chip): the main window's build
  ends with it; each view's window ends with it through the toolkit's hook (`ui.views_set_window_end`, set once beside
  the windows' backend). A view's build never calls it: docked or floating, the view is part of the main window's
  build, and a menu built twice in one build is two menus.
- **The context menu** records the window it opened in (`Ctx_Menu.window`). Each window's build builds it only there;
  in another window the toolkit closes a menu that is not built (`menu_prune`). The selection its Quote reads is that
  window's.
- **The quote chip** follows the last window pressed in: a selection is made with a press, and each window keeps its
  own selection, so a chip that went to the window with a selection would jump between two windows at each frame.
  In a conversation it holds to the message the selection ended in (its lazy item, and the pointer's offset in it), not
  to the screen: it scrolls with the text, hides while that point is out of the view, and comes back with it. The
  toolkit gives no rect of the selection itself, and a message is one rect test per message built.
- **Set the model's form and the agent chooser** (palettes, views of the window they open over) open in the build of
  the window of the pane that asked: `palette_choose` and `chooser_build` run at the top of the main window's build
  and at the top of the panel's build in its own window, and open only where `pane_window` of the asking pane is the
  State being built. The form sets that pane's model (palette.md, "The composer's buttons").
- **Tooltips** were already per window: `ui.tooltip` is built where it is asked.
- **`overlay_open` and `pane_at`** read the window being built: a menu of the main window does not stop a right click
  in the panel's window, and the pane under the pointer is found among that window's boxes.
- **Refused: one overlay pass per view.** Other views can have a window of their own (the diagram viewer has a
  right click too). A call in each view's build is a copy per view, and a view that forgets it has no menus in its
  window: the one hook covers every view's window.

## One session in both panes: one draft

The main view and the panel can show the same session. Each composer keeps its own text while it shows the session:
two panes on one session are two places to write, each with its caret and its undo. A text shared live would move one
person's caret under the other's typing, and the toolkit's undo would undo the other pane's edits.

- **A session shown keeps its whole draft in its composers.** `App.drafts` holds only the sessions that no pane shows.
- **A pane that leaves a session** another pane still shows gives its text, its attachments and its mentions to that
  pane's composer: after its text, a blank line between them, the caret kept. Nothing waits hidden in `App.drafts` for
  a session in view. The last pane to leave puts everything in `App.drafts`, as one pane always did.
- **A pane that comes to a session already shown** starts with an empty composer: the draft is in the other pane.
- **Something that comes for a session** after its pane moved on (an attachment read on a thread) goes to another
  pane that shows it, else to the draft.
- **On disk** (`drafts.json`), a session's text is the texts of its panes joined, as they would be if each left.
- **Refused: the last pane to close wins.** The draft was overwritten: the panel closed with its text, then the main
  view left the session with its own (or with none: the draft was dropped), and the panel's text was gone.

## Layer 3 decisions: /btw

- **A client command** (`CLIENT_COMMANDS`, slash.odin): listed first in the composer's `/` list and the palette's `>`,
  read before a server command (`submit_prompt` runs it before `slash_send`). With no text, or no session shown, it does
  nothing: the text stays.
- **One Outgoing** carries it (outgoing.odin, stages `Forking` then `Aside`): its text comes back to the composer it
  came from when the fork fails (`/btw ...` as typed), and to the fork's when the prompt fails. A server switch on the
  way gives it back to the home page, as any prompt not sent.
- **The fork point**: the last message; while a run streams, before the answer that streams (`fork_before`).
- **The title**: `btw: <first words>`, a PATCH as soon as the fork is made. The server (opencode 2.3.0) titles a fork
  `<parent's title> (fork #N)`; its own title is generated only for a root session still untitled
  (`SessionTitle.isUntitled`), and a generated title is not written when the title changed meanwhile. So the PATCH is
  never overridden, whatever arrives first: no need to wait for the first answer.
- **The preamble is a synthetic message**: the prompt body has no system or instructions field (`PromptInput`: text,
  files, agents, skills). `POST /api/session/<id>/synthetic` with `resume: false` admits it without starting a run;
  the prompt follows on its answer (two requests have no order otherwise), and its run reads both in order. Its
  `metadata.source` is `ocn.btw`: the display hides it, as the server keeps it apart. A delimiter in the prompt's text
  was refused: the text would carry the preamble into the history, the title generator and every other client.
- **The keyboard stays** in the composer that sent `/btw`: the panel opens without the focus.

## Layers

1. **Panes, no new behaviour**: `Chat_Pane`, the main view as pane 0, everything through the pane. All tests pass
   unchanged.
2. **A second pane in a panel**: `BTW_VIEW` shows a pane; requests and events reach it; its composer sends.
3. **/btw**: the command, the fork, the title, the preamble.
