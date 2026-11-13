// The rail beside the conversation: a dot for each prompt of the reader's, where it stands in the conversation (the toolkit's
// mark_rail), the part in view a band over it. The pointer over a dot shows the prompt's first line, a click goes there at once
// and gives that prompt the keyboard; a filter keeps the prompts that say what is typed. The setting conversation.prompt_rail
// shows it or not.
package ocn

import "core:math"
import "core:strings"
import "gt:ui"
import i18n "gt:i18n"

PROMPT_RAIL_W_EM      :: 1.5
PROMPT_RAIL_MARGIN_EM :: 0.8   // above a prompt the view goes to

Prompt_Rail :: struct {
	rail:    ui.Mark_Rail,
	made:    [3]u64,   // Chat.gen, Chat.subs_seq and the count of messages the marks were made from
	version: u64,
	focus:   string,   // the prompt the rail went to: its plate takes the keyboard when it is next built (owned)
	at:      int,      // the next prompt to place, in this build (prompt_rail_place)
}

// The rail's width in this build: 0 when it is not shown (the setting, or no session).
prompt_rail_w :: proc(app: ^App, em: f32) -> f32 {
	if !app.prefs.prompt_rail || app.chat.id == "" { return 0 }
	return math.round(em * PROMPT_RAIL_W_EM)
}

// The rail at the right of the row the conversation's scroll box `sb` is in (the last build's), floating, built before it:
// a jump is in place when the messages are built.
prompt_rail :: proc(app: ^App, sb: ^ui.Box, w, em: f32) {
	p := &app.conversation.prompt_rail
	prompt_rail_sync(app)
	row := ui.parent_box()
	ui.next({fixed_x = row.rect.max.x - row.rect.min.x - w, fixed_y = 0, width = ui.px(w), height = ui.px(sb.rect.max.y - sb.rect.min.y)})
	margin := math.round(em * PROMPT_RAIL_MARGIN_EM)
	i := ui.mark_rail("###prompt_rail", &p.rail, sb, {name = i18n.tr("Prompts"), margin = margin})
	if i < 0 { return }
	id := ui.mark_rail_id(&p.rail, i)
	// (the view goes there now; the column keeps it on the prompt while the heights around it settle)
	chat_scroll_event(app, Scroll_Restore{id, -margin})
	delete(p.focus)
	p.focus = strings.clone(id)
}

// The marks are those of the prompts as they are: made again when the messages come or go, not when one grows.
@(private = "file")
prompt_rail_sync :: proc(app: ^App) {
	p := &app.conversation.prompt_rail
	c := &app.chat
	now := [3]u64{c.gen, c.subs_seq, u64(len(c.messages))}
	if p.version > 0 && now == p.made && !ui.mark_rail_stale(&p.rail, p.version) { return }
	p.made = now
	p.version += 1
	marks := make([dynamic]ui.Rail_Mark, 0, 64, context.temp_allocator)
	for &m in c.messages {
		if m.kind == .User { append(&marks, ui.Rail_Mark{id = m.id, text = m.text}) }
	}
	ui.mark_rail_set(&p.rail, p.version, marks[:])
}

// Before the messages are built: the first prompt is placed next.
prompt_rail_begin :: proc(app: ^App) { app.conversation.prompt_rail.at = 0 }

// A prompt of the conversation starts at `top` in its content (the lazy column's `y` before its item).
prompt_rail_place :: proc(app: ^App, top: f32) {
	p := &app.conversation.prompt_rail
	ui.mark_rail_place(&p.rail, p.at, top)
	p.at += 1
}

// The plate of prompt `m` (its box): a Tab stop while it has the keyboard, which the rail gives it when it went there.
prompt_rail_focus :: proc(app: ^App, m: ^Message, plate: ^ui.Box) {
	p := &app.conversation.prompt_rail
	if p.focus != "" && p.focus == m.id {
		ui.set_focus(plate.key)
		delete(p.focus)
		p.focus = ""
	}
	if ui.focus_key() == plate.key { plate.flags += {.Focusable} }
}
