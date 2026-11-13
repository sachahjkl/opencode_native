// Several opencode servers: the desktop app's on this computer (service.json, always first), those the user added
// (%APPDATA%\opencode-native\servers.txt), the one of --url. One is connected at a time; switching drops everything
// read from the last one and reads the new one.
package ocn

import "core:fmt"
import tasks "gt:tasks"
import "core:math"
import "core:mem/virtual"
import "core:strings"
import "core:thread"
import store "gt:store"
import "gt:ui"
import lucide "gt:lucide"
import remote "gt:remote"
import i18n "gt:i18n"

Server :: struct {
	name:     string,
	url:      string,   // "http(s)://host[:port]"
	password: string,   // Basic authentication as "opencode" ("" : none)
	stored:   string,   // its field in the file when it could not be opened (another account, a locked keyring): kept as it is
	local:    bool,     // the desktop app's (found again at every start, not saved)
	argv:     bool,     // given by --url (not saved)
}

servers_path :: proc() -> string {
	return pjoin({config_dir(), "servers.txt"})
}

// A field of the file as a password: what password_seal wrote, or a password in clear from an older version.
password_from_field :: proc(name, field: string) -> (password, stored: string, clear_text: bool) {
	if field == "" { return "", "", false }
	if p, is_sealed, ok := password_open(name, field); is_sealed {
		return p, ok ? "" : field, false
	}
	return field, "", true
}

// The list at start, as far as it is known without reading anything: this computer's server, the saved ones (a line
// "name<TAB>url<TAB>protected password"), then --url's. Where this computer's server runs (its files), --url's password and the
// saved passwords (the keyring) are read on a chore when one of them is connected to (server_connect): until then a saved
// server's field waits in `stored`, as one the keyring would not open.
servers_init :: proc(app: ^App) {
	argv := app.cli.url != ""
	append(&app.servers, Server{name = strings.clone(i18n.later("This computer")), local = true})
	for e in store.list(&app.stores.servers) {   // (read at the start, stores_open: the name, then "url<TAB>field")
		if strings.trim_space(e.key) == "" { continue }
		url, _, field := strings.partition(e.value, "\t")
		append(&app.servers, Server{name = strings.clone(e.key), url = strings.clone(url), stored = strings.clone(field)})
	}
	app.server = 0
	if argv {
		append(&app.servers, Server{name = strings.clone(i18n.later("Command line")), argv = true})
		app.server = len(app.servers) - 1
	} else if last := settings_get(app, "server"); last != "" {
		for s, i in app.servers { if s.name == last { app.server = i } }
	}
	if name := app.cli.server; name != "" {   // --server=<name>: that one at start
		for s, i in app.servers { if s.name == name { app.server = i } }
	}
}

REDISCOVER_MS :: 2500

// While this computer's server does not answer, look again every few seconds where it runs: the service may have
// started since, or restarted on another port. A new address reconnects at once. Its files are read on a chore, one look at a time.
servers_rediscover :: proc(app: ^App) {
	if !rediscovering(app) || app.rediscover_busy { return }
	now := ui.now_ms()
	if now - app.rediscover_ms < REDISCOVER_MS { return }
	app.rediscover_ms = now
	app.rediscover_busy = true
	tasks.add(&app.cx.chores, rediscover_work, app)
}

@(private = "file")
Rediscovered :: struct { app: ^App, cfg: Server_Config }

@(private = "file")
rediscover_work :: proc(data: rawptr) {
	found := new(Rediscovered)
	found^ = {(^App)(data), discover_server()}
	if !ui.post(&found.app.state, rediscover_found, found) { delete(found.cfg.host); delete(found.cfg.password); free(found) }
}

@(private = "file")
rediscover_found :: proc(data: rawptr, word: u64) {
	found := (^Rediscovered)(data)
	app, cfg := found.app, found.cfg
	defer { delete(cfg.host); delete(cfg.password); free(found) }
	app.rediscover_busy = false
	if !rediscovering(app) { return }   // (it answered meanwhile, or another server was chosen)
	url := server_url(cfg)
	s := &app.servers[app.server]
	if url == s.url && cfg.password == s.password { delete(url); return }
	delete(s.url); delete(s.password)
	s.url, s.password = url, strings.clone(cfg.password)
	reopen_keep(app)
	server_connect(app, app.server)
}

