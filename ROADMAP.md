# Roadmap

## Now

- **Tab numbers while the modifier is held** (opencode 2.3.0). Holding Ctrl shows the number of each tab that Ctrl+1 to Ctrl+9 opens, as
  the desktop does after 400 ms. opencode native has no such shortcuts yet: decide first which list gets them (the
  sidebar's sessions, the server tabs).

## Next

- **The pictures of the documentation, again.** The README's and the site's pictures still show the old model picker and
  the colours before the theme. `ocntools shots` needs the demo sessions on the local server; make them reproducible
  so the pictures can be made again on any machine.
- **The sessions of every server in one list.** A setting shows the sessions of all servers in one list sorted by activity,
  each with the mark of its server, beside today's one tab per server. This needs a state per server (sessions, event
  stream, requests, What you missed) and a session identity that carries its server; decide first which servers stay
  connected, the cost of one event stream each, and how to open another server's session without dropping everything.

## Later

- **Preview a remote file outside the session's folder.** Today the Files dialog previews and searches a remote server
  only inside the session's folder, because /api/fs/read reads only inside a location; reopen this if the server reads an
  absolute path or offers a read without a location.
- **Sizes and dates of a remote server's files.** /api/fs/list gives only a path and a type, so the file browser hides
  these columns for a server; show them when the server gives them.
