// The look: opencode's dark palette (near-black steps, warm peach accent) with machined surfaces drawn by hand —
// bevelled and ridged buttons, sunken wells, carved grooves, glowing status lamps.
package occ

import "core:fmt"
import "core:math"
import "core:strings"
import "gt:draw"
import "gt:font"
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

// The look's own colours, shared by several files
HEX_PALETTE_BG      :: 0x0c0c0cff
HEX_ON_ACCENT       :: 0x1c120bff   // text on an accent button

// A session's lamp, as a traffic light: the same in every theme (draw.hex, never hex()), they are signals, not decoration.
LAMP_WORKING    :: 0x35d46aff   // green: it works
LAMP_BACKGROUND :: 0xff9a1fff   // orange: at rest, its commands still running
LAMP_WAITS      :: 0xff4b4bff   // red: it waits for the person (a permission, a question)

// A session's lamp, wherever it shows (the sidebar, the home page, the line over the composer): one lamp, lit and glowing a
// little, only its colour says the state (LAMP_*).
session_lamp :: proc(id: string, color: u32, em: f32) { lamp(id, draw.hex(color), size = em * 0.85) }

// The same lamp switched off: its colour (how a session that is over ended), no light around it.
session_lamp_off :: proc(id: string, color: Color, em: f32) { lamp(id, color, size = em * 0.85, halo = false) }
HEX_CODE_BG         :: 0x202020ff
HEX_FLOATING_BG     :: 0x181818ff   // menus, popovers
HEX_FLOATING_BORDER :: 0x333333ff
HEX_BRIGHT          :: 0xffffffff   // text at its brightest: titles, what is selected
HEX_TEXT_SOFT       :: 0xc8c8c8ff   // quiet light text, a step under HEX_TEXT
HEX_ERROR_TEXT      :: 0xf0a0a6ff   // the words of an error (HEX_RED is its mark)
HEX_BTN_FACE        :: 0x2a2a2aff
HEX_BTN_DANGER      :: 0xb8464fff
HEX_BTN_GHOST       :: 0x222222ff   // a ghost button under the pointer
HEX_WELL            :: 0x070707ff
HEX_CODE_WELL       :: 0x060606ff   // code and tool output
HEX_FACTS_WELL      :: 0x0b0b0bff   // key / value lines, a sub-agent's result
HEX_PILL            :: 0x0d0d0dff
HEX_PLATE_TOP       :: 0x1b1b1bff
HEX_PLATE_BOTTOM    :: 0x141414ff

OPENCODE_PALETTE :: ui.Palette{
	bg = HEX_PALETTE_BG, panel = HEX_BG2, panel2 = HEX_BG3, text = HEX_TEXT, weak = HEX_WEAK, border = HEX_LINE,
	accent = HEX_PEACH, accent_text = HEX_ON_ACCENT, good = HEX_GREEN, warn = HEX_YELLOW, bad = HEX_RED, dark = true,
	finish = .Machined, bar = HEX_BG1, well = HEX_WELL,
}

// One of opencode's colours (a HEX_ constant), as the theme shown has it (theme.odin).
hex :: proc(c: u32) -> Color { return draw.hex(themed(c)) }
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
	ui.theme_add(t, "code_bg", hex(HEX_CODE_BG))
	ui.theme_add(t, "link", hex(HEX_BLUE))
	ui.theme_add(t, "floating background", hex(HEX_FLOATING_BG))
	ui.theme_add(t, "floating border", hex(HEX_FLOATING_BORDER))
	ui.theme_add(t, "floating scrim background", CLEAR)   // (dialog_backdrop paints it; "floating background" made it opaque)
	ui.theme_add(t, "selection", with_alpha(hex(HEX_PEACH), SELECTION_ALPHA))
	ui.theme_add(t, "selection text", hex(HEX_BRIGHT))   // (over the selection, whatever the text's own colour: a faint one was lost on it)
	ui.apply_palette(t, themed_palette())
	t.glow = the_app != nil && the_app.prefs.glow ? 1 : 0
}