@(private = "file")
rediscovering :: proc(app: ^App) -> bool {
	return !online(app) && app.server >= 0 && app.server < len(app.servers) && app.servers[app.server].local
}

// When the next look is due (deferred_tick). 0: not looking.
rediscover_in_ms :: proc(app: ^App) -> int {
	if !rediscovering(app) { return 0 }
	return max(int(app.rediscover_ms + REDISCOVER_MS - ui.now_ms()) + 1, 1)
}

// The same service, come back on another port, has the same sessions: nothing else says it is the same one. So what was shown
// is noted here, and sessions_load opens it again if the server's list has it.
@(private = "file")
reopen_keep :: proc(app: ^App) {
	cx := &app.cx
	reopen_clear(app)
	if app.chat.id == "" { return }
	cx.reopen = {id = strings.clone(app.chat.id), msg = strings.clone(app.chat.view_msg), dy = app.chat.view_dy, bottom = chat_following(app)}
}

reopen_clear :: proc(app: ^App) {
	delete(app.cx.reopen.id); delete(app.cx.reopen.msg)
	app.cx.reopen = {}
}

// The whole list at once to its store, whose worker writes it beside the file, then moves it over, readable by the user only
// (stores_open): a failure leaves the file as it was, no password lost. The passwords are protected on a chore (the keyring is a call
// over D-Bus, or DPAPI), the list handed over when that is done. `forget`: a keyring item that goes once every password is safe (a
// server renamed); `forget_first`: one that goes whatever happens (a server removed). The chores keep their order: two saves land as
// they were asked.
servers_save :: proc(app: ^App, forget := "", forget_first := "") {
	job := new(Servers_Save)
	job.app = app
	job.forget, job.forget_first = strings.clone(forget), strings.clone(forget_first)
	for s in app.servers {
		if s.local || s.argv { continue }
		append(&job.servers, Server{name = strings.clone(s.name), url = strings.clone(s.url), password = strings.clone(s.password), stored = strings.clone(s.stored)})
	}
	tasks.add(&app.cx.chores, servers_save_work, job)
}

@(private = "file")
Servers_Save :: struct {
	app:      ^App,
	servers:  [dynamic]Server,        // (copies, owned)
	forget, forget_first: string,     // (owned)
	failed:   string,                 // the server whose password could not be protected: nothing was saved (owned)
	entries:  [dynamic]store.Entry,   // what goes to the store (owned)
}

@(private = "file")
servers_save_work :: proc(data: rawptr) {
	job := (^Servers_Save)(data)
	if job.forget_first != "" { password_forget(job.forget_first) }
	for s in job.servers {
		field := s.stored
		if s.password != "" {
			f, ok := password_seal(s.name, s.password)
			if !ok { job.failed = strings.clone(s.name); break }
			field = f
		}
		append(&job.entries, store.Entry{strings.clone(s.name), fmt.aprintf("%s\t%s", s.url, field)})
	}
	if job.failed == "" && job.forget != "" { password_forget(job.forget) }
	if !ui.post(&job.app.state, servers_saved, job) { servers_save_free(job) }
}

@(private = "file")
servers_saved :: proc(data: rawptr, word: u64) {
	job := (^Servers_Save)(data)
	defer servers_save_free(job)
	app := job.app
	if job.failed != "" {
		ui.announce(&app.announcer, .Bad, fmt.tprintf(i18n.tr("The password of %s could not be protected: the list of servers was not saved"), label_safe(job.failed)))
		return
	}
	store.replace(&app.stores.servers, job.entries[:])
	app.servers_in_clear = false
}

@(private = "file")
servers_save_free :: proc(job: ^Servers_Save) {
	for s in job.servers { delete(s.name); delete(s.url); delete(s.password); delete(s.stored) }
	for e in job.entries { delete(e.key); delete(e.value) }
	delete(job.servers); delete(job.entries)
	delete(job.forget); delete(job.forget_first); delete(job.failed)
	free(job)
}

