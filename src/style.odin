// The look: opencode's dark palette (near-black steps, warm peach accent) with machined surfaces drawn by hand —
// bevelled and ridged buttons, sunken wells, carved grooves, glowing status lamps.
package occ

import "core:fmt"
import "core:math"
import "gt:draw"
import "gt:ui"

Color :: draw.Color
Rect :: draw.Rect
Vec2 :: draw.Vec2

// opencode's dark steps and accents (sRGB)
HEX_BG0     :: 0x0a0a0aff   // the conversation
HEX_BG1     :: 0x101010ff   // sidebar, bars
HEX_BG2     :: 0x161616ff   // cards
HEX_BG3     :: 0x1e1e1eff   // raised elements
HEX_BG4     :: 0x282828ff
HEX_LINE    :: 0x2a2a2aff
HEX_TEXT    :: 0xedededff
HEX_WEAK    :: 0x8f8f8fff
HEX_FAINT   :: 0x5a5a5aff
HEX_PEACH   :: 0xfab283ff   // opencode's primary
HEX_BLUE    :: 0x5c9cf5ff
HEX_PURPLE  :: 0x9d7cd8ff
HEX_GREEN   :: 0x7fd88fff
HEX_YELLOW  :: 0xf5a742ff
HEX_RED     :: 0xe06c75ff
HEX_CYAN    :: 0x56b6c2ff

OPENCODE_PALETTE :: ui.Palette{
	bg = 0x0c0c0cff, panel = HEX_BG2, panel2 = HEX_BG3, text = HEX_TEXT, weak = HEX_WEAK, border = HEX_LINE,
	accent = HEX_PEACH, accent_text = 0x1c120bff, good = HEX_GREEN, warn = HEX_YELLOW, bad = HEX_RED, dark = true,
	finish = .Gradient, bar = HEX_BG1,
}

hex :: draw.hex
BLACK :: Color{0, 0, 0, 1}
WHITE :: Color{1, 1, 1, 1}
CLEAR :: Color{0, 0, 0, 0}

with_alpha :: proc(c: Color, a: f32) -> Color { return {c.r, c.g, c.b, c.a * a} }
lighten :: proc(c: Color, t: f32) -> Color { return ui.srgb_step(c, WHITE, t) }
darken :: proc(c: Color, t: f32) -> Color { return ui.srgb_step(c, BLACK, t) }

// Theme entries of our own, ahead of the palette's (equal specificity: the first one wins).
theme_setup :: proc(t: ^ui.Theme) {
	ui.theme_add(t, "button sheen", {1, 1, 1, 0.22})
	ui.theme_add(t, "bar sheen", {1, 1, 1, 0.10})
	ui.theme_add(t, "kbd sheen", {1, 1, 1, 0.25})
	ui.theme_add(t, "selected sheen", {1, 1, 1, 0.15})
	ui.theme_add(t, "accent_button sheen", {1, 1, 1, 0.45})
	ui.theme_add(t, "bare background", CLEAR)       // a field inside one of our wells: the well is its surface
	ui.theme_add(t, "bare border", CLEAR)
	ui.theme_add(t, "bare focus border", CLEAR)
	ui.theme_add(t, "bare input background", CLEAR)
	ui.theme_add(t, "bare input border", CLEAR)
	ui.theme_add(t, "code_bg", hex(0x202020ff))
	ui.theme_add(t, "link", hex(HEX_BLUE))
	ui.theme_add(t, "floating background", hex(0x181818ff))
	ui.theme_add(t, "floating border", hex(0x333333ff))
	ui.theme_add(t, "floating scrim background", CLEAR)   // (dialog_backdrop paints it; "floating background" made it opaque)
	ui.theme_add(t, "selection", with_alpha(hex(HEX_PEACH), 0.28))
	ui.apply_palette(t, OPENCODE_PALETTE)
}

