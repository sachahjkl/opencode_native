// The Markdown of the replies, shown by the toolkit's markdown package: here are ocn's faces, sizes and colours, and what it
// does with a link (link_open), a code block (code_block, a mermaid diagram), a table's frame and its copy button.
package ocn

import "core:math"
import "core:strings"
import "gt:markdown"
import "gt:platform"
import "gt:ui"
import lucide "gt:lucide"

HEX_INLINE_CODE :: 0xe5c07bff
HEX_CODE_TEXT   :: 0xd4d4d4ff
HEX_TABLE_WELL  :: 0x090909ff

// The doc of a Markdown text of the conversation, by the id it is built under: one per id, read again when its text is another.
md_doc :: proc(c: ^Chat, id: string) -> ^markdown.Doc {
	if d, ok := c.markdown[id]; ok { return d }
	if c.markdown == nil { c.markdown = make(map[string]^markdown.Doc, allocator = c.alloc) }
	d := new(markdown.Doc, c.alloc)
	d.alloc = c.alloc
	c.markdown[strings.clone(id, c.alloc)] = d
	return d
}

// How Markdown is shown in the conversation, its text in `color`: the answers' face and size, tables in the interface's.
md_config :: proc(app: ^App, color: Color) -> markdown.Config {
	return {
		prose = app.prose, face = app.font, mono = app.mono,
		prose_scale = app.prose_scale, line_ratio = PROSE_LINE_RATIO, cell_scale = FS_LABEL,
		colors = {
			text = color, heading = hex(HEX_BRIGHT), quote = hex(HEX_WEAK), marker = accent(), rail = with_alpha(accent(), 0.6),
			inline_code = hex(HEX_INLINE_CODE), code_text = hex(HEX_CODE_TEXT), table_header = hex(HEX_BRIGHT),
			table_stripe = with_alpha(hex(HEX_TEXT), markdown.TABLE_STRIPE_ALPHA), table_rule = with_alpha(accent(), markdown.TABLE_RULE_ALPHA),
		},
		user = app,
		link = proc(user: rawptr, url: string) { link_open(url) },
		code = md_code,
		frame = proc(user: rawptr, b: ^ui.Box, kind: markdown.Frame_Kind) { well_paint(b, 6, kind == .Table ? HEX_TABLE_WELL : HEX_CODE_WELL) },
		rule = proc(user: rawptr, id: string) { groove(id) },
		table_corner = md_table_copy,
	}
}

// A fenced block: a mermaid one is a diagram, the others code in ocn's well (highlighted by the package).
@(private = "file")
md_code :: proc(user: rawptr, id: string, c: markdown.Code) {
	if c.lang == "mermaid" { mermaid_block(id, c.text, c.closed, c.version); return }
	code_block(id, c.lang, c.text, (^App)(user).mono, version = c.version, runs = c.runs)
}

// A table's copy button: the table as HTML (a plain grid, any program's own style) and as its Markdown text.
@(private = "file")
md_table_copy :: proc(user: rawptr, t: ^markdown.Table, source: []string, size: f32) {
	app := (^App)(user)
	ui.a11y({role = .Button, name = "Copy the table"})
	sig := glyph_button("###copy", lucide.COPY, size, face = .Raised)
	if sig.clicked {
		_ = platform.clipboard_set(app.win, {text = strings.join(source, "\n", context.temp_allocator), html = markdown.table_html(t)})
		ui.toast(.Good, "Table copied")
	}
	if ui.hovered_for(sig, TOOLTIP_DELAY_S) { if ui.tooltip() { ui.tooltip_text("Copy the table (pastes as a table)") } }
}

link_clicked :: proc(res: ui.Rich_Result) {
	if res.link_clicked >= 0 { link_open(res.link) }
}

// Links come from the model or the server, and the system runs what it is handed (a program, a batch file, a share): only
// what a browser or a mail client is for.
link_allowed :: proc(url: string) -> bool {
	u := strings.to_lower(url, context.temp_allocator)
	return strings.has_prefix(u, "http://") || strings.has_prefix(u, "https://") || strings.has_prefix(u, "mailto:")
}

link_open :: proc(url: string) {
	if link_allowed(url) {
		// (what an agent serves here is what the panel is for)
		if strings.contains(url, "://localhost") || strings.contains(url, "://127.0.0.1") { preview_open(the_app, url) } else { platform.open_url(url) }
	} else { ui.toast(.Warn, "Link not opened: %s", ellipsize(url, TOAST_TITLE_CHARS)) }
}

// Code in a sunken well, under a header with its language and a copy button. `runs`: the code highlighted (else one run
// of the code colour).
code_block :: proc(id: string, lang: string, code: string, mono: Face_Id, table := false, version: u64 = 0, runs: []ui.Rich_Run = nil) {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.children_sum()})
	if well(id, radius = 6, base = HEX_CODE_WELL) {
		if !table {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###hdr") {
				ui.spacer(ui.px(em * 0.7))
				glyph(lucide.CODE, hex(HEX_FAINT), math.round(em * ICON_SMALL), em)
				ui.spacer(ui.px(em * 0.3))
				text("lang", lang != "" ? lang : "text", hex(HEX_FAINT), ui.Style_Mod{font = mono, font_size = math.round(em * FS_SMALL)})
				ui.spacer(ui.fill())
				if glyph_button("###copy", lucide.COPY, math.round(em * 1.6)).clicked {
					platform.set_clipboard(the_app.win, code)
					ui.toast(.Good, "Copied")
				}
				ui.spacer(ui.px(em * 0.3))
			}
			ui.next({width = ui.fill(), height = ui.px(2)})
			ui.build_box({}, "")
		}
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###body") {
			ui.spacer(ui.px(em * 0.9))
			plain := [1]ui.Rich_Run{{text = code, style = {font = mono, color = hex(table ? HEX_TEXT : HEX_CODE_TEXT)}}}
			ui.next({width = ui.fill(), font_size = math.round(em * FS_NOTE), flags = {.Selectable}})
			ui.rich_paragraph("###code", len(runs) > 0 ? runs : plain[:], version = version)
			ui.spacer(ui.px(em * 0.9))
		}
		ui.spacer(ui.px(em * 0.7))
	}
}
