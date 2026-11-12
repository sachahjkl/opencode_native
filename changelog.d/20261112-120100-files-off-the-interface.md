type: Fixed

**Settings and remembered lists are saved in the background**: the last session, the server, the palette's ranking, each shell's zoom, the drafts and the list of servers are read once at the start, then saved by a background thread a moment after they change. The window no longer waits on the disk for them, and a crash can no longer leave one of these files cut.
