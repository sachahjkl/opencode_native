// The conversation: its column and the handles that size it, the keys that scroll it, its messages in the lazy column, a
// message by kind (the reader's, the agent's steps, the lines between turns).
package ocn

import host "gt:host"
import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:strings"
import "gt:draw"
import "gt:markdown"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

// Where the conversation is on the window and how wide, and what the reader opened in it. (Where it is read and scrolled is
// Chat_View_State: that starts over with each session.)
Conversation :: struct {
	column_w:         f32,            // the conversation column, frame pixels (this frame)
	scroll_box:       ^ui.Box,        // the conversation's scroll box, when built this frame
	scroll_key:       ui.Key,         // ... its key, at its last build (what the find is open over)
	find_due:         bool,           // the find opens over it at its next build, with find_text (find.odin find_ask)
	find_text:        string,         // (owned)
	column_drag_from: f32,            // the conversation's width when a handle of it was pressed (column_handles)
	height:           f32,            // of the conversation, at the last frame
	width:            f32,            // the conversation's room, frame pixels (this frame)
	beside_px:        f32,            // what the views beside it took of the window's width at the last layout (views.odin main_area)
	layout_win_w:     f32,            // ... the window's width then
	prompt_rail:      Prompt_Rail,    // the marks of the prompts on its scroll bar (prompt_rail.odin)
	root:             ui.Key,         // its column's box, at its last build (pane_at: what is under the pointer)
	pointer_item:     ui.Key,         // the message's lazy item under the pointer in this build, 0: none (the quote chip's anchor)
}

////////////////////////////////
// Conversation

AVAIL_FALLBACK_PX :: 1000   // before the window has a width
COLUMN_MIN_W_PX   :: 240
BOTTOM_SLACK_PX   :: 4      // this near its end the conversation is at its bottom
AUTOSCROLL_SLACK_PX :: 0.01 // ... while the wheel's click scrolls it: its steps are smaller than the slack (each would be put back at the bottom)
OPENED_FOLLOW_MS  :: 2000   // a conversation just opened follows its bottom that long, whatever the preference
PAGE_SCROLL       :: 0.9    // of the view: the end of the last page stays in sight
LINE_SCROLL_EM    :: 3

// `avail`: its width this frame (0: not known yet). The main view's and the panel's (btw.odin): what is the main view's alone
// (its header, the column's handles) is built in the main view only (chat-panes.md, Layer 2); each has its find.
conversation :: proc(app: ^App, pane: ^Chat_Pane, em: f32, avail: f32) {
	is_main := pane == main_pane(app)
	// The pane's whole column is its zoom zone, not the messages' scroll box alone: the zoom keys follow the keyboard
	// focus, which is mostly in the composer (the dock, below the messages). Keyed by the session shown, so another
	// session shows its own zoom in this build; the home page ("") has the zone's own, not remembered.
	zoom := ui.zoom_zone(&pane.zone, pane.chat.id)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y, bg = ui.theme_color("background"), radius = 0})
	// (.Fits_Width: its column and its dock are sized from `avail`, the width it had, in pixels; counted as what it needs,
	// that width could never shrink, and a narrow window pushed the panel beside it past the edge)
	if ui.column(flags = {.Draw_Background, .Fits_Width}, id = "###main") {
		pane.conversation.root = ui.parent_box().key
		pane.conversation.pointer_item = 0
		sc := ui.scale()
		avail := avail
		if avail <= 0 { avail = AVAIL_FALLBACK_PX * sc }
		pane.conversation.width = avail
		pane.conversation.column_w = 0
		cem := math.round(em * zoom)   // the conversation's own size: its zoom is not the interface's
		col := max(COLUMN_MIN_W_PX * sc, min(app.prefs.column_w * sc * zoom, avail - em * 3))
		side := max(em * 1.5, (avail - col) * 0.5)
		pane.conversation.column_w = col
		if pane.chat.id != "" && is_main {
			chat_header(app, em)
		}
		main := ui.parent_box()
		sb: ^ui.Box
		ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
		if ui.row(id = "###chat_row") {
			sb = ui.prev_box("###chat")
			// (before the keys of the conversation: Up and Down are the marks' while they have the keyboard)
			if prompt_rail_on(app, pane) && sb != nil { prompt_rail(app, pane, sb, em) }
			chat_scroll_place(app, pane, sb, em)
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.scroll_y("###chat") {
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
				if ui.row(id = "###lane") {
					ui.spacer(ui.px(side))
					ui.next({width = ui.px(col), height = ui.children_sum(), axis = .Y})
					if ui.column(id = "###col") {
						if ui.style({font_size = cem}) {
							if pane_forking(pane) { btw_forking_body(app, pane, cem) } else if pane.chat.id == "" { home(app, pane, cem) } else { messages(app, pane, cem) }
						}
					}
				}
			}
			pane.conversation.scroll_box = ui.prev_box("###chat")
			if b := pane.conversation.scroll_box; b != nil { pane.conversation.scroll_key = b.key }
			// (each pane's view has its find: the toolkit's, one per window, moved to the view it is opened over)
			conversation_find(app, pane, pane.conversation.scroll_box)
		}
		chat_scroll_settle(app, pane, sb)
		if sb != nil && pane.chat.id != "" && is_main { column_handles(app, pane, sb, main, side, col, avail, em, zoom) }
		dock(app, pane, em, side, col)
		go_bottom_pill(app, pane, sb, main, avail, em)
	}
}

