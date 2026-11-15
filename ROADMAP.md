# Roadmap

## Now

- **Personal keys and aliases.** The commands read their keys through the toolkit's keymap (`ui.Keymap`, its
  `src/md/features/keymap.md`): a key set from the palette (Ctrl+Enter) replaces a command's own, and the settings show
  the Keys page. Until then the Keys settings are not registered.
- **Tab numbers while the modifier is held** (opencode 2.3.0). Holding Ctrl shows the number of each tab that Ctrl+1 to Ctrl+9 opens, as
  the desktop does after 400 ms. opencode native has no such shortcuts yet: decide first which list gets them (the
  sidebar's sessions, the server tabs).

## Next

- **The sessions of every server in one list.** A setting shows the sessions of all servers in one list sorted by activity,
  each with the mark of its server, beside today's one tab per server. This needs a state per server (sessions, event
  stream, requests, What you missed) and a session identity that carries its server; decide first which servers stay
  connected, the cost of one event stream each, and how to open another server's session without dropping everything.

## Later

- **MCP events, freeform tools, a step's first token (opencode 2.3.0, experimental).** The stream can carry
  `experimental.mcp.event`, a model can take freeform tool input, and a step says when its first token came
  (`time.firstToken`). opencode 2.3.0's own clients show none of them yet: show them once one does, or once a step's
  speed (from its first token) is wanted in the statistics.
- **A shell that costs less per frame.** An open command view costs 4.3 to 5.0 ms a frame against 1.2 ms without it
  (Linux, -o:speed): every glyph of every row is emitted again each frame. Keep a row's draw list
  while the row does not change. The bench (OCN_BENCH) also has two checks that fail on Linux: the middle wheel's
  "gone up" and app.find.index.
- **A choice of layouts for a Mermaid diagram.** In the diagram's viewer: top to bottom, left to right, and the other
  placements gt:mermaid offers.
- **Preview a remote file outside the session's folder.** Today the Files dialog previews and searches a remote server
  only inside the session's folder, because /api/fs/read reads only inside a location; reopen this if the server reads an
  absolute path or offers a read without a location.
- **Sizes and dates of a remote server's files.** /api/fs/list gives only a path and a type, so the file browser hides
  these columns for a server; show them when the server gives them.
