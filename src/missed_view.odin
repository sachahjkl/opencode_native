// "What you missed": the bell of the title bar and the view of the log (missed.odin). The view lists the entries of this
// server by session, the newest session first, what waits before what ended in each. Only the rows in view are built: the
// rows are made again when the log, the server or the history toggle changes, never at a frame that changes none of them.
package ocn

import "core:fmt"
import "core:hash"
import "core:math"
import "gt:draw"
import "gt:ui"
import lucide "gt:lucide"
import notices "gt:notices"

MISSED_HEADER_BIT :: u64(1) << 63   // (a header's identity in the list: never an entry's id)

// The rows of the view and the bell's count, as the log is now. O(1) when nothing moved; O(entries) once after a change.
missed_rows_refresh :: proc(app: ^App) {
	m := &app.missed
	log := missed_log(app)
	if m.rows_made && m.rows_log == log.ver && m.rows_server == app.server && m.rows_history == m.history { return }
	m.rows_made, m.rows_log, m.rows_server, m.rows_history = true, log.ver, app.server, m.history
	m.rows_stamp += 1
	clear(&m.rows)
	clear(&m.ids)
	clear(&m.selectable)
	m.new_here = 0
	for e in log.entries {
		if e.state != .New { continue }
		if _, mine := missed_unscoped(app, e.key); mine { m.new_here += 1 }
	}
	for g in notices.groups(log, m.history) {
		root, mine := missed_unscoped(app, g.group)
		if !mine { continue }
		open := 0
		for e in g.entries { if e.state != .Acknowledged && !missed_is_wait(e) { open += 1 } }
		append(&m.rows, Missed_Row{root = root, group = g.group, open = open})
		append(&m.ids, hash.fnv64a(transmute([]u8)g.group) | MISSED_HEADER_BIT)
		append(&m.selectable, false)
		// what waits first: it cannot go on without the person
		for waits_pass in ([2]bool{true, false}) {
			for e in g.entries {
				if missed_is_wait(e) != waits_pass { continue }
				append(&m.rows, Missed_Row{entry = e, root = root, group = g.group})
				append(&m.ids, e.id)
				append(&m.selectable, true)
			}
		}
	}
}

// The view's rows freed (the end of the program).
missed_rows_free :: proc(app: ^App) {
	m := &app.missed
	delete(m.rows); delete(m.ids); delete(m.selectable)
	m.rows, m.ids, m.selectable = nil, nil, nil
	ui.vlist_destroy(&m.vl)
	m.vl = {}
	m.rows_made = false
}

// The bell of the title bar: what was missed and not shown yet, counted on it.
missed_bell :: proc(app: ^App, size, em: f32) {
	missed_rows_refresh(app)
	n := app.missed.new_here
	ui.a11y({role = .Button, name = "What you missed"})
	ui.next({width = ui.px(size), height = ui.px(size), fg = ui.caption_ink(hex(n > 0 ? HEX_WEAK : HEX_FAINT))})
	sig := ui.icon_button("bell", lucide.BELL)
	if app.prefs.notices_badge { ui.badge(sig.box, n) }
	if sig.clicked { command_run(app, command_find("view.notices")) }
	if ui.hovered_for(sig) { if ui.tooltip() { ui.tooltip_text("What you missed  (Ctrl+Shift+N)") } }
}

// What an entry says happened.
missed_words :: proc(e: ^notices.Entry) -> string {
	st := Sub_State(e.outcome)
	word := e.title
	switch Missed_Kind(e.kind) {
	case .End:        word = e.title
	case .Permission: word = "Permission"
	case .Question:   word = "Question"
	case .Shell:      word = st == .Failed ? "Command failed" : "Command ended"
	case .Scheduled:  word = "Scheduled run"
	case .Sub:        word = st == .Failed ? "Sub-agent failed" : st == .Cancelled ? "Sub-agent stopped" : "Sub-agent done"
	}
	if e.count > 1 { return fmt.tprintf("%s ×%d", word, e.count) }
	return word
}

@(private = "file")
Missed_Act :: enum u8 { None, Open, Acknowledge, Acknowledge_Group, Acknowledge_All }

@(private = "file")
Missed_Row_Draw :: struct { selected: bool }

