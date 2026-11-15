# A server switch without a blink

Connecting to another server forgets everything of the old one at once (`server_forget`, every `Feature`), then the new
one answers over a few hundred milliseconds. The status bar showed what lies between: "0 sessions", no server version,
"connecting", and every label after them moved as the widths changed. Then the new values came. It read as a blink.

## The decision

- The status bar shows held values (`Chrome.said`, `status_said_follow`): the server's version changes when the new
  server has said its version; the sessions and the running counts change when its list of sessions has been read
  (`sessions_loaded`). Until then the old server's stay on screen. No count shows before a server's first list.
- Every label of the bar that a switch changes is a `ui.morph_label` (`morph_text`): the characters that differ flip
  into the new ones from left to right in 300 ms, at the new width at once; with the animations off, at once.
- The link's word and the server's address change at once, morphing: they say the state of the link, which is true
  from the click.

## Refused

- Keeping the old server's data until the new one answers: requests, events and drafts would then mix two servers.
  The data goes at once; only what the bar says is held, as words.
- A fade of the whole bar: it hides that the values did change.

## Subtle points

- A server whose list never comes (refused, unreachable) keeps the old counts beside its red link: the link's word
  says that the server did not answer, the counts are the last ones read.
- The rest of the window (the sidebar's sessions, the home page) still empties at the switch; the same rule can follow
  them.
