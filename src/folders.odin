// A folder of the server, chosen: where a new session starts, where a session moves. The folder is the server's, on whatever
// machine it runs: a server on this computer has the system's dialog (its places, its bookmarks); another's folders are read
// from it (GET /api/fs/list with an absolute path) and browsed in a dialog of this program.
package ocn

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "gt:platform"
import "gt:ui"
import lucide "gt:lucide"
import remote "gt:remote"
import i18n "gt:i18n"

// What the folder chosen is for.
Folder_Purpose :: enum u8 { New_Session, Move_Session }

Folders :: struct {
	purpose: Folder_Purpose,
	session: string,            // the session moved (owned)
	at:      string,            // the folder shown, absolute, with '/' (owned; "": the server's own, until its answer says which)
	field:   ui.Line_Edit,      // a folder typed, to go to
	read:    remote.Remote,     // its folders
	names:   [dynamic]string,   // (of the arena)
	arena:   virtual.Arena,
	sel:     int,               // the row the keyboard is on
	fresh:   bool,              // opened in this build: the field takes the keyboard
}

// Asks for a folder of the server, for `purpose` (`session`: the one moved), and does what it is for once chosen.
folder_choose :: proc(app: ^App, purpose: Folder_Purpose, session := "") {
	if folders_are_here(app) {
		folder_dialog_native(app, purpose, session)
		return
	}
	start := app.chat.new_dir
	if s := find_session(app, session); s != nil { start = s.directory }
	folders_open(app, purpose, session, start)
}

// Whether the server's folders are this computer's: the system's dialog shows them.
folders_are_here :: proc(app: ^App) -> bool { return app.conn != nil && url_is_here(app.conn.http.base) }

// What a folder chosen is for, done.
@(private = "file")
folder_chosen :: proc(app: ^App, purpose: Folder_Purpose, session, path: string) {
	switch purpose {
	case .New_Session:
		delete(app.chat.new_dir, app.chat.alloc)
		app.chat.new_dir = strings.clone(path, app.chat.alloc)
		app.composer.focus_next = true
	case .Move_Session:
		request(app, .Session_Moved, "POST", fmt.tprintf("/api/session/%s/move", session), fmt.tprintf(`{{"directory":%s}}`, jquote(path)), session)
	}
}

@(private = "file")
Folder_Job :: struct {
	app:     ^App,
	purpose: Folder_Purpose,
	session: string,   // (heap)
}

@(private = "file")
FOLDER_TITLES := [Folder_Purpose]string{.New_Session = i18n.later("Start a session in"), .Move_Session = i18n.later("Move the session to")}

@(private = "file")
folder_dialog_native :: proc(app: ^App, purpose: Folder_Purpose, session: string) {
	a := runtime.heap_allocator()
	j := new(Folder_Job, a)
	j^ = {app, purpose, strings.clone(session, a)}
	remember := purpose == .New_Session ? "new_session" : "session_move"
	ui.file_dialog(&app.state, .Folder, {owner = app.win, title = i18n.tr(FOLDER_TITLES[purpose]), remember_id = remember}, proc(r: platform.Dialog_Result, user: rawptr) {
		j := (^Folder_Job)(user)
		a := runtime.heap_allocator()
		defer { delete(j.session, a); free(j, a) }
		if r.status == .Chosen && len(r.paths) > 0 { folder_chosen(j.app, j.purpose, j.session, r.paths[0]) }
	}, j)
}

////////////////////////////////
// The server's folders

// The folder that holds `p` ("/home/x" in "/home", "/home" in "/", "C:/x" in "C:/"); false at a root.
folder_parent :: proc(p: string) -> (parent: string, ok: bool) {
	t := strings.trim_right(p, "/")
	i := strings.last_index_byte(t, '/')
	if i < 0 { return "", false }
	return i == 0 || t[i - 1] == ':' ? t[:i + 1] : t[:i], true
}

// `name` in the folder `dir`.
folder_join :: proc(dir, name: string, allocator := context.temp_allocator) -> string {
	return strings.has_suffix(dir, "/") ? strings.concatenate({dir, name}, allocator) : strings.concatenate({dir, "/", name}, allocator)
}

@(private = "file")
folders_rows_clear :: proc(f: ^Folders) {
	virtual.arena_destroy(&f.arena)
	clear(&f.names)
	f.sel = 0
}

// (`at`: where it starts, "": the server's own folder.)
folders_open :: proc(app: ^App, purpose: Folder_Purpose, session, at: string) {
	f := &app.cx.folders
	folders_clear(f)
	f.purpose, f.session, f.at = purpose, strings.clone(session), strings.clone(path_clean_slashes(at))
	app.cx.open[.Folders], f.fresh = true, true
	folders_list(app)
}

