// The prompts' marks on the conversation's scroll bar: a mark for each prompt of the reader's, where it stands in the
// conversation (the toolkit's scroll_marks), the thumb over them where the view is. The pointer over a mark shows the prompt's
// card (its number, when it was sent, its first lines), a click goes there at once and gives that prompt the keyboard;
// a filter keeps the prompts that say what is typed. The setting conversation.prompt_rail shows them or not.
package ocn

import "core:fmt"
import "core:math"
import "core:strings"
import "gt:ui"
import i18n "gt:i18n"

PROMPT_RAIL_MARGIN_EM :: 0.8   // above a prompt the view goes to

Prompt_Rail :: struct {
	rail:    ui.Scroll_Marks,
	made:    [3]u64,   // Chat.gen, Chat.subs_seq and the count of messages the marks were made from
	version: u64,
	focus:   string,   // the prompt the rail went to: its plate takes the keyboard when it is next built (owned)
	at:      int,      // the next prompt to place, in this build (prompt_rail_place)
}

// The marks are shown: the setting, and a session.
prompt_rail_on :: proc(app: ^App) -> bool { return app.prefs.prompt_rail && app.chat.id != "" }

// The marks on the bar of the conversation's scroll box `sb` (the last build's), given before it is built: a jump is in place
// when the messages are built.
prompt_rail :: proc(app: ^App, sb: ^ui.Box, em: f32) {
	p := &app.conversation.prompt_rail
	prompt_rail_sync(app)
	margin := math.round(em * PROMPT_RAIL_MARGIN_EM)
	// (the cards say when each prompt was sent, on the reader's clock)
	o := ui.Scroll_Marks_Options{name = i18n.tr("Prompts"), margin = margin, now_ms = now_epoch_ms(), offset_minutes = local_offset_minutes(), hours12 = !app.prefs.clock24}
	i := ui.scroll_marks("###prompt_rail", &p.rail, sb, o)
	if i < 0 { return }
	id := ui.scroll_marks_id(&p.rail, i)
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
	if p.version > 0 && now == p.made && !ui.scroll_marks_stale(&p.rail, p.version) { return }
	p.made = now
	p.version += 1
	marks := make([dynamic]ui.Scroll_Mark, 0, 64, context.temp_allocator)
	for &m in c.messages {
		if m.kind != .User { continue }
		// (its number among the prompts, as the reader counts them: the card's name)
		append(&marks, ui.Scroll_Mark{id = m.id, text = m.text, label = fmt.tprintf("#%d", len(marks) + 1), time_ms = m.created})
	}
	ui.scroll_marks_set(&p.rail, p.version, marks[:])
}

// Before the messages are built: the first prompt is placed next.
prompt_rail_begin :: proc(app: ^App) { app.conversation.prompt_rail.at = 0 }

// A prompt of the conversation starts at `top` in its content (the lazy column's `y` before its item).
prompt_rail_place :: proc(app: ^App, top: f32) {
	p := &app.conversation.prompt_rail
	ui.scroll_marks_place(&p.rail, p.at, top)
	p.at += 1
}

// The plate of prompt `m` (its box): a Tab stop while it has the keyboard, which the marks give it when they went there.
prompt_rail_focus :: proc(app: ^App, m: ^Message, plate: ^ui.Box) {
	p := &app.conversation.prompt_rail
	if p.focus != "" && p.focus == m.id {
		ui.set_focus(plate.key)
		delete(p.focus)
		p.focus = ""
	}
	if ui.focus_key() == plate.key { plate.flags += {.Focusable} }
}
