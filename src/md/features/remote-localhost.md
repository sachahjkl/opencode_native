# A remote server's local addresses in the browser panel

An agent of a remote server starts a development server and says "open http://127.0.0.1:5173". The browser panel
opened that address on the reader's computer, where nothing listens, or something else does. For a remote server, a
loopback address (localhost, 127.0.0.0/8, ::1, 0.0.0.0) names the server's machine.

## The decision

- Every navigation of the panel goes through `web_navigate`, whatever asked for it (a link, the address bar, an
  agent's browser tool): it translates there, once (`preview_reach`). A loopback host becomes the connected server's
  host (its domain or its address, as the server's URL says), the scheme, the port, the path and the rest kept.
- Only for a remote server: when the server's own host is a loopback address, the reader's machine is the server's,
  and nothing is translated.
- The address bar says it: its field shows the address opened, and a mark beside it says that the server's
  `127.0.0.1` was reached at its host (a tooltip says the whole). The tab keeps the host it translated (`mapped`), and
  the mark shows while the page is on the server's host.

## Refused

- Translating only the links of the conversation: the agents' browser tool and the address bar open the same pages.
- A tunnel to the server's loopback (an SSH forward, a proxy in the server): it would reach what listens only on the
  server's loopback, but it is a feature of its own, with its credentials. A development server that listens on all
  interfaces is what this reaches; one bound to 127.0.0.1 alone stays out of reach, and the page's error says so.
- Asking each time: the meaning of a loopback address does not change with the page.

## Subtle points

- A port kept: the server's own port (4096) is not the page's.
- An IPv6 host is written in brackets in a URL (`[::1]`); the server's host is put in as its URL writes it.
