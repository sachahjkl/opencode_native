// The conversation: its column and the handles that size it, the keys that scroll it, its messages in the lazy column, a
// message by kind (the reader's, the agent's steps, the lines between turns).
package ocn

import "core:fmt"
import "core:math"
import "core:strings"
import "gt:draw"
import "gt:markdown"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"


HEX_USER_PLATE_TOP    :: 0x222222ff
HEX_USER_PLATE_BOTTOM :: 0x1a1a1aff
HEX_USER_TEXT         :: 0xf2f2f2ff
HEX_ANSWER_TEXT       :: 0xdcdcdcff

// Where the conversation is on the window and how wide, and what the reader opened in it. (Where it is read and scrolled is
// Chat_View_State: that starts over with each session.)
Conversation :: struct {
	expanded:         map[u64]bool,   // tool and reasoning parts opened by the user (hash of their id)
	column_w:         f32,            // the conversation column, frame pixels (this frame)
	scroll_box:       ^ui.Box,        // the conversation's scroll box, when built this frame
	column_drag_from: f32,            // the conversation's width when a handle of it was pressed (column_handles)
	height:           f32,            // of the conversation, at the last frame
	rect:             Rect,           // the conversation's place (Ctrl and the wheel over it zoom it)
	docked_w:         f32,            // the conversation's room as a panel of the dock (0: it is not one)
	was_docked:       bool,           // the conversation was in the dock (preview.odin main_area)
	prompt_rail:      Prompt_Rail,    // the marks of the prompts on its scroll bar (prompt_rail.odin)
}

////////////////////////////////
// Conversation

SPLITTER_W_PX     :: 5
AVAIL_FALLBACK_PX :: 1000   // before the window has a width
COLUMN_MIN_W_PX   :: 240
BOTTOM_SLACK_PX   :: 4      // this near its end the conversation is at its bottom
AUTOSCROLL_SLACK_PX :: 0.01 // ... while the wheel's click scrolls it: its steps are smaller than the slack (each would be put back at the bottom)
OPENED_FOLLOW_MS  :: 2000   // a conversation just opened follows its bottom that long, whatever the preference
PAGE_SCROLL       :: 0.9    // of the view: the end of the last page stays in sight
LINE_SCROLL_EM    :: 3

conversation :: proc(app: ^App, em: f32) {
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y, bg = hex(HEX_BG0), radius = 0})
	if ui.column(flags = {.Draw_Background}, id = "###main") {
		sc := ui.scale()
		// this frame's width, from the window (the box's own size is the last frame's: a resize would lag a frame behind):
		// the window less the sidebar and the splitter
		avail := f32(app.win.size.x)
		if !app.sidebar.hidden { avail -= app.sidebar.width * sc + math.round(SPLITTER_W_PX * sc) }
		if app.conversation.docked_w > 0 { avail = app.conversation.docked_w }   // (a panel of the dock: its room)
		if avail <= 0 { avail = AVAIL_FALLBACK_PX * sc }
		app.conversation.column_w = 0
		zoom := content_zoom(app)
		cem := math.round(em * zoom)   // the conversation's own size: its zoom is not the interface's
		col := max(COLUMN_MIN_W_PX * sc, min(app.prefs.column_w * sc * zoom, avail - em * 3))
		side := max(em * 1.5, (avail - col) * 0.5)
		app.conversation.column_w = col
		if app.chat.id != "" {
			chat_header(app, em)
		}
		main := ui.parent_box()
		app.conversation.rect = main.rect
		sb: ^ui.Box
		ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
		if ui.row(id = "###chat_row") {
			sb = ui.prev_box("###chat")
			// (before the keys of the conversation: Up and Down are the marks' while they have the keyboard)
			if prompt_rail_on(app) && sb != nil { prompt_rail(app, sb, em) }
			find_update(app, sb, em)
			chat_scroll_place(app, sb, em)
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.scroll_y("###chat") {
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
				if ui.row(id = "###lane") {
					ui.spacer(ui.px(side))
					ui.next({width = ui.px(col), height = ui.children_sum(), axis = .Y})
					if ui.column(id = "###col") {
						if ui.style({font_size = cem}) {
							if app.chat.id == "" { home(app, cem) } else { messages(app, cem) }
						}
					}
				}
			}
			app.conversation.scroll_box = ui.prev_box("###chat")
		}
		chat_scroll_settle(app, sb)
		if sb != nil && app.chat.id != "" { column_handles(app, sb, main, side, col, avail, em) }
		dock(app, em, side, col)
		// the find bar over the conversation's top-right corner, under the header
		find_bar(app, em, avail - em * 1.4, sb != nil ? sb.rect.min.y - main.rect.min.y + em * 0.6 : em * 4)
		go_bottom_pill(app, sb, main, avail, em)
	}
}

