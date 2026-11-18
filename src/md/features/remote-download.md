# Download a file of the server

A person downloads a file of the server's computer to this computer. The server can be another computer: the files the
agents read and write are there, not here.

## Where a person asks for it

- **A tool call's file** (read, edit, write: `Part.file_path`): "Download…" in its context menu.
- **A path selected in a message**: "Download the selected path…" in the message's context menu, when the selection is
  one line that reads as a path. A relative path is taken from the session's folder.
- **The palette**: "Download a file…" (`session.download`) opens the file browser on the server's files in a pick mode
  (act: Download). The person chooses one file.
- **Folders: not now.** The server has no archive of a folder. If it offers one (a zip), a folder can come the same way.

## The transfer

- **The server's `GET /api/fs/read/<path>?location[directory]=<folder>` with `Range`.** opencode 2.3.0 answers 206 with
  `Content-Range: bytes a-b/total`, an `ETag`, and 416 `bytes */0` for an empty file. The path is taken from the
  location: an absolute path in the address is read as a relative one. The location is the session's folder when the
  file is in it (a folder the server has loaded already), else the file's own folder.
- **Chunks of `DOWNLOAD_CHUNK_BYTES` (4 MiB), one request each, on a worker.** gt:http gives a body whole, in memory: a
  range bounds that memory to one chunk, gives the progress after each chunk, and a cancel within one chunk. A file of
  any size never sits whole in memory.
- **`If-Range` with the first answer's ETag.** A file changed during the download answers 200 whole: the download fails
  with "the file changed during the download", not a file made of two versions.
- **A server that ignores `Range` answers 200 with the whole file.** It is taken whole, up to `REQUEST_MAX_BYTES`: the
  same bound as every other answer.
- **No compression.** A range of a compressed body is not a range of the file, and `Content-Length` goes when gt:http
  decodes.
- **The connection's credentials.** The download goes by the connection that was current when it was asked
  (`Transport.range`, `conn_hold`), with its `Authorization`. A switch to another server does not stop it: its file is
  of the server it was asked of.
- **A temp file beside the target, renamed at the end.** `<target>.ocn-<n>.part` in the same folder: the rename is atomic
  on one file system. The target is never half written. Each chunk opens the temp to append and closes it, so that the
  program's end can remove a temp that a worker still holds on Windows.
- **The workers are the downloads' own pool (`DOWNLOAD_WORKERS`, 3).** A long transfer does not take a worker of the
  connection's requests. A fourth download waits in the queue.

## What the person sees

- **The status bar's pill while a download exists**: its icon and the progress of the running ones ("45 %", or the count
  when no total is known). A click opens its menu: for each download, Cancel (running), Open and Show in the folder
  (done), the reason (failed); then "Clear the finished ones".
- **The outcome is said once** through `ui.announce`: "Downloaded logo.png" with the target (a click shows it in its
  folder), or "logo.png was not downloaded" with the reason (the server's message, the status, the disk's error). A
  cancel says nothing: the person did it.
- **The save dialog is the toolkit's** (`ui.file_dialog(.Save)`, the computer's files), with the file's name and the
  overwrite question, in the Downloads folder (`platform.known_folder_path(.Downloads)`, resolved on a chore).
- **A server on this computer works the same way.** The download is then a copy. One path for both is simpler and
  testable; "Show in the folder" of a tool call already shows the original.

## The state machine of a download

`Queued → Running → Done | Failed | Cancelled`. The worker writes `got`, `total` and `stop` atomically; the end comes
back by a post (`download_ended`), which alone changes the state to an end. The interface reads the atomics when it
builds the pill: no work in proportion to the bytes.

## The program's end

`downloads_stop` asks every download to stop and waits for the pool within `DOWNLOAD_STOP_BOUND`. A worker that sees the
stop removes its temp. A worker still in a request after the bound leaves its temp to `downloads_stop`, which removes it
from the ending thread: the window is gone then, nothing waits for a frame (as `stores_close`).

## Refused

- **A streamed body through gt:http.** It has none: `request` gives the body whole, `events` parses SSE. A streamed
  download is a capability of gt:http (a body sink with a stop); until then, ranges are the stream.
- **A toast with progress and buttons.** The toolkit's toasts are a text and one click. The pill is the program's own
  place for what lasts.
- **"Download…" in the file browser's own menu.** The toolkit's browser takes no action of the program on an entry. The
  palette's pick mode stands for it.
