// The sidebar minimised: its rail (src/md/features/sidebar-rail.md). The toolkit gives the sidebar's view a column
// SIDEBAR_RAIL_EM wide under its zone's Restore and builds it with View.rail; this is what the sidebar builds there: New
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

// What the rail keeps between builds: where the keyboard is among the marks. The marks are built lazily, as the list's
// rows: the one with the keyboard and its two neighbours stay built, so that Up and Down land on a box laid out.
Side_Rail :: struct {
	focused: string,      // the session whose mark has the keyboard (owned)
	near:    [2]string,   // the sessions before and after it at the last build (owned)
	want:    string,      // the mark that takes the keyboard once it is built (owned): a step to a mark not built yet
}

sidebar_rail :: proc(app: ^App, em: f32) {
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y, cross = .Center, bg = ui.theme_color("bar background"), radius = 0})
	if ui.column(.Center, {.Draw_Background}, "###sidebar_rail") {
		rail := ui.parent_box()
		// (one tooltip at a time: the pointer's, on the rail; the keyboard's card only while the pointer is elsewhere)
		keys_card := !draw.rect_contains(rail.rect, ui.mouse_pos())
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
					if ui.hovered_for(sig) || (card == nil && keys_card && ui.keyboard_focused(sig)) { card, card_at = s, b.rect }
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
	b := ui.build_box({.Clickable, .Focusable}, "###rail_mark")
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

// The card of a mark: what its row said, and more. Its title; its project and the folder that holds it; its state in
// words, or what waits for the person; its last activity. Each fact once.
@(private = "file")
rail_card :: proc(app: ^App, s: ^Session_Info, kids: map[string][dynamic]int, em: f32) {
	title := s.title != "" ? s.title : i18n.tr("Untitled")
	if ui.style({fg = ui.theme_color("bright text"), font = ui.styled_face(app.font, true, false)}) { ui.tooltip_text(title) }
	if s.directory != "" {
		// (the project is the folder's last part, the line under it the rest: the path said once)
		project := base_name(s.directory)
		whole := strings.trim_right(s.directory, "\\/")
		holder := strings.trim_right(whole[:len(whole) - len(project)], "\\/")
		ui.tooltip_text(project)
		if holder != "" { if ui.style({fg = ui.theme_color("weak text"), font_size = math.round(em * FS_SMALL)}) { ui.tooltip_text(holder) } }
	} else {
		ui.tooltip_text(i18n.tr("(no folder)"))
	}
	ui.space(ui.SPACE_1)
	for line in rail_state_words(app, s, rail_kids_running(app, kids, s.id)) { ui.tooltip_text(line) }
	if age := age_text(now_epoch_ms(), s.updated); age != "" {
		if ui.style({fg = ui.theme_color("weak text"), font_size = math.round(em * FS_SMALL)}) {
			ui.tooltip_text(age == "now" ? i18n.tr("Active just now") : fmt.tprintf(i18n.tr("Last active %s ago"), age))
		}
	}
}

// A session's state in words, as its lamp says it (session_light). Waiting: what waits, one line each (its own and its
// sub-agents'), up to RAIL_WAITS_MAX. At rest and seen: nothing to say.
rail_state_words :: proc(app: ^App, s: ^Session_Info, kids_running: int) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	ours :: proc(app: ^App, s: ^Session_Info, owner: string) -> bool {
		if owner == s.id { return true }
		o := find_session(app, owner)
		return o != nil && o.parent == s.id
	}
	light := session_light(app, s)
	switch light {
	case .Waits:
		n := 0
		for f in app.cx.forms {
			if !ours(app, s, f.session) { continue }
			if n < RAIL_WAITS_MAX { append(&lines, fmt.tprintf(f.question ? i18n.tr("Asks: %s") : i18n.tr("Waits on a form: %s"), f.title)) }
			n += 1
		}
		for p in app.permissions {
			if !ours(app, s, p.session) { continue }
			if n < RAIL_WAITS_MAX { append(&lines, fmt.tprintf(i18n.tr("Asks permission: %s"), p.message != "" ? p.message : p.action)) }
			n += 1
		}
		if n > RAIL_WAITS_MAX { append(&lines, fmt.tprintf(i18n.tr(n - RAIL_WAITS_MAX, "and %d more", "and %d more"), n - RAIL_WAITS_MAX)) }
		if n == 0 { append(&lines, i18n.tr("Waits for you")) }
	case .Running:    append(&lines, i18n.tr("Runs"))
	case .Background: append(&lines, i18n.tr("Its commands run in the background"))
	case .Unseen:
		st, _ := state_of_word(s.outcome)
		#partial switch st {
		case .Failed:    append(&lines, i18n.tr("Failed, not seen yet"))
		case .Cancelled: append(&lines, i18n.tr("Stopped, not seen yet"))
		case:            append(&lines, i18n.tr("Finished, not seen yet"))
		}
	case .Rest:
	}
	if kids_running > 0 && light != .Waits {
		append(&lines, fmt.tprintf(i18n.tr(kids_running, "%d sub-agent runs", "%d sub-agents run"), kids_running))
	}
	return lines[:]
}