// The icons: Lucide on every system (assets/fonts/lucide.ttf, embedded: ISC licence, assets/fonts/LUCIDE-LICENSE.txt),
// so they look the same everywhere and nothing depends on the fonts installed.
ICO_ADD      :: "\ue13d"   // plus
ICO_SEND     :: "\ue4f2"   // send-horizontal
ICO_STOP     :: "\ue167"   // square
ICO_SEARCH   :: "\ue151"   // search
ICO_FOLDER   :: "\ue0d7"   // folder
ICO_DOWN     :: "\ue06d"   // chevron-down
ICO_RIGHT    :: "\ue06f"   // chevron-right
ICO_CHAT     :: "\ue117"   // message-square
ICO_DELETE   :: "\ue18e"   // trash-2
ICO_REFRESH  :: "\ue145"   // refresh-cw
ICO_COPY     :: "\ue09e"   // copy
ICO_CODE     :: "\ue093"   // code
ICO_ROBOT    :: "\ue1bb"   // bot
ICO_EDIT     :: "\ue1f9"   // pencil
ICO_DOC      :: "\ue0c0"   // file
ICO_TERMINAL :: "\ue20a"   // square-terminal
ICO_GLOBE    :: "\ue0e8"   // globe
ICO_BULB     :: "\ue1c2"   // lightbulb
ICO_CANCEL   :: "\ue1b2"   // x
ICO_CHECK    :: "\ue06c"   // check
ICO_WARN     :: "\ue193"   // triangle-alert
ICO_SHIELD   :: "\ue158"   // shield
ICO_BOLT     :: "\ue1b4"   // zap
ICO_LIST     :: "\ue106"   // list
ICO_TOOL     :: "\ue1b1"   // wrench
ICO_PERSON   :: "\ue19f"   // user
ICO_MENU     :: "\ue115"   // menu
ICO_CHIP     :: "\ue0a9"   // cpu
ICO_HISTORY  :: "\ue1f5"   // history
ICO_PALETTE  :: "\ue1dd"   // palette
ICO_SLIDERS  :: "\ue29a"   // sliders-horizontal
ICO_PLUG     :: "\ue37f"   // plug
ICO_GAUGE    :: "\ue1bf"   // gauge
ICO_UNDO     :: "\ue2a1"   // undo-2
ICO_BACK     :: "\ue048"   // arrow-left

px1 :: proc() -> f32 { return max(1, math.round(ui.scale())) }

radii4 :: proc(r: f32) -> [4]f32 { return {r, r, r, r} }

////////////////////////////////
// Primitives (frame pixels)

// A raised, machined surface: soft drop shadow, a dark outer edge, a vertical gradient, a lit inner rim along the top
// and a shaded one along the bottom (the "ridge"). Pressed, it sinks: flat darker face and an inner shadow from above.
draw_bevel :: proc(dc: ^draw.Context, r: Rect, radius: f32, base: Color, hot, pressed: f32, glow: Color = CLEAR) {
	s := ui.scale()
	p := px1()
	rr := radii4(radius)
	face := lighten(base, 0.06 * hot)
	if pressed < 0.5 {
		draw.box_shadow(dc, draw.rect_shift(r, {0, 1.5 * s}), rr, 2.2 * s, {0, 0, 0, 0.65})
		if glow.a > 0 && hot > 0.01 && the_app.prefs.glow { draw.box_shadow(dc, r, rr, 2.5 * s, with_alpha(glow, 0.2 * hot)) }   // (under the pointer only, and tight: a wide halo reached the carved edge above)
		top := lighten(face, 0.10)
		bot := darken(face, 0.16)
		draw.rect_corners(dc, r, {top, bot, top, bot}, rr)
		// rim: light along the top, dark along the bottom
		inner := draw.rect_pad(r, -p)
		draw.rect_corners(dc, inner, {{1, 1, 1, 0.16}, {1, 1, 1, 0.03}, {1, 1, 1, 0.16}, {1, 1, 1, 0.03}}, radii4(max(0, radius - p)), p)
		draw.rect(dc, {{r.min.x + radius * 0.8, r.max.y - 2 * p}, {r.max.x - radius * 0.8, r.max.y - p}}, {0, 0, 0, 0.25})
	} else {
		sunk := darken(face, 0.22)
		draw.rect(dc, r, sunk, radius)
		draw.inset_shadow(dc, r, rr, draw.rect_shift(draw.rect_pad(r, -1 * s), {0, 2 * s}), radii4(radius), 2.5 * s, {0, 0, 0, 0.8})
		// the lip of the hole catches the light below
		draw.rect(dc, {{r.min.x + radius * 0.7, r.max.y}, {r.max.x - radius * 0.7, r.max.y + p}}, {1, 1, 1, 0.06})
	}
	draw.rect(dc, r, {0, 0, 0, 0.85}, radius, p)
}

