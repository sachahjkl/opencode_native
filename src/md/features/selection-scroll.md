# A selection dragged to the conversation's edge

A person who drags a selection of text to the top or the bottom of the conversation and holds it there sees the
conversation scroll, and the selection grow with what scrolls in. The toolkit does the scroll
(`ext/gui_toolkit/src/md/features/drag-autoscroll.md`): the selection marks its drag, and the nearest scroll view moves.
The conversation has two states of its own that stopped it. The code is in `src/scroll.odin` (`chat_selecting`) and
`src/conversation.odin` (`messages`).

## Following the bottom

While the view follows the bottom, `chat_scroll_place` puts the target at the bottom at each build. A move up by a hand
lets go of it (`Moved_Up`), but the drag's steps are a pixel or two a frame, under `BOTTOM_SLACK_PX`: each one was put
back. A selecting drag is therefore read as the middle-click autoscroll is read: a hand, with `AUTOSCROLL_SLACK_PX`.

The toolkit says nothing of its selecting drag. `chat_selecting` reads it from the window's state: the left button held
(its presses and releases, kept in the pane's view), no clickable box that holds the press (`active_key`), and text
selected. A press on a scroll bar or a column handle has a box, and keeps the old slack.

## The messages a selection spans

The lazy column builds only the messages near the view. A selection whose first box is not built ends (the toolkit),
and a copy reads only the boxes built. A drag over two screens took the message it started in out of the column.

`Chat_View_State.selected` keeps the first and the last message the selection spans, by the hash of their items' ids.
Those messages, and every one between them, are built whatever. While the button is held on text, each message the view
shows is added to the span. The span is dropped when no selection stays and the button is up, and a press on text starts
it again. A press on a button keeps it: a Copy button reads the selection on its release.

Refused: building every message while a selection stands. A selection of one line in a long conversation would cost
what a find costs, at every frame.

## Left to the toolkit

- Past the top edge of the main view, the moving end goes to the session's header (the project's folder), which is
  selectable text on the same surface. The marked box is then outside the conversation, and nothing scrolls. In the band
  inside the edge it scrolls. The toolkit's `sel_nearest` must keep the moving end inside the scroll view around the
  anchor while that view can still scroll toward the pointer.
- The full diff (`gt:diff` `view`) and What you missed (`ui.vlist`) build only their rows in view: a selection there
  ends when its first row leaves.
