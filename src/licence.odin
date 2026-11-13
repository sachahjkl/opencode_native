// The licence that supports the program (gt:licence): a signed key, checked here with no network. The program works the
// same without one; the settings say whose it is, or how to get one. Every read and write of its file is a task's.
package ocn

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import licence "gt:licence"
import product "product"
import "gt:platform"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

// Where a licence is bought (the site's shop: "Coming soon" until it opens).
LICENCE_PRICING_URL :: "https://ocn.froment.software/pricing/"

// The licence's state as the interface shows it: the store, its last status read, and the key being typed.
Licence_View :: struct {
	store:   ^licence.Store,      // nil: none (a test)
	status:  licence.Status,      // the last read (heap)
	read:    bool,                // a status was read once
	busy:    bool,                // a task on the store is on its way
	key:     ui.Text_Field,       // a key pasted
	problem: string,              // what the last install said (a constant; "": nothing)
}

// The store, beside the preferences, and its first read (a task). Not in a test: it has no preferences' file.
licence_init :: proc(app: ^App) {
	if app.prefs_file == "" { return }
	app.licence.store = new(licence.Store, runtime.heap_allocator())
	licence.store_init(app.licence.store, {product = product.LICENCE, path = pjoin({config_dir(), fmt.tprintf("licence%s", product.LICENCE.file_extension)}), accept_dev = ODIN_DEBUG})
	licence_read(app)
}

// What a task does with the store, then the status it reads after it.
@(private = "file")
Licence_Act :: enum u8 { Read, Install, Install_File, Remove }

@(private = "file")
Licence_Job :: struct { app: ^App, act: Licence_Act, text: string, err: licence.Error, status: licence.Status }

@(private = "file")
licence_job_free :: proc(data: rawptr) {
	j := (^Licence_Job)(data)
	h := runtime.heap_allocator()
	licence.status_destroy(&j.status, h)
	delete(j.text, h)
	free(j, h)
}

@(private = "file")
licence_run :: proc(app: ^App, act: Licence_Act, text := "") {
	if app.licence.store == nil || app.licence.busy { return }
	h := runtime.heap_allocator()
	j := new(Licence_Job, h)
	j^ = {app = app, act = act, text = strings.clone(text, h)}
	app.licence.busy = true
	ui.task(&app.state, proc(data: rawptr) {
		j := (^Licence_Job)(data)
		s := j.app.licence.store
		switch j.act {
		case .Read:
		case .Install:      j.err = licence.store_install(s, j.text)
		case .Install_File: j.err = licence.store_install_file(s, j.text)
		case .Remove:       _ = licence.store_remove(s)
		}
		j.status = licence.store_read(s, runtime.heap_allocator())
	}, proc(data: rawptr, _: u64) {
		j := (^Licence_Job)(data)
		l := &j.app.licence
		l.busy, l.read = false, true
		licence.status_destroy(&l.status, runtime.heap_allocator())
		l.status, j.status = j.status, {}
		l.problem = ""
		switch {
		case (j.act == .Install || j.act == .Install_File) && j.err != .None:
			l.problem = licence.error_text(j.err)
		case j.act == .Install || j.act == .Install_File:
			ui.field_wipe(&l.key)
			ui.announce(&j.app.announcer, .Good, i18n.tr("Thank you: the licence is registered"))
		case j.act == .Remove:
			ui.announce(&j.app.announcer, .Good, i18n.tr("The licence was removed"))
		}
		licence_job_free(j)
	}, j, licence_job_free)
}

licence_read :: proc(app: ^App) { licence_run(app, .Read) }

// A licence file given (dropped, on the command line, chosen): installed rather than opened.
licence_install_file :: proc(app: ^App, path: string) { licence_run(app, .Install_File, path) }

// The settings' part on the licence: whose it is, or how to support the program and register a key.
licence_section :: proc(app: ^App, em: f32) {
	l := &app.licence
	if l.store == nil { return }
	section(app, i18n.tr("LICENCE"), em)
	st := &l.status
	if st.registered {
		edition := licence.edition_title(product.LICENCE, st.licence.edition)
		info_line(app, "###lic_who", fmt.tprintf(i18n.tr("Registered to %s (%s). Thank you for supporting %s."), st.licence.name, edition, APP_NAME), em)
		ui.spacer(ui.px(em * 0.5))
		if ui.button_icon("###lic_remove", lucide.TRASH_2, i18n.tr("Remove the licence"), .Danger, face = .Ghost, disabled = l.busy).clicked { licence_run(app, .Remove) }
		return
	}
	info_line(app, "###lic_none", fmt.tprintf(i18n.tr("Unregistered: %s works the same. A licence supports its work."), APP_NAME), em)
	ui.spacer(ui.px(em * 0.3))
	if hint_action("###lic_buy", i18n.tr("Support opencode native"), em, icon = lucide.HEART, intent = .Primary) { ui.open(LICENCE_PRICING_URL, .Url) }
	ui.spacer(ui.px(em * 0.5))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###lic_row") {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * FIELD_H_EM))})
		res := ui.line_edit("###lic_key", &l.key, i18n.tr("Paste a licence key"))
		ui.spacer(ui.px(em * 0.5))
		key := strings.trim_space(ui.field_string(&l.key))
		if (ui.button_icon("###lic_reg", lucide.CHECK, i18n.tr("Register"), .Success, disabled = key == "" || l.busy).clicked || res.committed) && key != "" { licence_run(app, .Install, key) }
		ui.spacer(ui.px(em * 0.4))
		if ui.button_icon("###lic_file", lucide.FILE, i18n.tr("Choose a file…"), disabled = l.busy).clicked {
			ui.file_dialog(&app.state, .Open, licence.file_dialog(product.LICENCE, i18n.tr("Choose a licence file"), i18n.tr("opencode native licence")), proc(r: platform.Dialog_Result, user: rawptr) {
				if r.status != .Chosen || len(r.paths) == 0 { return }
				licence_install_file((^App)(user), r.paths[0])
			}, app)
		}
	}
	if l.problem != "" {
		ui.spacer(ui.px(em * 0.3))
		info_line(app, "###lic_problem", l.problem, em, hex(HEX_RED))
	}
}