// A sunken well (fields, code, the composer): darker face, inner shadow from above, a lit lip under the bottom edge;
// `focus` lights a glowing accent ring around it.
draw_well :: proc(dc: ^draw.Context, r: Rect, radius: f32, base: Color, focus: f32 = 0, accent := Color{}) {
	s := ui.scale()
	p := px1()
	rr := radii4(radius)
	if focus > 0.01 && the_app.prefs.glow { draw.box_shadow(dc, r, rr, 4 * s, with_alpha(accent, 0.12 * focus)) }
	draw.rect(dc, r, base, radius)
	draw.inset_shadow(dc, r, rr, draw.rect_shift(draw.rect_pad(r, -0.5 * s), {0, 2.5 * s}), rr, 3.5 * s, {0, 0, 0, 0.85})
	draw.rect(dc, {{r.min.x + radius * 0.6, r.max.y}, {r.max.x - radius * 0.6, r.max.y + p}}, {1, 1, 1, 0.07})
	edge := focus > 0.01 ? draw.mix(Color{0, 0, 0, 0.9}, with_alpha(accent, 0.85), focus) : Color{0, 0, 0, 0.9}
	draw.rect(dc, r, edge, radius, p)
	// the rim of the opening, lit: without it a dark well on a dark panel has no visible edge (the accent replaces it
	// under the focus)
	if focus < 0.99 { draw.rect(dc, draw.rect_pad(r, p), {1, 1, 1, 0.1 * (1 - focus)}, radius + p, p) }
}

// A carved line: a dark cut with the light catching its lower edge.
draw_groove :: proc(dc: ^draw.Context, a, b: Vec2, vertical := false) {
	p := px1()
	if vertical {
		draw.rect(dc, {a, {a.x + p, b.y}}, {0, 0, 0, 0.9})
		draw.rect(dc, {{a.x + p, a.y}, {a.x + 2 * p, b.y}}, {1, 1, 1, 0.05})
	} else {
		draw.rect(dc, {a, {b.x, a.y + p}}, {0, 0, 0, 0.9})
		draw.rect(dc, {{a.x, a.y + p}, {b.x, a.y + 2 * p}}, {1, 1, 1, 0.05})
	}
}

// A status lamp: a glass bead with a halo when lit.
draw_lamp :: proc(dc: ^draw.Context, c: Vec2, d: f32, col: Color, lit: f32 = 1) {
	s := ui.scale()
	prev := draw.set_circular_corners(dc, true)
	defer draw.set_circular_corners(dc, prev)
	r := Rect{c - d * 0.5, c + d * 0.5}
	rr := radii4(d * 0.5)
	if lit > 0.01 && the_app.prefs.glow { draw.box_shadow(dc, r, rr, d * 0.45, with_alpha(col, 0.4 * lit)) }
	draw.rect(dc, draw.rect_pad(r, 1 * s), {0, 0, 0, 0.8}, d * 0.5 + s)
	body := draw.mix(darken(col, 0.65), col, lit)
	draw.rect_corners(dc, r, {lighten(body, 0.25), darken(body, 0.2), lighten(body, 0.25), darken(body, 0.2)}, rr)
	hl := Rect{{c.x - d * 0.26, c.y - d * 0.36}, {c.x + d * 0.10, c.y - d * 0.10}}
	draw.rect(dc, hl, {1, 1, 1, 0.22 + 0.2 * lit}, d * 0.18, 0, d * 0.12)
}

// A pip: a small hole drilled in the surface with a dab of colour at its bottom, unlit. What is over (done, failed,
// stopped) shows as a pip; only what is live gets a glowing lamp, so the lamps stay rare enough to mean something.
draw_pip :: proc(dc: ^draw.Context, c: Vec2, d: f32, col: Color) {
	prev := draw.set_circular_corners(dc, true)
	defer draw.set_circular_corners(dc, prev)
	p := px1()
	r := Rect{c - d * 0.5, c + d * 0.5}
	draw.rect(dc, r, {0, 0, 0, 0.75}, d * 0.5)
	draw.rect(dc, {{r.min.x, r.max.y - p}, {r.max.x, r.max.y + p}}, {1, 1, 1, 0.05}, d * 0.5)   // the lit lower lip
	in_r := draw.rect_pad(r, -max(p, math.round(d * 0.22)))
	draw.rect(dc, in_r, with_alpha(col, col.a * 0.8), (in_r.max.x - in_r.min.x) * 0.5)
}