// The conversation's width by hand: a handle each side of its column where there is room, both moving it the same (the column stays
// in the middle). What it is let go at is the widest wanted (conversation.width): a narrower window narrows it, a wider one gives it
// back. Each shows as two short strokes, faint until the pointer comes.
@(private = "file")
column_handles :: proc(app: ^App, sb, main: ^ui.Box, side, col, avail, em: f32) {
	hw := math.round(em * COLUMN_HANDLE_EM)
	unit := ui.scale() * content_zoom(app)   // (the preference is in logical pixels of the conversation)
	// (no room beside it, or the window narrows it already: nothing to give it by hand)
	if side < hw * 1.5 || col < app.prefs.column_w * unit - 1 { return }
	top := sb.rect.min.y - main.rect.min.y
	h := sb.rect.max.y - sb.rect.min.y
	for right in ([]bool{false, true}) {
		x := right ? side + col : side - hw
		ui.next({fixed_x = math.round(x), fixed_y = math.round(top), width = ui.px(hw), height = ui.px(h), cursor = .Col_Resize})
		ui.a11y({role = .Slider, name = i18n.tr("Conversation width")})
		b := ui.build_box({.Clickable}, right ? "###col_r" : "###col_l")
		sig := ui.signal(b)
		if sig.pressed { app.conversation.column_drag_from = col / unit }
		if sig.dragging {
			d := (right ? sig.drag_delta.x : -sig.drag_delta.x) * 2 / unit
			most := min(f32(COLUMN_W_MAX), (avail - em * 3) / unit)
			app.prefs.column_w = clamp(math.round(app.conversation.column_drag_from + d), f32(COLUMN_W_MIN), max(f32(COLUMN_W_MIN), app.conversation.column_drag_from, most))   // (never under where it began for want of room)
		}
		if sig.released { pref_set(app, "conversation.width", fmt.tprintf("%d", int(app.prefs.column_w))) }
		g := ui.frame_new(f32)
		g^ = sig.dragging ? 1 : b.hot_t
		b.custom_user = g
		b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			lit := (^f32)(user)^
			p := px1()
			s := ui.scale()
			c := draw.rect_center(b.rect)
			len_ := math.round(COLUMN_GRIP_PX * s)
			col := ui.srgb_step(hex(HEX_LINE), hex(HEX_WEAK), lit)
			for i in ([]f32{-1, 1}) {   // two short strokes, side by side
				x := math.round(c.x + i * 1.5 * p)
				draw.rect(dc, {{x - p * 0.5, c.y - len_ * 0.5}, {x + p * 0.5, c.y + len_ * 0.5}}, col, p * 0.5)
			}
		}
	}
}

