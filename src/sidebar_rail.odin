// The sidebar minimised: its rail (src/md/features/sidebar-rail.md). The toolkit gives the sidebar's view a column
// SIDEBAR_RAIL_EM wide and builds it with View.rail; this is what the sidebar builds there: its zone's Restore, New
// session, Search, the server's mark, then a mark per session of the list, its details in a card beside it.
package ocn

import "core:fmt"
import "core:math"
import "core:strings"
import "gt:draw"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

SIDEBAR_RAIL_EM :: 3.5   // the rail's width: a mark, its lamp, and the toolkit's insets
RAIL_MARK_EM    :: 2.6   // a session's row in the rail
RAIL_FACE_EM    :: 1.9   // its avatar (as tall as the inbox's)
RAIL_WAITS_MAX  :: 3     // what waits, said one by one up to this many in the card
RAIL_CARD_EM    :: 24    // the card at its widest, its insets included: a title of about forty letters a line
RAIL_TITLE_LINES :: 2    // the card's title, then "…"
RAIL_LEAD_EM    :: 0.85  // the card's column of the lamp and the icons of what waits (session_lamp's box)

// What the rail keeps between builds: where the keyboard is among the marks. The marks are built lazily, as the list's
// rows: the one with the keyboard and its two neighbours stay built, so that Up and Down land on a box laid out.
Side_Rail :: struct {
	focused: string,      // the session whose mark has the keyboard (owned)
	near:    [2]string,   // the sessions before and after it at the last build (owned)
	want:    string,      // the mark that takes the keyboard once it is built (owned): a step to a mark not built yet
}