// The theme shown, in the toolkit's theme: its palette and our entries made of opencode's colours (a theme was chosen).
theme_refresh :: proc(t: ^ui.Theme) {
	ui.theme_set(t, "code_bg", hex(HEX_CODE_BG))
	ui.theme_set(t, "link", hex(HEX_BLUE))
	ui.theme_set(t, "floating background", hex(HEX_FLOATING_BG))
	ui.theme_set(t, "floating border", hex(HEX_FLOATING_BORDER))
	ui.theme_set(t, "selection", with_alpha(hex(HEX_PEACH), SELECTION_ALPHA))
	ui.theme_set(t, "selection text", hex(HEX_BRIGHT))
	ui.apply_palette(t, themed_palette())
	t.glow = the_app != nil && the_app.prefs.glow ? 1 : 0
}

// opencode's palette for the toolkit, as the theme shown has it; flat in the flat style.
themed_palette :: proc() -> ui.Palette {
	p := OPENCODE_PALETTE
	for c in ([]^u32{&p.bg, &p.panel, &p.panel2, &p.text, &p.weak, &p.border, &p.accent, &p.accent_text, &p.good, &p.warn, &p.bad, &p.bar}) { c^ = themed(c^) }
	if the_app != nil && the_app.prefs.flat { p.finish = .Flat }   // (a light version: apply_palette makes it flat)
	p.dark = !theme_light()   // (the toolkit's own marks, the window's buttons among them, light on dark or dark on light)
	return p
}

// The flat style: surfaces plain, edges as thin lines, no reliefs nor halos (appearance.style, or a light version: the
// reliefs are made for the dark). The toolkit's theme says it: its finish is machined or not.
flat :: proc() -> bool { return !ui.machined() }

// The thin edge of a flat surface of this face: the theme's line, lit a little under the pointer.
flat_edge :: proc(face: Color, hot: f32) -> Color { return draw.mix(hex(HEX_LINE), lighten(hex(HEX_LINE), 0.25), hot) }


// The icons: Lucide on every system (assets/fonts/lucide.ttf, embedded: ISC licence, assets/fonts/LUCIDE-LICENSE.txt),
// so they look the same everywhere and nothing depends on the fonts installed.
ICO_ADD      :: "\ue13d"   // plus
ICO_ATTACH   :: "\ue12d"   // paperclip
ICO_BACKGROUND :: "\ue4f3"   // send-to-back
ICO_SEND     :: "\ue4f2"   // send-horizontal
ICO_STOP     :: "\ue167"   // square
ICO_SEARCH   :: "\ue151"   // search
ICO_FOLDER   :: "\ue0d7"   // folder
ICO_DOWN     :: "\ue06d"   // chevron-down
ICO_UP       :: "\ue070"   // chevron-up
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
ICO_WINDOW   :: "\ue426"   // app-window
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
ICO_FORWARD  :: "\ue049"   // arrow-right

// Sizes shared by several files (_EM: in font sizes, _PX: in logical pixels).
BUTTON_H_EM         :: 2.1
BUTTON_COMPACT_H_EM :: 1.9    // in a toolbar or a header
BUTTON_SMALL_H_EM   :: 1.8    // in a row of a list
FIELD_H_EM          :: 2.1    // a one-line field in its well
GLYPH_BUTTON_EM     :: 1.8
PILL_H_EM           :: 1.45
PILL_RADIUS         :: 999    // far beyond half its height: the corners meet
BUTTON_RADIUS       :: 6
GLYPH_BUTTON_RADIUS :: 5
CARD_RADIUS         :: 9      // the plates of the conversation
GROOVE_BOX_PX       :: 6      // the box a groove lies in, thicker than its line
DIALOG_MARGIN_EM    :: 1.4
LINE_HEIGHT_RATIO   :: 1.35   // of the font size
SELECTION_ALPHA     :: 0.28
FADE_VISIBLE        :: 0.01   // a hover or focus fade above this shows on screen

// The type scale, in font sizes: what every label is set in, by its role.
FS_CAPTION  :: 0.72   // timestamps, counts, section labels, pills: what is read last
FS_SMALL    :: 0.78   // details in the mono face, hints, keys and values
FS_NOTE     :: 0.86   // secondary sentences, previews, code
FS_LABEL    :: 0.92   // row titles and text in rows
FS_BODY     :: 1      // what is read: prompts and answers
FS_HEADING  :: 1.12   // the title of a page or a conversation
FS_TITLE    :: 1.3    // the title of a dialog
FS_DISPLAY  :: 1.5
FS_WORDMARK :: 3
// And of the icons (Lucide draws them smaller than their size says).
ICON_TINY    :: 0.6    // disclosure chevrons
ICON_SMALL   :: 0.75   // beside a caption
ICON_REGULAR :: 0.85   // beside a label
ICON_LARGE   :: 1.1    // beside a title

