# Sub-agents that run in the background

Since opencode 2.3.0 a sub-agent always runs in the background. The `subagent` tool returns at once; the child works on;
the parent gets a report each time the child goes idle. Several children can run while the parent works. Before, ocn
read the end of the call as the end of the child: a launch showed as "done" a second after it began.

## What the server sends

- **The call returns at once.** Its output is `{sessionID, status: "running", output}` and its tool part completes with
  `metadata: {sessionID, status: "running"}` (`packages/core/src/tool/plugin/subagent.ts:18-27`, `:224-230`). The
  output is a note to the model ("The subagent is working in the background…"), not a result. The progress event
  carries the same metadata while the call runs (`:199`).
- **A follow-up** is a new call with `input.sessionID`: the same child works again and reports again
  (`subagent.ts:40-42`, `:147-176`).
- **The report** is a synthetic item that the child's end admits into the parent's inbox with `delivery: "steer"`
  (`packages/core/src/session/execution/subagent-report.ts:80-95`). The stream says `session.inbox.enqueued` with
  `item: {type: "synthetic", payload: {text, description, metadata}}`, then `session.inbox.delivered`. On delivery the
  server stores a message `{type: "synthetic", id: inboxID, text, description, metadata}`
  (`packages/core/src/session/projector.ts:1026-1034`). An idle parent is woken by it (`subagent-report.ts:126-127`).
- **Its text** is `<subagent sessionID=".." state=".." description="..">\nbody\n</subagent>`; its metadata is
  `{source: "subagent", childID, agent, state}` (`packages/core/src/session/subagent-completion.ts:73-79`).
- **"Still running"**: when the child goes idle while its own background work runs (shells, images, its own
  sub-agents), the body ends with `\n\nBackground work still running:\n- …` and the tag's `state` is `"running"`
  (`subagent-completion.ts:37-52`, `:72`). `metadata.state` keeps the real status of the period (`completed`): only
  the tag says it runs. A later report comes when that work ends.
- **The desktop** (`packages/app/src/session/requests/background.ts:80-119`) counts a sub-agent as running exactly
  while its session runs; "calls never decide whether it still runs". It shows each report as a notice row that links
  to the child (`packages/session-ui/src/timeline-next/row.tsx:615-635`, `:740-747`).

## Decisions

- **The child decides, never the call.** `sub_view` reads a completed call with `metadata.status = "running"`
  (`Part.sub_launched`) as a launch: the child runs until a report newer than the last such call came. Busy, it runs
  whatever the reports say. A completed call without that status is a foreground call of an older session: its output
  is the result, as before.
- **"Newer" is the order of the messages**, not the clocks. A report is delivered after the step that made the call,
  and a follow-up call is in a step after the report it answers. `Sub_Index` keeps, for each child, the index of its
  last report and of its last launching call (`calls`).
- **A report that says its work still runs keeps the child running** (`Message.sub_running`, read from the tag).
  Its card says so; the final report ends it.
- **The report shows as it comes.** At `session.inbox.enqueued` with a synthetic item, ocn adds the message at the end
  of the conversation, built from the payload as a page would build it. The page read later puts the stored one in
  its place; `session.inbox.cancelled` drops it (`queue_shown_as_sent`, `chat_drop`).
- **Each report is its own row**, as on the desktop: the call's card shows the last one, the conversation shows them
  all. A row of a "still running" report has a quiet mark, not a lamp: it is a past event, the card says the present.
- **What runs is kept, not computed per frame.** `sub_running` makes the list of running children again only when
  the index (`subs_seq`), what runs (`marks_ver`) or the list of children (`children_ver`) changed. The header's button,
  the chips over the composer and the activity tray read it. A child that a call names but that the children list
  does not have yet counts in the tray's line (`unlisted`).

## Refused

- **The child's session state alone, as the desktop does.** A child idle with its own shells still running would
  show as done, and the report that says "still running" would be ignored.
- **Clocks to order calls and reports.** The call's time is the client's view of a stream event, the report's is the
  server's; a page and the stream do not give the same.
- **Waiting for `session.inbox.delivered` to show a report.** A busy parent delivers it only at its next step; a long
  shell call would hide the child's end for its whole length.
- **Keeping `input.background` and the state "in background".** No 2.3.0 call has that input: every call is a launch.

## Subtle points

- A report enqueued before the conversation was opened comes with the page.
- A page asked before a report was enqueued but answered after does not have it: the streamed message is newer and
  stays (`chat_load`).
- A report's message has no tool part: the index must be read again when it arrives (`subs_changed`).
- A failed call (`session.tool.failed`) launches nothing: the index is read again so that it no longer counts.