missed_dialog :: proc(app: ^App, em: f32) {
	m := &app.missed
	if !app.cx.open[.Notices] { return }
	missed_rows_refresh(app)
	vl := &m.vl
	n := len(m.rows)
	act := Missed_Act.None
	act_row := -1
	if ui.modal_sized("notices", DIALOG_PREFERRED_EM[.Notices] * em, &app.cx.dialogs[.Notices], &app.cx.open[.Notices], DIALOG_MIN_EM[.Notices] * em) {
		dialog_backdrop()
		if ui.dialog_header("mi_head", "What you missed", {close = true}) {
			small := math.round(em * BUTTON_SMALL_H_EM)
			ui.a11y({role = .Button, name = "Acknowledged"})
			if ui.button_icon("###mi_hist", lucide.HISTORY, "Acknowledged", height = small, face = m.history ? .Toggled : .Raised, lit = m.history).clicked { m.history = !m.history }
			ui.spacer(ui.px(em * 0.4))
			if ui.button_icon("###mi_all", lucide.CHECK, "Acknowledge all", .Success, height = small).clicked { act = .Acknowledge_All }
		}
		// the keys: read in the dialog (its scope holds them), over every row, built or not
		if n > 0 {
			if ui.key_press(.A, {.Ctrl, .Shift}) { act = .Acknowledge_All }
			if ui.key_press(.A, {.Shift}) { act, act_row = .Acknowledge_Group, vl.sel }
			if ui.key_press(.A) { act, act_row = .Acknowledge, vl.sel }
		}
		vl.no_typeahead = true   // (letters are the view's keys)
		vl.sel = clamp(vl.sel, 0, max(n - 1, 0))
		if n > 0 && !m.selectable[vl.sel] && vl.sel + 1 < n { vl.sel += 1 }   // (a header is no row to act on: its first entry)
		ui.spacer(ui.px(em * 0.3))
		row_h := math.round(em * MISSED_ROW_H_EM)
		head_h := math.round(em * MISSED_HEAD_H_EM)
		ui.next({width = ui.fill(), height = ui.fill()})
		if rows, ok := ui.vlist("###mi_list", vl, m.ids[:], selectable = m.selectable[:], ids_version = m.rows_stamp); ok {
			if n == 0 {
				ui.next({width = ui.fill(), height = ui.px(row_h), text_align = .Center})
				if ui.tags("weak") { ui.label(m.history ? "Nothing yet###none" : "Nothing missed###none") }
			}
			if vl.activated && n > 0 { act, act_row = .Open, vl.sel }
			if vl.cancelled { app.cx.open[.Notices] = false }
			now := now_epoch_ms()
			for k in rows.first ..< rows.last {
				r := &m.rows[k]
				if r.entry == nil {
					if missed_header(app, r, k, head_h, em) { act, act_row = .Acknowledge_Group, k }
					continue
				}
				clicked, button := missed_entry_row(app, r, k, k == vl.sel, now, row_h, em)
				if button { act, act_row = r.entry.state == .Acknowledged || missed_is_wait(r.entry) ? .Open : .Acknowledge, k }
				else if clicked { act, act_row = .Open, k }
			}
		}
		if m.fresh && vl.key != 0 { ui.set_focus(vl.key); m.fresh = false }
		edge_line("###mi_foot_rule")
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###mi_foot") {
			ui.spacer(ui.px(em * 1))
			text("h", "Enter open    A acknowledge    Shift+A the session    Ctrl+Shift+A all", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}, ui.fill())
			ui.spacer(ui.px(em * 1))
		}
	}
	// (after the rows: acknowledging changes the log, and the rows hold its entries)
	missed_act(app, act, act_row)
}

// What a key, a click or a button asked, on the row `at` (-1: none).
@(private = "file")
missed_act :: proc(app: ^App, act: Missed_Act, at: int) {
	m := &app.missed
	if act == .None { return }
	if act == .Acknowledge_All { missed_acknowledge_all(app); return }
	if at < 0 || at >= len(m.rows) { return }
	r := m.rows[at]
	switch act {
	case .None, .Acknowledge_All:
	case .Open:
		if r.root != "" && r.root != app.chat.id { open_root(app, r.root) }
		app.cx.open[.Notices] = false
	case .Acknowledge:
		if r.entry != nil { missed_acknowledge(app, r.entry.key) }
	case .Acknowledge_Group:
		missed_acknowledge_group(app, r.group)
	}
}