// Far from the end of the conversation: the way back to it, over its bottom. It comes after a screen and a bit: a small scroll
// up to read something again needs no button.
go_bottom_pill :: proc(app: ^App, sb, main: ^ui.Box, avail, em: f32) {
	if sb == nil || app.chat.id == "" { return }
	far := ui.view_limit(sb) - sb.view_off.y > sb.size.y * GO_BOTTOM_SCREENS
	t := ui.anim(ui.key_from_string(0, "go_bottom"), far ? 1 : 0, GO_BOTTOM_RATE)
	if t < 0.02 { return }
	h := math.round(em * BUTTON_COMPACT_H_EM)
	w := math.round(em * GO_BOTTOM_W_EM)
	y := sb.rect.max.y - main.rect.min.y - h - em * (0.2 + 0.6 * t)
	ui.next({fixed_x = math.round((avail - w) * 0.5), fixed_y = math.round(y), width = ui.px(w), height = ui.px(h), axis = .X, cross = .Center, cursor = .Hand})
	ui.a11y({role = .Button, name = i18n.tr("Go to the latest message")})
	b := ui.build_box({.Clickable, .Focusable}, "###go_bottom")
	d := ui.frame_new(f32)
	d^ = t
	b.custom_user = d
	b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		a := (^f32)(user)^
		r := (b.rect.max.y - b.rect.min.y) * 0.5
		draw.box_shadow(dc, b.rect, radii4(r), 8 * ui.scale(), {0, 0, 0, 0.6 * a})
		draw.rect(dc, b.rect, with_alpha(hex(b.hot_t > FADE_VISIBLE ? HEX_BG4 : HEX_BG3), a), r)
		draw.rect(dc, b.rect, with_alpha(hex(HEX_FLOATING_BORDER), a), r, px1())
	}
	sig := ui.signal(b)
	if sig.clicked {
		chat_scroll_event(app, Scroll_Signal.Go_Bottom)
		sb.view_target.y = ui.view_limit(sb)
	}
	if ui.parent(b) {
		ui.spacer(ui.fill())
		glyph(lucide.CHEVRON_DOWN, with_alpha(hex(HEX_TEXT_SOFT), t), math.round(em * ICON_SMALL))
		ui.spacer(ui.px(em * 0.3))
		text("t", i18n.tr("Latest"), with_alpha(hex(HEX_TEXT_SOFT), t), ui.Style_Mod{font_size = math.round(em * FS_SMALL)})
		ui.spacer(ui.fill())
	}
}

// The keyboard scrolls the conversation, before this build reads where it is. Page Up and Page Down whatever has the focus
// (the composer too: the conversation is what one reads while typing); the arrows, Home and End when they mean nothing else:
// not in a text field, not while the focus is moved with the keyboard (a click gives a button the focus, and no ring).
chat_keys :: proc(app: ^App, sb: ^ui.Box, em: f32) -> (moved: bool) {
	if overlay_open(app) { return }
	limit := ui.view_limit(sb)
	y := sb.view_target.y
	if ui.key_press(.Page_Up) { y -= sb.size.y * PAGE_SCROLL }
	if ui.key_press(.Page_Down) { y += sb.size.y * PAGE_SCROLL }
	f := ui.box_from_key(ui.focus_key())
	top := false
	if f == nil || (.Text_Input not_in f.flags && !app.state.focus_visible) {
		if ui.key_press(.Up) { y -= em * LINE_SCROLL_EM }
		if ui.key_press(.Down) { y += em * LINE_SCROLL_EM }
		if ui.key_press(.Home) { y, top = 0, true }
		if ui.key_press(.End) { y = limit }
	}
	y = clamp(y, 0, limit)
	moved = y != sb.view_target.y
	if moved { ui.scrollbar_reveal(sb) }
	sb.view_target.y = y
	// (Home: the start as such, the pages read before it on the way included. Page Up stopped at the top is a place like any
	// other: a page read then comes above it, and the view stays on what it shows)
	if top { ui.view_top(sb) }
	return
}

