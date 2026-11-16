// The Markdown of the replies, shown by the toolkit's markdown package: here are ocn's faces, sizes and colours, and what it
// does with a link (link_open), a code block (code_block, a mermaid diagram), a table's frame and its copy button.
package ocn

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import "gt:markdown"
import "gt:platform"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"


// The doc of a Markdown text of the conversation, by the id it is built under: one per id, read again when its text is another.
md_doc :: proc(c: ^Chat, id: string) -> ^markdown.Doc {
	if d, ok := c.markdown[id]; ok { return d }
	if c.markdown == nil { c.markdown = make(map[string]^markdown.Doc, allocator = c.alloc) }
	d := new(markdown.Doc, c.alloc)
	d.alloc = c.alloc
	c.markdown[strings.clone(id, c.alloc)] = d
	return d
}

// What a Markdown view's procedures are given: the app, and the pane it is built in (a diagram is as wide as its column).
@(private = "file")
Md_User :: struct { app: ^App, pane: ^Chat_Pane }

// How Markdown is shown in the conversation, its text in `color`: the answers' face and size, tables in the interface's.
// `pane`: the one it is built in (nil: none, the main view's width).
md_config :: proc(app: ^App, color: Color, pane: ^Chat_Pane = nil) -> markdown.View_Options {
	u := ui.frame_new(Md_User)
	u^ = {app, pane != nil ? pane : main_pane(app)}
	return {
		prose = app.prose, face = app.font, mono = app.mono,
		prose_scale = app.prose_scale, line_ratio = PROSE_LINE_RATIO, cell_scale = FS_LABEL,
		colors = {
			text = color, heading = ui.theme_color("bright text"), quote = ui.theme_color("weak text"), marker = ui.hue(.Accent), rail = ui.with_alpha(ui.hue(.Accent), 0.6),
			inline_code = ui.hue(.Yellow), code_text = ui.theme_color("soft text"), table_header = ui.theme_color("bright text"),
			table_stripe = ui.with_alpha(ui.theme_color("text"), markdown.TABLE_STRIPE_ALPHA), table_rule = ui.with_alpha(ui.hue(.Accent), markdown.TABLE_RULE_ALPHA),
		},
		user = u,
		link = proc(user: rawptr, url: string) { link_open(url) },
		code = md_code,
		frame = proc(user: rawptr, b: ^ui.Box, kind: markdown.Frame_Kind) { well_paint(b, 6) },
		rule = proc(user: rawptr, id: string) { groove(id) },
		table_corner = md_table_copy,
	}
}

// A fenced block: a mermaid one is a diagram, the others code in ocn's well (highlighted by the package).
@(private = "file")
md_code :: proc(user: rawptr, id: string, c: markdown.Code) {
	u := (^Md_User)(user)
	if c.lang == "mermaid" { mermaid_block(u.app, u.pane, id, c.text, c.closed, c.version); return }
	code_block(id, c.lang, c.text, u.app.mono, version = c.version, runs = c.runs)
}

// A table's copy button: the table as HTML (a plain grid, any program's own style) and as its Markdown text.
@(private = "file")
md_table_copy :: proc(user: rawptr, t: ^markdown.Table, source: []string, size: f32) {
	app := (^Md_User)(user).app
	ui.a11y({role = .Button, name = i18n.tr("Copy the table")})
	ui.next({width = ui.px(size), height = ui.px(size)})
	sig := ui.button("copy", icon = lucide.COPY, o = {face = .Raised})
	if sig.clicked {
		_ = platform.clipboard_set(app.win, {text = strings.join(source, "\n", context.temp_allocator), html = markdown.table_html(t)})
		ui.announce(&app.announcer, .Good, i18n.tr("Table copied"))
	}
	if ui.hovered_for(sig) { if ui.tooltip() { ui.tooltip_text(i18n.tr("Copy the table (pastes as a table)")) } }
}