// The conversation's width by hand: a handle each side of its column where there is room, both moving it the same (the column stays
// in the middle). What it is let go at is the widest wanted (conversation.width): a narrower window narrows it, a wider one gives it
// back. Each shows as two short strokes, faint until the pointer comes.
@(private = "file")
column_handles :: proc(app: ^App, pane: ^Chat_Pane, sb, main: ^ui.Box, side, col, avail, em, zoom: f32) {
	hw := math.round(em * COLUMN_HANDLE_EM)
	unit := ui.scale() * zoom   // (the preference is in logical pixels of the conversation)
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
		if sig.pressed { pane.conversation.column_drag_from = col / unit }
		if sig.dragging {
			d := (right ? sig.drag_delta.x : -sig.drag_delta.x) * 2 / unit
			most := min(f32(COLUMN_W_MAX), (avail - em * 3) / unit)
			app.prefs.column_w = clamp(math.round(pane.conversation.column_drag_from + d), f32(COLUMN_W_MIN), max(f32(COLUMN_W_MIN), pane.conversation.column_drag_from, most))   // (never under where it began for want of room)
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
			col := ui.srgb_step(ui.theme_color("border"), ui.theme_color("weak text"), lit)
			for i in ([]f32{-1, 1}) {   // two short strokes, side by side
				x := math.round(c.x + i * 1.5 * p)
				draw.rect(dc, {{x - p * 0.5, c.y - len_ * 0.5}, {x + p * 0.5, c.y + len_ * 0.5}}, col, p * 0.5)
			}
		}
	}
}

// Far from the end of the conversation: the way back to it, over its bottom. It comes after a screen and a bit: a small scroll
// up to read something again needs no button.
go_bottom_pill :: proc(app: ^App, pane: ^Chat_Pane, sb, main: ^ui.Box, avail, em: f32) {
	if sb == nil || pane.chat.id == "" { return }
	far := ui.view_limit(sb) - sb.view_off.y > sb.size.y * GO_BOTTOM_SCREENS
	// (each pane's: one key for two would show the pill of one over the other)
	t := ui.anim(ui.key_from_u64(ui.key_from_string(0, "go_bottom"), u64(pane_index(app, pane))), far ? 1 : 0, GO_BOTTOM_RATE)
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
		draw.rect(dc, b.rect, ui.with_alpha(b.hot_t > FADE_VISIBLE ? between("button background", "border", 0.83) : ui.theme_color("button background"), a), r)
		draw.rect(dc, b.rect, ui.with_alpha(ui.theme_color("floating border"), a), r, px1())
	}
	sig := ui.signal(b)
	if sig.clicked {
		chat_scroll_event(pane, Scroll_Signal.Go_Bottom)
		sb.view_target.y = ui.view_limit(sb)
	}
	if ui.parent(b) {
		ui.spacer(ui.fill())
		glyph(lucide.CHEVRON_DOWN, ui.with_alpha(ui.theme_color("soft text"), t), math.round(em * ICON_SMALL))
		ui.space(ui.SPACE_1)
		text("t", i18n.tr("Latest"), ui.with_alpha(ui.theme_color("soft text"), t), ui.Style_Mod{font_size = math.round(em * FS_SMALL)})
		ui.spacer(ui.fill())
	}
}

