# Spacing: the toolkit's scale

The gaps and insets of opencode native's cards, lists and wells are the toolkit's spacing scale (its own
`src/md/features/spacing.md`): `ui.space(role)`, `ui.well(id, pad = ui.INNER_PAD)`, `ui.list_card` and `ui.card_row`. The
program keeps no spacing constant of its own for these.

## Decisions

- **A well's inset is the well's.** A text, a list of facts or a tool's input in a well sits `INNER_PAD` from its four
  edges through `ui.well`'s `pad`; the rows in it have no inset of their own (a `stat_row` gets `inset = {0, 0}`,
  `mono_text` starts at its box's edge). Before, each row padded itself and the top and bottom were spacers of their
  own: 0.4, 0.45, 0.5 em, and the left 0.75 or 0.8 em, depending on the place.
- **The dock's cards keep their plate.** A permission and a form are drawn by `plate` (their colours and the accent's
  border are theirs, which `ui.card` does not take); what is inside them uses `CARD_PAD`, `ICON_GAP`, `CONTROL_GAP`
  and `LINE_GAP`, and `ITEM_GAP` follows each.
- **A list is one card.** The MCP servers of the settings are a `list_card` with a row each, split by hairlines, not a
  plate per server with gaps between.
- **Dialogs and panels** (servers, schedules, artifacts, session tools, statistics) use `PAGE_MARGIN` at their sides;
  the tray under the composer uses `CARD_PAD`; a sub-agent's card uses `CARD_PAD` and `ICON_GAP` on its first line.

## Left as they are

- **Code listings with a gutter** (a read file, a search's matches, a diff): their line numbers are a column that starts
  at the well's edge, and a diff's rows are the toolkit's `diff.lines_view`. A well's `pad` would move the gutter in.
- **Sizes that are no gap**: the terminal's pixel inset (`TERM_PAD`, part of the grid's size in cells), the image
  viewer's grips (`VIEWER_PAD_EM`), the home page's top (`HOME_TOP_EM`), and the scroll margins.
- The other hand spacers of the views (between words of one line, in headers and bars) are not cards, lists nor wells.