sidebar_rail :: proc(app: ^App, v: ^ui.View, em: f32) {
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y, cross = .Center, bg = ui.theme_color("bar background"), radius = 0})
	if ui.column(.Center, {.Draw_Background}, "###sidebar_rail") {
		rail := ui.parent_box()
		// (one tooltip at a time: the pointer's, on the rail; the keyboard's card only while the pointer is elsewhere)
		keys_card := !draw.rect_contains(rail.rect, ui.mouse_pos())
		// the zone's Restore, in a row built as the list's servers' row: the same pixel as the list's Minimise
		ui.space(ui.SPACE_2)
		ui.next({width = ui.fill(), height = ui.px(math.round(em * SERVER_TABS_H_EM)), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###rail_fold") { sidebar_fold(v, em) }
		ui.space(ui.SPACE_1)
		nsig := ui.button("rail_new", icon = lucide.PLUS, o = {intent = .Primary, tip = i18n.tr("New session")})
		ui.act_name(nsig.box, "command:session.new")
		if nsig.clicked { new_session(app) }
		ui.space(ui.SPACE_1)
		// (the list's search field needs the width the rail gave away: the palette's sessions, "@", search them)
		if ui.button("rail_search", icon = lucide.SEARCH, o = {tip = i18n.tr("Search sessions")}).clicked { palette_show(app, "@") }
		ui.space(ui.SPACE_1)
		rail_server(app, rail, keys_card, em)
		ui.space(ui.SPACE_2)
		ui.next({width = ui.fill(), height = ui.px(GROOVE_BOX_PX)})
		groove("###rail_groove")
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###rail_marks") { rail_marks(app, rail, keys_card, em) }
	}
	session_menu(app, em)
	server_menu(app, SERVER_MENU_KEY, em)
}

// The server's strip as one mark: the link's lamp; its menu (every server, Add, Edit) on a click, its name in its tooltip.
@(private = "file")
rail_server :: proc(app: ^App, rail: ^ui.Box, keys_card: bool, em: f32) {
	if app.server < 0 || app.server >= len(app.servers) { return }
	srv := app.servers[app.server]
	name := i18n.tr(srv.name)
	size := math.round(em * RAIL_FACE_EM)
	ui.next({width = ui.px(size), height = ui.px(size), axis = .X, cross = .Center, cursor = .Hand})
	b := ui.build_box({.Clickable, .Focusable}, "###rail_server")
	b.custom = rail_spot_draw
	sig := ui.signal(b)
	ui.a11y_default(b, {role = .Button, name = name, description = link_word(app)})
	if ui.parent(b) {
		ui.spacer(ui.fill())
		glyph(lucide.SERVER, ui.theme_color("weak text"), math.round(em * ICON_REGULAR))
		ui.spacer(ui.fill())
		ui.next({fixed_x = 0, fixed_y = 0, width = ui.pct(1), height = ui.pct(1), axis = .X, cross = .End})
		if ui.parent(ui.build_box({}, "###light")) {
			ui.spacer(ui.fill())
			link_lamp(app, "###rail_srv_lamp", em * 0.8)
		}
	}
	if sig.clicked || sig.right_clicked { ui.menu_open(SERVER_MENU_KEY, b.rect, b.key) }
	if ui.hovered_for(sig) || (keys_card && ui.keyboard_focused(sig)) {
		// (past the rail's edge)
		if ui.tooltip_beside({b.rect.min, {rail.rect.max.x, b.rect.max.y}}) {
			ui.tooltip_text(fmt.tprintf("%s · %s", name, link_word(app)))
			if srv.url != "" { if ui.style({fg = ui.theme_color("weak text")}) { ui.tooltip_text(srv.url) } }
		}
	}
}

// A small square under the pointer: the server's mark, which is no row.
@(private = "file")
rail_spot_draw :: proc(b: ^ui.Box, _: rawptr, dc: ^draw.Context) {
	if b.hot_t > FADE_VISIBLE { draw.rect(dc, b.rect, ui.with_alpha(ui.theme_color("text"), ITEM_HOVER_TINT * b.hot_t), math.round(b.rect.max.y - b.rect.min.y) * 0.25) }
}

// The marks, in the list's sections and order (sidebar_view: the same sections, kept until they change, and held under
// the pointer), a groove between two sections. No search: the rail lists every session the list shows unsearched.
@(private = "file")
rail_marks :: proc(app: ^App, rail: ^ui.Box, keys_card: bool, em: f32) {
	if !app.sessions_loaded { return }
	pane := main_pane(app)
	r := &app.sidebar.rail
	sections := sidebar_view(app, "", sidebar_hold_wanted(app, ui.parent_box()))
	kids := app.sidebar.kept.kids
	// (one card at most: the pointer's mark, else the keyboard's)
	card: ^Session_Info
	card_at: ui.Rect
	focused_now, before, after, last_id: string
	after_next := false
	last_box: ^ui.Box   // the mark built just before this one (nil: not built)
	step := false       // Down on the mark with the keyboard: the next one takes it
	ui.space(ui.SPACE_1)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = "###rail_rows") {
		lz := ui.lazy_begin()
		first := true
		for &sec in sections {
			if app.sidebar.folded[sec.key] or_else sec.shut { continue }   // (folded in the list, folded here: the same rows)
			if !first {
				if ui.lazy_item(lz, sec.lazy_id) {
					ui.space(ui.SPACE_1)
					ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
					if ui.row(id = "###gap") {
						ui.space(ui.SPACE_3)
						groove("###g", across = true)   // (along the row: a section's end)
						ui.space(ui.SPACE_3)
					}
					ui.space(ui.SPACE_1)
				}
			}
			first = false
			for i in sec.items {
				s := &app.sessions[i]
				if s.parent != "" { continue }   // (a sub-agent: its parent's mark says it runs)
				if after_next { after, after_next = s.id, false }
				if s.id == r.focused { before, after_next = last_id, true }
				keep := s.id == pane.chat.id || s.id == r.focused || s.id == r.near[0] || s.id == r.near[1] || s.id == r.want
				built: ^ui.Box
				if ui.lazy_item(lz, s.lazy_id, always = keep) {
					b, sig := rail_mark(app, s, kids, em)
					built = b
					if step || s.id == r.want {
						ui.focus_by_keys(b.key)
						step = false
						rail_set(&r.want, "")
					}
					if sig.focused {
						focused_now = s.id
						if ui.key_press(.Down) { step = true }
						if ui.key_press(.Up) {
							if last_box != nil {
								ui.focus_by_keys(last_box.key)
							} else if last_id != "" {
								rail_set(&r.want, last_id)
								animate(app)
							}
						}
					}
					// (at once, not after Feel.tooltip_delay_ms: a mark has no label but its card, and a pointer run down
					// the rail must read each mark it passes)
					if sig.hovering || (card == nil && keys_card && ui.keyboard_focused(sig)) { card, card_at = s, b.rect }
				}
				if step && built == nil {
					// (past the marks built: this one takes the keyboard once it is, at the next build)
					rail_set(&r.want, s.id)
					step = false
					animate(app)
				}
				last_id, last_box = s.id, built
			}
		}
	}
	ui.space(ui.SPACE_4)
	rail_set(&r.focused, focused_now)
	rail_set(&r.near[0], focused_now != "" ? before : "")
	rail_set(&r.near[1], focused_now != "" ? after : "")
	// (beside the mark, past the rail's edge, whether the pointer or the keyboard is on it: over the rail it would hide the
	// marks around it)
	card_at.max.x = max(card_at.max.x, rail.rect.max.x)   // (the rail's edge: its scroll bar is beside the marks)
	if card != nil { if ui.tooltip_beside(card_at) { rail_card(app, card, kids, em) } }
}

