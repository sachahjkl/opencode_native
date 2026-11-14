package ocn

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "gt:ui"
import diff "gt:diff"
import i18n "gt:i18n"

// A diff in a window of its own, whole: stacked, or old and new side by side (gt:diff's view: read once, when it opens; only the
// rows in view are built).

diff_layout_name :: proc(l: diff.Layout) -> string { return l == .Split ? "split" : "stacked" }

diff_layout_of :: proc(s: string) -> diff.Layout { return s == diff_layout_name(.Split) ? .Split : .Stacked }

Diff_Full :: struct {
	title: string,
	doc:   diff.Doc,
}

diff_full_open :: proc(app: ^App, title, patch: string) {
	d := &app.cx.diff_full
	diff_full_close(d)
	d.title = strings.clone(title)
	diff.doc_set(&d.doc, patch)
	ui.view_open(&app.program_views, DIFF_VIEW, d)
}

diff_full_open_file :: proc(app: ^App, path: string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { ui.announce(&app.announcer, .Bad, fmt.tprintf(i18n.tr("Cannot read %s"), path)); return }
	diff_full_open(app, filepath.base(path), string(data))
}

diff_full_close :: proc(d: ^Diff_Full) {
	delete(d.title)
	diff.doc_destroy(&d.doc)
	d^ = {}
}

// (closed by the user: views_answers frees what it showed)
diff_full_view :: proc(v: ^ui.View, d: ^Diff_Full) {
	app := the_app
	em := ui.font_size()
	ui.view_title(v, d.title)
	{
		if ui.view_header_tools(v) {
			text("a", fmt.tprintf("+%d", d.doc.added), hex(HEX_GREEN), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL), height = ui.px(em * 2)})
			ui.spacer(ui.px(em * 0.5))
			text("d", fmt.tprintf("-%d", d.doc.removed), hex(HEX_RED), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL), height = ui.px(em * 2)})
			ui.spacer(ui.px(em))
			if ui.button("df_copy", i18n.tr("Copy")).clicked {
				clip_set(d.doc.patch)
				ui.announce(&app.announcer, .Good, i18n.tr("Diff copied"))
			}
			ui.spacer(ui.px(em * 0.6))
			sel := int(app.prefs.diff_layout)
			labels := []string{i18n.tr("Stacked"), i18n.tr("Split")}
			ui.next({width = ui.px(em * 12), height = ui.px(em * 2)})
			if choice("###df_mode", labels, &sel) { pref_set(app, "conversation.diff_layout", diff_layout_name(diff.Layout(sel))) }
		}
		ui.spacer(ui.px(em * 0.6))
		o := diff_options(app, em, d.title)
		o.selectable = true
		diff.view("###df_list", &d.doc, app.prefs.diff_layout, o)
		ui.spacer(ui.px(em * 0.6))
	}
}
