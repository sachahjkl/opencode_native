// Find in the conversation (Ctrl+F): a bar over the top-right corner of the conversation, the toolkit's find in page
// (gt:ui find.odin) on the text the conversation shows. Enter / F3 go to the next match, Shift+Enter / Shift+F3 to the
// previous one, Escape closes. The current match is scrolled into view.
package occ

import "core:fmt"
import "core:math"
import "gt:ui"

Find :: struct {
	open:   bool,
	fresh:  bool,           // opened in this frame: focus the field, select its text
	field:  ui.Text_Field,
	index:  int,            // the current occurrence (-1: none yet)
	needle: string,         // the needle of the last frame (a new one picks the first match from the view's top)
	reveal: bool,           // scroll the current match into view
}

find_open :: proc(app: ^App) {
	f := &app.find
	f.open, f.fresh = true, true
	ui.field_select_all(&f.field)
}

find_close :: proc(app: ^App) {
	app.find.open = false
	ui.find("", 0)
	ui.find_set_current(-1)
}

// The step to another match (+1 next, -1 previous), wrapping around.
find_step :: proc(app: ^App, d: int) {
	f := &app.find
	n := ui.find_count()
	if n == 0 { return }
	f.index = f.index < 0 ? (d > 0 ? 0 : n - 1) : (f.index + d + n) % n
	f.reveal = true
}

FIND_SETTLE_MS        :: 1500   // a conversation just opened moves under the reader that long
FIND_BOTTOM_MARGIN_EM :: 3      // a match nearer the bottom of the view is scrolled to
FIND_REVEAL_AT        :: 0.35   // where it lands, from the top of the view

// Called by conversation() before the scroll box is built: the needle for this build's layout, a new needle's first
// match, and the scroll that brings the current match into view (from the rects of the last layout).
find_update :: proc(app: ^App, sb: ^ui.Box, em: f32) {
	f := &app.find
	needle := f.open ? ui.field_string(&f.field) : ""
	ui.find(needle, sb != nil ? sb.key : 0)
	if !f.open { return }
	ms := ui.find_matches()
	n := ui.find_count()
	if needle != f.needle {
		delete(f.needle)
		f.needle = fmt.aprintf("%s", needle)
		// (the matches are the last layout's, still of the previous needle: choose on the next frame)
		f.index = -1
		return
	}
	if n == 0 { f.index = -1; ui.find_set_current(-1); return }
	// a conversation just opened is still loading and jumping to its bottom: its matches move under the reader
	if f.index < 0 && (app.chat.loading || ui.now_ms() - app.opened_ms < FIND_SETTLE_MS) { return }
	if f.index < 0 && sb != nil {
		// the first match from the top of the view down, like a browser
		f.index = 0
		for m in ms { if m.rect.min.y >= sb.rect.min.y { f.index = m.index; break } }
		f.reveal = true
	}
	f.index = min(f.index, n - 1)
	ui.find_set_current(f.index)
	if f.reveal && sb != nil {
		f.reveal = false
		for m in ms {
			if m.index != f.index { continue }
			top := sb.rect.min.y
			h := sb.size.y
			y0 := m.rect.min.y - top + sb.view_off.y   // in the content
			y1 := m.rect.max.y - top + sb.view_off.y
			if y0 < sb.view_off.y + em || y1 > sb.view_off.y + h - em * FIND_BOTTOM_MARGIN_EM {
				limit := max(0, sb.view_bounds.y - h)
				sb.view_target.y = clamp(y0 - h * FIND_REVEAL_AT, 0, limit)
				app.stick_bottom = false
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
	if plate("###findbar", radius = 8, shadow = 8) {
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2)), axis = .X, cross = .Center})
		if well("###fw", .X, radius = 6, focus = 1) {
			ui.spacer(ui.px(em * 0.5))
			glyph(ICO_SEARCH, hex(HEX_FAINT), math.round(em * 0.8))
			if ui.tags("bare") {
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.3})
				res := ui.line_edit("###ff", &f.field, "Find in the conversation")
				if f.fresh { ui.set_focus(res.box.key); f.fresh = false }
				if ui.key_press(.Return, {.Shift}) { find_step(app, -1) } else if res.committed { find_step(app, 1) }
				if res.cancelled { find_close(app) }
			}
			needle := ui.field_string(&f.field)
			count := needle == "" ? "" : n == 0 ? "no match" : fmt.tprintf("%d / %d", max(f.index, 0) + 1, n)
			text("fc", count, n == 0 ? hex(HEX_RED) : hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.74), height = ui.px(em * 1.5)})
			ui.spacer(ui.px(em * 0.5))
		}
		ui.spacer(ui.px(em * 0.3))
		if glyph_button("###fprev", ICO_UP, math.round(em * GLYPH_BUTTON_EM)).clicked { find_step(app, -1) }
		if glyph_button("###fnext", ICO_DOWN, math.round(em * GLYPH_BUTTON_EM)).clicked { find_step(app, 1) }
		if glyph_button("###fclose", ICO_CANCEL, math.round(em * GLYPH_BUTTON_EM)).clicked { find_close(app) }
		ui.spacer(ui.px(em * 0.3))
	}
}

// The keys that work anywhere in the window.
find_keys :: proc(app: ^App) {
	if app.chat.id == "" { return }
	if ui.key_press(.F, {.Ctrl}) { find_open(app) }
	if app.find.open {
		if ui.key_press(.F3) { find_step(app, 1) }
		if ui.key_press(.F3, {.Shift}) { find_step(app, -1) }
	}
}
