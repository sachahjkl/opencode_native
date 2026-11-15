# The server's transport

Every call to the server goes through the toolkit's `gt:http` (`src/http.odin`): the requests, the event stream
(`/api/event`) and the two WebSockets (a shell's `/api/pty/.../connect`, the browser tools' `client-mcp`). The system
does HTTP, TLS and the proxy: WinHTTP on Windows, libcurl on Linux. The toolkit's design is in its
`src/md/features/streams.md`.

## Decisions

- **No HTTP of its own.** ocn had a Rust copy (ureq, tungstenite, rustls). It was removed: the native library keeps only
  what the toolkit has no Odin equivalent for (the toolkit's Rust crates, the WebView2 on Windows).
- **The credentials are computed once.** `Http` holds the base address and the `Authorization` header (Basic, user
  `opencode`), built when a server is chosen. Threads read it and never change it.
- **A request is bounded as a whole: `REQUEST_TIMEOUT`, 3 minutes.** The old client bounded the connection (5 s), the
  wait for the answer (60 s) and the body (120 s) apart. `gt:http` has one limit; 3 minutes covers the sum. A body is
  bounded by `REQUEST_MAX_BYTES` (256 MiB: a long session's export).
- **The event stream is bounded by its silence: `STREAM_SILENCE`, 95 s.** A machine that slept leaves the socket open.
  The server's heartbeats restart the clock; several can be missed.
- **The stream is up at its first event.** The server opens every stream with `server.connected`. `stream_run` posts
  `stream_up` before it posts that event. A stream that answers 200 and ends before any event is down. `gt:http`'s
  `events` gives no "opened" signal; the protocol's first event is that signal.
- **A stop ends the stream within a second.** `Conn.stop` is the stream's `tk_http.Stop`. Before, a stop was seen only
  at the next event.
- **A socket's thread reads with short waits and sends between them (`ws_pump`).** `ws_recv` waits `TERM_READ_MS` or
  `BROWSER_READ_MS`; what the interface queued goes out after each wait. `gt:http` allows a send from any thread, but
  the interface's thread never touches a socket: a send can block.

## Refused

- **A send from the interface's thread.** A send blocks on a full or dead connection.
- **gzip.** ureq asked for gzip answers. `gt:http` sends no `Accept-Encoding`; the server's answers come plain. A remote
  server over a slow link costs more bytes; nothing else changes.