// What a connection needs read first, read on a chore (files, the keyring: the interface waits for neither). A password that could not be
// opened (a locked keyring) is asked again at the next connection: a keyring unlocked meanwhile needs no restart.
@(private = "file")
Servers_Read :: struct {
	app:      ^App,
	seq:      u64,    // the connection it was read for (App.connect_seq): a later choice connects instead, what was read is kept
	index:    int,    // the server to connect to once read
	local:    bool,   // where this computer's server runs: its files
	argv:     bool,   // --url's address and password (this computer's password, if it is this computer's server)
	cli_url, cli_password: string,   // (owned)
	fields:   [dynamic]Field_Read,
	local_cfg, argv_cfg: Server_Config,
}

// A saved server's field, and what it holds (all owned).
@(private = "file")
Field_Read :: struct { name, field, password, stored: string, clear_text: bool }

@(private = "file")
servers_read_work :: proc(data: rawptr) {
	job := (^Servers_Read)(data)
	if job.local { job.local_cfg = discover_server() }
	if job.argv { job.argv_cfg = discover_server(job.cli_url, job.cli_password) }
	for &f in job.fields {
		password, stored, clear_text := password_from_field(f.name, f.field)
		f.password, f.stored, f.clear_text = strings.clone(password), strings.clone(stored), clear_text
	}
	if !ui.post(&job.app.state, servers_read_done, job) { servers_read_free(job) }
}

@(private = "file")
servers_read_free :: proc(job: ^Servers_Read) {
	for f in job.fields { delete(f.name); delete(f.field); delete(f.password); delete(f.stored) }
	delete(job.fields)
	delete(job.cli_url); delete(job.cli_password)
	delete(job.local_cfg.host); delete(job.local_cfg.password)
	delete(job.argv_cfg.host); delete(job.argv_cfg.password)
	free(job)
}

@(private = "file")
servers_read_done :: proc(data: rawptr, word: u64) {
	job := (^Servers_Read)(data)
	app := job.app
	defer servers_read_free(job)
	for &s in app.servers {
		switch {
		case s.local && job.local:
			delete(s.url); delete(s.password)
			s.url, s.password = server_url(job.local_cfg), strings.clone(job.local_cfg.password)
		case s.argv && job.argv:
			delete(s.url); delete(s.password)
			s.url, s.password = server_url(job.argv_cfg), strings.clone(job.argv_cfg.password)
		case !s.local && !s.argv && s.password == "":
			// (by its name and the field read: a server renamed or edited meanwhile keeps what it has now)
			for f in job.fields {
				if f.name != s.name || f.field != s.stored { continue }
				delete(s.stored)
				s.password, s.stored = strings.clone(f.password), strings.clone(f.stored)
				if f.clear_text { app.servers_in_clear = true }
			}
		}
	}
	if app.servers_in_clear { servers_save(app) }   // (an older version's password in clear: protected now)
	if job.seq == app.connect_seq { server_connect_now(app, job.index) }
}

// "host:port" or "https://host" as typed: a full address ("http://" when no scheme is said, no trailing slash).
server_normalize :: proc(url: string) -> string {
	u := strings.trim_space(url)
	u = strings.trim_right(u, "/")
	if !strings.has_prefix(u, "http://") && !strings.has_prefix(u, "https://") { u = strings.concatenate({"http://", u}, context.temp_allocator) }
	return u
}

// The base of the server connected ("" : none).
server_base :: proc(app: ^App) -> string { return app.conn != nil ? app.conn.http.base : "" }

server_name :: proc(app: ^App) -> string { return app.server >= 0 && app.server < len(app.servers) ? app.servers[app.server].name : "" }

// Connects to server `i`: the last connection's threads are told to stop, everything read from it is dropped, the App lets go of it
// (freed once what still uses it ended), and the new one's event stream loads everything when it connects (stream_up).
// `all`: every saved password is read, not only this server's (the start: an older version's in clear are protected then).
server_connect :: proc(app: ^App, i: int, all := false) {
	if i < 0 || i >= len(app.servers) { return }
	app.connect_seq += 1
	job := new(Servers_Read)
	job^ = {app = app, seq = app.connect_seq, index = i}
	for s, k in app.servers {
		if s.local && s.url == "" && (all || k == i) { job.local = true }
		if s.argv && s.url == "" && (all || k == i) {
			job.argv = true
			job.cli_url, job.cli_password = strings.clone(app.cli.url), strings.clone(app.cli.password)
		}
		if !s.local && !s.argv && s.password == "" && s.stored != "" && (all || k == i) {
			append(&job.fields, Field_Read{name = strings.clone(s.name), field = strings.clone(s.stored)})
		}
	}
	if !job.local && !job.argv && len(job.fields) == 0 {
		servers_read_free(job)
		server_connect_now(app, i)
		return
	}
	tasks.add(&app.cx.chores, servers_read_work, job)
}

