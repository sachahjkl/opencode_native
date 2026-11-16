# Spacing: the toolkit's scale

The gaps and insets of opencode native's cards, lists and wells are the toolkit's spacing scale (its own
`src/md/features/spacing.md`): `ui.space(role)`, `ui.well(id, pad = ui.INNER_PAD)`, `ui.list_card` and `ui.card_row`. The
program keeps no spacing constant of its own for these.

## Decisions

- **A well's inset is the well's.** A text, a list of facts or a tool's input in a well sits `INNER_PAD` from its four
  edges through `ui.well`'s `pad`; the rows in it have no inset of their own (a `stat_row` gets `inset = {0, 0}`,
  `mono_text` starts at its box's edge). Before, each row padded itself and the top and bottom were spacers of their
  own: 0.4, 0.45, 0.5 em, and the left 0.75 or 0.8 em, depending on the place.
- **A raised card is `ui.card`.** A permission, a form, the person's prompt, a sub-agent's card and its banner are
  `ui.card` with their own look (colours.md); the card puts `CARD_PAD` on its four sides, so what is inside them has
  no inset of its own. Inside, they use `ICON_GAP`, `CONTROL_GAP` and `LINE_GAP`; `ITEM_GAP` follows a dock's card.
  The find bar keeps a `.Plate` box with a look and no card: it is only the shadow under its well, which an inset would
  part from it.
- **A list is one card.** The MCP servers of the settings are a `list_card` with a row each, split by hairlines, not a
  plate per server with gaps between.
- **Dialogs and panels** (servers, schedules, artifacts, session tools, statistics) use `PAGE_MARGIN` at their sides;
  the tray under the composer uses `CARD_PAD`; a sub-agent's card uses `ICON_GAP` on its first line.

- **Every other gap is a step.** The hand spacers of the views (between the words of a line, in headers and bars, the
  gaps of a flow) are `ui.space` with the nearest step: a value of 0.15 to 0.35 em is `SPACE_1`, 0.4 to 0.6 `SPACE_2`,
  0.7 to 0.85 `SPACE_3`, 0.9 to 1.2 `SPACE_4`, 1.3 to 1.6 `SPACE_6`. The gap after an icon, a lamp or a badge before
  its words is `ICON_GAP`, after a button `CONTROL_GAP`, where it was already 0.5 em. A gap after an icon that was 0.2
  to 0.35 em stays `SPACE_1`: `ICON_GAP` would part a line's icon from its words by twice as much.
- **The home page ends `PAGE_MARGIN` under its hints** (2 em before): the only gap that moved by more than 0.2 em.
- **The title bar's line keeps at least `SPACE_3` after the wordmark.** It is a minimum (the line follows the sidebar's
  handle); `SPACE_4` pushed it past a sidebar of its default width.
- `ui.space` measures in the current font size. No spacer of a view is inside a scope of smaller text (`ui.style` with a
  `font_size`); a gap that one day is must stay `ui.spacer(ui.px(em * ui.SPACE_n))`.

## Left as they are

- **Code listings with a gutter** (a read file, a search's matches, a diff): their line numbers are a column that starts
  at the well's edge, and a diff's rows are the toolkit's `diff.lines_view`. A well's `pad` would move the gutter in.
  The diff's `gap_height` and `indent` (`diff_options`) are its rows' geometry.
- **Sizes that are no gap**: the terminal's pixel inset (`TERM_PAD`, part of the grid's size in cells), the image and
  diagram viewers' grips (`VIEWER_PAD_EM`), the home page's top (`HOME_TOP_EM`), the space under the last message
  (`CHAT_FOOT_EM`, a run's line lives in it), the line under the browser's tab (`TAB_LINE_INSET_EM`, an inset of a
  drawn line), and the scroll margins (`PROMPT_RAIL_MARGIN_EM`, `FIND_BOTTOM_MARGIN_EM`, `OLDER_MARGIN`).
- **A control's inside**: the `text_pad` of a field or a composer's tool button (`COMPOSER_TOOL_PAD_EM`) is the inset of
  its text in the control, as a button's height is its size, not a gap between boxes.
- **Indents that line up with a column**: a sub-agent's rows under their mark (`CARD_INDENT_EM`, the mark and
  `ICON_GAP`), a tray's lines under a row's title (`CARD_PAD + 1.2`), an MCP server's notes under its lamp, the sidebar's
  tree (1.1 em a level, 1.6 em for a sub-agent at the top), its "… more" row (2.6 em), the missed card's brief (3.4 em),
  the server form's hint under its fields (7.4 em, the labels' column). They are the width of what they line up with.
