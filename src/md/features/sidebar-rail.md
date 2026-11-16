# The sidebar's rail

The sidebar can shrink to a rail: a narrow column of the sessions' marks only, each one's details in a rich tooltip
on hover. A person keeps their sessions in reach and gives the conversation the width.

## The model

- **The rail is the sidebar view minimised.** The sidebar is a view of the toolkit (`SIDEBAR_VIEW`, at the left). Its
  zone's Minimise (and the toolkit's minimise when the zone gets too narrow) gives the view a narrow column and builds it
  minimised; the sidebar then builds its rail in place of its list. No preference and no command of ocn's own fold it:
  one gesture for every side panel of every program.
- **What a row becomes.** Each session is its mark (the avatar: its project's letter in its project's colour) with its
  state on it (the lamp: running, waiting for you, failed), in the list's order (Waits for you first, then Recent). A
  sub-agent is not shown: its parent's mark says it runs.
- **The rest of the sidebar.** At the top, New session and Search; Search opens the palette on `@` (the sessions), as
  the list's search field would need the width the rail gave away. The server's strip becomes its mark.
- **The tooltip says what the row said, and more.** On hover (the toolkit's `tooltip_beside`), a card: the title, the
  project and its folder, the last activity, the state in words, and what waits (a question, a permission) when it
  waits. It says each fact once.
- **Keys and pointer.** A click opens the session, as a row does; the context menu is the row's. Up and Down move the
  focus along the marks; the tooltip follows the focus.

## Decisions

- **Not a second sidebar.** The rail is built from the same rows (the same sections, order and states), only drawn
  small: a session added, renamed or finished shows in both forms at once.
- **No fold of ocn's own.** A width threshold or a button in ocn would differ from every other panel's.

## Waits on

The toolkit: a side zone's Minimise that gives its view a narrow column (a rail width the view states) and builds it
minimised, instead of the strip alone (gui_toolkit's views).