////////////////////////////////
// Boxes painted by those primitives

Btn_Kind :: enum u8 { Normal, Accent, Danger, Ghost, Toggled }

@(private = "file")
Bevel_Draw :: struct { kind: Btn_Kind, radius: f32 }

@(private = "file")
bevel_box_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Bevel_Draw)(user)
	held := b.active_t * b.hot_t
	rad := d.radius * ui.scale()
	switch d.kind {
	case .Normal:  draw_bevel(dc, b.rect, rad, hex(0x2a2a2aff), b.hot_t, held)
	case .Accent:  draw_bevel(dc, b.rect, rad, accent(), b.hot_t, held, accent())
	case .Danger:  draw_bevel(dc, b.rect, rad, hex(0xb8464fff), b.hot_t, held, hex(HEX_RED))
	case .Toggled: draw_bevel(dc, b.rect, rad, hex(0x2a2a2aff), b.hot_t, 1)
	case .Ghost:
		if b.hot_t > 0.01 || held > 0.01 { draw_bevel(dc, b.rect, rad, hex(0x222222ff), b.hot_t, held) }
	}
}

// The close cross in the top-right corner of a dialog (call it last inside ui.modal, so it sits over the content and takes
// its clicks; Escape and a click outside close the dialog too). Placed from the panel's width of the last frame.
dialog_close :: proc(open: ^bool) {
	panel := ui.parent_box()
	w := panel.rect.max.x - panel.rect.min.x
	if w < 1 { return }
	em := ui.font_size()
	sz := math.round(em * 1.9)
	m := math.round(em * 0.5)
	ui.next({fixed_x = w - sz - m, fixed_y = m, width = ui.px(sz), height = ui.px(sz), axis = .X, cross = .Center})
	ui.a11y({role = .Button, name = "Close"})
	b := ui.build_box({.Clickable, .Focusable}, "###dialog_close")
	d := ui.frame_new(Bevel_Draw)
	d^ = {kind = .Ghost, radius = 5}
	b.custom, b.custom_user = bevel_box_draw, d
	sig := ui.signal(b)
	if ui.parent(b) {
		ui.next({width = ui.fill(), height = ui.fill(), font = the_app.icons, font_size = math.round(em * 0.9), fg = sig.hovering ? hex(HEX_TEXT) : hex(HEX_WEAK), text_align = .Center, text_pad = 0})
		ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###g", ICO_CANCEL))
	}
	if sig.clicked { open^ = false }
}

// A machined push button: an icon (Lucide glyph) and/or a label. `width`: its width (text size by default).
bevel_button :: proc(id: string, label: string, icon := "", kind := Btn_Kind.Normal, width: Maybe(ui.Size) = nil, height: f32 = 0, disabled := false, left := false) -> ui.Signal {
	em := ui.font_size()
	h := height > 0 ? height : math.round(em * 2.1)
	fg := kind == .Accent ? hex(0x1c120bff) : kind == .Danger ? WHITE : hex(HEX_TEXT)
	if disabled { fg = hex(HEX_FAINT) }
	ui.next({width = width.? or_else ui.children_sum(), height = ui.px(h), axis = .X, cross = .Center})
	flags: ui.Box_Flags = {.Clickable, .Focusable}
	if disabled { flags = {} }
	b := ui.build_box(flags, id)
	d := ui.frame_new(Bevel_Draw)
	d^ = {kind = disabled ? .Ghost : kind, radius = 6}
	b.custom = bevel_box_draw
	b.custom_user = d
	sig := ui.signal(b)
	if ui.parent(b) {
		pad := label != "" ? em * 0.75 : em * 0.55
		if _, fixed := width.?; fixed && !left { ui.spacer(ui.fill()) } else { ui.spacer(ui.px(left ? em * 0.8 : pad)) }
		if icon != "" {
			ui.next({width = ui.px(em * 1.25), height = ui.pct(1), font = the_app.icons, font_size = math.round(em * 0.95), fg = fg, text_align = .Center, text_pad = 0})
			ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###ico", icon))
			if label != "" { ui.spacer(ui.px(em * 0.4)) }
		}
		if label != "" {
			ui.next({width = ui.text_size(0), height = ui.pct(1), fg = fg, text_pad = 0})
			ui.build_box({.Draw_Text}, fmt.tprintf("%s###txt", label))
		}
		if _, fixed := width.?; fixed { ui.spacer(ui.fill()) } else { ui.spacer(ui.px(pad)) }
	}
	if disabled { sig.clicked = false }
	return sig
}

