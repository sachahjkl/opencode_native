# The server's pictures in the file browser's cards

The toolkit's file browser shows cards with a thumbnail of each file when its source answers
`File_Source.thumbnail` (gui_toolkit `src/md/features/thumbnails.md`). With a server on another computer, ocn's source
(`folders.odin`, `Server_Files`) is the browser's source; `server_thumbs.odin` gives it thumbnails.

## Decisions

- **Only what `gt:image` decodes, only in the session's folder.** `ui.file_thumbnail_decodes` says it by the name's
  extension (PNG, JPEG, BMP, WebP, GIF): any other file is answered failed at once, without a request, and its card
  shows its kind's icon. The source has the call only with a location, as the preview and the search: the server reads a
  file only inside one of its locations, and loads and keeps one for every folder it is asked about. A picture outside
  the location is answered failed at once.
- **The bytes by the download's transport**: one `GET /api/fs/read/<path>?location[directory]=<folder>` through
  `Transport.receive`, with the connection's credentials, held (`conn_hold`) until the answer. The server has no
  thumbnails of its own, so the whole file comes and is reduced here. The connection's workers are not used: a large
  picture would hold one of the requests' four.
- **A pool of its own, `SERVER_THUMB_WORKERS` (2) threads.** At most two pictures come at once, whatever asks: the
  toolkit's cache asks at most `Thumb_Options.asks` (2) at a time, and the pool keeps the bound if that changes. A
  third waits in the pool's queue.
- **`SERVER_THUMB_MAX_BYTES` (20 MiB) at most.** The server's listing says no size, so the bound is checked as the bytes
  come: a `Content-Length` over it, or a body that passes it, stops the request and answers failed. The bytes are kept
  in memory until the decode: at most two times the bound at once.
- **The decode and the reduction on the worker.** `gt:image` decodes; `image.resize` (box filter, as the local source)
  brings the longer side to the size asked, the ratio kept; a smaller picture is sent as it is. The answer is posted to
  the interface's thread, which calls `file_reply_thumbnail` or `file_reply_failed`.
- **Every ask is answered once**, a failure included: an ask without an answer holds one of the browser's slots. The
  answer is the job's post (`server_thumb_done`), and only it. A job the pool refuses (the program ends) is answered
  failed at once.

## The cache

- **The toolkit's thumbnail cache is the cache.** It keeps the pixels by the source, the path, the size and the date,
  with a count and a byte budget (least used first), and it outlives the dialog: a second view of the same folder, or the
  next dialog, shows them without a request. A second cache here was refused: it holds the same pixels twice, and the
  source is asked again only after the toolkit dropped an entry over its budget.
- **One `user`, a generation per connection.** The toolkit keys a thumbnail by `File_Source.user`,
  `File_Source.generation` and the file. `user` is the App, for the program's run; `Server_Files.generation` is the
  generation, and the source takes it each time it is built. It goes up at a server switch (`server_files_forget`) and
  when the stream comes back after a loss (`server_files_renew` from `stream_up`): a path of another server, or of the
  same one after a gap, never shows a picture kept before. The browser reads it when a dialog opens; the old entries are
  no longer asked, and the cache's budget drops them.
- **The price: a server come back fetches its pictures again.** A key per server address (one owner each, kept for the
  run) let a server come back find its thumbnails; it was refused, since they could be stale and the owners were never
  freed. A switch back and forth fetches the folder's pictures once more.
- **What the cache cannot see.** The listing gives no size and no date: a picture changed on the server keeps its old
  thumbnail until the toolkit drops it, a reconnection, or a server switch. F5 in the browser lists the folder again
  but keeps the thumbnails: it is the toolkit's act, ocn is not told of it, and the generation is read only when a
  dialog opens.

## The state machine of an ask

`Asked` (the interface: `server_thumbnail`) → `Fetching` (a worker) → `Decoded` | `Failed` → `Answered` (the
interface: `server_thumb_done`). A server switch asks each job's `Stop`: the job ends at the next chunk, or within the
transport's silence bound, and is still answered (failed) by its post. The program's end asks every stop and waits for
the pool within `SERVER_THUMB_STOP_BOUND`.

## Refused

- **The server's own thumbnails.** It has none: a route that reduces a picture where it is would send a few kilobytes
  instead of the whole file. If opencode adds one, the source asks it and the worker keeps only the decode.
- **A fetch or a decode on the interface's thread**, and a texture made on a worker: the toolkit makes the texture at
  the first draw.
