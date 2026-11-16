# MCP events (opencode 2.3.0, experimental)

MCP Events is a draft MCP extension: a server pushes events (a job ended, a message came) instead of being polled.
opencode 2.3.0 turns it on with its `mcp_events` flag, which ocn sets as it sets every experimental switch
(`experimental.odin`). The events reach ocn by two roads, and each shows where a person looks for it.

## What the server sends

- **`experimental.mcp.event`, on the event stream.** An ephemeral event of the server's place, not of a session:
  `{id, server, name, eventId, timestamp, data, cursor, truncated?}`. `id` is the subscription (one per server, event
  name and arguments); `name` is the event type; `eventId` and `timestamp` are the MCP server's; `data` is any JSON;
  `cursor` is where the subscription resumes; `truncated` says that events before this one were skipped. Delivery is
  at least once: dedupe on `id` and `eventId`. In 2.3.0 no HTTP route makes a subscription: a plugin of the server
  does (`Mcp.subscribe`).
- **A synthetic message in a session.** The `watch_mcp_event` tool wakes its session with a synthetic message whose
  `metadata` is `{source: "mcp.event", server, event, eventID}`, its `description` `"<server> <event>"`, and its text a
  preamble for the model, an optional line that events were skipped, then the event's data as fenced JSON (at most
  16384 characters). A watch that fails sends one with no `eventID`, whose text says why it stopped.

## Decisions

- **The stream's events go on the MCP servers page, under their server.** They name a server and no session. That
  page is where a person looks at what a server does. The activity is about runs and commands; a conversation is
  not theirs. Each server row lists its last events, newest first: the type, the data on one line, the age.
- **Kept, few, owned by the app.** At most `MCP_EVENTS_KEPT` events in all, the oldest dropped. They outlive a new
  reading of the page's facts (the list of servers is read again; the events are not the server's to give again),
  and go with the server (`server_forget`).
- **Read once, on arrival.** The data's one line is made when the event comes (cut to `MCP_EVENT_DATA_CHARS`); the page
  only draws strings. A duplicate (same subscription and event id) is dropped there too.
- **`truncated` says itself once**, on the event that carries it: "earlier events skipped".
- **The wake-up stays in the conversation**, as a note with the plug icon: `<server> · <event>`, and the event's data
  under it in a well. The preamble is the model's: the person sees what came, not the warning to the model. The data
  is the text between the last fence, read once when the message is read (`synthetic_set`).
- **A watch that stopped keeps its plain line** (its text's first line says why): it has no event to show.
- **Refused: a toast per event.** An event can come every second; the page and the session that watches are enough.
- **Refused: `experimental.mcp.subscription.changed`.** It carries only a subscription's id, and 2.3.0 has no route to
  read its status.
