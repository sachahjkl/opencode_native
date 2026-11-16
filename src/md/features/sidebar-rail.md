# The sidebar's rail

The sidebar can shrink to a rail: a narrow column of the sessions' marks only, each one's details in a rich tooltip
on hover. A person keeps their sessions in reach and gives the conversation the width.

## The model

- **The rail is the sidebar view minimised.** The sidebar is a view of the toolkit (`SIDEBAR_VIEW`, at the left), with
  `View_Options.rail_em = SIDEBAR_RAIL_EM` (3.5: an avatar, its lamp and the toolkit's insets). Its zone's Minimise, and
  the toolkit's fold when the window leaves the conversation less than `DOCK_MIN_EM`, keep that column and build the
  view in it with `View.rail`: `sidebar_pane` then builds `sidebar_rail` (`src/sidebar_rail.odin`) in place of the list.
  The zone's Restore, at the column's top, is the toolkit's. No preference and no command of ocn's own fold it: one
  gesture for every side panel of every program. Ctrl+B still shows or hides the sidebar, rail or list.
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
- **The card says what the row said, and more.** `tooltip_beside` anchored on the mark, past the rail's edge: the
  title; the project (the folder's last part) and, under it, the folder that holds it (the path said once); the state
  in words, or, when it waits, what waits (each question, form or permission of it and of its sub-agents, three at
  most and a count of the rest); the last activity.
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
- **The card beside the mark, not the pointer.** Beside the pointer it covered the rail's own marks.
