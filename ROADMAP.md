# Roadmap

## Now

## Next

- **The sessions of every server in one list.** A setting shows the sessions of all servers in one list sorted by activity,
  each with the mark of its server, beside today's one tab per server. This needs a state per server (sessions, event
  stream, requests, What you missed) and a session identity that carries its server; decide first which servers stay
  connected, the cost of one event stream each, and how to open another server's session without dropping everything.

## Later

- **A choice of layouts for a Mermaid diagram.** In the diagram's viewer: top to bottom, left to right, and the other
  placements gt:mermaid offers.
- **Preview a remote file outside the session's folder.** Today the Files dialog previews and searches a remote server
  only inside the session's folder, because /api/fs/read reads only inside a location; reopen this if the server reads an
  absolute path or offers a read without a location.
- **Sizes and dates of a remote server's files.** /api/fs/list gives only a path and a type, so the file browser hides
  these columns for a server; show them when the server gives them.