// The keyboard scrolls the conversation, before this build reads where it is. Page Up and Page Down whatever has the focus
// (the composer too: the conversation is what one reads while typing); the arrows, Home and End when they mean nothing else:
// not in a text field, not while the focus is moved with the keyboard (a click gives a button the focus, and no ring). Only the
// keyboard's pane: two panes would scroll together.
chat_keys :: proc(app: ^App, pane: ^Chat_Pane, sb: ^ui.Box, em: f32) -> (moved: bool) {
	if overlay_open(app) || keys_pane(app) != pane { return }
	limit := ui.view_limit(sb)
	y := sb.view_target.y
	if ui.key_press(.Page_Up) { y -= sb.size.y * PAGE_SCROLL }
	if ui.key_press(.Page_Down) { y += sb.size.y * PAGE_SCROLL }
	f := ui.box_from_key(ui.focus_key())
	top := false
	if f == nil || (.Text_Input not_in f.flags && !built_state(app).focus_visible) {
		if ui.key_press(.Up) { y -= em * LINE_SCROLL_EM }
		if ui.key_press(.Down) { y += em * LINE_SCROLL_EM }
		if ui.key_press(.Home) { y, top = 0, true }
		if ui.key_press(.End) { y = limit }
	}
	y = clamp(y, 0, limit)
	moved = y != sb.view_target.y
	sb.view_target.y = y
	// (Home: the start as such, the pages read before it on the way included. Page Up stopped at the top is a place like any
	// other: a page read then comes above it, and the view stays on what it shows)
	if top { ui.view_top(sb) }
	return
}