messages :: proc(app: ^App, em: f32) {
	app.chat.view_box = nil
	c := &app.chat
	ui.spacer(ui.px(em * 1.2))
	subagent_banner(app, em)
	// Scrolling up reads the pages before this one by itself (load_older): this row is what is seen when it gets here first.
	if c.older != "" {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.4)), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###older") {
			ui.spacer(ui.fill())
			if c.loading_older {
				scanner("###older_bar", accent(), math.round(em * 5), math.round(em * 0.9))
				ui.spacer(ui.px(em * 0.7))
			}
			if ui.tags("weak") { text("older_t", c.older_failed > 0 ? i18n.tr("Earlier messages could not be read: scroll to try again") : i18n.tr("Loading earlier messages…"), hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_NOTE)}) }
			ui.spacer(ui.fill())
		}
		ui.spacer(ui.px(em * 0.6))
	}
	view := chat_view(app)
	if view == .Loading && len(c.messages) == 0 {
		ui.next({width = ui.fill(), height = ui.px(em * 2), text_align = .Center})
		if ui.tags("weak") { ui.label(fmt.tprintf("%s###loading", i18n.tr("Loading the conversation…"))) }
	}
	if view == .Failed { chat_failed(app, em) }
	// Only the messages near the view are built (the toolkit's lazy column): the others stand as a space of the height they
	// had when last built. A long conversation, Markdown and all, made every frame slow. A find reads them all once for a needle,
	// a slice at each frame (its sweep: the window never freezes on a long conversation); everything is built while the
	// conversation loads; the last message always (it grows while streaming).
	// (The item is the if's block, like a row's; the column ends with this block: the space of the last messages skipped
	// goes before what follows.)
	{
		lz := ui.lazy_begin(all = app.chat.loading, sweep = ui.find_sweep())
		// (a view going back to where it was: the column keeps it on its message, however the heights around it settle. A page read
		// above: the message the view holds is built whatever, frame moves the view by as much as the page pushed it down. Copied:
		// a click in this build changes the state that owns them)
		back, keep := "", ""
		back_dy: f32
		#partial switch s in app.chat_scroll {
		case Scroll_Restoring: back, back_dy = strings.clone(s.msg, context.temp_allocator), s.dy
		case Scroll_Anchored:  keep = strings.clone(s.keep, context.temp_allocator)
		}
		restore := back != "" && !c.loading
		if restore { ui.lazy_pin(lz, fmt.tprintf("###msg_%s", back), back_dy) }
		top_seen := false   // the first message under the top of the view, for Back and Forward (subagents.odin nav_mark)
		prompt_rail_begin(app)
		for &m, i in c.messages {
			// (by its id: a page read before it does not change what it is, its height is still known)
			if m.id != "" && m.lazy_id == "" { m.lazy_id = fmt.aprintf("###msg_%s", m.id, allocator = c.alloc) }   // (once: this is every message, at every build)
			id := m.id != "" ? m.lazy_id : fmt.tprintf("###msg_end%d", len(c.messages) - i)
			held := m.id != "" && (m.id == back || m.id == keep)
			if m.kind == .User { prompt_rail_place(app, lz.y) }   // (where it starts: built or not)
			if ui.lazy_item(lz, id, always = i == len(c.messages) - 1 || held) {
				item := ui.parent_box()
				if sb := lz.scroll; sb != nil {
					if !top_seen && m.id != "" && item.rect.max.y > sb.rect.min.y {
						top_seen = true
						app.chat.view_msg, app.chat.view_dy, app.chat.view_box = m.id, sb.rect.min.y - item.rect.min.y, item
					}
				}
				message(app, c, &m, i, em)
				ctx_check(app, ui.parent_box(), .Message, m.id)
				// (what was made while this message was the last: up to the next one; before the first message, at the first)
				from := i == 0 ? 0 : m.created
				to := i + 1 < len(c.messages) ? c.messages[i + 1].created : max(f64)
				for a in chat_artifacts_between(app, from, to) { artifact_card(app, a, em) }
			}
		}
		if restore {
			// (what the first layouts say of the heights around it is not what the next ones find: it stays a few builds)
			found, moved := ui.lazy_pinned(lz)
			chat_scroll_event(app, Scroll_Restore_Held{found, moved})
			app.settle = max(app.settle, FRAMES_AFTER_INPUT)
		}
	}
	// The line of a run stands in the room the end of the conversation keeps anyway: the height is the same with it and without it, so
	// the bottom does not move when a run starts or ends. (It came on top of that room, and took four lines for one word.)
	goal_reason_line(app, em)
	foot := math.round(em * CHAT_FOOT_EM)
	if c.busy {
		line := math.round(em * WORKING_LINE_EM)
		ui.next({width = ui.fill(), height = ui.px(line), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###working") {
			ui.spacer(ui.px(em * 0.4))
			throbber(app, "###wl", accent(), math.round(em * 7), math.round(em * 0.9), em)
			ui.spacer(ui.fill())
			if hint_action("###stop_hint", i18n.tr("Esc to stop"), em, intent = .Danger) { interrupt_session(app, c.id) }
		}
		foot -= line
	}
	ui.spacer(ui.px(foot))
}

