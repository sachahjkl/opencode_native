// Find in the conversation (Ctrl+F): a bar over the top-right corner of the conversation, the toolkit's find in page
// (gt:ui find.odin) on the text the conversation shows. Enter / F3 go to the next match, Shift+Enter / Shift+F3 to the
// previous one, Escape closes. The current match is scrolled into view.
package ocn

import "core:fmt"
import "core:math"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

Find :: struct {
	open:   bool,
	fresh:  bool,           // opened in this frame: focus the field, select its text
	field:  ui.Line_Edit,
	index:  int,            // the current occurrence (-1: none yet)
	needle: string,         // the needle of the last frame (a new one picks the first match from the view's top)
	reveal: bool,           // scroll the current match into view
	from_end: int,          // a page came in front of the current match: how far it is from the last one (0: not counted so)
}

find_open :: proc(app: ^App) {
	f := &app.find
	f.open, f.fresh = true, true
	ui.line_edit_select_all(&f.field)
}

find_close :: proc(app: ^App) {
	app.find.open = false
	app.find.from_end = 0
	ui.find("", 0)
	ui.find_set_current(-1)
}

// Another conversation: its matches are not this one's. The home page has none, the bar goes.
find_chat_changed :: proc(app: ^App) {
	f := &app.find
	if !f.open { return }
	if app.chat.id == "" { find_close(app); return }
	f.index, f.reveal, f.from_end = -1, false, 0
	ui.find_set_current(-1)
	ui.find_refresh()
}

find_forget :: proc(app: ^App) {
	if app.find.open { find_close(app) }
	app.find.index = -1
}

// An older page came, in front of everything: the current match stays the one it is, so its number grows by what the page has.
find_page_added :: proc(app: ^App) {
	f := &app.find
	if f.open && f.index >= 0 && f.from_end == 0 { f.from_end = ui.find_count() - f.index }
	ui.find_refresh()
}

// The step to another match (+1 next, -1 previous), wrapping around.
find_step :: proc(app: ^App, d: int) {
	f := &app.find
	n := ui.find_count()
	if n == 0 { return }
	f.index = f.index < 0 ? (d > 0 ? 0 : n - 1) : (f.index + d + n) % n
	f.from_end = 0
	f.reveal = true
}

FIND_SETTLE_MS        :: 1500   // a conversation just opened moves under the reader that long
FIND_BOTTOM_MARGIN_EM :: 3      // a match nearer the bottom of the view is scrolled to
FIND_REVEAL_AT        :: 0.35   // where it lands, from the top of the view

// Called by conversation() before the scroll box is built: the needle for this build's layout, a new needle's first
// match, and the scroll that brings the current match into view (from the rects of the last layout).
find_update :: proc(app: ^App, sb: ^ui.Box, em: f32) {
	f := &app.find
	needle := f.open ? ui.line_edit_string(&f.field) : ""
	ui.find(needle, sb != nil ? sb.key : 0)
	if !f.open { return }
	ms := ui.find_all()   // (of the sweep, in the content: what is far from the view is not built)
	n := ui.find_count()
	if needle != f.needle {
		delete(f.needle)
		f.needle = fmt.aprintf("%s", needle)
		// (the matches are the last layout's, still of the previous needle: choose on the next frame)
		f.index = -1
		f.from_end = 0
		return
	}
	if ui.find_pending() { return }
	if n == 0 { f.index = -1; ui.find_set_current(-1); return }
	if f.from_end > 0 { f.index = max(n - f.from_end, 0) }
	// a conversation just opened is still loading and jumping to its bottom: its matches move under the reader
	if f.index < 0 && (app.chat.loading || ui.now_ms() - app.opened_ms < FIND_SETTLE_MS) { return }
	if f.index < 0 && sb != nil {
		// (the first match from the top of the view down; when none is under it, the view is past the last one (at the bottom of
		// a conversation): the nearest above it, not the conversation's first, a whole conversation away)
		f.index = -1
		for m in ms { if m.rect.min.y >= sb.view_off.y { f.index = m.index; break } }
		if f.index < 0 {
			low := min(f32)
			for m in ms { if m.rect.min.y > low { low, f.index = m.rect.min.y, m.index } }
			f.index = max(f.index, 0)
		}
		f.reveal = true
	}
	f.index = min(f.index, n - 1)
	ui.find_set_current(f.index)
	if f.reveal && sb != nil {
		f.reveal = false
		for m in ms {
			if m.index != f.index { continue }
			h := sb.size.y
			y0, y1 := m.rect.min.y, m.rect.max.y
			if y0 < sb.view_off.y + em || y1 > sb.view_off.y + h - em * FIND_BOTTOM_MARGIN_EM {
				limit := max(0, sb.view_bounds.y - h)
				sb.view_target.y = clamp(y0 - h * FIND_REVEAL_AT, 0, limit)
				chat_scroll_event(app, Scroll_Signal.Moved_Up)
				app.settle = max(app.settle, FRAMES_AFTER_INPUT)   // (the sweep's answer comes with no input: the glide needs its frames)
			}
			break
		}
	}
}