// Connects to server `i`, all it needs known.
@(private = "file")
server_connect_now :: proc(app: ^App, i: int) {
	if i < 0 || i >= len(app.servers) { return }
	s := app.servers[i]
	h: Http
	if !http_init(&h, s.url, "opencode", s.password) {
		ui.announce(&app.announcer, .Bad, fmt.tprintf(i18n.tr("No HTTP client for %s"), s.url))
		delete(h.base)
		return
	}
	c := conn_make(app, h, HTTP_TRANSPORT, CONN_WORKERS)
	if old := app.conn; old != nil {
		conn_stop(old)
		server_forget(app)   // (app.conn is still that one: what must be undone there is asked of it)
		conn_release(app, old)
	}
	app.conn = c
	app.server = i
	if !s.argv { settings_set(app, "server", s.name) }
	conn_hold(c)   // (the event thread's: conn_release_post at its end)
	thread.create_and_start_with_data(c, events_thread, self_cleanup = true)
}

// What holds something of a server. Every one is here: a new one does not compile until it says what it forgets, what it holds and every flag
// that says something is on its way, since the answer will be dropped (answer) and could not lower it. A Remote is reset there too.
Feature :: enum u8 {
	View, Activity, Find, Waits, Permissions, Forms, Busy, Slash, Queue, Outgoing, Dialogs, Known, Facts, Stats, Changes, Integrations, Plugins,
	Schedules, Artifacts, Files, Mentions, Terminals, Outputs, Browser, Preview,
}

@(rodata) FEATURE_FORGET := [Feature]proc(app: ^App){
	.View         = server_view_forget,
	.Activity     = activity_forget,
	.Find         = find_forget,
	.Waits        = waits_forget,
	.Permissions  = permissions_clear,
	.Forms        = forms_clear,
	.Busy         = busy_forget,
	.Slash        = slash_forget,
	.Queue        = queue_forget,
	.Outgoing     = outgoing_forget,
	.Dialogs      = server_dialogs_forget,
	.Known        = server_known_end,
	.Facts        = server_facts_forget,
	.Stats        = stats_forget,
	.Changes      = changes_forget,
	.Integrations = integrations_forget,
	.Plugins      = plugins_forget,
	.Schedules    = schedules_forget,
	.Artifacts    = artifacts_forget,
	.Files        = files_forget,
	.Mentions     = mentions_forget,
	.Terminals    = terminals_forget,
	.Outputs      = output_views_forget,
	.Browser      = browser_forget,
	.Preview      = preview_forget,
}

// What was read from the server left, in the order of Feature. `app.conn` is still that server: what must be undone there can be asked of it
// (changes_forget, integrations_forget).
server_forget :: proc(app: ^App) {
	app.link = .Connecting
	for forget in FEATURE_FORGET { forget(app) }
}

@(private = "file")
server_view_forget :: proc(app: ^App) {
	chat_home(app)
	remote.reset(&app.cx.chat_read)
	for id in app.nav.drilled { delete(id) }
	clear(&app.nav.drilled)
	for st in app.nav.steps { delete(st.id) }
	clear(&app.nav.steps)
	nav_clear(app)
}

@(private = "file")
server_dialogs_forget :: proc(app: ^App) {
	app.cx.due[.Refresh], app.cx.due[.Facts], app.cx.due[.Children], app.cx.due[.Context] = {}, {}, {}, {}
	app.cx.open[.Picker] = false
	app.cx.open[.Delete], app.cx.open[.Rename], app.rename.at = false, false, .None   // (their ids were that server's: nothing acts on one with what came from the other)
	sidebar_hold_end(app)
	delete(app.composer.fork_prompt)
	app.composer.fork_prompt = ""
	app.opened_first = false
	app.start_session = ""
}