messages :: proc(app: ^App, pane: ^Chat_Pane, em: f32) {
	pane.chat.view_box = nil
	c := &pane.chat
	ui.space(ui.SPACE_4)
	subagent_banner(app, pane, em)
	// Scrolling up reads the pages before this one by itself (load_older): this row is what is seen when it gets here first.
	if c.older != "" {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.4)), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###older") {
			ui.spacer(ui.fill())
			if c.loading_older {
				scanner("###older_bar", ui.hue(.Accent), math.round(em * 5), math.round(em * 0.9))
				ui.space(ui.SPACE_3)
			}
			if ui.tags("weak") { text("older_t", c.older_failed > 0 ? i18n.tr("Earlier messages could not be read: scroll to try again") : i18n.tr("Loading earlier messages…"), ui.theme_color("faint text"), ui.Style_Mod{font_size = math.round(em * FS_NOTE)}) }
			ui.spacer(ui.fill())
		}
		ui.space(ui.SPACE_2)
	}
	view := chat_view(app, pane)
	// (a /btw's prompt on its way shows instead: the panel that waited for its fork does not blink to "Loading")
	pending, _ := btw_pending(app, pane)
	if view == .Loading && len(c.messages) == 0 && pending == "" {
		ui.next({width = ui.fill(), height = ui.px(em * 2), text_align = .Center})
		if ui.tags("weak") { ui.label(fmt.tprintf("%s###loading", i18n.tr("Loading the conversation…"))) }
	}
	if view == .Failed { chat_failed(app, pane, em) }
	// Only the messages near the view are built (the toolkit's lazy column): the others stand as a space of the height they
	// had when last built. A long conversation, Markdown and all, made every frame slow. Everything is built while the
	// conversation loads; the last message always (it grows while streaming).
	// (The item is the if's block, like a row's; the column ends with this block: the space of the last messages skipped
	// goes before what follows.)
	{
		// (the messages are the selection's rows and the find's: the toolkit builds the two that hold a selection's ends wherever
		// they are, and a copy reads the ones between that are not built by message_text; the find reads every message's whole
		// text, by its stamp, and builds and opens the one that holds its current match. A message is a block: a blank line
		// before it)
		lz := ui.lazy_begin(all = pane.chat.loading, rows = ui.Text_Rows{
			count = len(c.messages), text = message_text, id = message_row_id, stamp = message_stamp, version = messages_version(c),
			reveal = message_reveal, user = pane, gap = "\n\n",
		})
		// (a view going back to where it was: the column keeps it on its message, however the heights around it settle. A page read
		// above: the message the view holds is built whatever, frame moves the view by as much as the page pushed it down. Copied:
		// a click in this build changes the state that owns them)
		back, keep := "", ""
		back_dy: f32
		#partial switch s in pane.view.chat_scroll {
		case Scroll_Restoring: back, back_dy = strings.clone(s.msg, context.temp_allocator), s.dy
		case Scroll_Anchored:  keep = strings.clone(s.keep, context.temp_allocator)
		}
		restore := back != "" && !c.loading
		if restore { ui.lazy_pin(lz, fmt.tprintf("###msg_%s", back), back_dy) }
		top_seen := false   // the first message under the top of the view, for Back and Forward (subagents.odin nav_mark)
		prompt_rail_begin(app, pane)
		for &m, i in c.messages {
			// (by its id: a page read before it does not change what it is, its height is still known)
			if m.id != "" && m.lazy_id == "" { m.lazy_id = fmt.aprintf("###msg_%s", m.id, allocator = c.alloc) }   // (once: this is every message, at every build)
			id := message_lazy_id(c, i)
			held := m.id != "" && (m.id == back || m.id == keep)
			if m.kind == .User { prompt_rail_place(app, pane, lz.y) }   // (where it starts: built or not)
			// (every message has its item, in its order: the item is the selection's row, message_text's `i`)
			if ui.lazy_item(lz, id, always = i == len(c.messages) - 1 || held) {
				item := ui.parent_box()
				// (one rect test per message built: the chip of a selection ended here holds to this message as it scrolls)
				if draw.rect_contains(item.rect, ui.mouse_pos()) { pane.conversation.pointer_item = item.key }
				if sb := lz.scroll; sb != nil {
					if !top_seen && m.id != "" && item.rect.max.y > sb.rect.min.y {
						top_seen = true
						pane.chat.view_msg, pane.chat.view_dy, pane.chat.view_box = m.id, sb.rect.min.y - item.rect.min.y, item
					}
				}
				message(app, pane, &m, i, em)
				message_block(item)
				ctx_check(app, ui.parent_box(), .Message, m.id, pane = pane)
				// (what was made while this message was the last: up to the next one; before the first message, at the first)
				from := i == 0 ? 0 : m.created
				to := i + 1 < len(c.messages) ? c.messages[i + 1].created : max(f64)
				for a in chat_artifacts_between(app, pane, from, to) { artifact_card(app, a, em) }
			}
		}
		if restore {
			// (what the first layouts say of the heights around it is not what the next ones find: it stays a few builds)
			found, moved := ui.lazy_pinned(lz)
			chat_scroll_event(pane, Scroll_Restore_Held{found, moved})
			host.host_settle(&app.window)
		}
	}
	if pending != "" { btw_pending_prompt(app, pane, em) }
	// The line of a run stands in the room the end of the conversation keeps anyway: the height is the same with it and without it, so
	// the bottom does not move when a run starts or ends. (It came on top of that room, and took four lines for one word.)
	goal_reason_line(app, pane, em)
	foot := math.round(em * CHAT_FOOT_EM)
	if c.busy {
		line := math.round(em * WORKING_LINE_EM)
		ui.next({width = ui.fill(), height = ui.px(line), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###working") {
			ui.space(ui.SPACE_2)
			throbber(app, pane, "###wl", ui.hue(.Accent), math.round(em * 7), math.round(em * 0.9), em)
			ui.spacer(ui.fill())
			if hint_action("###stop_hint", i18n.tr("Esc twice to stop"), em, intent = .Danger) { interrupt_session(app, c.id) }
		}
		foot -= line
	}
	ui.spacer(ui.px(foot))
}