// The animations: phases in radians per millisecond of ui.now_ms.
PULSE_RATE     :: 0.006
PULSE_LIT_MIN  :: 0.45
PULSE_LIT_SPAN :: 0.55
SCANNER_RATE   :: 0.0028

// Something pulses, in the window being built: the next frame soon. (detached_asks tells the loop of a window's.)
animate :: proc(app: ^App) { ui.wake_within(app.cx.built != nil ? app.cx.built : &app.state, ANIMATION_WAIT_MS) }

px1 :: proc() -> f32 { return max(1, math.round(ui.scale())) }

radii4 :: proc(r: f32) -> [4]f32 { return {r, r, r, r} }

// appearance.rounding, for what this program draws itself as the toolkit does for its own boxes: the window being drawn's (0: square).
corners :: proc() -> f32 {
	app := the_app
	if app == nil { return 1 }
	return ui.rounding(app.cx.built != nil ? app.cx.built : &app.state)
}

////////////////////////////////
// Primitives (frame pixels)

// The primitives of the machined look are the toolkit's (ui.machined_*: docs/themes.md); they draw their flat form when
// the finish is not machined (appearance.style flat, or a light version). These give them opencode's corners
// (appearance.rounding).

// A raised, machined surface; pressed, it sinks. `glow`: a halo of that colour under the pointer.
draw_bevel :: proc(dc: ^draw.Context, r: Rect, radius_asked: f32, base: Color, hot, pressed: f32, glow: Color = CLEAR) {
	ui.machined_bevel(dc, r, radius_asked * corners(), base, hot, pressed, glow)
}

// Words that say what can be done are also what does it: quiet like a hint, lit under the pointer. True when clicked.
hint_action :: proc(id, label: string, em: f32, face: font.Font_Id = 0, icon := "") -> bool {
	ui.next({width = ui.children_sum(), height = ui.px(math.round(em * 1.4)), axis = .X, cross = .Center, cursor = .Hand})
	ui.a11y({role = .Button, name = label})
	b := ui.build_box({.Clickable, .Focusable}, id)
	sig := ui.signal(b)
	if ui.parent(b) {
		m := ui.Style_Mod{font_size = math.round(em * (face != 0 ? FS_CAPTION : FS_SMALL))}
		if face != 0 { m.font = face }
		col := sig.hovering ? hex(HEX_BRIGHT) : hex(HEX_FAINT)
		if icon != "" {
			glyph(icon, col, math.round(em * ICON_SMALL))
			ui.spacer(ui.px(em * 0.3))
		}
		text("t", label, col, m)
	}
	return sig.clicked
}

// A sunken well (fields, code, the composer); `focus` lights a ring of `accent` around it.
draw_well :: proc(dc: ^draw.Context, r: Rect, radius_asked: f32, base: Color, focus: f32 = 0, accent := Color{}) {
	ui.machined_well(dc, r, radius_asked * corners(), base, focus, accent)
}

// A carved line.
draw_groove :: proc(dc: ^draw.Context, a, b: Vec2, vertical := false) { ui.machined_groove(dc, a, b, vertical) }

// A status lamp: a glass bead with a halo when lit (`glow`: its halo; < 0: as `lit`).
draw_lamp :: proc(dc: ^draw.Context, c: Vec2, d: f32, col: Color, lit: f32 = 1, glow: f32 = -1) { ui.machined_lamp(dc, c, d, col, lit, glow) }

// A pip: what is over (done, failed, stopped); only what is live gets a glowing lamp, so the lamps stay rare enough to mean
// something.
draw_pip :: proc(dc: ^draw.Context, c: Vec2, d: f32, col: Color) { ui.machined_pip(dc, c, d, col) }

////////////////////////////////
// Boxes painted by those primitives

Btn_Kind :: enum u8 { Normal, Accent, Danger, Ghost, Toggled }

@(private = "file")
Bevel_Draw :: struct { kind: Btn_Kind, radius: f32, lit: bool }   // lit: drawn as under the pointer (its menu is open)