// A round, icon-only ghost button (the glyph only lights up under the pointer).
glyph_button :: proc(id: string, icon: string, size: f32 = 0, color := Color{}) -> ui.Signal {
	em := ui.font_size()
	sz := size > 0 ? size : math.round(em * 1.8)
	ui.next({width = ui.px(sz), height = ui.px(sz), axis = .X, cross = .Center})
	b := ui.build_box({.Clickable, .Focusable}, id)
	d := ui.frame_new(Bevel_Draw)
	d^ = {kind = .Ghost, radius = 5}
	b.custom = bevel_box_draw
	b.custom_user = d
	sig := ui.signal(b)
	fg := color.a > 0 ? color : hex(HEX_WEAK)
	if sig.hovering { fg = lighten(fg, 0.5) }
	if ui.parent(b) {
		ui.next({width = ui.fill(), height = ui.fill(), font = the_app.icons, font_size = math.round(em * 0.85), fg = fg, text_align = .Center, text_pad = 0})
		ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###g", icon))
	}
	return sig
}

@(private = "file")
Well_Draw :: struct { radius: f32, base: Color, focus: f32 }

@(private = "file")
well_box_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Well_Draw)(user)
	draw_well(dc, b.rect, d.radius * ui.scale(), d.base, d.focus, accent())
}

// `if well("###id", ...) { ... }`: a sunken container (size it with `next`).
@(deferred_none = ui.pop_parent)
well :: proc(id: string, axis := ui.Axis.Y, radius: f32 = 7, base: u32 = 0x070707ff, focus: f32 = 0, flags: ui.Box_Flags = {}) -> bool {
	b := ui.build_box(flags, id)
	b.layout_axis = axis
	d := ui.frame_new(Well_Draw)
	d^ = {radius = radius, base = hex(base), focus = focus}
	b.custom = well_box_draw
	b.custom_user = d
	ui.push_parent(b)
	return true
}

@(private = "file")
Lamp_Draw :: struct { color: Color, lit: f32, pulse: bool }

@(private = "file")
lamp_box_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Lamp_Draw)(user)
	lit := d.lit
	if d.pulse { lit = 0.45 + 0.55 * (0.5 + 0.5 * math.sin(f32(ui.now_ms()) * 0.006)) }
	sz := min(b.rect.max.x - b.rect.min.x, b.rect.max.y - b.rect.min.y)
	draw_lamp(dc, draw.rect_center(b.rect), math.round(sz * 0.62), d.color, lit)
}

// A status lamp in a box of `size` (em fraction of the font size by default).
lamp :: proc(id: string, color: Color, lit: f32 = 1, pulse := false, size: f32 = 0) {
	em := ui.font_size()
	sz := size > 0 ? size : math.round(em * 1.1)
	ui.next({width = ui.px(sz), height = ui.px(sz)})
	b := ui.build_box({}, id)
	d := ui.frame_new(Lamp_Draw)
	d^ = {color = color, lit = lit, pulse = pulse}
	b.custom = lamp_box_draw
	b.custom_user = d
}

// A pip (see draw_pip) in a box of `size`.
pip :: proc(id: string, color: Color, size: f32 = 0) {
	em := ui.font_size()
	sz := size > 0 ? size : math.round(em * 0.8)
	ui.next({width = ui.px(sz), height = ui.px(sz)})
	b := ui.build_box({}, id)
	d := ui.frame_new(Color)
	d^ = color
	b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		sz := min(b.rect.max.x - b.rect.min.x, b.rect.max.y - b.rect.min.y)
		draw_pip(dc, draw.rect_center(b.rect), math.round(sz * 0.6), (^Color)(user)^)
	}
	b.custom_user = d
}

