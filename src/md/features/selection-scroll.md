# A selection dragged to the conversation's edge

A person who drags a selection of text to the top or the bottom of the conversation and holds it there sees the
conversation scroll, and the selection grow with what scrolls in. A copy then has every message the selection spans.
The toolkit does the scroll and keeps the selection (`ext/gui_toolkit/src/md/features/drag-autoscroll.md`, and
`text-selection.md`, "Rows built only in view"). The conversation has one state of its own that stopped it, and it gives
the toolkit its messages as rows. The code is in `src/scroll.odin` (`chat_selecting`) and `src/conversation.odin`
(`messages`, `message_text`).

## Following the bottom

While the view follows the bottom, `chat_scroll_place` puts the target at the bottom at each build. A move up by a hand
lets go of it (`Moved_Up`), but the drag's steps are a pixel or two a frame, under `BOTTOM_SLACK_PX`: each one was put
back. A selecting drag is therefore read as the middle-click autoscroll is read: a hand, with `AUTOSCROLL_SLACK_PX`.

The toolkit says nothing of its selecting drag. `chat_selecting` reads it from the window's state: the left button held
(its presses and releases, kept in the pane's view), no clickable box that holds the press (`active_key`), and text
selected. A press on a scroll bar or a column handle has a box, and keeps the old slack.

## Past the top edge

The session's header, above the conversation, is selectable text (the project's folder). Past the top edge, the moving
end went there, out of the conversation, and nothing scrolled. The toolkit now keeps the moving end inside the scroll
view around the anchor while that view can still scroll toward the pointer (`sel_drag_view`). The conversation does
nothing for it.

## The messages are the selection's rows

The lazy column builds only the messages near the view. `messages` declares them to the selection (`lazy_begin`'s
`rows`): row `i` is message `i`, and each message has its lazy item, in its order. The toolkit builds the two messages
that hold the selection's ends wherever they are. A copy reads each message between that is not built with
`message_text`.

- **The same text, built or not.** `message_text` follows the selectable boxes that each part's view builds, in the
  same state: a part open or folded, the preferences (reasoning, tools open), a diagram or its text. Each view has its
  text twin beside it (`md_text`, `tool_part_text`, `tool_body_text`, `subagent_card_text`, `job_reports_text`,
  `mono_well_text`), joined as the toolkit joins boxes (`Copy_Text`). Markdown is read again into a doc in temp
  memory: the views' docs and runs stay as their builds left them. A change to a view changes its twin; the test
  `a_copy_across_messages_not_built_is_their_text` compares a copy across messages not built with the copy of every
  message built.
- **A message is a block.** The rows' gap is "\n\n". The first selectable box of each message built takes
  `.Selection_Block` (`message_block`), so a copy puts the same blank line before a message built. Without it, a
  prompt after an answer was a line apart when built and a blank line apart when read.
- **`user` is the pane.** It stays where it is (`App.panes`), and the toolkit reads it after the build. A row past the
  messages (another conversation since the build) has no text.
- **Rows by index.** The toolkit keeps an end's row by its index. A page of older messages read while a selection
  stands (a drag held at the top reads it) puts messages above it: the toolkit then holds the wrong message, and an end
  whose message is out of view is not built, so the selection ends. The toolkit has no way yet to shift the rows.

Refused: building every message the selection spans (this file's first answer, `Chat_View_State.selected`). A drag
over a long conversation built thousands of messages at each frame.

## Left to the toolkit

- The full diff (`gt:diff` `view`) declares its rows already. What you missed (`ui.vlist`) builds only its rows in
  view: a selection there ends when its first row leaves.