// The id of the `i`th message's lazy item (its lazy_id is made by `messages` first).
@(private = "file")
message_lazy_id :: proc(c: ^Chat, i: int) -> string {
	m := &c.messages[i]
	return m.id != "" ? m.lazy_id : fmt.tprintf("###msg_end%d", len(c.messages) - i)
}

// The first page was not read: why, and the way to try again.
@(private = "file")
chat_failed :: proc(app: ^App, pane: ^Chat_Pane, em: f32) {
	r := &pane.read
	ui.next({width = ui.fill(), flags = {.Text_Wrap}, text_align = .Center})
	if ui.tags("weak") { ui.paragraph(fmt.tprintf("%s###read_failed", label_safe(fmt.tprintf(i18n.tr("The conversation could not be read: %s"), r.message != "" ? r.message : i18n.tr("no answer"))))) }
	ui.space(ui.SPACE_3)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###read_retry") {
		ui.spacer(ui.fill())
		if ui.button("retry", i18n.tr("Try again"), lucide.REFRESH_CW, {disabled = !online(app)}).clicked { chat_read(app, pane) }
		ui.spacer(ui.fill())
	}
}

// One message of the conversation, in its lazy item.
message :: proc(app: ^App, pane: ^Chat_Pane, m: ^Message, i: int, em: f32) {
	c := &pane.chat
	switch m.kind {
	case .User:        user_message(app, pane, m, em)
	case .Assistant:
		prev := i > 0 ? &c.messages[i - 1] : nil
		next := i + 1 < len(c.messages) ? &c.messages[i + 1] : nil
		assistant_message(app, pane, m, em, continues(prev, m), next != nil && continues(m, next) ? next : nil, prev)
	case .Synthetic:
		if m.sub_child != "" { subagent_result(app, pane, m, em) } else if m.mcp_event != "" { mcp_wake_note(app, pane, m, em) } else if len(m.jobs) > 0 { job_reports(app, pane, m, em) } else { note_line(app, m, em, lucide.ZAP, m.text != "" ? first_line(m.text) : i18n.tr("synthetic message")) }
	case .Shell:       note_line(app, m, em, lucide.SQUARE_TERMINAL, fmt.tprintf("$ %s", m.text))
	case .Compaction:  note_line(app, m, em, lucide.LIST, i18n.tr("Conversation compacted"))
	case .Idle:        if i < len(c.messages) - 1 { turn_end(app, m, em) }
	case .Switch:      switch_line(app, m, em)
	case .Other:
	}
}

// A message is a block of the conversation: a copy puts a blank line before its first selectable box, whatever that box is
// (a prompt's paragraph, a reasoning, a table's cell). The messages a copy reads and does not build (message_text) come after
// the same blank line (the rows' gap): built or not, a copy is the same text.
@(private = "file")
message_block :: proc(item: ^ui.Box) {
	first :: proc(b: ^ui.Box) -> ^ui.Box {
		for c := b.first; c != nil; c = c.next {
			if .Selectable in c.flags { return c }
			if f := first(c); f != nil { return f }
		}
		return nil
	}
	if b := first(item); b != nil { b.flags += {.Selection_Block} }
}

