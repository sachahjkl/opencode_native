package ocn

// What could not be read as JSON, of the server (an event, an answer) or of what this client keeps (a queued prompt's payload): counted,
// and said in the log. A `_` that dropped the error hid a defect of either side; this shows it, without a line per event of a stream that
// went bad.

import "core:encoding/json"
import "core:log"
import "core:strings"
import "gt:ui"

UNREADABLE_EXCERPT_BYTES :: 80       // of what could not be read, in its line of the log
UNREADABLE_SAY_EVERY_MS  :: 60_000   // a kind is said again at most this often

Unreadable_Log :: struct {
	count: int,               // since the start (the status bar says it with the frame rate)
	said:  map[string]f64,    // a kind → when it was last said (keys owned)
}

unreadable_note :: proc(app: ^App, kind, text: string) {
	u := &app.cx.unreadable
	u.count += 1
	now := ui.now_ms()
	if at, known := u.said[kind]; known {
		if now - at < UNREADABLE_SAY_EVERY_MS { return }
		u.said[kind] = now
	} else {
		u.said[strings.clone(kind)] = now
	}
	log.warnf("unreadable %s (%d so far): %q", kind, u.count, text[:min(len(text), UNREADABLE_EXCERPT_BYTES)])
}

// The JSON a caller of this client wrote, read again; what does not read is counted (nil: nothing to read).
json_of_own :: proc(app: ^App, kind, text: string) -> json.Value {
	if v, ok := json_read_temp(text); ok { return v }
	unreadable_note(app, kind, text)
	return nil
}

@(private = "file")
json_read_temp :: proc(text: string) -> (json.Value, bool) {
	// (on an error the parser frees what it made with context.allocator: the frame's memory must not go to the heap's free)
	context.allocator = context.temp_allocator
	v, err := json.parse_string(text, parse_integers = true, allocator = context.temp_allocator)
	return v, err == nil
}