@(private = "file")
bevel_box_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Bevel_Draw)(user)
	held := b.active_t * b.hot_t
	hot := d.lit ? 1 : b.hot_t
	rad := d.radius * ui.scale()
	switch d.kind {
	case .Normal:  draw_bevel(dc, b.rect, rad, hex(HEX_BTN_FACE), hot, held)
	case .Accent:  draw_bevel(dc, b.rect, rad, accent(), hot, held, accent())
	case .Danger:  draw_bevel(dc, b.rect, rad, hex(HEX_BTN_DANGER), hot, held, hex(HEX_RED))
	case .Toggled: draw_bevel(dc, b.rect, rad, hex(HEX_BTN_FACE), hot, 1)
	case .Ghost:
		if hot > FADE_VISIBLE || held > FADE_VISIBLE { draw_bevel(dc, b.rect, rad, hex(HEX_BTN_GHOST), hot, held) }
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
	// clear of the scroll bar a scrolling dialog has along its right edge
	right := math.round(em * 1.4)
	ui.next({fixed_x = w - sz - right, fixed_y = m, width = ui.px(sz), height = ui.px(sz), axis = .X, cross = .Center})
	ui.a11y({role = .Button, name = "Close"})
	b := ui.build_box({.Clickable, .Focusable}, "###dialog_close")
	d := ui.frame_new(Bevel_Draw)
	d^ = {kind = .Ghost, radius = GLYPH_BUTTON_RADIUS}
	b.custom, b.custom_user = bevel_box_draw, d
	sig := ui.signal(b)
	if ui.parent(b) {
		ui.next({width = ui.fill(), height = ui.fill(), font = the_app.icons, font_size = math.round(em * ICON_REGULAR), fg = sig.hovering ? hex(HEX_TEXT) : hex(HEX_WEAK), text_align = .Center, text_pad = 0})
		ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###g", ICO_CANCEL))
	}
	if sig.clicked { open^ = false }
}

// A machined push button: an icon (Lucide glyph) and/or a label. `width`: its width (text size by default).
// `lit`: shown as under the pointer, as long as what it opened is open (a menu, a picker).
// `wrap`: a label longer than the button's width goes on more lines and the button grows to hold them (it is `height`
// tall on one line); else it is one line, as wide as its text.
bevel_button :: proc(id: string, label: string, icon := "", kind := Btn_Kind.Normal, width: Maybe(ui.Size) = nil, height: f32 = 0, disabled := false, left := false, quiet := false, wrap := false, lit := false) -> ui.Signal {
	em := ui.font_size()
	h := height > 0 ? height : math.round(em * BUTTON_H_EM)
	fg := kind == .Accent ? hex(HEX_ON_ACCENT) : kind == .Danger ? WHITE : hex(HEX_TEXT)
	if disabled { fg = hex(HEX_FAINT) }
	ui.next({width = width.? or_else ui.children_sum(), height = wrap ? ui.children_sum() : ui.px(h), axis = .X, cross = .Center})
	flags: ui.Box_Flags = {.Clickable, .Focusable}
	if disabled { flags = {} }
	b := ui.build_box(flags, id)
	d := ui.frame_new(Bevel_Draw)
	d^ = {kind = disabled ? .Ghost : kind, radius = BUTTON_RADIUS, lit = lit && !disabled}
	b.custom = bevel_box_draw
	b.custom_user = d
	sig := ui.signal(b)
	if quiet && !disabled { fg = sig.hovering || lit ? hex(HEX_TEXT) : hex(HEX_WEAK) }   // (a secondary action: lit only under the pointer)
	if ui.parent(b) {
		pad := label != "" ? em * 0.75 : em * 0.55
		if _, fixed := width.?; fixed && !left { ui.spacer(ui.fill()) } else { ui.spacer(ui.px(left ? em * 0.8 : pad)) }
		if icon != "" {
			ui.next({width = ui.px(em * 1.25), height = ui.pct(1), font = the_app.icons, font_size = math.round(em * ICON_REGULAR), fg = fg, text_align = .Center, text_pad = 0})
			ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###ico", icon))
			if label != "" { ui.spacer(ui.px(em * 0.4)) }
		}
		if label != "" && wrap {
			// (the lines between margins that make one line `h` tall)
			fs := quiet ? math.round(em * FS_NOTE) : em
			margin := max(math.round((h - math.ceil(font.metrics(&the_app.fonts, the_app.font, fs).line_height)) * 0.5), 0)
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column() {
				ui.spacer(ui.px(margin))
				ui.next({width = ui.fill(), fg = fg, text_pad = 0, font_size = fs})
				ui.paragraph(fmt.tprintf("%s###txt", label_safe(label)))
				ui.spacer(ui.px(margin))
			}
		} else if label != "" {
			ui.next({width = ui.text_size(0), height = ui.pct(1), fg = fg, text_pad = 0, font_size = quiet ? math.round(em * FS_NOTE) : em})
			ui.build_box({.Draw_Text}, fmt.tprintf("%s###txt", label_safe(label)))
		}
		if _, fixed := width.?; fixed && !wrap { ui.spacer(ui.fill()) } else { ui.spacer(ui.px(pad)) }
	}
	if disabled { sig.clicked = false }
	return sig
}