// What a copy reads of boxes not built: their texts in their order, joined as the toolkit joins selectable boxes (a line
// break; a blank line before a block). Nothing before the first: the rows' gap goes there.
// `whole`: the text of the boxes with every part that opens opened (the find's: what is folded is found). `reveal` >= 0: a byte
// of that text, and `opens` the keys (part_open's) of the folded parts that hold it, outermost first.
Copy_Text :: struct {
	b:      strings.Builder,
	boxes:  int,
	whole:  bool,
	reveal: int,
	folds:  [dynamic]string,   // the folded parts being written (whole), outermost first (temp)
	opens:  []string,
}

copy_box :: proc(t: ^Copy_Text, s: string, block := false) {
	if t.boxes > 0 { strings.write_string(&t.b, block ? "\n\n" : "\n") }
	at := strings.builder_len(t.b)
	strings.write_string(&t.b, s)
	t.boxes += 1
	if t.opens == nil && t.reveal >= at && t.reveal < at + len(s) && t.reveal >= 0 {
		t.opens = make([]string, len(t.folds), context.temp_allocator)
		copy(t.opens, t.folds[:])
	}
}

// A part that opens, `key` its part_open key: written when it is `open`, or when the text is whole (then noted as folded until
// copy_unfold). Used as `if copy_fold(t, key, open) { defer copy_unfold(t, open); ... }`.
copy_fold :: proc(t: ^Copy_Text, key: string, open: bool) -> bool {
	if open { return true }
	if !t.whole { return false }
	if t.folds == nil { t.folds = make([dynamic]string, context.temp_allocator) }
	append(&t.folds, key)
	return true
}

copy_unfold :: proc(t: ^Copy_Text, open: bool) {
	if !open && len(t.folds) > 0 { pop(&t.folds) }
}

// Message `i`'s identity (ui.Text_Rows.id): its id hashed. A page of older messages loaded above a selection shifts the
// indexes, and the selection's ends find their messages again by this.
message_row_id :: proc(user: rawptr, i: int) -> u64 {
	c := &(^Chat_Pane)(user).chat
	if i < 0 || i >= len(c.messages) { return 0 }
	return hash.fnv64a(transmute([]u8)c.messages[i].id)
}

// Message `i` of the pane `user` as its boxes give it (ui.Text_Rows.text): to a copy, the message a selection spans and the
// lazy column did not build, each part as its view builds its selectable boxes, in the same state (open or folded, the
// preferences); `whole`, to the find, as they would be with every part that opens opened (folded reasoning unless the
// preference hides it, folded tool calls, a closed sub-agent card or result, a job's report, a Mermaid diagram's text).
// ok false: it builds none.
message_text :: proc(user: rawptr, i: int, allocator: runtime.Allocator, whole: bool) -> (string, bool) {
	pane := (^Chat_Pane)(user)
	if i < 0 || i >= len(pane.chat.messages) { return "", false }   // (another conversation since the build)
	t := Copy_Text{b = strings.builder_make(allocator), whole = whole, reveal = -1}
	message_write(&t, pane, i)
	if t.boxes == 0 { strings.builder_destroy(&t.b); return "", false }
	return strings.to_string(t.b), true
}