// The first page was not read: why, and the way to try again.
@(private = "file")
chat_failed :: proc(app: ^App, em: f32) {
	r := &app.cx.chat_read
	ui.next({width = ui.fill(), flags = {.Text_Wrap}, text_align = .Center})
	if ui.tags("weak") { ui.paragraph(fmt.tprintf("%s###read_failed", label_safe(fmt.tprintf(i18n.tr("The conversation could not be read: %s"), r.message != "" ? r.message : i18n.tr("no answer"))))) }
	ui.spacer(ui.px(em * 0.7))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###read_retry") {
		ui.spacer(ui.fill())
		if ui.button("retry", i18n.tr("Try again"), lucide.REFRESH_CW, {disabled = !online(app)}).clicked { chat_read(app) }
		ui.spacer(ui.fill())
	}
}

// One message of the conversation, in its lazy item.
message :: proc(app: ^App, c: ^Chat, m: ^Message, i: int, em: f32) {
	switch m.kind {
	case .User:        user_message(app, m, em)
	case .Assistant:
		prev := i > 0 ? &c.messages[i - 1] : nil
		next := i + 1 < len(c.messages) ? &c.messages[i + 1] : nil
		assistant_message(app, m, em, continues(prev, m), next != nil && continues(m, next) ? next : nil, prev)
	case .Synthetic:
		if m.sub_child != "" { subagent_result(app, m, em) } else { note_line(app, m, em, lucide.ZAP, m.text != "" ? first_line(m.text) : i18n.tr("synthetic message")) }
	case .Shell:       note_line(app, m, em, lucide.SQUARE_TERMINAL, fmt.tprintf("$ %s", m.text))
	case .Compaction:  note_line(app, m, em, lucide.LIST, i18n.tr("Conversation compacted"))
	case .Idle:        if i < len(c.messages) - 1 { turn_end(app, m, em) }
	case .Switch:      switch_line(app, m, em)
	case .Other:
	}
}

// The first line of Markdown that says something, as text: a preview shows no marks (headings, quotes, lists, emphasis).
preview_text :: proc(s: string) -> string {
	rest := s
	for line in strings.split_lines_iterator(&rest) {
		t := strings.trim_left(strings.trim_space(line), "#>-*+ \t")
		digits := 0
		for digits < len(t) && t[digits] >= '0' && t[digits] <= '9' { digits += 1 }
		if digits > 0 && digits + 1 < len(t) && (t[digits] == '.' || t[digits] == ')') && t[digits + 1] == ' ' { t = t[digits + 2:] }
		if t == "" || strings.trim(t, "-*_=~` ") == "" { continue }
		for mark in ([]string{"**", "__", "~~", "`"}) { t, _ = strings.remove_all(t, mark, context.temp_allocator) }
		return t
	}
	return ""
}

first_line :: proc(s: string) -> string {
	t := strings.trim_space(s)
	if i := strings.index_byte(t, '\n'); i >= 0 { return t[:i] }
	return t
}

note_line :: proc(app: ^App, m: ^Message, em: f32, icon: string, s: string) {
	ui.next({width = ui.fill(), height = ui.px(em * 1.9), axis = .X, cross = .Center})
	if ui.row(.Center, id = fmt.tprintf("###n_%s", m.id)) {
		glyph(icon, hex(HEX_FAINT), math.round(em * ICON_SMALL))
		ui.spacer(ui.px(em * 0.3))
		text("t", s, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_NOTE)}, ui.fill())
	}
	ui.spacer(ui.px(em * 0.6))
}