// An owned string of the rail, replaced only when it changes (most builds change nothing).
@(private = "file")
rail_set :: proc(dst: ^string, s: string) {
	if dst^ == s { return }
	delete(dst^)
	dst^ = strings.clone(s)
}

// A session's mark: its avatar, its lamp over the avatar's corner, the ground of the one shown. A click opens it, as its
// row's does; a right click opens the row's menu.
@(private = "file")
rail_mark :: proc(app: ^App, s: ^Session_Info, kids: map[string][dynamic]int, em: f32) -> (^ui.Box, ui.Signal) {
	pane := main_pane(app)
	selected := s.id == pane.chat.id
	ui.next({width = ui.fill(), height = ui.px(math.round(em * RAIL_MARK_EM)), axis = .X, cross = .Center})
	b := chosen_box({.Clickable, .Focusable}, "###rail_mark", selected, .Nav)
	d := ui.frame_new(Item_Draw)
	d.selected = selected
	b.custom, b.custom_user = item_draw, d
	sig := ui.signal(b)
	title := s.title != "" ? s.title : i18n.tr("Untitled")
	ui.a11y_default(b, {role = .Button, name = title, selected = selected})
	if sig.clicked { open_root(app, s.id) }
	if sig.right_clicked {
		ui.menu_open("session_menu", b.rect.min + sig.mouse)
		delete(app.sidebar.menu_session)
		app.sidebar.menu_session = strings.clone(s.id)
	}
	light := session_light(app, s)
	if light < .Running && rail_kids_running(app, kids, s.id) > 0 { light = .Running }
	face := math.round(em * RAIL_FACE_EM)
	if ui.parent(b) {
		ui.spacer(ui.fill())
		ui.next({width = ui.px(face), height = ui.px(face), axis = .X})
		if ui.parent(ui.build_box({}, "###face")) {
			session_badge(app, s, face, em)
			if light != .Rest {
				// (over the avatar, its lamp at the bottom right corner: the toolkit's badge places its count so)
				ui.next({fixed_x = 0, fixed_y = 0, width = ui.pct(1), height = ui.pct(1), axis = .X, cross = .End})
				if ui.parent(ui.build_box({}, "###light")) {
					ui.spacer(ui.fill())
					session_light_lamp(s, light, em)
				}
			}
		}
		ui.spacer(ui.fill())
	}
	return b, sig
}

