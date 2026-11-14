// A folder of the server, chosen: where a new session starts, where a session moves. The folder is the server's, on whatever
// machine it runs: the toolkit's file browser shows it, reading this computer's files when the server is here, and the server's
// own through the source below when it is elsewhere (GET /api/fs/list with an absolute path, GET /api/fs/read for the preview).
package ocn

import "core:encoding/json"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "gt:platform"
import "gt:ui"
import i18n "gt:i18n"

// What the folder chosen is for.
Folder_Purpose :: enum u8 { New_Session, Move_Session }

// The server's files as a source of the file browser. It lists any folder of the server (GET /api/fs/list with an absolute
// path). It reads a file and searches subfolders only inside its location, a session's folder: the server does both only
// inside one of its locations, and loads and keeps one for every folder it is asked about, so no other folder is asked.
// One request of each kind is on its way at a time; a reply replaced is never answered (its dialog moved on).
Server_Files :: struct {
	source:   ui.File_Source,
	location: string,              // the session's folder, with '/' ("": none: no preview, no search) (owned)
	list:     Server_Files_Wait,
	read:     Server_Files_Wait,
	find:     Server_Files_Wait,
	found_in: string,              // the folder searched, from the location ("": itself), with a '/' at its end (owned)
}

// A reply of the browser and the request that answers it.
Server_Files_Wait :: struct {
	reply:   ui.File_Reply,
	waiting: bool,   // the reply waits for an answer
	asked:   u64,    // the tag of the latest request: an answer of an older one is not this reply's
}

@(private = "file")
FOLDER_TITLES := [Folder_Purpose]string{.New_Session = i18n.later("Start a session in"), .Move_Session = i18n.later("Move the session to")}

@(private = "file")
Folder_Job :: struct {
	app:     ^App,
	purpose: Folder_Purpose,
	session: string,   // (owned)
}

// Asks for a folder of the server, for `purpose` (`session`: the one moved), and does what it is for once chosen.
folder_choose :: proc(app: ^App, purpose: Folder_Purpose, session := "") {
	start := app.chat.new_dir
	if s := find_session(app, session); s != nil { start = s.directory }
	// (the folders of the latest sessions: where one most often starts again)
	folders := home_folders(app)
	places := make([]platform.File_Place, len(folders), context.temp_allocator)
	for d, i in folders { places[i] = {path = d} }
	j := new(Folder_Job)
	j^ = {app, purpose, strings.clone(session)}
	ui.file_dialog(&app.state, .Folder, {owner = app.win, title = i18n.tr(FOLDER_TITLES[purpose]), start_dir = start, places = places, remember_id = purpose == .New_Session ? "new_session" : "session_move"}, proc(r: platform.Dialog_Result, user: rawptr) {
		j := (^Folder_Job)(user)
		defer { delete(j.session); free(j) }
		if r.status == .Chosen && len(r.paths) > 0 { folder_chosen(j.app, j.purpose, j.session, r.paths[0]) }
	}, j, source = folders_are_here(app) ? nil : server_files(app))
}

// Whether the server's folders are this computer's: the toolkit's local source reads them.
folders_are_here :: proc(app: ^App) -> bool { return app.conn != nil && url_is_here(app.conn.http.base) }

// What a folder chosen is for, done.
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

////////////////////////////////
// The source

// The source of the server connected now; `location`: a session's folder, where it reads and searches.
server_files :: proc(app: ^App, location := "") -> ^ui.File_Source {
	f := &app.server_files
	delete(f.location)
	f.location = strings.clone(path_clean(location))
	f.source = {user = app, separator = '/', list = server_files_list}
	if f.location != "" {
		f.source.caps = {.Read}
		f.source.read, f.source.find = server_files_read, server_files_find
	}
	return &f.source
}

@(private = "file")
server_files_list :: proc(src: ^ui.File_Source, path: string, reply: ui.File_Reply) {
	app := (^App)(src.user)
	tag := server_files_wait(&app.server_files.list, reply)
	request(app, .Server_Files_List, "GET", path != "" ? fmt.tprintf("/api/fs/list?path=%s", url_escape(path)) : "/api/fs/list", tag = tag)
}

// `path` from the location ("": the location itself), false when it is not in it.
@(private = "file")
server_files_within :: proc(f: ^Server_Files, path: string) -> (rel: string, ok: bool) {
	p := path_clean(path)
	if p == f.location { return "", true }
	if !strings.has_prefix(p, f.location) || len(p) <= len(f.location) || p[len(f.location)] != '/' { return "", false }
	return p[len(f.location) + 1:], true
}

@(private = "file")
server_files_read :: proc(src: ^ui.File_Source, path: string, max: int, reply: ui.File_Reply) {
	app := (^App)(src.user)
	f := &app.server_files
	rel, ok := server_files_within(f, path)
	if !ok || rel == "" {
		ui.file_reply_failed(reply, i18n.tr("Only the files of the session's folder are shown here."))
		return
	}
	tag := server_files_wait(&f.read, reply)
	// (the server sends the whole file: the browser keeps the start it asked for)
	request(app, .Server_File_Read, "GET", fmt.tprintf("/api/fs/read/%s?%s", path_escape(rel), location_query(f.location)), tag = tag)
}

