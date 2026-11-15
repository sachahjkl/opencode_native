// The look: opencode's dark palette (near-black steps, warm peach accent) with machined surfaces drawn by hand —
// bevelled and ridged buttons, sunken wells, carved grooves, glowing status lamps.
package ocn

import "core:fmt"
import "core:math"
import "core:strings"
import "gt:draw"
import "gt:font"
import "gt:ui"

Color :: draw.Color
Rect :: draw.Rect
Vec2 :: draw.Vec2

// A session's lamp, as a traffic light: the same in every theme (draw.hex, never hex()), they are signals, not decoration.
LAMP_WORKING    :: 0x35d46aff   // green: it works
LAMP_BACKGROUND :: 0xff9a1fff   // orange: at rest, its commands still running
LAMP_WAITS      :: 0xff4b4bff   // red: it waits for the person (a permission, a question)

// A session's lamp, wherever it shows (the sidebar, the home page, the line over the composer): one lamp, lit and glowing a
// little, only its colour says the state (LAMP_*).
session_lamp :: proc(id: string, color: u32, em: f32) { lamp(id, draw.hex(color), size = em * 0.85) }

// The same lamp switched off: its colour (how a session that is over ended), no light around it.
session_lamp_off :: proc(id: string, color: Color, em: f32) { lamp(id, color, size = em * 0.85, halo = false) }
BLACK :: Color{0, 0, 0, 1}
WHITE :: Color{1, 1, 1, 1}
CLEAR :: Color{0, 0, 0, 0}


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
	ui.theme_add(t, "floating scrim background", CLEAR)   // (dialog_backdrop paints it; "floating background" made it opaque)
	theme_entries(t, false)
	ui.apply_palette(t, themed_palette())
	t.glow = the_app != nil && the_app.prefs.glow ? 1 : 0
}

// A text 70 % of the way from the theme's weak text to its text: tool output, quiet labels (the palette has two texts).
SOFT_TEXT_STEP :: 0.7

// The entries the toolkit's palette lacks, made from the version shown (src/md/features/colours.md): ahead of the palette's,
// those of a kind before the plain ones (the first of two equal patterns wins). `set`: a theme was chosen, they are there.
@(private = "file")
theme_entries :: proc(t: ^ui.Theme, set: bool) {
	c := theme_colors()
	page, line := draw.hex(c.steps[1]), draw.hex(c.steps[5])
	faint, weak, text, bright := draw.hex(c.texts[0]), draw.hex(c.texts[1]), draw.hex(c.texts[2]), draw.hex(c.texts[3])
	accent, blue, green, red := draw.hex(c.hues[0]), draw.hex(c.hues[1]), draw.hex(c.hues[3]), draw.hex(c.hues[5])
	soft := ui.srgb_step(weak, text, SOFT_TEXT_STEP)
	Entry :: struct { tags: string, c: Color }
	entries := [?]Entry{
		{"faint text", faint}, {"soft text", soft}, {"bright text", bright},
		{"link", blue},
		{"selection", ui.with_alpha(accent, SELECTION_ALPHA)},
		{"selection text", bright},   // (over the selection, whatever the text's own colour: a faint one was lost on it)
		// a diff (gt:diff): a line on a tint of its hue over the page, what changed in it on a stronger one, its words tinted
		{"diff_added background", ui.srgb_step(page, green, 0.12)}, {"diff_removed background", ui.srgb_step(page, red, 0.13)},
		{"diff_added mark", ui.srgb_step(page, green, 0.33)}, {"diff_removed mark", ui.srgb_step(page, red, 0.4)},
		{"diff_added text", ui.srgb_step(text, green, 0.25)}, {"diff_removed text", ui.srgb_step(text, red, 0.25)},
		{"diff_added sign", green}, {"diff_removed sign", red},
		{"diff text", soft}, {"diff sign", faint}, {"diff mark_text", bright},
		{"diff line_number", ui.srgb_step(line, faint, 0.67)}, {"diff gap", faint}, {"diff divider", faint},
	}
	for e in entries {
		if set { ui.theme_set(t, e.tags, e.c) } else { ui.theme_add(t, e.tags, e.c) }
	}
}

// The theme shown, in the toolkit's theme: its palette and our entries (a theme was chosen).
theme_refresh :: proc(t: ^ui.Theme) {
	theme_entries(t, true)
	ui.apply_palette(t, themed_palette())
	t.glow = the_app != nil && the_app.prefs.glow ? 1 : 0
}

// The toolkit's palette of the theme shown, in the finish asked for (unless the theme is made for one: Kernel, edged); a light
// version: apply_palette draws the reliefs by their light.
themed_palette :: proc() -> ui.Palette {
	app := the_app
	if app == nil { return ui.theme_palette(THEME_OPENCODE, false, .Machined) }
	all := themes(app)
	def := app.cx.theme.at < len(all) ? all[app.cx.theme.at] : THEME_OPENCODE
	return ui.theme_palette(def, app.cx.theme.light, app.prefs.finish)
}

