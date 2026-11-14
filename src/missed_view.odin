// "What you missed": the bell of the title bar and the view of the log (missed.odin). The view shows the entries of this
// server by session, the newest session first, what waits before what ended in each, in one of two ways (notices.view):
// one card at a time, its whole report (missed_report.odin), or a list whose rows unfold in place. Only the rows in view
// are built: the rows are made again when the log, the server or the history toggle changes, never at a frame that
// changes none of them.
package ocn

import "core:fmt"
import "core:hash"
import "core:math"
import "core:strings"
import "gt:draw"
import "gt:markdown"
import "gt:ui"
import lucide "gt:lucide"
import notices "gt:notices"
import i18n "gt:i18n"

MISSED_HEADER_BIT :: u64(1) << 63   // (a header's identity in the list: never an entry's id)
MISSED_OPEN_BIT   :: u64(1) << 62   // (an entry unfolded: another height, another identity)
MISSED_FILES_MAX  :: 60             // files a card lists; the rest is counted
MISSED_FILES_BRIEF :: 4             // ... a row unfolded
MISSED_TAIL_LINES :: 12             // of a command's output, in its card

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
	clear(&m.cards_rows)
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
				append(&m.cards_rows, len(m.rows))
				append(&m.rows, Missed_Row{entry = e, root = root, group = g.group})
				append(&m.ids, e.id | (m.unfolded[e.id] ? MISSED_OPEN_BIT : 0))
				append(&m.selectable, true)
			}
		}
	}
	// (what is unfolded and no longer listed is forgotten; the reports no entry refers to go)
	if len(m.unfolded) > 0 {
		listed := make(map[u64]bool, len(m.rows), context.temp_allocator)
		for r in m.rows { if r.entry != nil { listed[r.entry.id] = true } }
		gone := make([dynamic]u64, context.temp_allocator)
		for id in m.unfolded { if id not_in listed { append(&gone, id) } }
		for id in gone { delete_key(&m.unfolded, id) }
	}
	missed_reports_sweep(app)
}

// The view's rows freed (the end of the program).
missed_rows_free :: proc(app: ^App) {
	m := &app.missed
	delete(m.rows); delete(m.ids); delete(m.selectable); delete(m.cards_rows); delete(m.unfolded)
	m.rows, m.ids, m.selectable, m.cards_rows, m.unfolded = nil, nil, nil, nil, nil
	ui.vlist_destroy(&m.vl)
	m.vl = {}
	m.rows_made = false
}

// The bell of the title bar: what was missed and not shown yet, counted on it.
missed_bell :: proc(app: ^App, size, em: f32) {
	missed_rows_refresh(app)
	n := app.missed.new_here
	ui.a11y({role = .Button, name = i18n.tr("What you missed")})
	ui.next({width = ui.px(size), height = ui.px(size), fg = ui.caption_ink(hex(n > 0 ? HEX_WEAK : HEX_FAINT))})
	sig := ui.button("bell", icon = lucide.BELL)
	if app.prefs.notices_badge { ui.badge(sig.box, n) }
	if sig.clicked { command_run(app, command_find("view.notices")) }
	if ui.hovered_for(sig) { if ui.tooltip() { ui.tooltip_text(i18n.tr("What you missed  (Ctrl+Shift+N)")) } }
}

// What an entry says happened.
missed_words :: proc(e: ^notices.Entry) -> string {
	st := Sub_State(e.outcome)
	word := i18n.tr(e.title)   // (kept in English in the log: said in the language of the day)
	switch Missed_Kind(e.kind) {
	case .End:        word = i18n.tr(e.title)
	case .Permission: word = i18n.tr("Permission")
	case .Question:   word = i18n.tr("Question")
	case .Shell:      word = st == .Failed ? i18n.tr("Command failed") : i18n.tr("Command ended")
	case .Scheduled:  word = i18n.tr("Scheduled run")
	case .Sub:        word = st == .Failed ? i18n.tr("Sub-agent failed") : st == .Cancelled ? i18n.tr("Sub-agent stopped") : i18n.tr("Sub-agent done")
	}
	if e.count > 1 { return fmt.tprintf("%s ×%d", word, e.count) }
	return word
}