// The boxes markdown.view builds of `src` under `id` with md_config, as a copy reads them (message_text): each block's text
// without its marks (no rule, no list marker), a table cell by cell, a code block or a mermaid one's text unless its
// diagram shows. A doc of its own in temp memory: the views' docs and their runs stay as their builds left them.
md_text :: proc(t: ^Copy_Text, app: ^App, id, src: string) {
	d := markdown.Doc{alloc = context.temp_allocator}
	markdown.read(&d, src)
	item :: proc(k: markdown.Block_Kind) -> bool { return k == .Bullet || k == .Number }
	inline :: proc(s: string) -> string {
		runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
		markdown.inline_runs(s, {}, &runs)
		return ui.rich_text(runs[:])
	}
	for n in 0 ..< len(d.blocks) {
		kind := d.blocks[n].kind
		switch kind {
		case .Rule:
		case .Code:
			code := markdown.block_text(&d, n)
			if d.blocks[n].lang == "mermaid" {
				dg, _ := mermaid_diagram(app, fmt.tprintf("###%s_b%d", id, n), code, d.blocks[n].closed)
				if dg != nil && dg.why == "" { continue }   // (a diagram: no text)
			}
			copy_box(t, code)
		case .Table:
			// (markdown's table_of: the cells of each line, the line of dashes under the first one left out)
			rows := make([dynamic][]string, context.temp_allocator)
			for l in markdown.block_lines(&d, n) {
				cells := strings.split(strings.trim_suffix(strings.trim_prefix(strings.trim_space(l), "|"), "|"), "|", context.temp_allocator)
				for &c in cells { c = strings.trim_space(c) }
				sep := len(cells) > 0
				for c in cells { if strings.trim(c, ":- ") != "" || c == "" { sep = false } }
				if sep && len(rows) == 1 { continue }
				append(&rows, cells)
			}
			cols := 0
			for r in rows { cols = max(cols, len(r)) }
			for r in rows {
				for ci in 0 ..< cols { copy_box(t, inline(ci < len(r) ? r[ci] : "")) }
			}
		case .Heading, .Para, .Quote, .Bullet, .Number:
			copy_box(t, inline(markdown.block_text(&d, n)), block = !(item(kind) && n > 0 && item(d.blocks[n - 1].kind)))
		}
	}
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

// A session's id is a link (the toolkit's link words): set once for the process, before any text is read.
@(init)
session_links_init :: proc "contextless" () {
	context = runtime.default_context()
	ui.link_words_set({SESSION_ID_PREFIX})
}

SESSION_ID_PREFIX :: "ses_"

link_open :: proc(url: string) {
	// (a session's id in a message: that session opens, and Back comes here again, as a sub-agent's does)
	if strings.has_prefix(url, SESSION_ID_PREFIX) { drill_down(the_app, url); return }
	if link_allowed(url) {
		// (what an agent serves here is what the panel is for)
		if strings.contains(url, "://localhost") || strings.contains(url, "://127.0.0.1") { preview_open(the_app, url) } else { ui.open(url, .Url) }
	} else { ui.announce(&the_app.announcer, .Warn, fmt.tprintf(i18n.tr("Link not opened: %s"), ellipsize(url, TOAST_TITLE_CHARS))) }
}

// Code in a sunken well, under a header with its language and a copy button. `runs`: the code highlighted (else one run
// of the code colour).
code_block :: proc(id: string, lang: string, code: string, mono: Face_Id, table := false, version: u64 = 0, runs: []ui.Rich_Run = nil) {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.children_sum()})
	if ui.well(id) {
		if !table {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###hdr") {
				ui.space(ui.SPACE_3)
				glyph(lucide.CODE, ui.theme_color("faint text"), math.round(em * ICON_SMALL), em)
				ui.space(ui.SPACE_1)
				text("lang", lang != "" ? lang : "text", ui.theme_color("faint text"), ui.Style_Mod{font = mono, font_size = math.round(em * FS_SMALL)})
				ui.spacer(ui.fill())
				ui.next({width = ui.px(math.round(em * 1.6)), height = ui.px(math.round(em * 1.6))})
				if ui.button("copy", icon = lucide.COPY).clicked {
					platform.set_clipboard(the_app.win, code)
					ui.announce(&the_app.announcer, .Good, i18n.tr("Copied"))
				}
				ui.space(ui.SPACE_1)
			}
			ui.next({width = ui.fill(), height = ui.px(2)})
			ui.build_box({}, "")
		}
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###body") {
			ui.space(ui.SPACE_4)
			plain := [1]ui.Rich_Run{{text = code, style = {font = mono, color = ui.theme_color(table ? "text" : "soft text")}}}
			ui.next({width = ui.fill(), font_size = math.round(em * FS_NOTE), flags = {.Selectable}})
			ui.rich_paragraph("###code", len(runs) > 0 ? runs : plain[:], version = version)
			ui.space(ui.SPACE_4)
		}
		ui.space(ui.SPACE_3)
	}
}