// message_text's writing, into `t` (the find's reveal reads it too, to learn which folds hold a byte).
message_write :: proc(t: ^Copy_Text, pane: ^Chat_Pane, i: int) {
	app := the_app
	m := &pane.chat.messages[i]
	#partial switch m.kind {
	case .User: copy_box(t, m.text)
	case .Assistant:
		for &p, k in m.parts {
			pid := fmt.tprintf("%s_%d", m.id, k)
			switch p.kind {
			case .Text: if len(p.text) > 0 { md_text(t, app, pid, string(p.text[:])) }
			case .Reasoning:
				open := part_open(app, pid, app.prefs.reasoning == "expanded")
				if app.prefs.reasoning != "hidden" && copy_fold(t, pid, open) {
					defer copy_unfold(t, open)
					copy_box(t, string(p.text[:]))
				}
			case .Tool: if plain_tool(&p) { tool_part_text(t, app, pane, &p, pid) } else { subagent_card_text(t, app, pane, &p, pid) }
			}
		}
	case .Synthetic:
		if m.sub_child != "" {
			open := part_open(app, m.id)
			if m.text != "" && copy_fold(t, m.id, open) {
				defer copy_unfold(t, open)
				md_text(t, app, fmt.tprintf("%s_sr", m.id), m.text)
			}
		} else if m.mcp_event != "" {
			if m.mcp_data != "" { mono_well_text(t, m.mcp_data, TOOL_INPUT_LINES_MAX) }
		} else if len(m.jobs) > 0 {
			job_reports_text(t, app, m)
		}
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
		glyph(icon, ui.theme_color("faint text"), math.round(em * ICON_SMALL))
		ui.space(ui.SPACE_1)
		text("t", s, ui.theme_color("faint text"), ui.Style_Mod{font_size = math.round(em * FS_NOTE)}, ui.fill())
	}
	ui.space(ui.SPACE_2)
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
		ui.space(ui.SPACE_2)
		glyph(icon, ui.theme_color("faint text"), math.round(em * ICON_SMALL))
		ui.space(ui.SPACE_1)
		text("w", word, ui.theme_color("faint text"), small)
		ui.space(ui.SPACE_2)
		if m.previous != "" && m.previous != m.text {
			text("p", m.previous, ui.theme_color("faint text"), small)
			text("arrow", "  →  ", ui.theme_color("faint text"), small)
		}
		text("n", m.text, ui.theme_color("weak text"), small)
		ui.space(ui.SPACE_2)
		groove(across = true)
	}
	ui.space(ui.SPACE_3)
}

turn_end :: proc(app: ^App, m: ^Message, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(em * 2), axis = .X, cross = .Center})
	if ui.row(.Center, id = fmt.tprintf("###e_%s", m.id)) {
		groove(across = true)
		if m.finish != "" && m.finish != "succeeded" {
			ui.space(ui.SPACE_2)
			col := m.finish == "interrupted" ? ui.hue(.Yellow) : ui.hue(.Red)
			text("o", m.finish, col, ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
			ui.space(ui.SPACE_2)
			groove(across = true)
		}
	}
	ui.space(ui.SPACE_3)
}

USER_IMAGE_W_PX :: 320
USER_IMAGE_H_PX :: 220

// The plate of the person's prompt (a /btw's on its way has the same: btw_pending_prompt).
user_card_look :: proc() -> ui.Plate_Look {
	return {top = between("button background", "border", 0.33), bottom = between("card background", "button background", 0.5), rim = 0.09, shadow = 8}
}

user_message :: proc(app: ^App, pane: ^Chat_Pane, m: ^Message, em: f32) {
	ui.space(ui.SPACE_2)
	if ui.card("", id = fmt.tprintf("###u_%s", m.id), o = {radius = CARD_RADIUS, look = user_card_look()}) {
		prompt_rail_focus(app, pane, m, ui.card_box())
		ui.next({width = ui.fill(), height = ui.px(em * 1.4), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###who") {
			glyph(lucide.USER, ui.hue(.Accent), math.round(em * ICON_SMALL), em * 1.1)
			ui.space(ui.SPACE_1)
			text("you", i18n.tr("You"), ui.hue(.Accent), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)})
			ui.spacer(ui.fill())
			text("at", clock_text(m.created, app.prefs.clock24), ui.theme_color("faint text"), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
		}
		ui.space(ui.SPACE_1)
		runs := link_runs(&m.text_runs, m.text, {color = ui.theme_color("text")}, pane.chat.alloc)
		ui.next({width = ui.fill(), flags = {.Selectable}})
		link_clicked(ui.rich_paragraph("###text", runs))
		if len(m.images) > 0 {
			ui.space(ui.SPACE_2)
			sc := ui.scale()
			image_strip(app, "###imgs", m.images[:], USER_IMAGE_W_PX * sc, USER_IMAGE_H_PX * sc)
		}
	}
	ui.space(ui.SPACE_4)
}

