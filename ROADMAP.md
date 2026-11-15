# Roadmap

## Now

What opencode 2.3.0 (https://opencode.ai/changelog/v2.3.0) brings that opencode native must follow:

- **Sub-agents run in the background by default.** A sub-agent's call returns at once and the child reports when it goes
  idle, several at a time, while the parent goes on; a report can say the child's own work still runs. Show the running
  children and their reports as they come, and never treat a call's quick return as the child's end.
- **Jump to an earlier prompt.** A command (Ctrl+Alt+G, and in the palette) searches the session's prompts and scrolls
  the conversation to the one chosen.
- **Order the queue from the composer.** Alt+Enter puts the follow-up first in the queue; Ctrl+Enter steers the next
  queued prompt, as the desktop app does.
- **A session's id is found and opened.** A session id in a message opens that session; the session's own id is easy to
  copy from its header or menu.
- **A Mermaid diagram maximised.** The diagram's viewer fills the window, with zoom and pan.
- **Each server's shell chosen from its menu.** The terminal's shell is a choice of the server's menu.
- **Tab numbers while the modifier is held.** Holding the key of the tab shortcuts shows each tab's number.
- **The free-limit panel.** When the server says the free limit is reached, a panel takes the composer's place.
- **MCP events and freeform tools (experimental).** Subscribe to `experimental.mcp.event` when the flag is on; the
  model's capabilities now list freeform tool input; the session's throughput is measured from the first token.

## Next

- **The sessions of every server in one list.** A setting shows the sessions of all servers in one list sorted by activity,
  each with the mark of its server, beside today's one tab per server. This needs a state per server (sessions, event
  stream, requests, What you missed) and a session identity that carries its server; decide first which servers stay
  connected, the cost of one event stream each, and how to open another server's session without dropping everything.

## Later

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