// (What it owns, and then all of it.)
@(private = "file")
server_known_end :: proc(app: ^App) {
	agents_clear(app)
	models_clear(app)
	delete(app.server_version)
	server_urls_clear(app)
	delete(app.busy)
	delete(app.agents)
	delete(app.models)
	delete(app.permissions)
	virtual.arena_destroy(&app.sess_arena)
	virtual.arena_destroy(&app.proj_arena)
	app.known = {}
	app.cx.sessions_ver += 1   // (no list, no busy, no waits: what was made from them goes)
	app.cx.open[.Pair] = false   // (its code was that server's; the dialog's state is in known, its being open is not)
}

// The window closes. Every connection's threads are told; none is waited for, workers included (one may be blocked in a read: the
// process ends with it).
threads_stop :: proc(app: ^App) {
	for c in app.cx.conns { conn_stop(c) }
	detached_stop(app)
	terminals_stop(app)
	browser_stop(app)
}

////////////////////////////////
// The interface: the status bar's server menu, the dialog that adds or edits one

Server_Edit :: struct {
	index:    int,          // the server edited (-1: a new one)
	name:     ui.Line_Edit,
	url:      ui.Line_Edit,
	password: ui.Line_Edit,
	password_shown: bool,   // the password's eye: shown as text
}

server_edit_open :: proc(app: ^App, i: int) {
	e := &app.server_edit
	app.cx.open[.Server] = true
	e.password_shown = false   // (each time it opens, hidden)
	e.index = i
	if i >= 0 {
		s := app.servers[i]
		ui.line_edit_set(&e.name, s.name)
		ui.line_edit_set(&e.url, s.url)
		ui.line_edit_set(&e.password, s.password)
	} else {
		ui.line_edit_set(&e.name, "")
		ui.line_edit_set(&e.url, "")
		ui.line_edit_set(&e.password, "")
	}
}

server_menu :: proc(app: ^App, key: string, em: f32) {
	if ui.menu(key, em * 26) {
		for s, i in app.servers {
			label := fmt.tprintf("%s   %s###srv%d", label_safe(i18n.tr(s.name)), label_safe(s.url), i)
			if ui.menu_item(label, "", i == app.server, icon = lucide.SERVER).clicked && i != app.server { server_connect(app, i) }
		}
		ui.menu_separator()
		if ui.menu_item(i18n.tr("Add a server…"), icon = lucide.PLUG).clicked { server_edit_open(app, -1) }
		cur := app.server >= 0 && app.server < len(app.servers) ? app.servers[app.server] : Server{local = true}
		if ui.menu_item(i18n.tr("Edit this server…"), icon = lucide.PENCIL, disabled = cur.local || cur.argv).clicked { server_edit_open(app, app.server) }
	}
}

SERVER_DIALOG_TOP :: 0.2   // of the window's height

