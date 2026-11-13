// The composer's history: Up and Down go through the prompts of the session shown, newest first. Another session's prompts
// are not part of it. What was being typed is kept and comes back past the newest one, or on Escape. Editing what is shown
// leaves the history: it is a new prompt.
package ocn

import "core:strings"
import "gt:ui"

History :: struct {
	view:  [dynamic]string,   // while going through it: the session's prompts, newest first (owned)
	at:    int,               // the one shown is view[at - 1] (0: not going through it, the zero value)
	draft: string,            // what was being typed (owned)
}

@(private = "file")
history_view :: proc(app: ^App) {
	h := &app.composer.history
	for s in h.view { delete(s) }
	clear(&h.view)
	seen := make(map[string]bool, allocator = context.temp_allocator)
	#reverse for &m in app.chat.messages {
		if m.kind != .User { continue }
		t := strings.trim_space(m.text)
		if t == "" || t in seen { continue }
		seen[t] = true
		append(&h.view, strings.clone(t))
	}
}

history_browsing :: proc(app: ^App) -> bool { return app.composer.history.at > 0 }

// One step: 1 to an older prompt, -1 to a newer one, past the newest one back to what was being typed.
history_step :: proc(app: ^App, dir: int) {
	h := &app.composer.history
	if h.at == 0 {
		if dir < 0 { return }
		history_view(app)
		if len(h.view) == 0 { return }
		delete(h.draft)
		h.draft = strings.clone(ui.text_edit_string(&app.composer.area))
	}
	next := h.at + dir
	if next > len(h.view) { return }   // (the oldest one stays)
	if next == 0 { history_leave(app, true); return }
	h.at = next
	ui.text_edit_set(&app.composer.area, h.view[next - 1])
}

// Out of the history; `restore`: what was being typed comes back.
history_leave :: proc(app: ^App, restore: bool) {
	h := &app.composer.history
	if h.at == 0 { return }
	h.at = 0
	if restore { ui.text_edit_set(&app.composer.area, h.draft) }
}

// The text shown is no longer the prompt it came from: it is the user's now.
history_track :: proc(app: ^App) {
	h := &app.composer.history
	if h.at > 0 && ui.text_edit_string(&app.composer.area) != h.view[h.at - 1] { h.at = 0 }
}