// What the session changed (its model, its agent, its folder), across the conversation as the end of a turn is: what it was, what it is.
switch_line :: proc(app: ^App, m: ^Message, em: f32) {
	icon, word: string
	switch m.switched {
	case .Agent:    icon, word = lucide.BOT, "agent"
	case .Model:    icon, word = lucide.CPU, "model"
	case .Location: icon, word = lucide.FOLDER, "folder"
	}
	small := ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}
	ui.next({width = ui.fill(), height = ui.px(em * 2), axis = .X, cross = .Center})
	if ui.row(.Center, id = fmt.tprintf("###sw_%s", m.id)) {
		groove(across = true)
		ui.spacer(ui.px(em * 0.6))
		glyph(icon, hex(HEX_FAINT), math.round(em * ICON_SMALL))
		ui.spacer(ui.px(em * 0.35))
		text("w", word, hex(HEX_FAINT), small)
		ui.spacer(ui.px(em * 0.5))
		if m.previous != "" && m.previous != m.text {
			text("p", m.previous, hex(HEX_FAINT), small)
			text("arrow", "  →  ", hex(HEX_FAINT), small)
		}
		text("n", m.text, hex(HEX_WEAK), small)
		ui.spacer(ui.px(em * 0.6))
		groove(across = true)
	}
	ui.spacer(ui.px(em * 0.8))
}

turn_end :: proc(app: ^App, m: ^Message, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(em * 2), axis = .X, cross = .Center})
	if ui.row(.Center, id = fmt.tprintf("###e_%s", m.id)) {
		groove(across = true)
		if m.finish != "" && m.finish != "succeeded" {
			ui.spacer(ui.px(em * 0.5))
			col := m.finish == "interrupted" ? hex(HEX_YELLOW) : hex(HEX_RED)
			text("o", m.finish, col, ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
			ui.spacer(ui.px(em * 0.5))
			groove(across = true)
		}
	}
	ui.spacer(ui.px(em * 0.8))
}

USER_IMAGE_W_PX :: 320
USER_IMAGE_H_PX :: 220

user_message :: proc(app: ^App, m: ^Message, em: f32) {
	ui.spacer(ui.px(em * 0.4))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if plate(fmt.tprintf("###u_%s", m.id), top = HEX_USER_PLATE_TOP, bottom = HEX_USER_PLATE_BOTTOM, radius = CARD_RADIUS, shadow = 8, rim = 0.09) {
		prompt_rail_focus(app, m, ui.parent_box())
		ui.spacer(ui.px(em * 0.75))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###in") {
			ui.spacer(ui.px(em * 1.1))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column() {
				ui.next({width = ui.fill(), height = ui.px(em * 1.4), axis = .X, cross = .Center})
				if ui.row(.Center, id = "###who") {
					glyph(lucide.USER, accent(), math.round(em * ICON_SMALL), em * 1.1)
					ui.spacer(ui.px(em * 0.2))
					text("you", i18n.tr("You"), accent(), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)})
					ui.spacer(ui.fill())
					text("at", clock_text(m.created, app.prefs.clock24), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
				}
				ui.spacer(ui.px(em * 0.35))
				runs := link_runs(&m.text_runs, m.text, {color = hex(HEX_USER_TEXT)}, app.chat.alloc)
				ui.next({width = ui.fill(), flags = {.Selectable}})
				link_clicked(ui.rich_paragraph("###text", runs))
				if len(m.images) > 0 {
					ui.spacer(ui.px(em * 0.6))
					sc := ui.scale()
					image_strip(app, "###imgs", m.images[:], USER_IMAGE_W_PX * sc, USER_IMAGE_H_PX * sc)
				}
			}
			ui.spacer(ui.px(em * 1.1))
		}
		ui.spacer(ui.px(em * 0.85))
	}
	ui.spacer(ui.px(em * 1.1))
}

agent_color :: proc(agent: string) -> Color {
	switch agent {
	case "build":   return accent()
	case "plan":    return hex(HEX_BLUE)
	case "general": return hex(HEX_PURPLE)
	case "explore": return hex(HEX_CYAN)
	}
	return hex(HEX_GREEN)
}

// `m` goes on from `prev` (an assistant step of the same agent and model, right after it): no header of its own.
continues :: proc(prev, m: ^Message) -> bool {
	return prev != nil && prev.kind == .Assistant && m.kind == .Assistant && (len(prev.parts) > 0 || prev.streaming) &&
		prev.agent == m.agent && prev.model == m.model
}

// A tool call drawn on the timeline (a sub-agent has its own card).
plain_tool :: proc(p: ^Part) -> bool { return p.kind == .Tool && p.tool_name != "subagent" && p.sub_agent == "" }

@(private = "file")
Who_Draw :: struct { col: Color, live, glow: bool }   // (glow: the preference, read at the build)