// The flat style: surfaces plain, edges as thin lines, no reliefs nor halos (appearance.style, or a light version: the
// reliefs are made for the dark). The toolkit's theme says it: its finish is machined or not.
flat :: proc() -> bool { return !ui.machined() }

// The thin edge of a flat surface of this face: the theme's line, lit a little under the pointer.
flat_edge :: proc(face: Color, hot: f32) -> Color { return draw.mix(themed("border"), ui.lighten(themed("border"), 0.25), hot) }



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

// Something pulses, in the window being built: the next frame soon. (A view's window counts in the loop's wait: hosts_wait.)
animate :: proc(app: ^App) { ui.wake_within(built_state(app), ANIMATION_WAIT_MS) }

px1 :: proc() -> f32 { return max(1, math.round(ui.scale())) }

radii4 :: proc(r: f32) -> [4]f32 { return {r, r, r, r} }

// appearance.rounding, for what this program draws itself as the toolkit does for its own boxes. (A view's window follows
// the main window's rounding: ui.style_follow.)
corners :: proc() -> f32 {
	app := the_app
	if app == nil { return 1 }
	return ui.rounding(built_state(app))
}

////////////////////////////////
// Primitives (frame pixels)

// The primitives of the machined look are the toolkit's (ui.machined_*: docs/themes.md); they draw their flat form when
// the finish is not machined (appearance.style flat, or a light version). These give them opencode's corners
// (appearance.rounding).

// A raised, machined surface; pressed, it sinks. `glow`: a halo of that colour under the pointer.
// `drawn`: the radius is as drawn already (a control in a corner the toolkit drew), not one the rounding scales.
draw_bevel :: proc(dc: ^draw.Context, r: Rect, radius_asked: f32, base: Color, hot, pressed: f32, glow: Color = CLEAR, drawn := false) {
	ui.machined_bevel(dc, r, drawn ? radius_asked : radius_asked * corners(), base, hot, pressed, glow)
}

// A Link button (ui.button) in this program's hints' face: small, in `face` (the mono face for keys) when given. True when clicked.
hint_action :: proc(id, label: string, em: f32, face: font.Font_Id = 0, icon := "", intent := ui.Intent.Neutral) -> bool {
	m := ui.Style_Mod{font_size = math.round(em * (face != 0 ? FS_CAPTION : FS_SMALL))}
	if face != 0 { m.font = face }
	if ui.style(m) { return ui.button(id, label, icon, {intent = intent, face = .Link}).clicked }
	return false
}

// A sunken well drawn by hand (code, a meter, a selected row); `focus` lights a ring of `accent` around it.
draw_well :: proc(dc: ^draw.Context, r: Rect, radius_asked: f32, base: Color, focus: f32 = 0, accent := Color{}) {
	ui.machined_well(dc, r, radius_asked * corners(), base, focus, accent)
}

// A carved line.
draw_groove :: proc(dc: ^draw.Context, a, b: Vec2, vertical := false) { ui.machined_groove(dc, a, b, vertical) }

// A status lamp: a glass bead with a halo when lit (`glow`: its halo; < 0: as `lit`).
draw_lamp :: proc(dc: ^draw.Context, c: Vec2, d: f32, col: Color, lit: f32 = 1, glow: f32 = -1) { ui.machined_lamp(dc, c, d, col, lit, glow) }

// A pip: a state at rest (connected, nothing known); only what is live gets a glowing lamp, so the lamps stay rare enough
// to mean something. (What ended has its sign: state_mark.)
draw_pip :: proc(dc: ^draw.Context, c: Vec2, d: f32, col: Color) { ui.machined_pip(dc, c, d, col) }

////////////////////////////////
// Boxes painted by those primitives

// The face, the words and the halo of a thing that says `intent` (a sub-agent's state, a queue's act): the toolkit's soft pair
// of its hue (the same in every theme, light or dark), or this look's plain face (Neutral). Read while it is built: soft_pair
// reads the page.
intent_colors :: proc(intent: ui.Intent) -> (fill, ink, glow: Color) {
	if intent == .Neutral { return themed("button background"), themed("text"), CLEAR }
	glow = ui.hue_color(ui.intent_hue(intent))
	glow.a = 1
	fill, ink = ui.soft_pair(glow)
	return
}

@(private = "file")
Well_Draw :: struct { radius: f32, base: Color }

@(private = "file")
well_box_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Well_Draw)(user)
	draw_well(dc, b.rect, d.radius * ui.scale(), d.base)
}

// Paints `b` as a well of the theme: for a box another builds (the Markdown package's frames).
well_paint :: proc(b: ^ui.Box, radius: f32 = 7) {
	d := ui.frame_new(Well_Draw)
	d^ = {radius = radius, base = themed("well")}
	b.custom = well_box_draw
	b.custom_user = d
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
		draw_well(dc, slot, h * 0.5, themed("well"))
		w := slot.max.x - slot.min.x
		t := 0.5 - 0.5 * math.cos(f32(ui.now_ms()) * SCANNER_RATE)   // eased back and forth
		gw := w * 0.28
		x := slot.min.x + (w - gw) * t
		g := Rect{{x, slot.min.y + s}, {x + gw, slot.max.y - s}}
		draw.push_clip(dc, slot)
		if the_app.prefs.glow { draw.box_shadow(dc, g, radii4(h * 0.5), 4 * s, ui.with_alpha(col, 0.22)) }
		draw.rect(dc, g, ui.with_alpha(col, 0.9), h * 0.5)
		draw.pop_clip(dc)
	}
	b.custom_user = d
	animate(the_app)
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