@(private = "file")
Missed_Act :: enum u8 {
	None, Open, Acknowledge, Acknowledge_Group, Acknowledge_All,
	Fold_Toggle,   // a row of the list unfolds, or folds
	Retry,         // the report of the row is asked again
	Settle,        // the middle act of the card: Acknowledge, or Answer for a wait
	Cards, List,   // the view changes
}

@(private = "file")
Missed_Row_Draw :: struct { selected: bool }

missed_dialog :: proc(app: ^App, em: f32) {
	m := &app.missed
	if !app.cx.open[.Notices] { return }
	missed_rows_refresh(app)
	cards := app.prefs.notices_cards
	act := Missed_Act.None
	act_row := -1
	if ui.modal("notices", &app.cx.open[.Notices], dialog_options(app, .Notices)) {
		dialog_backdrop()
		if ui.dialog_header("mi_head", i18n.tr("What you missed"), {close = true}) {
			small := math.round(em * BUTTON_SMALL_H_EM)
			modes := [2]string{i18n.tr("Cards"), i18n.tr("List")}
			mode := cards ? 0 : 1
			ui.next({height = ui.px(small)})
			if ui.segmented("###mi_mode", modes[:], &mode) { act = mode == 0 ? .Cards : .List }
			ui.spacer(ui.px(em * 0.6))
			ui.a11y({role = .Button, name = i18n.tr("Acknowledged")})
			if ui.button("mi_hist", i18n.tr("Acknowledged"), lucide.HISTORY, {face = m.history ? .Toggled : .Raised, height = small, lit = m.history}).clicked { m.history = !m.history }
			ui.spacer(ui.px(em * 0.4))
			if ui.button("mi_all", i18n.tr("Acknowledge all"), lucide.CHECK, {intent = .Success, height = small}).clicked { act = .Acknowledge_All }
		}
		ui.spacer(ui.px(em * 0.3))
		body: Missed_Act
		at: int
		if cards { body, at = missed_cards(app, em) } else { body, at = missed_list(app, em) }
		if act == .None { act, act_row = body, at }   // (the header's buttons first)
	}
	// (after the rows: acknowledging changes the log, and the rows hold its entries)
	missed_act(app, act, act_row)
}

// The list: a row per entry under its session's header; a row unfolds in place.
@(private = "file")
missed_list :: proc(app: ^App, em: f32) -> (act: Missed_Act, act_row: int) {
	m := &app.missed
	vl := &m.vl
	n := len(m.rows)
	act_row = -1
	vl.no_typeahead = true   // (letters are the view's keys)
	vl.sel = clamp(vl.sel, 0, max(n - 1, 0))
	if n > 0 && !m.selectable[vl.sel] && vl.sel + 1 < n { vl.sel += 1 }   // (a header is no row to act on: its first entry)
	// the keys: read in the dialog (its scope holds them), over every row, built or not
	if n > 0 {
		if ui.key_press(.A, {.Ctrl, .Shift}) { act = .Acknowledge_All }
		if ui.key_press(.A, {.Shift}) { act, act_row = .Acknowledge_Group, vl.sel }
		if ui.key_press(.A) { act, act_row = .Acknowledge, vl.sel }
		// (before the list: it takes the rows' identities of this frame)
		if ui.key_press(.Right) { missed_fold(app, vl.sel, true) }
		if ui.key_press(.Left) { missed_fold(app, vl.sel, false) }
		if ui.key_press(.Space) { missed_fold(app, vl.sel, !missed_row_unfolded(app, vl.sel)) }
	}
	row_h := math.round(em * MISSED_ROW_H_EM)
	head_h := math.round(em * MISSED_HEAD_H_EM)
	ui.next({width = ui.fill(), height = ui.fill()})
	if rows, ok := ui.vlist("###mi_list", vl, m.ids[:], selectable = m.selectable[:], ids_version = m.rows_stamp); ok {
		if n == 0 { missed_none(app, row_h) }
		if vl.activated && n > 0 { act, act_row = .Open, vl.sel }
		if vl.cancelled { app.cx.open[.Notices] = false }
		now := now_epoch_ms()
		for k in rows.first ..< rows.last {
			r := &m.rows[k]
			if r.entry == nil {
				if missed_header(app, r, k, head_h, em) { act, act_row = .Acknowledge_Group, k }
				continue
			}
			clicked, button, chevron, retry := missed_entry_row(app, r, k, k == vl.sel, now, row_h, em)
			if chevron { act, act_row = .Fold_Toggle, k }
			else if retry { act, act_row = .Retry, k }
			else if button { act, act_row = r.entry.state == .Acknowledged || missed_is_wait(r.entry) ? .Open : .Acknowledge, k }
			else if clicked { act, act_row = .Open, k }
			// (built and unfolded: what it shows is read if it is not)
			if m.unfolded[r.entry.id] { missed_report_want(app, missed_report_session(app, r.entry)) }
		}
	}
	if m.fresh && vl.key != 0 { ui.set_focus(vl.key); m.fresh = false }
	missed_foot(app, i18n.tr("Enter open    Space unfold    A acknowledge    Shift+A the session    Ctrl+Shift+A all"), em)
	return
}