// A round, icon-only ghost button (the glyph only lights up under the pointer).
glyph_button :: proc(id: string, icon: string, size: f32 = 0, color := Color{}) -> ui.Signal {
	em := ui.font_size()
	sz := size > 0 ? size : math.round(em * GLYPH_BUTTON_EM)
	ui.next({width = ui.px(sz), height = ui.px(sz), axis = .X, cross = .Center})
	b := ui.build_box({.Clickable, .Focusable}, id)
	d := ui.frame_new(Bevel_Draw)
	d^ = {kind = .Ghost, radius = GLYPH_BUTTON_RADIUS}
	b.custom = bevel_box_draw
	b.custom_user = d
	sig := ui.signal(b)
	fg := color.a > 0 ? color : hex(HEX_WEAK)
	if sig.hovering { fg = lighten(fg, 0.5) }
	if ui.parent(b) {
		ui.next({width = ui.fill(), height = ui.fill(), font = the_app.icons, font_size = math.round(em * ICON_REGULAR), fg = fg, text_align = .Center, text_pad = 0})
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
well :: proc(id: string, axis := ui.Axis.Y, radius: f32 = 7, base: u32 = HEX_WELL, focus: f32 = 0, flags: ui.Box_Flags = {}) -> bool {
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
Lamp_Draw :: struct { color: Color, lit: f32, pulse: bool, halo: bool }

@(private = "file")
lamp_box_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Lamp_Draw)(user)
	glow: f32 = d.halo ? -1 : 0   // (no halo: the same lamp, unlit around)
	if d.pulse && d.halo { glow = PULSE_LIT_MIN + PULSE_LIT_SPAN * (0.5 + 0.5 * math.sin(f32(ui.now_ms()) * PULSE_RATE)) }   // (lit as a steady one; its halo breathes)
	sz := min(b.rect.max.x - b.rect.min.x, b.rect.max.y - b.rect.min.y)
	draw_lamp(dc, draw.rect_center(b.rect), math.round(sz * 0.62), d.color, d.lit, glow)
}

// A status lamp in a box of `size` (em fraction of the font size by default).
lamp :: proc(id: string, color: Color, lit: f32 = 1, pulse := false, size: f32 = 0, halo := true) {
	em := ui.font_size()
	sz := size > 0 ? size : math.round(em * 1.1)
	ui.next({width = ui.px(sz), height = ui.px(sz)})
	b := ui.build_box({}, id)
	d := ui.frame_new(Lamp_Draw)
	d^ = {color = color, lit = lit, pulse = pulse, halo = halo}
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
		draw_well(dc, slot, h * 0.5, hex(HEX_WELL))
		w := slot.max.x - slot.min.x
		t := 0.5 - 0.5 * math.cos(f32(ui.now_ms()) * SCANNER_RATE)   // eased back and forth
		gw := w * 0.28
		x := slot.min.x + (w - gw) * t
		g := Rect{{x, slot.min.y + s}, {x + gw, slot.max.y - s}}
		draw.push_clip(dc, slot)
		if the_app.prefs.glow { draw.box_shadow(dc, g, radii4(h * 0.5), 4 * s, with_alpha(col, 0.22)) }
		draw.rect(dc, g, with_alpha(col, 0.9), h * 0.5)
		draw.pop_clip(dc)
	}
	b.custom_user = d
	animate(the_app)
}

