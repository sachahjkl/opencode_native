# opencode native: intent

The design of opencode native's parts, beside the code (https://srcmd.org). The code says how; these files say why: the
purpose, the decisions, what was refused.

- The interface is gui_toolkit's. What the toolkit decides is in its own `src/md`; these files record only what this
  program decides on top of it.

## File Index

- [features/views.md](features/views.md): the dialogs and the panels as views; the program's state as the truth of what
  is open; a shell's input in a window of its own; the Preview's page across windows.
- [features/missed.md](features/missed.md): several entries of What you missed selected and acknowledged at once.
- [features/job-reports.md](features/job-reports.md): the harness's reports of ended background jobs, read as cards.
- [features/background-subagents.md](features/background-subagents.md): sub-agents run in the background (opencode
  2.3.0): the child's state and its reports decide, never the call's quick return.
- [features/remote-localhost.md](features/remote-localhost.md): a remote server's localhost in the browser panel is
  that server's machine: translated in `web_navigate`, said in the address bar.
- [features/free-limit.md](features/free-limit.md): the free limit reached: a panel in the composer's place until it
  resets, unless a provider is paid.
- [features/server-switch.md](features/server-switch.md): a server switch without a blink: the status bar holds the
  old server's values until the new one says its own; the changes morph.
- [features/session-links.md](features/session-links.md): a session's id in a message is a link that opens it, with
  Back.
- [features/chat-panes.md](features/chat-panes.md): conversation panes, the main view one of them; /btw forks the
  session into a panel on the right with the same composer; its menus in its window of its own; one draft for a
  session in both panes.
- [features/jump.md](features/jump.md): Jump to message (Ctrl+Alt+G): a chooser over the session's prompts; why a
  palette of its own.
- [features/queue-first.md](features/queue-first.md): Alt+Enter queues a prompt first while a run works; the inbox
  re-admitted in order, admit before cancel, the reorder's state machine.
- [features/escape-stop.md](features/escape-stop.md): Escape stops a run in two presses; the banner in the composer.
- [features/sidebar-rail.md](features/sidebar-rail.md): the sidebar minimised to a rail of the sessions' marks, their
  details in a rich tooltip; the toolkit's minimise of a side zone, no fold of ocn's own.
- [features/single-instance.md](features/single-instance.md): one window per person: a second start hands its
  command line to the window that runs; `--quit` ends it as Quit does; the starts that stay on their own.
- [features/images.md](features/images.md): the images and logos over the toolkit's picture cache; which bytes an
  image is; base64 decoded at a miss only.
- [features/diagrams.md](features/diagrams.md): Mermaid diagrams: the layouts on the interface's thread and off it;
  the viewer's four directions, remembered per diagram for the program's run; why not a preference.
- [features/palette.md](features/palette.md): the toolkit's palette with ocn's sources; the shared prefixes; what was
  lost and why.
- [features/server-passwords.md](features/server-passwords.md): the servers' passwords sealed with `gt:secrets`; the
  field kept per server, the one forget after the seals, a password in clear where no store answers.
- [features/spacing.md](features/spacing.md): the toolkit's spacing scale in the cards, lists and wells; what keeps
  its own size and why.
- [features/setup.md](features/setup.md): gt:setup's screen with ocn's content (identity, logo, vendor); no note,
  no screen of its own.
- [features/keys.md](features/keys.md): the commands' keys through the toolkit's keymap: a person's key replaces a
  command's own; the keys read elsewhere, shown here.
- [features/folders.md](features/folders.md): the program's folders and its install in its vendor's
  (FromentSoftware/OpencodeNative), the earlier folders moved once; the title a person reads.
- [features/colours.md](features/colours.md): the views draw with the theme chosen, by role and hue; OpenCode is one
  theme definition; the entries the toolkit's palette lacks.
- [features/mcp-events.md](features/mcp-events.md): MCP events (opencode 2.3.0, experimental): the stream's on the
  MCP servers page under their server; a session's wake-up as a note with its data.
- [features/freeform-tools.md](features/freeform-tools.md): a tool input of one long text shows as text, streamed through
  an explicit decoder of the input's JSON fragments.
- [features/step-speed.md](features/step-speed.md): a step's latency and writing speed from `time.firstToken`, per model
  in the Statistics panel and at the end of an answer.
- [infrastructure/transport.md](infrastructure/transport.md): requests, the event stream and the sockets over the
  toolkit's gt:http; the limits, the stream up at its first event, why sockets send from their own thread.