// The cards: the entries of the list in its order, one at a time, each with its whole report.
@(private = "file")
missed_cards :: proc(app: ^App, em: f32) -> (act: Missed_Act, act_row: int) {
	m := &app.missed
	st := &m.cards
	count := len(m.cards_rows)
	act_row = -1
	st.at = clamp(st.at, 0, max(count - 1, 0))
	opts: ui.Card_Stack_Options
	if count > 0 {
		k := m.cards_rows[st.at]
		if ui.key_press(.A, {.Ctrl, .Shift}) { act = .Acknowledge_All }
		if ui.key_press(.A, {.Shift}) { act, act_row = .Acknowledge_Group, k }
		if ui.key_press(.Return) { act, act_row = .Open, k }
		// (a wait is acknowledged by its answer alone: its act is to go and answer)
		if e := m.rows[k].entry; missed_is_wait(e) && e.state != .Acknowledged {
			opts = {settle = i18n.tr("Answer"), settle_icon = lucide.ARROW_RIGHT, settle_intent = ui.Intent.Primary}
		}
	}
	m.fresh = false
	now := now_epoch_ms()
	{
		shown := ui.card_stack("###mi_cards", st, count, opts)
		if shown {
			k := m.cards_rows[st.at]
			if missed_card(app, &m.rows[k], now, em) { act, act_row = .Retry, k }
		} else {
			missed_none(app, math.round(em * MISSED_ROW_H_EM))
		}
	}
	if count > 0 {
		k := m.cards_rows[st.at]
		if st.act == .Settle && act == .None { act, act_row = .Settle, k }
		missed_report_want(app, missed_report_session(app, m.rows[k].entry))   // (the card shown: its report, if none was read)
	}
	missed_foot(app, i18n.tr("Enter open    ← → move    A acknowledge    Shift+A the session    Ctrl+Shift+A all"), em)
	return
}

@(private = "file")
missed_none :: proc(app: ^App, h: f32) {
	ui.next({width = ui.fill(), height = ui.px(h), text_align = .Center})
	if ui.tags("weak") { ui.label(fmt.tprintf("%s###none", app.missed.history ? i18n.tr("Nothing yet") : i18n.tr("Nothing missed"))) }
}

@(private = "file")
missed_foot :: proc(app: ^App, keys: string, em: f32) {
	edge_line("###mi_foot_rule")
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###mi_foot") {
		ui.spacer(ui.px(em * 1))
		text("h", keys, hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}, ui.fill())
		ui.spacer(ui.px(em * 1))
	}
}