// A live state as a pulsing lamp, a finished one as a pip.
state_mark :: proc(id: string, color: Color, live: bool, size: f32 = 0) {
	if live { lamp(id, color, 1, pulse = true, size = size); animate(the_app) } else { pip(id, color, size) }
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
	t := thickness > 0 ? thickness : GROOVE_BOX_PX
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
	ui.machined_plate(dc, b.rect, d.radius * ui.scale() * corners(), d.top, d.bottom, d.shadow, d.rim, d.border, d.glow)
}

// `if plate("###id", ...) { ... }`: a raised panel (cards, the user's prompt, popover bodies): gradient face, lit rim,
// soft shadow. Size and axis with `next` before it.
@(deferred_none = ui.pop_parent)
plate :: proc(id: string, top: u32 = HEX_PLATE_TOP, bottom: u32 = HEX_PLATE_BOTTOM, radius: f32 = 8, shadow: f32 = 6, rim: f32 = 0.07, border: Color = {0, 0, 0, 0.85}, glow := Color{}) -> bool {
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
	fs := math.round(em * FS_SMALL)
	ui.next({width = ui.children_sum(), height = ui.px(math.round(em * PILL_H_EM)), axis = .X, cross = .Center})
	if well(id, .X, radius = PILL_RADIUS, base = HEX_PILL) {
		ui.spacer(ui.px(em * 0.5))
		fg := color.a > 0 ? color : hex(HEX_WEAK)
		if icon != "" {
			ui.next({width = ui.px(em), height = ui.pct(1), font = the_app.icons, font_size = math.round(em * ICON_SMALL), fg = fg, text_pad = 0, text_align = .Center})
			ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###i", icon))
			ui.spacer(ui.px(em * 0.25))
		}
		ui.next({width = ui.text_size(0), height = ui.pct(1), font = the_app.mono, font_size = fs, fg = fg, text_pad = 0})
		ui.build_box({.Draw_Text}, fmt.tprintf("%s###t", label_safe(text)))
		ui.spacer(ui.px(em * 0.5))
	}
}

// An icon glyph as a box.
// (a fixed height, not the parent's: in a row sized by its children a percentage is of a distant ancestor, the whole view)
glyph :: proc(icon: string, color: Color, size: f32 = 0, width: f32 = 0) {
	em := ui.font_size()
	ui.next({width = ui.px(width > 0 ? width : em * 1.3), height = ui.px(math.round(max((size > 0 ? size : em * ICON_REGULAR) * 1.6, em * 1.2))), font = the_app.icons, font_size = size > 0 ? size : math.round(em * ICON_REGULAR), fg = color, text_pad = 0, text_align = .Center})
	ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###glyph_%s", icon, icon))
}

// Text from elsewhere in a box's id: the toolkit's id rules cut it at its first "##", so a zero-width space parts them.
label_safe :: proc(s: string) -> string {
	if !strings.contains(s, "##") { return s }
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(s) {
		strings.write_byte(&b, s[i])
		if s[i] == '#' && i + 1 < len(s) && s[i + 1] == '#' { strings.write_string(&b, "\u200b") }
	}
	return strings.to_string(b)
}

// A label with a colour and an optional font, as wide as its text.
text :: proc(id: string, s: string, color: Color, f: Maybe(ui.Style_Mod) = nil, width: Maybe(ui.Size) = nil) {
	m := f.? or_else ui.Style_Mod{}
	m.width = width.? or_else ui.text_size(0)
	if m.height == nil { m.height = ui.pct(1) }
	m.fg = color
	if m.text_pad == nil { m.text_pad = 0 }
	ui.next(m)
	ui.build_box({.Draw_Text}, fmt.tprintf("%s###%s", label_safe(s), id))
}

// A key / value line in a mono face; each panel has its own sizes (in font sizes).
Kv_Row :: struct { h, key_w, key_fs, val_fs, pad_l, pad_r: f32, val: u32 }

