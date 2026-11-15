# What you missed: several entries at once

The list of the view (`src/missed_view.odin`) selects several entries by gui_toolkit's model (`Item_Selection`, its
`src/md/features/selection.md`): Ctrl+click, Shift+click, Ctrl+Shift+click, Shift and Ctrl with the moves, Ctrl+Space,
Ctrl+A. The rows are the program's own boxes, not `list_row`: a press on a row gives the model the press and its
modifiers (`item_selection_click`); the list's keys are the toolkit's.

## Decisions

- **A acknowledges every entry selected**, the cursor's when none is. A row's own button (Acknowledge, Answer) acts on
  its row alone: it is a click on that row, not on the selection. Shift+A (the cursor's session) and Ctrl+Shift+A
  (everything) stay as they were.
- **A plain click opens; with Ctrl or Shift it only selects.** Opening closes the view: a click that is meant to select
  must not close it.
- **Enter, Space, Right and Left act on the cursor's row.** Enter opens one session; a fold is a look at one entry.
- **An unfolded row keeps its selection.** Its identity in the list carries the fold (`MISSED_OPEN_BIT`: another height,
  measured again), so a fold changes the id; the toolkit's `item_selection_rekey` moves the selection, its base and its
  anchor to the new id. An identity without the fold was refused: the list would keep the folded row's height.
- **Escape on several entries keeps the cursor's alone; on one, it closes the view**: the toolkit's rule, the list's
  own (its `cancelled` closes the view).
- **The cards do not select.** They show one entry at a time; A acknowledges the card shown.
- **A wait is answered in its card.** While the server still asks it, a permission's or a question's card holds the
  conversation's own card (`permission_card`, `form_card`), so it is answered without going to its session. The answer
  acknowledges it, as any answer does (`missed_sync`: a wait gone from the server's lists). Answer, the card's act, still
  opens the session. A copy of those cards for the view was refused: two cards that answer the same request would drift.
