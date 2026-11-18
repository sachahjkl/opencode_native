# The sidebar's rail

The sidebar can shrink to a rail: a narrow column of the sessions' marks only, each one's details in a rich tooltip
on hover. A person keeps their sessions in reach and gives the conversation the width.

## The model

- **The rail is the sidebar view minimised.** The sidebar is a view of the toolkit (`SIDEBAR_VIEW`, at the left), with
  `View_Options.rail_em = SIDEBAR_RAIL_EM` (3.5: an avatar, its lamp and the toolkit's insets). Its zone's Minimise, and
  the toolkit's fold when the window leaves the conversation less than `DOCK_MIN_EM`, keep that column and build the
  view in it with `View.rail`: `sidebar_pane` then builds `sidebar_rail` (`src/sidebar_rail.odin`) in place of the list.
  No preference and no command of ocn's own fold it: one gesture for every side panel of every program. The toolkit's
  rule (`ext/gui_toolkit/src/md/features/side-panels.md`): the zone folds when the room leaves the conversation less than
  `DOCK_MIN_EM`, and opens again 1 em past it. A Minimise, a Restore or a pull by hand holds only until the width next
  crosses that threshold, either way: a list restored in a narrow window stays the list while the window stays narrow,
  and a rail minimised in a wide window opens again when the window goes narrow and then wide. Ctrl+B still
  shows or hides the sidebar, rail or list. Pulling the rail's edge outward opens the list at the pointer (the
  toolkit's handle, which the rail keeps; the title bar's line goes on from it in both forms, `view_dock_line`).
- **The fold button: first in the servers' row, at the rail's top.** The toolkit draws no head row and no Restore for
  a view with `rail_em`: the sidebar places the zone's fold button (`ui.view_fold_button`, `sidebar_fold`) itself. In
  the list it is the first box of the servers' row, before the server's tab: [fold] [This computer ▾] [+]. In the rail
  it is alone in a top row built as that row (same height, same space above). Its space before it puts its centre on
  the rail's centre, so it is the same pixel in both forms (24, 60 at 1600×1000): it stays under the pointer that folds
  and unfolds.
- **What a row becomes.** Each session is its mark: the avatar (`session_badge`: its project's logo, else its title's
  letter in the colour its id picks) with its lamp over the avatar's bottom right corner, the ground of the session
  shown behind it (`item_draw`, the row's). A groove stands between two sections where the list has a header.
- **One lamp, one rule.** `session_light` says what a session's lamp says, in the order one wins over another (waits,
  runs, runs in the background, finished unseen, rest); the row, the mark and the card's words all read it. A sub-agent
  has no mark: a parent at rest whose sub-agent runs lights its mark as running, and its card says how many run.
- **The rest of the sidebar.** At the top, New session and Search; Search opens the palette on `@` (the sessions), as
  the list's search field would need the width the rail gave away. The server's strip becomes its mark: the link's
  lamp on a server glyph, a click opens the server menu (every server, Add, Edit), its card says the name, the link's
  state and the address.
- **The card says what the row said, and more.** `tooltip_beside` anchored on the mark, past the rail's edge, at most
  `RAIL_CARD_EM` wide, its lines on the toolkit's spacing scale with no text padding of their own:
  - the title, bold, two lines at most (`rich_paragraph`'s `max_lines`, then "…");
  - one weak line "project · folder": the project is the folder's last part, the folder the one that holds it (the path
    said once), cut in its middle (`ui.elide` `.Middle`) so that both its root and its end show;
  - the state line: the mark's lamp, then its words, its running sub-agents and the last activity, parted by " · "
    ("Running · 2 sub-agents run · 3m ago"; at rest, the time alone). The time says "ago": no "Last active" label;
  - when it waits, what waits: each question, form or permission of it and of its sub-agents, one line each with its
    kind's icon under the lamp's column, three at most and "and N more".
- **At once under the pointer.** The pointer on a mark shows its card on that build (`Signal.hovering`, not
  `ui.hovered_for`): the rail is a column of faces, the card is what reads them, and the person runs the pointer down the
  rail to find a session. Each mark the pointer reaches shows its card at once; the toolkit's one tooltip box stays up and
  takes the new mark's content. The other buttons of the rail (New session, Search, the server) keep the delay: their
  tooltips name a button already known.
- **Keys and pointer.** A click opens the session, as a row does; a right click opens the row's menu (`session_menu`).
  Up and Down move the keyboard along the marks (`ui.focus_by_keys`: its ring shows, the mark comes into view); the card
  follows the keyboard (`ui.keyboard_focused`) while the pointer is off the rail. Enter opens, as on every button.

## Decisions

- **Not a second sidebar.** The rail reads the list's sections (`sidebar_view`: the same order, kept until what they
  come from changes, held under the pointer) and its fold of each section: a session added, renamed or finished shows
  in both forms at once. It reads them without the list's search: the rail has no field to show what was searched.
- **Built lazily, as the list.** The marks are a lazy column: only those near the view are built. The mark with the
  keyboard and its two neighbours stay built (`Side_Rail.near`), so Up and Down land on a box laid out; a step past
  them (`Side_Rail.want`) takes the keyboard at the next build.
- **One card at a time.** The toolkit has one tooltip per window. The pointer's card wins: the keyboard's shows only
  while the pointer is off the rail, which also keeps a button's own tooltip (New session, Search) alone.
- **No fold of ocn's own.** A width threshold or a button in ocn would differ from every other panel's.
- **The fold button in the servers' row (the user's choice, of mockups).** A row of its own for it (the toolkit's
  head row) was an empty band across the sidebar, seen as a strange black line. Refused: the button at the row's end
  (it jumps when the zone folds: the rail is narrower than the list); the button over the list's top corner (it lies
  over the list's controls). The space before it is read from the toolkit's button once built, not copied from its
  size: one size, the toolkit's.
- **The card beside the mark, not the pointer.** Beside the pointer it covered the rail's own marks.
- **No delay on the marks.** With `Feel.tooltip_delay_ms` (500 ms) the card came only once the pointer rested, and
  each move to the next mark started the wait again: a person who scans the rail saw no card at all. A mark has no
  label to read without its card, so the card is its label. The delay stays a toolkit setting for every other tooltip.
- **Dense lines, not tooltip_text.** `tooltip_text` gives each line the style's text padding: five facts took five
  loose lines with a gap of a line between each. The card lays its own lines out with `text_pad = 0`, `SPACE_1`
  between lines of a group and `SPACE_2` between the title group and the state group.
