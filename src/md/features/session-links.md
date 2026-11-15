# A session's id is a link

An agent writes the id of a session it made or read ("the child was ses_01HZ…"), and opencode 2.3.0 opens that
session from it. opencode native makes `ses_…` a link wherever a text has links: plain text (`ui.rich_links`) and
Markdown, inline code alone too.

## The decision

- The toolkit's link words (`ui.link_words_set`): the prefix `ses_` is set once for the process, in an `@(init)`
  (the toolkit refuses a second call: its prefixes are read without a lock by the threads that make runs).
- The link's target is the id. `link_open` opens it as a sub-agent's card does (`drill_down`): Back returns to the
  session it was read in.

## Refused

- Finding ids by a pattern in each text at each frame: the runs are made when a text changes, by the same pass that
  finds web addresses.
- Opening it as a new root (`open_root`): the reader followed a link and expects Back.

## Subtle points

- An id of another server's session, or one deleted, opens a session that cannot be read: its page says so, and Back
  comes back.