// What a key, a click or a button asked, on the row `at` (-1: none).
@(private = "file")
missed_act :: proc(app: ^App, act: Missed_Act, at: int) {
	m := &app.missed
	switch act {
	case .None:
		return
	case .Acknowledge_All:
		missed_acknowledge_all(app)
		return
	case .Cards, .List:
		pref_set(app, "notices.view", act == .Cards ? "cards" : "list")
		m.fresh = act == .List   // (the list takes the keyboard)
		return
	case .Open, .Acknowledge, .Acknowledge_Group, .Fold_Toggle, .Retry, .Settle:
	}
	if at < 0 || at >= len(m.rows) { return }
	r := m.rows[at]
	#partial switch act {
	case .Open:
		missed_open_row(app, &r)
	case .Acknowledge:
		if r.entry != nil { missed_acknowledge(app, r.entry.key) }
	case .Acknowledge_Group:
		missed_acknowledge_group(app, r.group)
	case .Fold_Toggle:
		missed_fold(app, at, !missed_row_unfolded(app, at))
	case .Retry:
		if r.entry != nil { missed_report_ask(app, missed_report_session(app, r.entry)) }
	case .Settle:
		e := r.entry
		if e == nil { return }
		if missed_is_wait(e) && e.state != .Acknowledged { missed_open_row(app, &r); return }
		// (acknowledged, it leaves the open entries: the next takes its place; one that stays in the history is passed)
		if !missed_acknowledge(app, e.key) || m.history { m.cards.at += 1 }
	}
}

@(private = "file")
missed_open_row :: proc(app: ^App, r: ^Missed_Row) {
	if r.root != "" && r.root != app.chat.id { open_root(app, r.root) }
	app.cx.open[.Notices] = false
}

@(private = "file")
missed_row_unfolded :: proc(app: ^App, k: int) -> bool {
	m := &app.missed
	if k < 0 || k >= len(m.rows) || m.rows[k].entry == nil { return false }
	return m.unfolded[m.rows[k].entry.id]
}

// Row `k` of the list unfolds (`open`) or folds: its identity says it, the list measures it again.
@(private = "file")
missed_fold :: proc(app: ^App, k: int, open: bool) {
	m := &app.missed
	if k < 0 || k >= len(m.rows) || m.rows[k].entry == nil || missed_row_unfolded(app, k) == open { return }
	id := m.rows[k].entry.id
	if open { m.unfolded[id] = true } else { delete_key(&m.unfolded, id) }
	m.ids[k] = id | (open ? MISSED_OPEN_BIT : 0)
	m.rows_stamp += 1
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
		text("t", missed_title(s, r.root), hex(HEX_TEXT), ui.Style_Mod{font_size = math.round(em * FS_LABEL)})
		if s != nil && s.directory != "" {
			ui.spacer(ui.px(em * 0.6))
			text("d", base_name(s.directory), hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_CAPTION)}, ui.fill())
		} else {
			ui.spacer(ui.fill())
		}
		if r.open > 0 {
			ui.a11y({role = .Button, name = i18n.tr("Acknowledge the session")})
			acknowledge = ui.button("ack_g", i18n.tr("Acknowledge"), lucide.CHECK, {face = .Ghost, height = math.round(em * BUTTON_SMALL_H_EM), quiet = true}).clicked
		}
		ui.spacer(ui.px(em * 0.8))
	}
	return
}

@(private = "file")
missed_title :: proc(s: ^Session_Info, root: string) -> string {
	if s == nil { return root }
	return s.title != "" ? s.title : i18n.tr("Untitled")
}

// An entry's mark: the lamp of a wait, else the state its end left.
@(private = "file")
missed_mark :: proc(e: ^notices.Entry, em: f32) {
	mark := math.round(em * 0.8)
	if missed_is_wait(e) {
		if e.state == .Acknowledged { pip("###mk", hex(HEX_FAINT), mark) } else { session_lamp("###mk", LAMP_WAITS, em) }
	} else {
		state_mark("###mk", Sub_State(e.outcome), mark)
	}
}

