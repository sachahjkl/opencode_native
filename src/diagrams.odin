// Mermaid diagrams in the conversation: a ```mermaid block is drawn as its diagram (the toolkit's mermaid and svg packages: laid
// out by mermaid-svg in native/ocn_native, drawn with the interface's paths and fonts), with a button to see its text. While the
// block is still being written, or when its text is no diagram, the text shows, with why.
package ocn

import "core:fmt"
import "core:hash"
import "core:math"
import "core:strings"
import "gt:draw"
import "gt:font"
import mermaid "gt:mermaid"
import svg "gt:svg"
import "gt:ui"
import lucide "gt:lucide"

// A diagram laid out once for its text and the theme's lightness, kept while it is shown (DIAGRAMS_KEPT at most, the least
// recently drawn going first).
Diagram :: struct {
	doc:  svg.Document,
	why:  string,   // not a diagram: what mermaid says (owned)
	used: u64,      // the build it was last shown in
}

DIAGRAMS_KEPT :: 32
// Mermaid draws its text at 14 px: at the conversation's size it is as large as the text around it, never wider than the column.
DIAGRAM_FONT_PX :: 14

@(private = "file")
diagram_of :: proc(app: ^App, code: string, dark: bool) -> ^Diagram {
	key := hash.fnv64a(transmute([]u8)code) ~ (dark ? 1 : 0)
	m := &app.cx.diagrams
	if m^ == nil { m^ = make(map[u64]Diagram) }
	if d, ok := &m[key]; ok {
		d.used = app.state.build_index
		return d
	}
	if len(m) >= DIAGRAMS_KEPT { diagrams_trim(app) }
	doc, why := mermaid.diagram(code, dark)
	m[key] = Diagram{doc = doc, why = strings.clone(why), used = app.state.build_index}
	return &m[key]
}

@(private = "file")
diagrams_trim :: proc(app: ^App) {
	oldest: u64
	first := true
	for k, d in app.cx.diagrams {
		if first || d.used < app.cx.diagrams[oldest].used { oldest, first = k, false }
	}
	if first { return }
	d := app.cx.diagrams[oldest]
	svg.destroy(&d.doc)
	delete(d.why)
	delete_key(&app.cx.diagrams, oldest)
}

diagrams_free :: proc(app: ^App) {
	for _, &d in app.cx.diagrams { svg.destroy(&d.doc); delete(d.why) }
	delete(app.cx.diagrams)
	app.cx.diagrams = nil
}

// A ```mermaid block: its diagram, or its text (the header's button; still being written; not a diagram).
mermaid_block :: proc(id, code: string, closed: bool, version: u64) {
	app := the_app
	em := ui.font_size()
	k := hash.fnv64a(transmute([]u8)id)
	as_text := app.expanded[k] or_else false
	d: ^Diagram
	if closed && !as_text { d = diagram_of(app, code, !app.cx.theme.light) }
	ok := d != nil && d.why == ""
	ui.next({width = ui.fill(), height = ui.children_sum()})
	if well(id, radius = 6, base = HEX_CODE_WELL) {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###hdr") {
			ui.spacer(ui.px(em * 0.7))
			glyph(lucide.GIT_FORK, hex(HEX_FAINT), math.round(em * ICON_SMALL), em)
			ui.spacer(ui.px(em * 0.3))
			text("lang", "mermaid", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
			if d != nil && d.why != "" {
				ui.spacer(ui.px(em * 0.6))
				text("why", fmt.tprintf("not a diagram: %s", first_line(d.why)), hex(HEX_YELLOW), ui.Style_Mod{font_size = math.round(em * FS_SMALL)}, ui.fill())
			} else {
				ui.spacer(ui.fill())
			}
			if closed && (d == nil || d.why == "") {   // (what is no diagram shows its text already)
				ui.a11y({role = .Button, name = as_text ? "Show the diagram" : "Show its text"})
				sig := glyph_button("###as_text", as_text ? lucide.GIT_FORK : lucide.CODE, math.round(em * 1.6))
				if sig.clicked { app.expanded[k] = !as_text }
				if ui.hovered_for(sig, TOOLTIP_DELAY_S) { if ui.tooltip() { ui.tooltip_text(as_text ? "Show the diagram" : "Show its text") } }
			}
			if glyph_button("###copy", lucide.COPY, math.round(em * 1.6)).clicked {
				clip_set(code)
				ui.toast(.Good, "Copied")
			}
			ui.spacer(ui.px(em * 0.3))
		}
		ui.next({width = ui.fill(), height = ui.px(2)})
		ui.build_box({}, "")
		if ok {
			diagram_box(app, &d.doc, em)
		} else {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(id = "###body") {
				ui.spacer(ui.px(em * 0.9))
				runs := [1]ui.Rich_Run{{text = code, style = {font = app.mono, color = hex(HEX_CODE_TEXT)}}}
				ui.next({width = ui.fill(), font_size = math.round(em * FS_NOTE), flags = {.Selectable}})
				ui.rich_paragraph("###code", runs[:], version = version)
				ui.spacer(ui.px(em * 0.9))
			}
		}
		ui.spacer(ui.px(em * 0.7))
	}
}

@(private = "file")
Diagram_Draw :: struct { doc: ^svg.Document, scale: f32 }

// The diagram at the conversation's size, centred, never wider than the column (its width is the last layout's).
@(private = "file")
diagram_box :: proc(app: ^App, doc: ^svg.Document, em: f32) {
	ui.spacer(ui.px(em * 0.6))
	avail := max(app.column_w - em * 1.8, em * 8)
	scale := min(em / DIAGRAM_FONT_PX, avail / max(doc.view[2], 1))
	sz := svg.size(doc, scale)
	ui.next({width = ui.fill(), height = ui.px(math.ceil(sz.y)), axis = .X})
	if ui.row(id = "###diagram_row") {
		ui.spacer(ui.fill())
		ui.a11y({role = .Image, name = "A diagram"})
		ui.next({width = ui.px(math.ceil(sz.x)), height = ui.px(math.ceil(sz.y))})
		b := ui.build_box({}, "###diagram")
		dd := ui.frame_new(Diagram_Draw)
		dd^ = {doc, scale}
		b.custom_user = dd
		b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			dd := (^Diagram_Draw)(user)
			bold := font.styled_face(dc.fonts, the_app.font, true, false)
			svg.draw_doc(dc, dd.doc, b.rect.min, dd.scale, {regular = the_app.font, bold = bold})
		}
		ui.spacer(ui.fill())
	}
}