// A scanner: a slot carved in the surface with a glint of `color` sweeping to and fro (work going on, no lamp).
scanner :: proc(id: string, color: Color, width, height: f32) {
	ui.next({width = ui.px(width), height = ui.px(height)})
	b := ui.build_box({}, id)
	d := ui.frame_new(Color)
	d^ = color
	b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		col := (^Color)(user)^
		s := ui.scale()
		r := b.rect
		h := max(3 * s, math.round((r.max.y - r.min.y) * 0.4))
		cy := math.round((r.min.y + r.max.y) * 0.5)
		slot := Rect{{r.min.x, cy - h * 0.5}, {r.max.x, cy + h * 0.5}}
		draw_well(dc, slot, h * 0.5, hex(0x070707ff))
		w := slot.max.x - slot.min.x
		t := 0.5 - 0.5 * math.cos(f32(ui.now_ms()) * 0.0028)   // eased back and forth
		gw := w * 0.28
		x := slot.min.x + (w - gw) * t
		g := Rect{{x, slot.min.y + s}, {x + gw, slot.max.y - s}}
		draw.push_clip(dc, slot)
		if the_app.prefs.glow { draw.box_shadow(dc, g, radii4(h * 0.5), 4 * s, with_alpha(col, 0.22)) }
		draw.rect(dc, g, with_alpha(col, 0.9), h * 0.5)
		draw.pop_clip(dc)
	}
	b.custom_user = d
	the_app.animating = true
}

// A live state as a pulsing lamp, a finished one as a pip.
state_mark :: proc(id: string, color: Color, live: bool, size: f32 = 0) {
	if live { lamp(id, color, 1, pulse = true, size = size); the_app.animating = true } else { pip(id, color, size) }
}

@(private = "file")
groove_box_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	r := b.rect
	if uintptr(user) == 1 {
		x := math.round((r.min.x + r.max.x) * 0.5)
		draw_groove(dc, {x, r.min.y}, {x, r.max.y}, true)
	} else {
		y := math.round((r.min.y + r.max.y) * 0.5) - px1()
		draw_groove(dc, {r.min.x, y}, {r.max.x, y})
	}
}

// A carved separator across the parent (horizontal in a column, vertical in a row).
groove :: proc(id: string = "", thickness: f32 = 0, across := false) {
	p := ui.parent_box()
	t := thickness > 0 ? thickness : 6
	if (p.layout_axis == .Y) != across { ui.next({width = ui.fill(), height = ui.px(t)}) } else { ui.next({width = ui.px(t), height = ui.fill()}) }
	b := ui.build_box({}, id)
	b.custom = groove_box_draw
	b.custom_user = rawptr(uintptr((p.layout_axis == .X) != across ? 1 : 0))
}

// Right after ui.modal opened: the window behind the dialog shows through its scrim, blurred and darkened. (The scrim
// is the box ui.modal builds just before the panel, the current parent.)
dialog_backdrop :: proc() {
	scrim := ui.parent_box().prev
	if scrim == nil { return }
	scrim.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		s := ui.scale()
		draw.backdrop(dc, b.rect, {}, {draw.filter_blur(6 * s)})
		draw.rect(dc, b.rect, {0, 0, 0, 0.45})
	}
}

// The carved line between two regions, in a box exactly as thick as the line (two device pixels at 100%, more when
// scaled): a thinner box let the next region paint over the line's lit half.
edge_line :: proc(id: string, vertical := false) {
	t := ui.px(2 * px1())
	if vertical { ui.next({width = t, height = ui.fill()}) } else { ui.next({width = ui.fill(), height = t}) }
	b := ui.build_box({}, id)
	b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		if b.rect.max.x - b.rect.min.x < b.rect.max.y - b.rect.min.y {
			draw_groove(dc, b.rect.min, {b.rect.min.x, b.rect.max.y}, true)
		} else {
			draw_groove(dc, b.rect.min, {b.rect.max.x, b.rect.min.y})
		}
	}
}

@(private = "file")
Plate_Draw :: struct { radius: f32, top, bottom: Color, border: Color, shadow: f32, rim: f32, glow: Color }

@(private = "file")
plate_box_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Plate_Draw)(user)
	s := ui.scale()
	p := px1()
	r := b.rect
	rad := d.radius * s
	rr := radii4(rad)
	if d.shadow > 0 { draw.box_shadow(dc, draw.rect_shift(r, {0, 2 * s}), rr, d.shadow * s, {0, 0, 0, 0.6}) }
	if d.glow.a > 0 && the_app.prefs.glow { draw.box_shadow(dc, r, rr, 6 * s, with_alpha(d.glow, d.glow.a * 0.5)) }
	draw.rect_corners(dc, r, {d.top, d.bottom, d.top, d.bottom}, rr)
	if d.rim > 0 {
		draw.rect_corners(dc, draw.rect_pad(r, -p), {{1, 1, 1, d.rim}, {1, 1, 1, 0}, {1, 1, 1, d.rim}, {1, 1, 1, 0}}, radii4(max(0, rad - p)), p)
	}
	if d.border.a > 0 { draw.rect(dc, r, d.border, rad, p) }
}