// An entry: a chevron that unfolds it, its mark, what happened, the excerpt, how long ago, and what to do (Answer for a wait,
// Acknowledge otherwise); unfolded, what it is about under it. `clicked`: the row; `button`: its button; `retry`: Try again.
@(private = "file")
missed_entry_row :: proc(app: ^App, r: ^Missed_Row, k: int, selected: bool, now: f64, h, em: f32) -> (clicked, button, chevron, retry: bool) {
	e := r.entry
	open := app.missed.unfolded[e.id]
	ui.next({width = ui.fill(), height = open ? ui.children_sum() : ui.px(h), axis = .Y})
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
		small := math.round(em * BUTTON_SMALL_H_EM)
		acked := e.state == .Acknowledged
		ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###line") {
			ui.spacer(ui.px(em * 0.6))
			ui.a11y({role = .Button, name = open ? i18n.tr("Fold") : i18n.tr("Unfold")})
			chevron = ui.button("chev", icon = open ? lucide.CHEVRON_DOWN : lucide.CHEVRON_RIGHT, o = {face = .Ghost, height = small, quiet = true}).clicked
			ui.spacer(ui.px(em * 0.2))
			missed_mark(e, em)
			ui.spacer(ui.px(em * 0.5))
			ink := acked ? hex(HEX_FAINT) : e.state == .New ? hex(HEX_BRIGHT) : hex(HEX_TEXT)
			text("w", missed_words(e), ink, ui.Style_Mod{font_size = math.round(em * FS_LABEL)})
			ui.spacer(ui.px(em * 0.6))
			text("x", e.text, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_SMALL)}, ui.fill())
			ui.spacer(ui.px(em * 0.5))
			text("a", age_text(now, f64(e.at)), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
			ui.spacer(ui.px(em * 0.5))
			if missed_is_wait(e) && !acked {
				button = ui.button("answer", i18n.tr("Answer"), lucide.ARROW_RIGHT, {intent = .Primary, height = small, quiet = true}).clicked
			} else if !acked {
				ui.a11y({role = .Button, name = i18n.tr("Acknowledge")})
				button = ui.button("ack", icon = lucide.CHECK, o = {face = .Ghost, height = small, quiet = true}).clicked
			}
			ui.spacer(ui.px(em * 0.8))
		}
		if open {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(id = "###more") {
				ui.spacer(ui.px(em * 3.4))
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
				if ui.column(id = "###brief") { retry = missed_brief(app, e, em) }
				ui.spacer(ui.px(em * 1.2))
			}
			ui.spacer(ui.px(em * 0.7))
		}
	}
	return
}

// What a row unfolded shows, to be read at a glance: the request, the first lines of the answer, the files.
@(private = "file")
missed_brief :: proc(app: ^App, e: ^notices.Entry, em: f32) -> (retry: bool) {
	switch Missed_Kind(e.kind) {
	case .Permission, .Question:
		missed_para("as", e.text, hex(HEX_TEXT), em)
	case .Shell:
		missed_para("cm", fmt.tprintf("$ %s", e.text), hex(HEX_TEXT_SOFT), em, mono = true)
		missed_shell_exit(app, e, em)
	case .End, .Sub, .Scheduled:
		rep := missed_report_find(app, missed_report_session(app, e))
		if rep == nil || rep.state == .Unread || rep.state == .Reading { missed_faint("rd", i18n.tr("Reading…"), em); return }
		if rep.state == .Failed { return missed_failed(em) }
		if rep.request_head != "" {
			section_label("rq", i18n.tr("REQUEST"), em)
			missed_para("rq_t", rep.request_head, hex(HEX_TEXT_SOFT), em)
		}
		section_label("re", i18n.tr("REPORT"), em)
		if rep.answer_head != "" {
			// (Markdown, as the card shows it: its marks read, not shown)
			markdown.view(missed_report_head_doc(rep), "re_md", rep.answer_head, md_config(app, hex(HEX_TEXT)), math.round(em * FS_SMALL))
		} else {
			missed_faint("na", i18n.tr("No answer"), em)
		}
		if len(rep.files) > 0 {
			section_label("fl", i18n.tr("FILES"), em)
			shown := rep.files[:min(len(rep.files), MISSED_FILES_BRIEF)]
			line := strings.join(shown, "   ", context.temp_allocator)
			if more := len(rep.files) - len(shown); more > 0 { line = fmt.tprintf("%s   %s", line, fmt.tprintf(i18n.tr(more, "and %d more", "and %d more"), more)) }
			missed_para("fl_t", line, hex(HEX_TEXT_SOFT), em, mono = true)
		}
	}
	return
}

