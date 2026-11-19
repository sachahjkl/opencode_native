# Download a file of the server

A person downloads a file of the server's computer to this computer. The server can be another computer: the files the
agents read and write are there, not here.

## Where a person asks for it

- **A tool call's file** (read, edit, write: `Part.file_path`): "Download…" in its context menu.
- **A path selected in a message**: "Download the selected path…" in the message's context menu, when the selection is
  one line that reads as a path. A relative path is taken from the session's folder.
- **The palette**: "Download a file…" (`session.download`) opens the file browser on the server's files in a pick mode
  (act: Download). The person chooses one file.
- **A row of the file browser** (`File_Dialog.row_actions`): "Download" in the context menu of a file (a right click, the
  Menu key), in the palette's pick and in the session's files (Ctrl+P). It goes straight to this computer's Downloads
  folder, as a web browser's download does, and the browser stays open: the person goes on choosing. A multiple
  selection downloads each file. A name already there gets " (1)", " (2)"... before its extension.
- **Folders: not now.** The server has no archive of a folder. If it offers one (a zip), a folder can come the same way.

The three "Download…" entries ask where the file goes: the toolkit's Save dialog, with the file's name and the overwrite
question, in the folder the last download went to, else in Downloads (`start_known = .Downloads`: the toolkit asks the
system on its chores).

## The transfer

- **One `GET /api/fs/read/<path>?location[directory]=<folder>`, its body streamed** (`gt:http.receive`, through
  `Transport.receive`). Each chunk goes to the disk on the request's thread and is kept nowhere: a file of any size takes
  the memory of one chunk. The path is taken from the location: the server reads an absolute path in the address as a
  relative one. The location is the session's folder when the file is in it (a folder the server has loaded already),
  else the file's own folder.
- **The bytes go through `fsx.Writer`.** The writer's temp file is beside the target and takes its name at the commit:
  the target is never half written. A failure, a cancel or the program's end aborts it: the temp goes, the target is as
  it was. The writer opens at the first chunk: a refusal writes nothing. An empty file (2xx, no chunk) opens and commits
  at once.
- **A cancel is the request's `Stop`.** Cancel asks it from the interface's thread; the chunk callback also answers
  `.Stop` when it sees it, so a cancel takes effect at the next chunk, or within about a second of silence.
- **A body shorter than its `Content-Length` fails** ("the file changed or the connection was cut during the
  download"). What is lost from the ranges: a file rewritten with the same size during the transfer is no longer seen.
  The ranges' `If-Range` saw it; one stream has no second answer to compare. A check after the body (a one-byte range
  with `If-Range`) would see it again at the cost of a second request; refused for now (see Refused).
- **The silence bound is `DOWNLOAD_SILENCE` (30 s), not a total.** A large file takes longer than any total; a server
  that sends nothing for 30 s is gone. No byte bound: the body is not kept.
- **No compression.** A compressed body has no length (`Body_Part.length` -1): no percent, no short-body check.
- **The connection's credentials.** The download goes by the connection that was current when it was asked (`conn_hold`),
  with its `Authorization`. A switch to another server does not stop it: its file is of the server it was asked of.
- **A refusal says its status.** `receive` gives no body of an answer that is not 2xx, so the server's message is not
  read: 404 says "the file is not on the server", 401 the authentication, 403 the refusal, any other "the server
  answered <status>".
- **The workers are the downloads' own pool (`DOWNLOAD_WORKERS`, 3).** A long transfer does not take a worker of the
  connection's requests. A fourth download waits in the queue.

## What the person sees

- **A notification of the system with a progress bar** (`Notification.progress`), when the person's messages go to the
  system (`Announcer.mode == .System`) and the system shows one. Its title is the file's name; the bar's words are
  "45 % (12 MB of 27 MB)" ("12 MB" without a size); its button is Cancel. The worker wakes the interface at most every
  `DOWNLOAD_STEP` (250 ms) and the notification is sent again with `replace`: Windows moves its bar in place.
- **Its end in the same notification**: "Downloaded logo.png" with the target, its buttons Open and Show in folder (a
  click shows it in its folder), or "logo.png was not downloaded" with the reason. Another shape: the system shows it
  again, the end is news. A cancel closes it: the person did it.
- **The status bar's pill holds the downloads that have no notification**: the system shows none, the messages go to
  the window, or the person closed the notification while it ran (Linux servers also close it when it expires). Its
  icon and the progress of its running ones ("45 %", or the count when no total is known); its menu: Cancel (running),
  Open and Show in the folder (done), the reason (failed), then "Clear the finished ones". A download is in one place at
  a time: each fact is said once. The end of a download of the pill is said by `ui.announce` (a click shows the file).
- **A server on this computer works the same way.** The download is then a copy. One path for both is simpler and
  testable; "Show in the folder" of a tool call already shows the original.

## The state machines

- **A download**: `Queued → Running → Done | Failed | Cancelled`. The worker writes `got`, `total` atomically and asks
  nothing of the interface; its end comes back by a post (`download_ended`), which alone changes the state to an end.
  The interface reads the atomics when it builds the pill or a notification: no work in proportion to the bytes.
- **Its notification** (`Download.note`): `Off → Asking → Shown → Gone`, or `Asking → Off` when the system refuses.
  `Off` and `Gone` are the pill's. A change while `Asking` is sent once the id came (`note_again`). A download whose
  notification is `Asking` is never freed: the answer's callback holds it. A `Shown` one that ended is freed when its
  notification is closed (`Notification_Closed`); a notification event of an id that is no download's goes on to
  what was missed (settings.odin `notify_event`).

## The program's end

`downloads_stop` asks every download's `Stop` and waits for the pool within `DOWNLOAD_STOP_BOUND`. A worker that sees the
stop aborts its writer. A worker still in a request after the bound (a server that never answers) leaves its temp to
`downloads_stop`, which removes it from the ending thread: the worker publishes the temp's name under `Download.lock`
when it opens the writer and marks it gone when it commits or aborts, under the same lock.

## Refused

- **Ranges (4 MiB requests with `If-Range`).** They were the stream while gt:http gave bodies whole. One stream makes
  one request, one connection's slow start, and a cancel at the next chunk instead of the next 4 MiB.
- **A check of the file after the stream** (a one-byte range with `If-Range`): a second request to catch a same-size
  rewrite during a transfer, which an agent rarely does to a file being downloaded. If it matters, it is one request
  after the body, before the commit.
- **The server's message of a refusal** by a second request: a second GET of a file that now exists would stream a
  whole file to read an error.
- **The pill and the notification at once.** The same progress and the same Cancel twice.
- **A Save dialog from the browser's row action.** One toolkit file dialog shows at a time: the Save dialog would close
  the browser and lose a multiple selection. The row's Download goes to Downloads; "Download…" asks.
