// Mermaid diagrams in the conversation: a ```mermaid block is drawn as its diagram (the toolkit's mermaid and svg packages: laid
// out by mermaid-svg in native/ocn_native, drawn with the interface's paths and fonts), with a button to see its text. While the
// block is still being written, or when its text is no diagram, the text shows, with why. A click opens it in the viewer
// (diagram_viewer: a dialog of any shape, zoomed and moved there, drawn as paths at any zoom, laid out in another direction);
// its menu copies its text, or its picture (svg.raster).
package ocn

import "core:fmt"
import "core:hash"
import "core:math"
import "core:strings"
import "gt:draw"
import mermaid "gt:mermaid"
import paint "gt:paint"
import "gt:platform"
import svg "gt:svg"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

// A diagram laid out once for its text and the theme's lightness, kept while it is shown (DIAGRAMS_KEPT at most, the least
// recently drawn going first).
Diagram :: struct {
	doc:     svg.Document,
	why:     string,   // not a diagram: what mermaid says (owned)
	used:    u64,      // the build it was last shown in
	pending: bool,     // laid out on the chores (diagram_laid_out): no doc yet
}

DIAGRAMS_KEPT :: 32
// Mermaid draws its text at 14 px: at the conversation's size it is as large as the text around it, never wider than the column.
DIAGRAM_FONT_PX :: 14