server_dialog :: proc(app: ^App, em: f32) {
	e := &app.server_edit
	if ui.modal("server", &app.cx.open[.Server], {width_em = 32, top = SERVER_DIALOG_TOP}) {
		dialog_backdrop()
		pad :: proc(em: f32) { ui.spacer(ui.px(em * DIALOG_MARGIN_EM)) }
		if ui.dialog_header("sv_head", e.index >= 0 ? i18n.tr("Edit the server") : i18n.tr("Add a server"), {icon = lucide.GLOBE, close = true}) {}
		ui.spacer(ui.px(em * 0.9))
		field :: proc(id, label, hint: string, f: ^ui.Line_Edit, em: f32, secret := false, reveal: ^bool = nil) -> ui.Edit_Result {
			res: ui.Edit_Result
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
			if ui.row(.Center, id = id) {
				ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
				text("k", label, hex(HEX_WEAK), ui.Style_Mod{font_size = math.round(em * FS_NOTE), height = ui.px(em * 1.5)}, ui.px(em * 6))
				ui.next({width = ui.fill(), height = ui.px(math.round(em * FIELD_H_EM)), axis = .X, cross = .Center})
				if ui.well("###w", .X) {
					if ui.tags("bare") {
						ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.5})
						res = ui.line_edit("###e", f, {placeholder = hint, kind = secret ? .Secret : .Plain, reveal = reveal})
					}
				}
				ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
			}
			ui.spacer(ui.px(em * 0.5))
			return res
		}
		r1 := field("###fn", i18n.tr("Name"), i18n.tr("Work laptop"), &e.name, em)
		r2 := field("###fu", i18n.tr("Address"), "http://host:4096", &e.url, em)
		r3 := field("###fp", i18n.tr("Password"), i18n.tr("none"), &e.password, em, secret = true, reveal = &e.password_shown)
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row() {
				ui.spacer(ui.px(em * 7.4))
				text("h", i18n.tr("the server's OPENCODE_SERVER_PASSWORD, as user opencode"), hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.3)}, ui.fill())
				ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
			}
			if note := password_note(app); note != "" {
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
				if ui.row(id = "###storenote") {
					ui.spacer(ui.px(em * 7.4))
					ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
					if ui.column() { info_line(app, "###note", note, em, hex(HEX_YELLOW)) }
					ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
				}
			}
		}
		ui.spacer(ui.px(em * 1.1))
		name := strings.trim_space(ui.line_edit_string(&e.name))
		url := strings.trim_space(ui.line_edit_string(&e.url))
		taken := false
		for s, i in app.servers { if s.name == name && i != e.index { taken = true } }
		valid := name != "" && url != "" && !taken
		save := r1.committed || r2.committed || r3.committed
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center) {
			pad(em)
			if e.index >= 0 {
				if ui.button("rm", i18n.tr("Remove"), lucide.TRASH_2, {intent = .Danger}).clicked {
					server_remove(app, e.index)
					app.cx.open[.Server] = false
				}
			}
			ui.spacer(ui.fill())
			if taken { text("tk", i18n.tr("That name is taken"), hex(HEX_RED), ui.Style_Mod{font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.5)}); ui.spacer(ui.px(em * 0.6)) }
			if ui.button("cancel", i18n.tr("Cancel"), o = {intent = .Cancel}).clicked { app.cx.open[.Server] = false }
			ui.spacer(ui.px(em * 0.5))
			if ui.button("ok", ui.text_shown(e.index >= 0 ? i18n.tr("Save and connect") : i18n.tr("Add and connect")), lucide.CHECK, {intent = .Success, disabled = !valid}).clicked { save = true }
			pad(em)
		}
		if save && valid {
			s := Server{name = strings.clone(name), url = strings.clone(server_normalize(url)), password = strings.clone(ui.line_edit_string(&e.password))}
			i := e.index
			forget := ""   // (after the save: what was under the old name goes once it is safe under the new one)
			if i >= 0 {
				old := app.servers[i]
				stored, drop := server_password_moves(old, s)
				s.stored = strings.clone(stored)
				if drop { forget = strings.clone(old.name, context.temp_allocator) }
				delete(old.name); delete(old.url); delete(old.password); delete(old.stored)
				app.servers[i] = s
			} else {
				append(&app.servers, s)
				i = len(app.servers) - 1
			}
			servers_save(app, forget = forget)
			app.cx.open[.Server] = false
			server_connect(app, i)
		}
		ui.spacer(ui.px(em * 1.2))
	}
}

// A server edited: what its file field keeps, and whether what the old name held in the keyring can go. A password left empty that could not
// be opened (a locked keyring) stays where it is, and the field says under which name: it is the only copy, and renaming must not lose it. A
// password typed goes under the new name; only then is the old one's dropped.
server_password_moves :: proc(old, new: Server) -> (stored: string, drop_old: bool) {
	if new.password != "" { return "", new.name != old.name }
	if old.stored == "" { return "", true }   // (no password any more)
	return new.name != old.name ? password_field_of(old.name, old.stored) : old.stored, false
}

@(private = "file")
server_remove :: proc(app: ^App, i: int) {
	if i <= 0 || i >= len(app.servers) || app.servers[i].local { return }
	s := app.servers[i]
	ordered_remove(&app.servers, i)
	servers_save(app, forget_first = s.name)
	delete(s.name); delete(s.url); delete(s.password); delete(s.stored)
	if app.server == i {
		server_connect(app, 0)
	} else if app.server > i {
		app.server -= 1
	}
}