// A session's header: its project's mark, its title, its folder, and Acknowledge for what of it is open. True: Acknowledge.
@(private = "file")
missed_header :: proc(app: ^App, r: ^Missed_Row, k: int, h, em: f32) -> (acknowledge: bool) {
	s := find_session(app, r.root)
	ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center})
	b := ui.build_box({}, ui.vlist_row_name(k))
	if ui.parent(b) {
		ui.spacer(ui.px(em * 0.8))
		if s != nil {
			session_badge(app, s, math.round(em * SESSION_BADGE_EM), em)
			ui.spacer(ui.px(em * 0.55))
		}
		title := s != nil && s.title != "" ? s.title : s != nil ? "Untitled" : r.root
		text("t", title, hex(HEX_TEXT), ui.Style_Mod{font_size = math.round(em * FS_LABEL)})
		if s != nil && s.directory != "" {
			ui.spacer(ui.px(em * 0.6))
			text("d", base_name(s.directory), hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_CAPTION)}, ui.fill())
		} else {
			ui.spacer(ui.fill())
		}
		if r.open > 0 {
			ui.a11y({role = .Button, name = "Acknowledge the session"})
			acknowledge = ui.button_icon("###ack_g", lucide.CHECK, "Acknowledge", height = math.round(em * BUTTON_SMALL_H_EM), quiet = true, face = .Ghost).clicked
		}
		ui.spacer(ui.px(em * 0.8))
	}
	return
}

// An entry: its mark, what happened, the excerpt, how long ago, and what to do (Answer for a wait, Acknowledge otherwise).
// `clicked`: the row; `button`: its button.
@(private = "file")
missed_entry_row :: proc(app: ^App, r: ^Missed_Row, k: int, selected: bool, now: f64, h, em: f32) -> (clicked, button: bool) {
	e := r.entry
	ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center})
	ui.a11y({role = .Button, name = missed_words(e), description = e.text})
	rb := ui.build_box({.Clickable}, ui.vlist_row_name(k))
	rd := ui.frame_new(Missed_Row_Draw)
	rd.selected = selected
	rb.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		if !(^Missed_Row_Draw)(user).selected { return }
		s := ui.scale()
		r := b.rect
		draw_well(dc, r, 0, hex(HEX_PAL_SELECTED))
		draw.rect(dc, {{r.min.x + 2 * s, r.min.y + 6 * s}, {r.min.x + 4 * s, r.max.y - 6 * s}}, accent(), 1 * s)
	}
	rb.custom_user = rd
	clicked = ui.signal(rb).clicked
	if ui.parent(rb) {
		ui.spacer(ui.px(em * 2.4))
		acked := e.state == .Acknowledged
		mark := math.round(em * 0.8)
		if missed_is_wait(e) {
			if acked { pip("###mk", hex(HEX_FAINT), mark) } else { session_lamp("###mk", LAMP_WAITS, em) }
		} else {
			state_mark("###mk", Sub_State(e.outcome), mark)
		}
		ui.spacer(ui.px(em * 0.5))
		ink := acked ? hex(HEX_FAINT) : e.state == .New ? hex(HEX_BRIGHT) : hex(HEX_TEXT)
		text("w", missed_words(e), ink, ui.Style_Mod{font_size = math.round(em * FS_LABEL)})
		ui.spacer(ui.px(em * 0.6))
		text("x", e.text, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_SMALL)}, ui.fill())
		ui.spacer(ui.px(em * 0.5))
		text("a", age_text(now, f64(e.at)), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
		ui.spacer(ui.px(em * 0.5))
		small := math.round(em * BUTTON_SMALL_H_EM)
		if missed_is_wait(e) && !acked {
			button = ui.button_icon("###answer", lucide.ARROW_RIGHT, "Answer", .Primary, height = small, quiet = true).clicked
		} else if !acked {
			ui.a11y({role = .Button, name = "Acknowledge"})
			button = ui.button_icon("###ack", lucide.CHECK, "", height = small, quiet = true, face = .Ghost).clicked
		}
		ui.spacer(ui.px(em * 0.8))
	}
	return
}