diagram_of :: proc(app: ^App, code: string, dark: bool) -> ^Diagram {
	key := diagram_key(code, dark, .Text)
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

// The key of a layout in App_Context.diagrams: its text, the theme's lightness, its direction.
diagram_key :: proc(code: string, dark: bool, direction: mermaid.Direction) -> u64 {
	return hash.fnv64a(transmute([]u8)code) ~ (dark ? 1 : 0) ~ u64(direction) * HASH_MIX_B
}

// The diagram of `code` laid out in `direction` (not .Text), or nil while it is laid out: a layout takes time in proportion to
// the diagram, so it is a task (ui.task), its result kept as diagram_of keeps its own.
diagram_laid_out :: proc(app: ^App, code: string, dark: bool, direction: mermaid.Direction) -> ^Diagram {
	key := diagram_key(code, dark, direction)
	m := &app.cx.diagrams
	if m^ == nil { m^ = make(map[u64]Diagram) }
	if d, ok := &m[key]; ok {
		d.used = app.state.build_index
		return d.pending ? nil : d
	}
	if len(m) >= DIAGRAMS_KEPT { diagrams_trim(app) }
	m[key] = Diagram{pending = true, used = app.state.build_index}
	job := new_clone(Diagram_Layout{key = key, code = strings.clone(code), dark = dark, direction = direction})
	ui.task(&app.state, diagram_layout_work, diagram_layout_done, job, diagram_layout_lost)
	return nil
}

@(private = "file")
Diagram_Layout :: struct {
	key:       u64,
	code:      string,   // (owned)
	dark:      bool,
	direction: mermaid.Direction,
	doc:       svg.Document,
	why:       string,   // (owned)
}

@(private = "file")
diagram_layout_work :: proc(data: rawptr) {
	job := (^Diagram_Layout)(data)
	doc, why := mermaid.diagram(job.code, job.dark, direction = job.direction)
	job.doc, job.why = doc, strings.clone(why)
}

@(private = "file")
diagram_layout_done :: proc(data: rawptr, _: u64) {
	job := (^Diagram_Layout)(data)
	defer { delete(job.code); free(job) }
	m := &the_app.cx.diagrams
	// (its place was trimmed and asked again meanwhile: the layout that came first is kept, this one is not needed)
	if d, ok := &m[job.key]; ok && !d.pending {
		svg.destroy(&job.doc)
		delete(job.why)
		return
	}
	m[job.key] = Diagram{doc = job.doc, why = job.why, used = the_app.state.build_index}
}

@(private = "file")
diagram_layout_lost :: proc(data: rawptr) {
	job := (^Diagram_Layout)(data)
	svg.destroy(&job.doc)
	delete(job.why)
	delete(job.code)
	free(job)
}

@(private = "file")
diagrams_trim :: proc(app: ^App) {
	oldest: u64
	first := true
	for k, d in app.cx.diagrams {
		if d.pending { continue }   // (its task writes it when it is done)
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
	as_text := app.conversation.expanded[k] or_else false
	d: ^Diagram
	if closed && !as_text { d = diagram_of(app, code, !app.cx.theme.light) }
	ok := d != nil && d.why == ""
	ui.next({width = ui.fill(), height = ui.children_sum()})
	if ui.well(id) {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###hdr") {
			ui.spacer(ui.px(em * 0.7))
			glyph(lucide.GIT_FORK, hex(HEX_FAINT), math.round(em * ICON_SMALL), em)
			ui.spacer(ui.px(em * 0.3))
			text("lang", "mermaid", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
			if d != nil && d.why != "" {
				ui.spacer(ui.px(em * 0.6))
				text("why", fmt.tprintf(i18n.tr("not a diagram: %s"), first_line(d.why)), hex(HEX_YELLOW), ui.Style_Mod{font_size = math.round(em * FS_SMALL)}, ui.fill())
			} else {
				ui.spacer(ui.fill())
			}
			if closed && (d == nil || d.why == "") {   // (what is no diagram shows its text already)
				ui.a11y({role = .Button, name = as_text ? i18n.tr("Show the diagram") : i18n.tr("Show its text")})
				ui.next({width = ui.px(math.round(em * 1.6)), height = ui.px(math.round(em * 1.6))})
				sig := ui.button("as_text", icon = as_text ? lucide.GIT_FORK : lucide.CODE)
				if sig.clicked { app.conversation.expanded[k] = !as_text }
				if ui.hovered_for(sig) { if ui.tooltip() { ui.tooltip_text(as_text ? i18n.tr("Show the diagram") : i18n.tr("Show its text")) } }
			}
			if ok {
				ui.a11y({role = .Button, name = i18n.tr("Open in the viewer")})
				ui.next({width = ui.px(math.round(em * 1.6)), height = ui.px(math.round(em * 1.6))})
				sig := ui.button("open", icon = lucide.ZOOM_IN)
				if sig.clicked { diagram_view_open(app, code) }
				if ui.hovered_for(sig) { if ui.tooltip() { ui.tooltip_text(i18n.tr("Open in the viewer")) } }
			}
			ui.a11y({role = .Button, name = i18n.tr("Copy")})
			ui.next({width = ui.px(math.round(em * 1.6)), height = ui.px(math.round(em * 1.6))})
			if ui.button("copy", icon = lucide.COPY).clicked {
				if ok { ctx_open(app, .Diagram, msg = code) } else { clip_set(code); ui.announce(&app.announcer, .Good, i18n.tr("Copied")) }
			}
			ui.spacer(ui.px(em * 0.3))
		}
		ui.next({width = ui.fill(), height = ui.px(2)})
		ui.build_box({}, "")
		if ok {
			diagram_box(app, &d.doc, code, em)
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

// The diagram at the conversation's size, centred, never wider than the column (its width is the last layout's). A click opens
// it in the viewer; a right click, its menu.
@(private = "file")
diagram_box :: proc(app: ^App, doc: ^svg.Document, code: string, em: f32) {
	ui.spacer(ui.px(em * 0.6))
	avail := max(app.conversation.column_w - em * 1.8, em * 8)
	scale := min(em / DIAGRAM_FONT_PX, avail / max(doc.view[2], 1))
	sz := svg.size(doc, scale)
	ui.next({width = ui.fill(), height = ui.px(math.ceil(sz.y)), axis = .X})
	if ui.row(id = "###diagram_row") {
		ui.spacer(ui.fill())
		ui.a11y({role = .Image, name = i18n.tr("A diagram")})
		ui.next({width = ui.px(math.ceil(sz.x)), height = ui.px(math.ceil(sz.y)), cursor = .Zoom_In})
		b := ui.build_box({.Clickable}, "###diagram")
		if ui.signal(b).clicked { diagram_view_open(app, code) }
		ctx_check(app, b, .Diagram, msg = code)
		dd := ui.frame_new(Diagram_Draw)
		dd^ = {doc, scale}
		b.custom_user = dd
		b.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			dd := (^Diagram_Draw)(user)
			bold := ui.styled_face(the_app.font, true, false)   // (the family's own bold, not a simulated one)
			svg.draw_doc(dc, dd.doc, b.rect.min, dd.scale, {regular = the_app.font, bold = bold})
		}
		ui.spacer(ui.fill())
	}
}

// The scale of a diagram at the conversation's size: its text as large as the text around it.
diagram_scale :: proc(em: f32) -> f32 { return em / DIAGRAM_FONT_PX }

// The viewer of a diagram (open: Dialog.Diagram): its text, the direction it is laid out in, and its zoom and pan. The dialog's
// size is the person's (layout.dialogs), any shape: the diagram fits it, then zooms and moves inside it (ui.preview).
Diagram_Viewer :: struct {
	code:      string,              // (owned)
	own:       mermaid.Direction,   // the direction its text says (.Text: it takes none, there is no choice)
	direction: mermaid.Direction,   // the one chosen (.Text: its text's)
	shown:     u64,                 // the layout shown (diagram_key): a new one fits the view again
	preview:   ui.Preview,
	focus:     bool,                // it opened: the view takes the keyboard
}

// The viewer, on the diagram of `code` (as the theme has it now), as its text lays it out.
diagram_view_open :: proc(app: ^App, code: string) {
	v := &app.diagram_view
	delete(v.code)
	v^ = {code = strings.clone(code), own = mermaid.direction_of(code), focus = true}
	ui.preview_reset(&v.preview)
	app.cx.open[.Diagram] = true
}

// The layout of the viewer's diagram that is shown: the one chosen once it is laid out, the one shown before meanwhile
// (`waiting`), its text's when the chosen one is no diagram.
@(private = "file")
diagram_view_shown :: proc(app: ^App, v: ^Diagram_Viewer, dark: bool) -> (d: ^Diagram, key: u64, waiting: bool) {
	d = diagram_of(app, v.code, dark)
	key = diagram_key(v.code, dark, .Text)
	if v.direction == .Text || d == nil || d.why != "" { return }
	if l := diagram_laid_out(app, v.code, dark, v.direction); l != nil {
		if l.why == "" { d, key = l, diagram_key(v.code, dark, v.direction) }
		return
	}
	if before, ok := &app.cx.diagrams[v.shown]; ok && !before.pending && before.why == "" { d, key = before, v.shown }
	return d, key, true
}

// The viewer of a diagram: a dialog of the size the person gives it, the diagram fitted in it; the wheel moves it, Ctrl and
// the wheel (a touchpad's pinch) zoom it, a drag moves it, the keys and the buttons zoom it; a graph is laid out in the direction chosen.
diagram_viewer :: proc(app: ^App, em: f32) {
	v := &app.diagram_view
	if !app.cx.open[.Diagram] { return }
	dark := !app.cx.theme.light
	d, key, waiting := diagram_view_shown(app, v, dark)
	if d == nil || d.why != "" { app.cx.open[.Diagram] = false; return }
	if key != v.shown {
		v.shown = key
		ui.preview_reset(&v.preview)   // (another shape: it fits again)
	}
	if ui.modal("diagram_view", &app.cx.open[.Diagram], dialog_options(app, .Diagram)) {
		dialog_backdrop()
		if ui.dialog_header("dv_head", i18n.tr("Mermaid diagram"), {icon = lucide.GIT_FORK, close = true}) {
			if waiting {
				text("dv_wait", i18n.tr("Laying out…"), hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_SMALL)})
				ui.spacer(ui.px(em * 0.6))
			}
			if v.own != .Text {
				// (the menu's order is the enum's, from .Top_Down)
				words := [4]string{i18n.tr("Top to bottom"), i18n.tr("Left to right"), i18n.tr("Bottom to top"), i18n.tr("Right to left")}
				want := v.direction == .Text ? v.own : v.direction
				sel := int(want) - int(mermaid.Direction.Top_Down)
				ui.a11y({name = i18n.tr("Direction")})
				if ui.dropdown("###dv_direction", words[:], &sel) {
					chosen := mermaid.Direction(sel + int(mermaid.Direction.Top_Down))
					v.direction = chosen == v.own ? .Text : chosen
				}
			}
		}
		pad := math.round(em * VIEWER_PAD_EM)
		ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
		if ui.row(id = "###dv_body") {
			ui.spacer(ui.px(pad))
			ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
			if ui.column(id = "###dv_col") {
				ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
				well := ui.build_box({}, "###dv_well")
				well.custom = proc(b: ^ui.Box, _: rawptr, dc: ^draw.Context) { draw_well(dc, b.rect, 0, hex(HEX_CODE_WELL)) }
				if ui.parent(well) {
					content := [2]f32{d.doc.view[2], d.doc.view[3]} * diagram_scale(em)
					dd := ui.frame_new(Diagram_Draw)
					dd.doc = &d.doc
					ui.a11y({role = .Image, name = i18n.tr("A diagram")})
					r := ui.preview("###dv_view", &v.preview, content, proc(dc: ^draw.Context, dst: ui.Rect, user: rawptr) {
						dd := (^Diagram_Draw)(user)
						bold := ui.styled_face(the_app.font, true, false)
						svg.draw_doc(dc, dd.doc, dst.min, (dst.max.x - dst.min.x) / max(dd.doc.view[2], 1), {regular = the_app.font, bold = bold})
					}, dd, {buttons = true, grow = true, wheel_pans = true})
					if v.focus { ui.set_focus(r.box.key); v.focus = false }
					if ui.mouse_pressed(.Right) && ui.pointer_on(r.box) && !app.ctx_menu.taken { ctx_open(app, .Diagram, msg = v.code) }
				}
				ui.spacer(ui.px(pad))
			}
			ui.spacer(ui.px(pad))
		}
		if ui.key_press(.C, {.Ctrl}) { diagram_copy_png(app, v.code, v.direction) }
	}
}

// A copied picture of a diagram: DIAGRAM_COPY_SCALE times its size in the conversation, its longest side at most
// DIAGRAM_COPY_MOST pixels, on the conversation's colour for code (its colours are the theme's).
DIAGRAM_COPY_SCALE :: 2
DIAGRAM_COPY_MOST :: 4096

// The diagram of `code` as a picture on the clipboard, laid out in `direction` when that layout is ready (else as its text says).
diagram_copy_png :: proc(app: ^App, code: string, direction := mermaid.Direction.Text) {
	c, ok := diagram_picture(app, code, direction)
	if !ok { ui.announce(&app.announcer, .Bad, i18n.tr("The diagram could not be copied: it is not a diagram")); return }
	defer paint.canvas_destroy(&c)
	pixels := platform.Clipboard_Image{rgba = paint.to_rgba8(c, context.temp_allocator), size = {c.width, c.height}}
	if platform.clipboard_set_image(app.win, pixels) { ui.announce(&app.announcer, .Good, i18n.tr("Diagram copied as a picture")) } else { ui.announce(&app.announcer, .Bad, i18n.tr("The diagram could not be copied")) }
}

// The pixels of the diagram of `code`, as diagram_copy_png copies them (the caller's: paint.canvas_destroy).
diagram_picture :: proc(app: ^App, code: string, direction := mermaid.Direction.Text) -> (c: paint.Canvas, ok: bool) {
	dark := !app.cx.theme.light
	d := diagram_of(app, code, dark)
	if d == nil || d.why != "" { return }
	if direction != .Text {
		if l, laid := &app.cx.diagrams[diagram_key(code, dark, direction)]; laid && !l.pending && l.why == "" { d = l }
	}
	scale := DIAGRAM_COPY_SCALE * diagram_scale(ui.font_size())
	scale = min(scale, DIAGRAM_COPY_MOST / max(d.doc.view[2], d.doc.view[3], 1))
	well := themed(HEX_CODE_WELL)
	bg := svg.Color{f32(well >> 24) / 255, f32((well >> 16) & 0xFF) / 255, f32((well >> 8) & 0xFF) / 255, 1}
	bold := ui.styled_face(app.font, true, false)
	return svg.raster(&d.doc, scale, &app.fonts, {regular = app.font, bold = bold}, bg), true
}
