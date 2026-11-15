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
- **What is keyed by session or part stays in `App`**: the drafts (`App.drafts`), the parts opened (`App.expanded`: a part's
  id names one part of one session; the stats panel uses it too). The restore clock of a way back is the pane's view state.
- **The main view's own features keep `main_pane`**: the history (Back, Forward), the sidebar, the commands, the palette,
  the title bar, the activity tray, the statistics, "What you missed", the context menu, `open_chat` and the home page's
  folder. They act on the main view; Layer 2 decides which of them a panel has.

## Layers

1. **Panes, no new behaviour**: `Chat_Pane`, the main view as pane 0, everything through the pane. All tests pass
   unchanged.
2. **A second pane in a panel**: `BTW_VIEW` shows a pane; requests and events reach it; its composer sends.
3. **/btw**: the command, the fork, the title, the preamble.