// A card: its session at its top, what happened, then what it is about: what is asked, the command, or the report of the run.
// True: Try again.
@(private = "file")
missed_card :: proc(app: ^App, r: ^Missed_Row, now: f64, em: f32) -> (retry: bool) {
	e := r.entry
	s := find_session(app, r.root)
	pad := math.round(em * 1.4)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###mi_card") {
		ui.spacer(ui.px(pad))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###body") {
			ui.spacer(ui.px(em * 0.9))
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.2)), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###who") {
				if s != nil {
					session_badge(app, s, math.round(em * SESSION_BADGE_EM), em)
					ui.spacer(ui.px(em * 0.6))
				}
				text("t", missed_title(s, r.root), hex(HEX_BRIGHT), ui.Style_Mod{font_size = math.round(em * FS_HEADING)})
				if s != nil && s.directory != "" {
					ui.spacer(ui.px(em * 0.7))
					text("d", base_name(s.directory), hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_CAPTION)}, ui.fill())
				} else {
					ui.spacer(ui.fill())
				}
				text("a", age_text(now, f64(e.at)), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
			}
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.8)), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###what") {
				missed_mark(e, em)
				ui.spacer(ui.px(em * 0.5))
				text("w", missed_words(e), e.state == .Acknowledged ? hex(HEX_FAINT) : hex(HEX_TEXT), ui.Style_Mod{font_size = math.round(em * FS_LABEL)})
				kind := Missed_Kind(e.kind)
				if e.text != "" && (kind == .Sub || kind == .Scheduled) {
					ui.spacer(ui.px(em * 0.6))
					text("x", e.text, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_SMALL)}, ui.fill())
				}
			}
			ui.spacer(ui.px(em * 0.5))
			switch Missed_Kind(e.kind) {
			case .Permission, .Question:
				section_label("as", i18n.tr("ASKED"), em)
				missed_para("as_t", e.text, hex(HEX_TEXT), em)
			case .Shell:
				section_label("cm", i18n.tr("COMMAND"), em)
				missed_para("cm_t", fmt.tprintf("$ %s", e.text), hex(HEX_TEXT_SOFT), em, mono = true)
				missed_shell_exit(app, e, em)
				missed_shell_tail(app, e, em)
			case .End, .Sub, .Scheduled:
				retry = missed_report_card(app, missed_report_find(app, missed_report_session(app, e)), em)
			}
			ui.spacer(ui.px(em * 1.2))
		}
		ui.spacer(ui.px(pad))
	}
	return
}