// `cont`: it goes on from the step before (no header); `next`: the step after when it goes on from this one.
assistant_message :: proc(app: ^App, m: ^Message, em: f32, cont := false, next: ^Message = nil, prev: ^Message = nil) {
	if len(m.parts) == 0 && !m.streaming { return }
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = fmt.tprintf("###a_%s", m.id)) {
		// the speaker, once per run of steps: a rail in the agent's colour, agent, model, time
		if !cont {
		ui.next({width = ui.fill(), height = ui.px(em * 1.6), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###who") {
			ui.next({width = ui.px(math.round(em * 0.5)), height = ui.px(math.round(em * 1.0))})
			rb := ui.build_box({}, "###al")
			wd := ui.frame_new(Who_Draw)
			wd^ = {agent_color(m.agent), m.streaming, app.prefs.glow}
			rb.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				d := (^Who_Draw)(user)
				s := ui.scale()
				c := draw.rect_center(b.rect)
				r := Rect{{c.x - 1.5 * s, b.rect.min.y}, {c.x + 1.5 * s, b.rect.max.y}}
				if d.live && d.glow {
					a := 0.15 + 0.15 * (0.5 + 0.5 * math.sin(f32(ui.now_ms()) * PULSE_RATE))
					draw.box_shadow(dc, r, radii4(1.5 * s), 4 * s, with_alpha(d.col, a))
				}
				draw.rect(dc, r, d.live ? d.col : with_alpha(d.col, 0.75), 1.5 * s)
			}
			rb.custom_user = wd
			if m.streaming { animate(app) }
			ui.spacer(ui.px(em * 0.4))
			name := m.agent != "" ? m.agent : "assistant"
			text("ag", strings.to_upper(name[:1], context.temp_allocator), agent_color(m.agent), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)})
			text("ag2", name[1:], agent_color(m.agent), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)})
			if m.model != "" {
				text("dot", "  ·  ", hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_SMALL)})
				text("md", m.model, hex(HEX_WEAK), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
			}
			ui.spacer(ui.fill())
			text("at", clock_text(m.created, app.prefs.clock24), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
		}
		ui.spacer(ui.px(em * 0.4))
		}
		for &p, i in m.parts {
			pid := fmt.tprintf("%s_%d", m.id, i)
			switch p.kind {
			case .Text:
				if len(p.text) > 0 {
					markdown.view(md_doc(&app.chat, pid), pid, string(p.text[:]), md_config(app, hex(HEX_ANSWER_TEXT)))
					ui.spacer(ui.px(em * 0.6))
				}
			case .Reasoning: reasoning_part(app, &p, pid, em)
			case .Tool:
				if !plain_tool(&p) { subagent_card(app, &p, pid, em); break }
				// consecutive calls share the timeline's rail, across the steps that go on from each other
				above := i > 0 ? plain_tool(&m.parts[i - 1]) : cont && prev != nil && len(prev.parts) > 0 && plain_tool(&prev.parts[len(prev.parts) - 1])
				below := i + 1 < len(m.parts) ? plain_tool(&m.parts[i + 1]) : next != nil && len(next.parts) > 0 && plain_tool(&next.parts[0])
				tool_part(app, &p, pid, em, above, below)
				ctx_check(app, ui.prev_box(fmt.tprintf("###tp_%s", pid)), .Tool, m.id, i)
			}
		}
		if app.prefs.usage && !m.streaming && m.tokens_out > 0 && m.finish == "stop" {
			ui.next({width = ui.fill(), height = ui.px(em * 1.5), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###foot") {
				text("tk", m.cost > 0 ? fmt.tprintf(i18n.tr("%s in · %s out · %s"), kfmt(m.tokens_in + m.cache_read), kfmt(m.tokens_out), dollars(m.cost, 3)) : fmt.tprintf(i18n.tr("%s in · %s out"), kfmt(m.tokens_in + m.cache_read), kfmt(m.tokens_out)), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
			}
		}
	}
	// a step that goes on in the next one stays close to it (the rail runs on when both meet on a tool call)
	if next == nil { ui.spacer(ui.px(em * 0.9)) }
}