// How many of a session's sub-agents run (only for a mark built: its own sub-agents, from the list's index of them).
@(private = "file")
rail_kids_running :: proc(app: ^App, kids: map[string][dynamic]int, id: string) -> int {
	n := 0
	if list, ok := kids[id]; ok { for k in list { if app.busy[app.sessions[k].id] or_else false { n += 1 } } }
	return n
}

// The card of a mark: what its row said, and more (src/md/features/sidebar-rail.md). The title; "project · folder"; the
// lamp with the state, the sub-agents that run and the last activity on one line; what waits, a line each. Each fact once.
@(private = "file")
rail_card :: proc(app: ^App, s: ^Session_Info, kids: map[string][dynamic]int, em: f32) {
	inner := math.round(em * (RAIL_CARD_EM - 2 * ui.SPACE_3))
	// (no text padding: tooltip_text's gave each line the room of two; the insets and gaps are the spacing scale's)
	if ui.style({text_pad = 0}) {
		ui.next({width = ui.children_sum(), height = ui.children_sum(), axis = .X})
		if ui.parent(ui.build_box({}, "###rail_card")) {
			ui.space(ui.SPACE_3)
			rail_card_lines(app, s, kids, em, inner)
			ui.space(ui.SPACE_3)
		}
	}
}

// The card's column of lines, `inner` pixels at most.
@(private = "file")
rail_card_lines :: proc(app: ^App, s: ^Session_Info, kids: map[string][dynamic]int, em, inner: f32) {
	lead := math.round(em * RAIL_LEAD_EM)
	small := math.round(em * FS_SMALL)
	weak := ui.theme_color("weak text")
	face := ui.top_style().font
	ui.next({width = ui.children_sum(), height = ui.children_sum(), axis = .Y})
	if ui.parent(ui.build_box({}, "###lines")) {
		ui.space(ui.SPACE_2)
		title := s.title != "" ? s.title : i18n.tr("Untitled")
		bold := ui.styled_face(app.font, true, false)
		ui.next({width = ui.px(math.ceil(min(ui.text_width(bold, ui.font_size(), title), inner))), font = bold, fg = ui.theme_color("bright text")})
		ui.rich_paragraph("###card_title", {{text = title}}, max_lines = RAIL_TITLE_LINES, selectable = false)
		ui.space(ui.SPACE_1)
		meta := i18n.tr("(no folder)")
		if s.directory != "" {
			// (the project is the folder's last part, the folder the one that holds it: the path said once)
			project := base_name(s.directory)
			whole := strings.trim_right(s.directory, "\\/")
			holder := strings.trim_right(whole[:len(whole) - len(project)], "\\/")
			meta = project
			if holder != "" {
				head := fmt.tprintf("%s · ", project)
				meta = fmt.tprintf("%s%s", head, ui.elide(face, small, holder, inner - ui.text_width(face, small, head), .Middle))
			}
		}
		if ui.style({fg = weak, font_size = small}) { rail_card_text(ui.elide(face, small, meta, inner), "card_meta") }
		ui.space(ui.SPACE_2)
		running := rail_kids_running(app, kids, s.id)
		light := session_light(app, s)
		lit := light
		if lit < .Running && running > 0 { lit = .Running }   // (as its mark: lit by its sub-agents)
		ui.next({width = ui.children_sum(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.parent(ui.build_box({}, "###card_state")) {
			if lit != .Rest {
				session_light_lamp(s, lit, em)
				ui.space(ui.SPACE_2)
			}
			rail_card_text(rail_state_line(app, s, light, running), "card_state_words")
		}
		waits, n := rail_waits(app, s)
		for w, i in waits {
			ui.space(ui.SPACE_1)
			ui.next({width = ui.children_sum(), height = ui.children_sum(), axis = .X, cross = .Center})
			if ui.parent(ui.build_box({}, fmt.tprintf("###card_wait%d", i))) {
				glyph(w.icon, w.color, math.round(em * ICON_SMALL), lead)
				ui.space(ui.SPACE_2)
				rail_card_text(ui.elide(face, ui.font_size(), w.text, inner - lead - math.round(em * ui.SPACE_2)), "card_wait")
			}
		}
		if n > len(waits) {
			ui.space(ui.SPACE_1)
			ui.next({width = ui.children_sum(), height = ui.children_sum(), axis = .X})
			if ui.parent(ui.build_box({}, "###card_more")) {
				ui.space(RAIL_LEAD_EM + ui.SPACE_2)   // (under the words of what waits, past their icons)
				if ui.style({fg = weak, font_size = small}) {
					rail_card_text(fmt.tprintf(i18n.tr(n - len(waits), "and %d more", "and %d more"), n - len(waits)), "card_more_words")
				}
			}
		}
		ui.space(ui.SPACE_2)
	}
}

// A line of the card, as wide as its text (cut before it is built: no wrap).
@(private = "file")
rail_card_text :: proc(text, id: string) {
	ui.next({width = ui.text_size(), height = ui.text_size()})
	ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###%s", label_safe(text), id))
}

// The card's state line: the state in words as the lamp says it (session_light), the sub-agents that run, the last
// activity, parted by " · ". At rest and seen, the time alone.
rail_state_line :: proc(app: ^App, s: ^Session_Info, light: Session_Light, kids_running: int) -> string {
	parts := make([dynamic]string, 0, 3, context.temp_allocator)
	switch light {
	case .Waits:      append(&parts, i18n.tr("Waits for you"))
	case .Running:    append(&parts, i18n.tr("Running"))
	case .Background: append(&parts, i18n.tr("Its commands run in the background"))
	case .Unseen:
		st, _ := state_of_word(s.outcome)
		#partial switch st {
		case .Failed:    append(&parts, i18n.tr("Failed, not seen yet"))
		case .Cancelled: append(&parts, i18n.tr("Stopped, not seen yet"))
		case:            append(&parts, i18n.tr("Finished, not seen yet"))
		}
	case .Rest:
	}
	if kids_running > 0 { append(&parts, fmt.tprintf(i18n.tr(kids_running, "%d sub-agent runs", "%d sub-agents run"), kids_running)) }
	if s.updated > 0 {
		now := now_epoch_ms()
		// (timefmt.age says "now" under a minute: "now ago" does not read)
		append(&parts, now - s.updated < SECS_PER_MINUTE * MS_PER_S ? i18n.tr("just now") : fmt.tprintf(i18n.tr("%s ago"), age_text(now, s.updated)))
	}
	return strings.join(parts[:], " · ", context.temp_allocator)
}

// One thing that waits for the person, as the card says it: its kind's icon, its words.
Rail_Wait :: struct {
	icon:  string,
	color: Color,
	text:  string,
}

// What waits on a session, its own and its sub-agents': the first RAIL_WAITS_MAX (temp memory), and how many in all.
rail_waits :: proc(app: ^App, s: ^Session_Info) -> (first: []Rail_Wait, n: int) {
	list := make([dynamic]Rail_Wait, 0, RAIL_WAITS_MAX, context.temp_allocator)
	ours :: proc(app: ^App, s: ^Session_Info, owner: string) -> bool {
		if owner == s.id { return true }
		o := find_session(app, owner)
		return o != nil && o.parent == s.id
	}
	for f in app.cx.forms {
		if !ours(app, s, f.session) { continue }
		if n < RAIL_WAITS_MAX {
			append(&list, f.question ? Rail_Wait{lucide.MESSAGE_CIRCLE_QUESTION_MARK, ui.hue(.Accent), f.title} : Rail_Wait{lucide.CLIPBOARD_LIST, ui.hue(.Accent), f.title})
		}
		n += 1
	}
	for p in app.permissions {
		if !ours(app, s, p.session) { continue }
		if n < RAIL_WAITS_MAX { append(&list, Rail_Wait{lucide.SHIELD, ui.hue(.Yellow), p.message != "" ? p.message : p.action}) }
		n += 1
	}
	return list[:], n
}
