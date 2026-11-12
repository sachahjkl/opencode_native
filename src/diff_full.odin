package ocn

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "gt:ui"
import diff "gt:diff"

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
	app.cx.open[.Diff] = true
}

diff_full_open_file :: proc(app: ^App, path: string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { ui.toast(.Bad, "Cannot read %s", path); return }
	diff_full_open(app, filepath.base(path), string(data))
}

diff_full_close :: proc(d: ^Diff_Full) {
	delete(d.title)
	diff.doc_destroy(&d.doc)
	d^ = {}
}

diff_full_dialog :: proc(app: ^App, em: f32) {
	d := &app.cx.diff_full
	open := &app.cx.open[.Diff]
	if !open^ { return }
	if ui.modal_sized("diff_full", DIALOG_PREFERRED_EM[.Diff] * em, &app.cx.dialogs[.Diff], open, DIALOG_MIN_EM[.Diff] * em) {
		dialog_backdrop()
		ui.spacer(ui.px(em * 0.9))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###df_head") {
			ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
			text("t", d.title, hex(HEX_BRIGHT), ui.Style_Mod{font_size = math.round(em * FS_TITLE), height = ui.px(em * 2), flags = {.Selectable}}, ui.fill())   // (a path: to copy, to go to)
			text("a", fmt.tprintf("+%d", d.doc.added), hex(HEX_GREEN), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL), height = ui.px(em * 2)})
			ui.spacer(ui.px(em * 0.5))
			text("d", fmt.tprintf("-%d", d.doc.removed), hex(HEX_RED), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL), height = ui.px(em * 2)})
			ui.spacer(ui.px(em))
			if bevel_button("###df_copy", "Copy", "", .Normal).clicked {
				clip_set(d.doc.patch)
				ui.toast(.Good, "Diff copied")
			}
			ui.spacer(ui.px(em * 0.6))
			sel := int(app.prefs.diff_layout)
			labels := []string{"Stacked", "Split"}
			ui.next({width = ui.px(em * 12), height = ui.px(em * 2)})
			if choice("###df_mode", labels, &sel) { pref_set(app, "conversation.diff_layout", diff_layout_name(diff.Layout(sel))) }
			ui.spacer(ui.px(em * 3.2))   // (the dialog's close button is there)
		}
		ui.spacer(ui.px(em * 0.6))
		o := diff_options(app, em, d.title)
		o.selectable = true
		diff.view("###df_list", &d.doc, app.prefs.diff_layout, o)
		ui.spacer(ui.px(em * 0.6))
		dialog_close(open)
	}
	if !open^ { diff_full_close(d) }
}