@(private = "file")
server_files_find :: proc(src: ^ui.File_Source, folder, query: string, limit: int, reply: ui.File_Reply) {
	app := (^App)(src.user)
	f := &app.server_files
	rel, ok := server_files_within(f, folder)
	if !ok {
		ui.file_reply_failed(reply, i18n.tr("The search covers the session's folder only."))
		return
	}
	delete(f.found_in)
	f.found_in = rel != "" ? strings.concatenate({rel, "/"}) : ""
	tag := server_files_wait(&f.find, reply)
	request(app, .Server_Files_Find, "GET", fmt.tprintf("/api/fs/find?%s&query=%s&limit=%d", location_query(f.location), url_escape(query), limit), tag = tag)
}

// A path in the address of a request: each part escaped, the slashes kept.
@(private = "file")
path_escape :: proc(p: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	rest := p
	first := true
	for part in strings.split_iterator(&rest, "/") {
		if !first { strings.write_byte(&b, '/') }
		first = false
		strings.write_string(&b, url_escape(part))
	}
	return strings.to_string(b)
}

// `reply` waits, in the place of the one before; the tag of its request.
@(private = "file")
server_files_wait :: proc(w: ^Server_Files_Wait, reply: ui.File_Reply) -> string {
	w.reply, w.waiting = reply, true
	w.asked += 1
	return fmt.tprintf("%d", w.asked)
}

// Whether `r` answers the reply that waits: the latest asked. It waits no more.
@(private = "file")
server_files_answers :: proc(w: ^Server_Files_Wait, r: ^Request) -> bool {
	if !w.waiting || r.tag != fmt.tprintf("%d", w.asked) { return false }
	w.waiting = false
	return true
}

// What is on its way ends: the server left, its answers will not come.
server_files_forget :: proc(app: ^App) {
	f := &app.server_files
	for w in ([]^Server_Files_Wait{&f.list, &f.read, &f.find}) {
		if w.waiting { ui.file_reply_failed(w.reply, i18n.tr("The server changed.")) }
		w.waiting = false
	}
	delete(f.location); delete(f.found_in)
	f.location, f.found_in = "", ""
}

////////////////////////////////
// What the answers to its requests do (net.odin REQ_FACTS)

// The entries by their name: the server gives them relative to its own folder, whatever folder was asked.
server_files_list_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) {
	f := &app.server_files
	if !server_files_answers(&f.list, r) { return }
	items := jarr(v, "data")
	entries := make([]ui.File_Entry, len(items), context.temp_allocator)
	for it, i in items {
		p, _ := strings.replace_all(jstr(it, "path"), `\`, "/", context.temp_allocator)
		entries[i] = {name = filepath.base(strings.trim_right(p, "/")), kind = jstr(it, "type") == "directory" ? .Folder : .File, size = -1}
	}
	ui.file_reply_listed(f.list.reply, entries)
}

server_files_list_on_fail :: proc(app: ^App, r: ^Request, failure: Failure, message: string) -> (told: bool) {
	f := &app.server_files
	if server_files_answers(&f.list, r) { ui.file_reply_failed(f.list.reply, message, refused = failure == .Refused, missing = r.status == 404) }
	return true
}

server_file_read_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) {
	f := &app.server_files
	if server_files_answers(&f.read, r) { ui.file_reply_read(f.read.reply, transmute([]u8)r.resp, i64(len(r.resp))) }
}

server_file_read_on_fail :: proc(app: ^App, r: ^Request, failure: Failure, message: string) -> (told: bool) {
	f := &app.server_files
	if server_files_answers(&f.read, r) { ui.file_reply_failed(f.read.reply, message, refused = failure == .Refused, missing = r.status == 404) }
	return true
}

// What the server found in the location, best first: what is in the folder searched, by its path from it.
server_files_find_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) {
	f := &app.server_files
	if !server_files_answers(&f.find, r) { return }
	entries := make([dynamic]ui.File_Entry, 0, len(jarr(v, "data")), context.temp_allocator)
	for it in jarr(v, "data") {
		p := path_clean(jstr(it, "path"))
		if !strings.has_prefix(p, f.found_in) || len(p) == len(f.found_in) { continue }
		append(&entries, ui.File_Entry{name = p[len(f.found_in):], kind = jstr(it, "type") == "directory" ? .Folder : .File, size = -1})
	}
	ui.file_reply_found(f.find.reply, entries[:])
}

server_files_find_on_fail :: proc(app: ^App, r: ^Request, failure: Failure, message: string) -> (told: bool) {
	f := &app.server_files
	if server_files_answers(&f.find, r) { ui.file_reply_failed(f.find.reply, message, refused = failure == .Refused) }
	return true
}