// First in a view shown as a dialog (view_backdrop): the window behind it shows through its scrim, blurred and darkened.
// (The scrim is the box the dialog builds just before its panel, the current parent.)
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
// soft shadow. Size and axis with `next` before it. `top`, `bottom` zero: a face around the theme's cards.
@(deferred_none = ui.pop_parent)
plate :: proc(id: string, top: Color = {}, bottom: Color = {}, radius: f32 = 8, shadow: f32 = 6, rim: f32 = 0.07, border: Color = {0, 0, 0, 0.85}, glow := Color{}) -> bool {
	b := ui.build_box({}, id)
	d := ui.frame_new(Plate_Draw)
	face_top := top != {} ? top : between("card background", "button background", 0.6)
	face_bottom := bottom != {} ? bottom : between("bar background", "card background", 0.67)
	d^ = {radius = radius, top = face_top, bottom = face_bottom, border = border, shadow = shadow, rim = rim, glow = glow}
	b.custom = plate_box_draw
	b.custom_user = d
	ui.push_parent(b)
	return true
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
// `text` whose changes morph (ui.morph_label): the characters that differ flip into the new ones, its width the new
// text's at once. For a value another source replaces (the status bar's at a server switch).
morph_text :: proc(id: string, s: string, color: Color, f: Maybe(ui.Style_Mod) = nil) {
	m := f.? or_else ui.Style_Mod{}
	if m.height == nil { m.height = ui.pct(1) }
	m.fg = color
	if m.text_pad == nil { m.text_pad = 0 }
	ui.next(m)
	ui.morph_label(fmt.tprintf("%s###%s", label_safe(s), id))
}

text :: proc(id: string, s: string, color: Color, f: Maybe(ui.Style_Mod) = nil, width: Maybe(ui.Size) = nil) {
	m := f.? or_else ui.Style_Mod{}
	m.width = width.? or_else ui.text_size(0)
	if m.height == nil { m.height = ui.pct(1) }
	m.fg = color
	if m.text_pad == nil { m.text_pad = 0 }
	ui.next(m)
	ui.build_box({.Draw_Text}, fmt.tprintf("%s###%s", label_safe(s), id))
}

// `text`, its parts that `query`'s words find lit (each word where it is in `s`, in any case: a word that is in another field of
// what was searched, not here, lights nothing). An empty query: `text`.
text_found :: proc(id: string, s: string, query: string, color: Color, f: Maybe(ui.Style_Mod) = nil, width: Maybe(ui.Size) = nil) {
	ranges := make([dynamic]ui.Fuzzy_Range, context.temp_allocator)
	for word in strings.fields(query, context.temp_allocator) {
		if r, ok := ui.fuzzy_find(word, s); ok { append(&ranges, ..r) }
	}
	if len(ranges) == 0 { text(id, s, color, f, width); return }
	m := f.? or_else ui.Style_Mod{}
	m.width = width.? or_else ui.text_size(0)
	if m.height == nil { m.height = ui.pct(1) }
	m.fg = color
	if m.text_pad == nil { m.text_pad = 0 }
	ui.next(m)
	ui.label_fuzzy(fmt.tprintf("%s###%s", label_safe(s), id), ranges[:])
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
// What is chosen in a list (ui.contrast and ui.readable keep the words on it read)

// The ground of what is chosen in a list (the session shown). Dark: the raised step's lightness, a little of the accent's hue and
// chroma (OKLCH: as much colour whatever the accent's own lightness, never a muddy brown). Light: the sidebar's ground a little darker,
// its own hue and chroma: a pale accent, or a neutral of less colour than what is around it, would read as another colour. Words on it go through readable.
chosen_ground :: proc() -> Color {
	c := theme_colors()   // (read in a test with no interface: the theme's own colours)
	base := ui.to_oklch(draw.hex(c.steps[4]))
	if theme_light() {   // (light: the ground it lies on, a step darker, its hue and chroma kept. A pale accent reads as another colour, an orange
		// as pink; and a neutral of less colour than that ground, as its opposite: on Gruvbox's yellow, a blue)
		under := ui.to_oklch(draw.hex(c.steps[2]))
		return ui.from_oklch({clamp(under[0] - CHOSEN_LIGHTNESS_LIGHT, 0, 1), under[1], under[2]})
	}
	acc := ui.to_oklch(draw.hex(c.hues[0]))
	return ui.from_oklch({clamp(base[0] + CHOSEN_LIGHTNESS, 0, 1), CHOSEN_CHROMA, acc[2]})
}