// The bar, over the conversation's top-right corner (built after the conversation: on top of it, taking its clicks).
find_bar :: proc(app: ^App, em: f32, right, top: f32) {
	f := &app.find
	if !f.open { return }
	n := ui.find_count()
	w := math.round(em * 24)
	ui.next({fixed_x = right - w, fixed_y = top, width = ui.px(w), height = ui.children_sum(), axis = .X, cross = .Center})
	// One box: the field and its buttons in a single well, its focus ring around all of it. (The plate under it is only its shadow:
	// the same size and the same corners, all of it covered; a well inside a plate showed the plate's edge beside it.)
	if plate("###findbar", radius = FIND_RADIUS, shadow = 8, rim = 0, border = CLEAR) {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.2)), cross = .Center, radius = FIND_RADIUS * ui.scale()})
		if ui.well("###fw", .X, flags = {.Focus_Within, .Draw_Focus_Ring}) {
			ui.spacer(ui.px(em * 0.6))
			glyph(lucide.SEARCH, hex(HEX_FAINT), math.round(em * ICON_SMALL))
			if ui.tags("bare") {
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.3})
				res := ui.line_edit("###ff", &f.field, {placeholder = i18n.tr("Find in the conversation")})
				if f.fresh { ui.set_focus(res.box.key); f.fresh = false }
				if ui.key_press(.Return, {.Shift}) { find_step(app, -1) } else if res.committed { find_step(app, 1) }
				if res.cancelled { find_close(app) }
			}
			needle := ui.line_edit_string(&f.field)
			pending := ui.find_pending()   // (read so far, and how far: "no match" would be a lie before the end; nothing while the needle rests)
			count := needle == "" ? "" : pending ? (ui.find_progress() < 1 ? fmt.tprintf("%d…  %d %%", n, int(ui.find_progress() * 100)) : "") : n == 0 ? i18n.tr("no match") : fmt.tprintf("%d / %d", max(f.index, 0) + 1, n)
			text("fc", count, n == 0 && !pending ? hex(HEX_RED) : hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION), height = ui.px(em * 1.5)})
			ui.spacer(ui.px(em * 0.4))
			ui.next({width = ui.px(math.round(em * GLYPH_BUTTON_EM)), height = ui.px(math.round(em * GLYPH_BUTTON_EM))})
			if ui.button("fprev", icon = lucide.CHEVRON_UP).clicked { find_step(app, -1) }
			ui.next({width = ui.px(math.round(em * GLYPH_BUTTON_EM)), height = ui.px(math.round(em * GLYPH_BUTTON_EM))})
			if ui.button("fnext", icon = lucide.CHEVRON_DOWN).clicked { find_step(app, 1) }
			ui.next({width = ui.px(math.round(em * GLYPH_BUTTON_EM)), height = ui.px(math.round(em * GLYPH_BUTTON_EM))})
			if ui.button("fclose", icon = lucide.X).clicked { find_close(app) }
			ui.spacer(ui.px(em * 0.3))
		}
	}
}

FIND_RADIUS :: 7

// The keys that work anywhere in the window.
find_keys :: proc(app: ^App) {
	if app.chat.id == "" || overlay_open(app) { return }
	if ui.key_press(.F, {.Ctrl}) { find_open(app) }
	if app.find.open {
		if ui.key_press(.F3) { find_step(app, 1) }
		if ui.key_press(.F3, {.Shift}) { find_step(app, -1) }
	}
}
