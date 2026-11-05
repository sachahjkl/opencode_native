// The composer's history: Up and Down go through what was sent, the session's own prompts first, then those of the other
// sessions (kept in a file beside the preferences). What was being typed is kept and comes back past the newest one, or on
// Escape. Editing what is shown leaves the history: it is a new prompt.
package occ

import "core:encoding/json"
import "core:os"
import "core:strings"
import "gt:ui"

History :: struct {
	sent:  [dynamic]string,   // what was sent, oldest first (owned)
	view:  [dynamic]string,   // while going through it: newest first (owned)
	at:    int,               // the one shown, in `view` (-1: not going through it)
	draft: string,            // what was being typed (owned)
	file:  string,            // where `sent` is kept ("": nowhere)
}

// `file` "": nothing read or saved (a test).
history_init :: proc(app: ^App, file: string) {
	h := &app.history
	h.at = -1
	h.file = strings.clone(file)
	if file == "" { return }
	data, err := os.read_entire_file(file, context.temp_allocator)
	if err != nil { return }
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		v, perr := json.parse_string(line, allocator = context.temp_allocator)
		if perr != nil { continue }   // (a line cut short: the others stand)
		if s, ok := v.(json.String); ok && s != "" { append(&h.sent, strings.clone(string(s))) }
	}
}

// A prompt sent: the newest of the history (the same one twice in a row counts once).
history_add :: proc(app: ^App, text: string) {
	h := &app.history
	if len(h.sent) > 0 && h.sent[len(h.sent) - 1] == text { return }
	append(&h.sent, strings.clone(text))
	if len(h.sent) > HISTORY_MAX {
		delete(h.sent[0])
		ordered_remove(&h.sent, 0)
	}
	history_save(h)
}

@(private = "file")
history_save :: proc(h: ^History) {
	if h.file == "" { return }
	b := strings.builder_make(context.temp_allocator)
	for s in h.sent {
		strings.write_string(&b, jquote(s))
		strings.write_byte(&b, '\n')
	}
	tmp := strings.concatenate({h.file, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, transmute([]u8)strings.to_string(b)) != nil { return }
	_ = os.rename(tmp, h.file)
}

@(private = "file")
history_view :: proc(app: ^App) {
	h := &app.history
	for s in h.view { delete(s) }
	clear(&h.view)
	seen := make(map[string]bool, allocator = context.temp_allocator)
	add :: proc(h: ^History, seen: ^map[string]bool, s: string) {
		t := strings.trim_space(s)
		if t == "" || t in seen { return }
		seen[t] = true
		append(&h.view, strings.clone(t))
	}
	#reverse for &m in app.chat.messages { if m.kind == .User { add(h, &seen, m.text) } }
	#reverse for s in h.sent { add(h, &seen, s) }
}

history_browsing :: proc(app: ^App) -> bool { return app.history.at >= 0 }

// One step: 1 to an older prompt, -1 to a newer one, past the newest one back to what was being typed.
history_step :: proc(app: ^App, dir: int) {
	h := &app.history
	if h.at < 0 {
		if dir < 0 { return }
		history_view(app)
		if len(h.view) == 0 { return }
		delete(h.draft)
		h.draft = strings.clone(ui.area_string(&app.composer))
	}
	next := h.at + dir
	if next >= len(h.view) { return }   // (the oldest one stays)
	if next < 0 { history_leave(app, true); return }
	h.at = next
	ui.area_set(&app.composer, h.view[next])
}

// Out of the history; `restore`: what was being typed comes back.
history_leave :: proc(app: ^App, restore: bool) {
	h := &app.history
	if h.at < 0 { return }
	h.at = -1
	if restore { ui.area_set(&app.composer, h.draft) }
}

// The text shown is no longer the prompt it came from: it is the user's now.
history_track :: proc(app: ^App) {
	h := &app.history
	if h.at >= 0 && ui.area_string(&app.composer) != h.view[h.at] { h.at = -1 }
}