agent_color :: proc(agent: string) -> Color {
	switch agent {
	case "build":   return ui.hue(.Accent)
	case "plan":    return ui.hue(.Blue)
	case "general": return ui.hue(.Purple)
	case "explore": return ui.hue(.Cyan)
	}
	return ui.hue(.Green)
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
assistant_message :: proc(app: ^App, pane: ^Chat_Pane, m: ^Message, em: f32, cont := false, next: ^Message = nil, prev: ^Message = nil) {
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
					draw.box_shadow(dc, r, radii4(1.5 * s), 4 * s, ui.with_alpha(d.col, a))
				}
				draw.rect(dc, r, d.live ? d.col : ui.with_alpha(d.col, 0.75), 1.5 * s)
			}
			rb.custom_user = wd
			if m.streaming { animate(app) }
			ui.space(ui.SPACE_2)
			name := m.agent != "" ? m.agent : "assistant"
			text("ag", strings.to_upper(name[:1], context.temp_allocator), agent_color(m.agent), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)})
			text("ag2", name[1:], agent_color(m.agent), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_SMALL)})
			if m.model != "" {
				text("dot", "  ·  ", ui.theme_color("faint text"), ui.Style_Mod{font_size = math.round(em * FS_SMALL)})
				text("md", m.model, ui.theme_color("weak text"), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
			}
			ui.spacer(ui.fill())
			text("at", clock_text(m.created, app.prefs.clock24), ui.theme_color("faint text"), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
		}
		ui.space(ui.SPACE_2)
		}
		for &p, i in m.parts {
			pid := fmt.tprintf("%s_%d", m.id, i)
			switch p.kind {
			case .Text:
				if len(p.text) > 0 {
					markdown.view(md_doc(&pane.chat, pid), pid, string(p.text[:]), md_config(app, ui.theme_color("text"), pane))
					ui.space(ui.SPACE_2)
				}
			case .Reasoning: reasoning_part(app, pane, &p, pid, em)
			case .Tool:
				if !plain_tool(&p) { subagent_card(app, pane, &p, pid, em); break }
				// consecutive calls share the timeline's rail, across the steps that go on from each other
				above := i > 0 ? plain_tool(&m.parts[i - 1]) : cont && prev != nil && len(prev.parts) > 0 && plain_tool(&prev.parts[len(prev.parts) - 1])
				below := i + 1 < len(m.parts) ? plain_tool(&m.parts[i + 1]) : next != nil && len(next.parts) > 0 && plain_tool(&next.parts[0])
				tool_part(app, pane, &p, pid, em, above, below)
				ctx_check(app, ui.prev_box(fmt.tprintf("###tp_%s", pid)), .Tool, m.id, i, pane = pane)
			}
		}
		if app.prefs.usage && !m.streaming && m.tokens_out > 0 && m.finish == "stop" {
			ui.next({width = ui.fill(), height = ui.px(em * 1.5), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###foot") {
				usage := m.cost > 0 ? fmt.tprintf(i18n.tr("%s in · %s out · %s"), kfmt(m.tokens_in + m.cache_read), kfmt(m.tokens_out), dollars(m.cost, 3)) : fmt.tprintf(i18n.tr("%s in · %s out"), kfmt(m.tokens_in + m.cache_read), kfmt(m.tokens_out))
				if s := speed_text(m.latency_ms, m.write_rate); s != "" { usage = fmt.tprintf("%s · %s", usage, s) }   // (kept in the message: step_speed_set)
				text("tk", usage, ui.theme_color("faint text"), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
			}
		}
	}
	// a step that goes on in the next one stays close to it (the rail runs on when both meet on a tool call)
	if next == nil { ui.space(ui.SPACE_4) }
}
