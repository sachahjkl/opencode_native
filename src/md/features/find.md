# Find in the conversation

The find is the toolkit's (gui_toolkit `src/md/features/find-in-view.md`): one find per window, over one view, its bar at
the view's top right, its count, its steps, its ticks on the scroll bar, its scopes. This file says what opencode native
gives it and why. The code is `src/find.odin`, `message_text` and its writers (`conversation.odin`), the tests
`src/find_test.odin`.

## Purpose

"Where in this conversation does it say X" had three answers in 0.73: ocn's own find bar (it read only what was built; a
folded tool output, a reasoning past its preview, a diagram's source were never found), the prompt marks' filter field
(no count, no highlight, the same corner as the find bar), and Jump to message (Ctrl+Alt+G, a palette of the prompts).
They are one now: the toolkit's find over the conversation, with a scope for the prompts.

## What ocn gives the find

The messages are the rows of the lazy column (`ui.Text_Rows`), the same rows the text selection reads
(selection-scroll.md):

- **The whole text** (`message_text(..., whole = true)`): a message's text as its `.Selectable` boxes would give it with
  every part that opens opened. One writer (`message_write`) makes the copy's text and the find's; each part's writer
  (`tool_part_text`, `subagent_card_text`, `job_reports_text`, `md_text`) says what a fold hides with `copy_fold`. What is
  opened: a folded reasoning (unless the preference hides it: then no box would show it), a folded tool call's body, a
  closed sub-agent card (its facts, prompt and result), a closed sub-agent result, a closed job report, a Mermaid
  diagram's text. What is cut by the preference (`conversation.tool_lines`, the lines of a well) is not a fold: no click
  shows it, so it is not in the whole text either.
- **The stamp** (`message_stamp`): a sum of what the message's text is made of (the stream's clock `touched`, the lengths
  of its texts, outputs, inputs and streamed input, each call's status, the preferences that shape it). A streaming
  message moves it at each delta. A sub-agent card reads its child's session and result from elsewhere in the
  conversation: a message with one also takes `Chat.changes`.
- **The version** (`messages_version`): the conversation's generation, its count of messages and `Chat.changes`. A change
  makes the find go over the stamps again (a few thousand a frame), and read only the texts whose stamp moved.
- **The reveal** (`message_reveal`): the message's whole text is written again with the byte of the match; the folds that
  hold it (outermost first) are opened in `App.expanded`, as a click on their headers opens them. A Mermaid diagram then
  shows its text, as its header's button does.
- **The scopes**: "All", and "Prompts" (`message_is_prompt`: the reader's messages). Prompts replaces Jump to message: a
  few words of an earlier prompt and Enter go there, counted and lit.

## The bar in each pane

Each pane's conversation calls `ui.find_bar` after its scroll box (`conversation_find`): the main view and the /btw panel
each have their find. The toolkit's State holds one find, so a pane in the main window and the main view share it (Ctrl+F
moves it to the view with the keyboard); a panel in a window of its own has its window's.

Ctrl+F (`session.find`, the pane with the keyboard: `keys_pane`) and `--find` do not open it themselves: a command runs
after the frame, outside the build of the pane's window, where `ui.find_open` would act on another window's State. They
ask (`find_ask`), and the pane's next build opens it over its scroll box with the text. The home page closes it (no
conversation to search); `--find` given at a start waits for the session the start opens.

The magnifier above the prompt marks is the toolkit's: it opens and closes this find. ocn wires nothing for it.

## The view's place

The toolkit brings a match in by moving the scroll box's target after the layout. The conversation's scroll state
(scroll.odin) would undo it: following the bottom puts the view back at the end, a way back pins its message. So a target
that moved between two builds while the find is open over the view counts as the reader's move (`chat_scroll_place`): it
ends a way back and lets go of the bottom.

## Refused

- **Keeping ocn's bar over the toolkit's find in page**: its sweep built a slice of messages a frame to read their boxes,
  missed what a build folds, and two finds (the bar and the marks' filter) could be open in one corner.
- **A text of its own for the find** (a second procedure beside `message_text`): the copy and the find would drift, and a
  match counted in a text the boxes do not show could not be lit.
- **Jump to message kept beside the scope**: two ways to the same prompt, one without a count or a highlight.
- **The find in the main view only** (0.73: a panel with the keyboard kept Ctrl+F from it): the panel is a view; it has
  its bar.

## Subtle points

- The whole text of a sub-agent card says how long ago it started: the stamp does not move with the clock, so that one
  fact can be stale in the count. It is the facts' line alone.
- A reveal of a Mermaid block lays out its diagram to know whether it shows (as the build does); counting never does.
- A message that is not loaded (an older page not read) is not searched: the find counts what the conversation holds.