// The server writes paths with the separators of its system; '/' is understood by every one.
@(private = "file")
path_clean_slashes :: proc(p: string) -> string {
	s, _ := strings.replace_all(p, `\`, "/", context.temp_allocator)
	if len(s) > 1 && !strings.has_suffix(s, ":/") { s = strings.trim_right(s, "/") }
	return s
}

folders_list :: proc(app: ^App) {
	f := &app.cx.folders
	ui.line_edit_set(&f.field, f.at)
	remote.begin(&f.read)
	request(app, .Folders_List, "GET", f.at != "" ? fmt.tprintf("/api/fs/list?path=%s", url_escape(f.at)) : "/api/fs/list", reading = &f.read)
}

// Another folder shown: what was read goes.
folders_go :: proc(app: ^App, at: string) {
	f := &app.cx.folders
	next := strings.clone(path_clean_slashes(at))   // (`at` may be of the arena that goes)
	delete(f.at)
	f.at = next
	folders_rows_clear(f)
	remote.reset(&f.read)
	folders_list(app)
}

@(private = "file")
folders_clear :: proc(f: ^Folders) {
	delete(f.session); delete(f.at)
	f.session, f.at = "", ""
	folders_rows_clear(f)
	remote.reset(&f.read)
	ui.line_edit_set(&f.field, "")
}

folders_forget :: proc(app: ^App) {
	app.cx.open[.Folders] = false
	folders_clear(&app.cx.folders)
}

// Its folders by name, the files left out; the folder itself, when it was the server's own, from the answer.
folders_load :: proc(app: ^App, v: json.Value) {
	f := &app.cx.folders
	if f.at == "" {
		f.at = strings.clone(path_clean_slashes(jstr(v, "location", "directory")))
		ui.line_edit_set(&f.field, f.at)
	}
	folders_rows_clear(f)
	_ = virtual.arena_init_growing(&f.arena)
	a := virtual.arena_allocator(&f.arena)
	for it in jarr(v, "data") {
		if jstr(it, "type") != "directory" { continue }
		append(&f.names, strings.clone(filepath.base(path_clean_slashes(jstr(it, "path"))), a))
	}
	slice.sort_by(f.names[:], proc(x, y: string) -> bool { return strings.compare(strings.to_lower(x, context.temp_allocator), strings.to_lower(y, context.temp_allocator)) < 0 })
}

folders_dialog :: proc(app: ^App, em: f32) {
	f := &app.cx.folders
	if !app.cx.open[.Folders] { return }
	if ui.modal("folders", &app.cx.open[.Folders], dialog_options(app, .Folders)) {
		dialog_backdrop()
		if ui.dialog_header("fo_head", i18n.tr(FOLDER_TITLES[f.purpose]), {icon = lucide.FOLDER, close = true}) {}
		ui.spacer(ui.px(em * 0.5))
		folders_where(app, em)
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
		if ui.row(id = "###fo_body") {
			ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
			ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
			if ui.column(id = "###fo_list") { folders_rows(app, em) }
			ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
		}
		ui.spacer(ui.px(em * 0.7))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###fo_bar") {
			ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
			ui.spacer(ui.fill())
			if ui.button("fo_cancel", i18n.tr("Cancel")).clicked { app.cx.open[.Folders] = false }
			ui.spacer(ui.px(em * 0.5))
			if ui.button("fo_choose", i18n.tr("Choose this folder"), lucide.CHECK, {intent = .Primary, disabled = f.at == ""}).clicked { folders_commit(app) }
			ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
		}
		ui.spacer(ui.px(em * 0.9))
	}
	f.fresh = false
}

// The folder shown is chosen.
folders_commit :: proc(app: ^App) {
	f := &app.cx.folders
	if f.at == "" { return }
	app.cx.open[.Folders] = false
	folder_chosen(app, f.purpose, f.session, f.at)
	folders_clear(f)
}

// The folder shown, a field where another is typed (Enter goes there), and the way up.
@(private = "file")
folders_where :: proc(app: ^App, em: f32) {
	f := &app.cx.folders
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###fo_where") {
		ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
		up, has_up := folder_parent(f.at)
		if ui.button("fo_up", i18n.tr("Up"), lucide.ARROW_UP, {height = math.round(em * FIELD_H_EM), disabled = !has_up}).clicked { folders_go(app, up); return }
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.fill(), height = ui.px(math.round(em * FIELD_H_EM)), axis = .X, cross = .Center})
		if ui.well("###fo_well", .X, flags = {.Focus_Within, .Draw_Focus_Ring}) {
			if ui.tags("bare") {
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.5, font = app.mono, font_size = math.round(em * FS_SMALL)})
				res := ui.line_edit("###fo_at", &f.field, {placeholder = i18n.tr("A folder of the server")})
				if f.fresh { ui.set_focus(res.box.key) }
				if res.cancelled { app.cx.open[.Folders] = false }
				if res.committed {
					typed := strings.trim_space(ui.line_edit_string(&f.field))
					if typed != "" && typed != f.at { folders_go(app, typed) } else if f.sel < len(f.names) && remote.shows(&f.read) { folders_go(app, folder_join(f.at, f.names[f.sel])) }
				}
			}
		}
		ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
	}
}

@(private = "file")
folders_rows :: proc(app: ^App, em: f32) {
	f := &app.cx.folders
	shows := remote.shows(&f.read)
	if n := len(f.names); n > 0 && shows {
		if ui.key_press(.Down) { f.sel = (f.sel + 1) % n }
		if ui.key_press(.Up) { f.sel = (f.sel + n - 1) % n }
	}
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###fo_rows") {
		if !read_shown(app, "###fo_read", &f.read, em, folders_list) { return }
		if len(f.names) == 0 { info_line(app, "###fo_none", i18n.tr("No folder in this one."), em) }
		for name, i in f.names {
			if !file_row(app, fmt.tprintf("###for%d", i), name, lucide.FOLDER, i == f.sel, em) { continue }
			folders_go(app, folder_join(f.at, name))
			return
		}
	}
}

////////////////////////////////
// What the answers to its requests do (net.odin REQ_FACTS)

folders_list_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { folders_load(app, v) }