// The report of a run, whole: the request, the answer as Markdown, the files, the todo list. True: Try again.
@(private = "file")
missed_report_card :: proc(app: ^App, rep: ^Missed_Report, em: f32) -> (retry: bool) {
	if rep == nil || rep.state == .Unread || rep.state == .Reading { missed_faint("rd", i18n.tr("Reading…"), em); return }
	if rep.state == .Failed { return missed_failed(em) }
	if rep.request != "" {
		section_label("rq", i18n.tr("REQUEST"), em)
		missed_para("rq_t", rep.request_card, hex(HEX_TEXT_SOFT), em)
		ui.spacer(ui.px(em * 0.6))
	}
	note := rep.tools > 0 ? fmt.tprintf(i18n.tr(rep.tools, "%d tool call", "%d tool calls"), rep.tools) : ""
	ui.next({width = ui.fill(), height = ui.px(em * 1.4), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###sl_re") { caption_title("l", i18n.tr("REPORT"), note, em) }
	if rep.answer != "" {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###answer") {
			markdown.view(missed_report_doc(rep), "mi_md", rep.answer, md_config(app, hex(HEX_ANSWER_TEXT)), math.round(em * FS_LABEL))
		}
	} else {
		missed_faint("na", i18n.tr("No answer"), em)
	}
	if len(rep.files) > 0 {
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.px(em * 1.4), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###sl_fl") { caption_title("l", i18n.tr("FILES"), fmt.tprintf("%d", len(rep.files)), em) }
		for f, k in rep.files {
			if k >= MISSED_FILES_MAX {
				more := len(rep.files) - k
				missed_faint("fl_more", fmt.tprintf(i18n.tr(more, "and %d more", "and %d more"), more), em)
				break
			}
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.45)), axis = .X, cross = .Center})
			if ui.row(.Center, id = fmt.tprintf("###f%d", k)) {
				glyph(lucide.FILE, hex(HEX_FAINT), math.round(em * ICON_SMALL), em * 1.2)
				ui.spacer(ui.px(em * 0.3))
				text("p", f, hex(HEX_TEXT_SOFT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}, ui.fill())
			}
		}
	}
	if len(rep.todos) > 0 {
		ui.spacer(ui.px(em * 0.6))
		section_label("td", i18n.tr("TODO"), em)
		for t, k in rep.todos { todo_row(app, t, k, em) }
	}
	return
}

// The command of the entry, if the tray knows it still: how it ended.
@(private = "file")
missed_shell_job :: proc(app: ^App, e: ^notices.Entry) -> ^Shell_Job {
	id, _, ok := missed_key_parts(app, e.key)
	if !ok { return nil }
	for &j in app.activity.jobs { if j.id == id { return &j } }
	return nil
}

@(private = "file")
missed_shell_exit :: proc(app: ^App, e: ^notices.Entry, em: f32) {
	if j := missed_shell_job(app, e); j != nil && j.has_exit { missed_faint("ex", fmt.tprintf(i18n.tr("exit %d"), j.exit), em) }
}

// The end of what the command printed (its last lines: the tray keeps a bounded tail).
@(private = "file")
missed_shell_tail :: proc(app: ^App, e: ^notices.Entry, em: f32) {
	j := missed_shell_job(app, e)
	if j == nil || len(j.tail) == 0 { return }
	out := strings.trim_right_space(string(j.tail[:]))
	at, lines := len(out), 0
	for at > 0 && lines < MISSED_TAIL_LINES {
		at -= 1
		if out[at] == '\n' { lines += 1 }
	}
	if lines == MISSED_TAIL_LINES { at += 1 }
	ui.spacer(ui.px(em * 0.4))
	section_label("ou", i18n.tr("OUTPUT"), em)
	missed_para("ou_t", out[at:], hex(HEX_TOOL_OUTPUT), em, mono = true)
}

// Text that wraps, whole.
@(private = "file")
missed_para :: proc(id, s: string, color: Color, em: f32, mono := false) {
	ui.next({width = ui.fill(), font = mono ? the_app.mono : the_app.font, font_size = math.round(em * (mono ? FS_SMALL : FS_NOTE)), flags = {.Text_Wrap}, fg = color, text_pad = 0})
	ui.paragraph(fmt.tprintf("%s###%s", label_safe(s), id))
}

@(private = "file")
missed_faint :: proc(id, s: string, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.5)), axis = .X, cross = .Center})
	if ui.row(.Center, id = fmt.tprintf("###%s", id)) { text("t", s, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_NOTE)}, ui.fill()) }
}

// The report could not be read: said, with Try again. True: Try again.
@(private = "file")
missed_failed :: proc(em: f32) -> (retry: bool) {
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 2)), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###failed") {
		text("t", i18n.tr("Could not be read"), hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_NOTE)})
		ui.spacer(ui.px(em * 0.6))
		retry = ui.button("mi_retry", i18n.tr("Try again"), lucide.REFRESH_CW, {face = .Ghost, height = math.round(em * BUTTON_SMALL_H_EM)}).clicked
		ui.spacer(ui.fill())
	}
	return
}