kv_row :: proc(id, k, v: string, em: f32, st: Kv_Row, col := Color{}) {
	ui.next({width = ui.fill(), height = ui.px(em * st.h), axis = .X, cross = .Center})
	if ui.row(.Center, id = id) {
		if st.pad_l > 0 { ui.spacer(ui.px(em * st.pad_l)) }
		text("k", k, hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * st.key_fs)}, ui.px(em * st.key_w))
		text("v", v, col.a > 0 ? col : hex(st.val), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * st.val_fs)}, ui.fill())
		if st.pad_r > 0 { ui.spacer(ui.px(em * st.pad_r)) }
	}
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


////////////////////////////////
// A choice of a few: a sunken track, the one chosen on a small raised plate that slides to it, its word lit, the others quiet.

@(private = "file")
Choice_Draw :: struct { t: f32, n: int, pad: f32 }

@(private = "file")
choice_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Choice_Draw)(user)
	r := b.rect
	radius := (r.max.y - r.min.y) * CHOICE_RADIUS_SHARE / ui.scale()
	draw_well(dc, r, radius, hex(HEX_WELL))
	if d.n <= 0 { return }
	w := (r.max.x - r.min.x - 2 * d.pad) / f32(d.n)
	x := r.min.x + d.pad + d.t * w
	plate := Rect{{math.round(x), r.min.y + d.pad}, {math.round(x + w), r.max.y - d.pad}}
	draw_bevel(dc, plate, max(0, radius - d.pad / ui.scale()), hex(HEX_BTN_FACE), 0, 0)
}

// `if choice(id, labels, &sel)`: true when another was chosen. Size it with `next` before it.
choice :: proc(id: string, labels: []string, selected: ^int) -> (changed: bool) {
	em := ui.font_size()
	t := ui.anim(ui.key_from_string(ui.parent_box().key, fmt.tprintf("%s_t", id)), f32(selected^), CHOICE_RATE, f32(selected^))
	pad := math.round(em * CHOICE_PAD_EM)
	b := ui.build_box({}, id)   // (sized by the caller's next; its row inside)
	d := ui.frame_new(Choice_Draw)
	d^ = {t, len(labels), pad}
	b.custom, b.custom_user = choice_draw, d
	ui.a11y_default(b, {role = .Radio_Group, orientation = .X})
	if ui.parent(b) {
		ui.next({width = ui.pct(1), height = ui.pct(1), axis = .X})
		if ui.row(id = "###r") {
		ui.spacer(ui.px(pad))
		for label, i in labels {
			ui.next({width = ui.fill(), height = ui.pct(1), text_align = .Center, cursor = .Hand})   // (equal shares of what the pads leave)
			item := ui.build_box({.Clickable, .Focusable, .Draw_Text}, fmt.tprintf("%s###ch%d", label, i))
			sig := ui.signal(item)
			item.text_color = i == selected^ ? hex(HEX_BRIGHT) : sig.hovering ? hex(HEX_TEXT) : hex(HEX_WEAK)
			if sig.clicked && i != selected^ { selected^ = i; changed = true }
			ui.a11y_default(item, {role = .Radio_Button, toggled = i == selected^ ? .True : .False, position = i + 1, set_size = len(labels)})
		}
		ui.spacer(ui.px(pad))
		}
	}
	return
}

////////////////////////////////
// What is chosen in a list (ui.contrast and ui.readable keep the words on it read)

// The ground of what is chosen in a list (the session shown). Dark: the raised step's lightness, a little of the accent's hue and
// chroma (OKLCH: as much colour whatever the accent's own lightness, never a muddy brown). Light: the sidebar's ground a little darker,
// its own hue and chroma: a pale accent, or a neutral of less colour than what is around it, would read as another colour. Words on it go through readable.
chosen_ground :: proc() -> Color {
	base := ui.to_oklch(hex(HEX_BG3))
	if theme_light() {   // (light: the ground it lies on, a step darker, its hue and chroma kept. A pale accent reads as another colour, an orange
		// as pink; and a neutral of less colour than that ground, as its opposite: on Gruvbox's yellow, a blue)
		under := ui.to_oklch(hex(HEX_BG1))
		return ui.from_oklch({clamp(under[0] - CHOSEN_LIGHTNESS_LIGHT, 0, 1), under[1], under[2]})
	}
	acc := ui.to_oklch(accent())
	return ui.from_oklch({clamp(base[0] + CHOSEN_LIGHTNESS, 0, 1), CHOSEN_CHROMA, acc[2]})
}