// `if plate("###id", ...) { ... }`: a raised panel (cards, the user's prompt, popover bodies): gradient face, lit rim,
// soft shadow. Size and axis with `next` before it.
@(deferred_none = ui.pop_parent)
plate :: proc(id: string, top: u32 = 0x1b1b1bff, bottom: u32 = 0x141414ff, radius: f32 = 8, shadow: f32 = 6, rim: f32 = 0.07, border: Color = {0, 0, 0, 0.85}, glow := Color{}) -> bool {
	b := ui.build_box({}, id)
	d := ui.frame_new(Plate_Draw)
	d^ = {radius = radius, top = hex(top), bottom = hex(bottom), border = border, shadow = shadow, rim = rim, glow = glow}
	b.custom = plate_box_draw
	b.custom_user = d
	ui.push_parent(b)
	return true
}

// A small pill of text (model names, token counts): a tiny sunken capsule.
pill :: proc(id: string, text: string, color := Color{}, icon := "") {
	em := ui.font_size()
	fs := math.round(em * 0.8)
	ui.next({width = ui.children_sum(), height = ui.px(math.round(em * 1.45)), axis = .X, cross = .Center})
	if well(id, .X, radius = 999, base = 0x0d0d0dff) {
		ui.spacer(ui.px(em * 0.5))
		fg := color.a > 0 ? color : hex(HEX_WEAK)
		if icon != "" {
			ui.next({width = ui.px(em), height = ui.pct(1), font = the_app.icons, font_size = math.round(em * 0.7), fg = fg, text_pad = 0, text_align = .Center})
			ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###i", icon))
			ui.spacer(ui.px(em * 0.25))
		}
		ui.next({width = ui.text_size(0), height = ui.pct(1), font = the_app.mono, font_size = fs, fg = fg, text_pad = 0})
		ui.build_box({.Draw_Text}, fmt.tprintf("%s###t", text))
		ui.spacer(ui.px(em * 0.5))
	}
}

// An icon glyph as a box.
// (a fixed height, not the parent's: in a row sized by its children a percentage is of a distant ancestor, the whole view)
glyph :: proc(icon: string, color: Color, size: f32 = 0, width: f32 = 0) {
	em := ui.font_size()
	ui.next({width = ui.px(width > 0 ? width : em * 1.3), height = ui.px(math.round(max((size > 0 ? size : em * 0.9) * 1.6, em * 1.2))), font = the_app.icons, font_size = size > 0 ? size : math.round(em * 0.9), fg = color, text_pad = 0, text_align = .Center})
	ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###glyph_%s", icon, icon))
}

// A label with a colour and an optional font, as wide as its text.
text :: proc(id: string, s: string, color: Color, f: Maybe(ui.Style_Mod) = nil, width: Maybe(ui.Size) = nil) {
	m := f.? or_else ui.Style_Mod{}
	m.width = width.? or_else ui.text_size(0)
	if m.height == nil {
		// the row's height when the row has one; in a row sized by its children a percentage would be of a distant
		// ancestor (the window): the line's own height there
		p := ui.parent_box()
		m.height = p != nil && p.pref[.Y].kind == .Children_Sum ? ui.text_size(0) : ui.pct(1)
	}
	m.fg = color
	if m.text_pad == nil { m.text_pad = 0 }
	ui.next(m)
	ui.build_box({.Draw_Text}, fmt.tprintf("%s###%s", s, id))
}

@(private = "file")
rail_box_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	c := (^Color)(user)^
	s := ui.scale()
	r := b.rect
	draw.rect(dc, {r.min, {r.min.x + 2.5 * s, r.max.y}}, c, 1.25 * s)
}

// `if rail_row("###id", color) { ... }`: a row as tall as its content with a coloured rail along its left edge
// (quotes, reasoning). Width with `next`.
@(deferred_none = ui.pop_parent)
rail_row :: proc(id: string, color: Color) -> bool {
	b := ui.build_box({}, id)
	b.layout_axis = .X
	c := ui.frame_new(Color)
	c^ = color
	b.custom = rail_box_draw
	b.custom_user = c
	ui.push_parent(b)
	return true
}

