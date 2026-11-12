// Several opencode servers: the desktop app's on this computer (service.json, always first), those the user added
// (%APPDATA%\opencode-native\servers.txt), the one of --url. One is connected at a time; switching drops everything
// read from the last one and reads the new one.
package ocn

import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:thread"
import store "gt:store"
import "gt:ui"
import lucide "gt:lucide"

Server :: struct {
	name:     string,
	url:      string,   // "http(s)://host[:port]"
	password: string,   // Basic authentication as "opencode" ("" : none)
	stored:   string,   // its field in the file when it could not be opened (another account, a locked keyring): kept as it is
	local:    bool,     // the desktop app's (found again at every start, not saved)
	argv:     bool,     // given by --url (not saved)
}

// One connection: its HTTP client and its event thread. Never freed while the program runs: a request's worker or the
// thread of a server left may still be using it (they end on their own; what they bring back is dropped).
Conn :: struct {
	app:    ^App,      // (for its threads: the_app is the interface's)
	http:   Http,
	stop:   bool,      // (atomic) the event thread stops at its next event or retry
	browser: ^Browser_Link,   // the agents' browser tools on this connection, while they are wanted (browser_mcp.odin)
	browsers_left: [dynamic]^Browser_Link,   // ... in the folders one left while an agent works there
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

// The list at start: this computer's server, the saved ones (a line "name<TAB>url<TAB>protected password"), then --url's.
servers_init :: proc(app: ^App) {
	cfg := discover_server(app.cli.url, app.cli.password)
	argv := app.cli.url != ""
	local := argv ? discover_server() : cfg   // (this computer's server as its files say, whatever --url says)
	append(&app.servers, Server{name = strings.clone("This computer"), url = server_url(local), password = strings.clone(local.password), local = true})
	for e in store.list(&app.stores.servers) {   // (read at the start, stores_open: the name, then "url<TAB>field")
		if strings.trim_space(e.key) == "" { continue }
		url, _, field := strings.partition(e.value, "\t")
		password, stored, clear_text := password_from_field(e.key, field)
		append(&app.servers, Server{name = strings.clone(e.key), url = strings.clone(url), password = strings.clone(password), stored = strings.clone(stored)})
		if clear_text { app.servers_in_clear = true }
	}
	app.server = 0
	if argv {
		append(&app.servers, Server{name = strings.clone("Command line"), url = server_url(cfg), password = strings.clone(cfg.password), argv = true})
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
// started since, or restarted on another port. A new address reconnects at once.
servers_rediscover :: proc(app: ^App) {
	if !rediscovering(app) { return }
	now := ui.now_ms()
	if now - app.rediscover_ms < REDISCOVER_MS { return }
	app.rediscover_ms = now
	cfg := discover_server()
	defer { delete(cfg.host); delete(cfg.password) }
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
// (stores_open): a failure leaves the file as it was, no password lost. `saved`: every password was protected and the list
// handed over; the disk follows in a moment.
servers_save :: proc(app: ^App) -> (saved: bool) {
	entries := make([dynamic]store.Entry, context.temp_allocator)
	for s in app.servers {
		if s.local || s.argv { continue }
		field := s.stored
		if s.password != "" {
			f, ok := password_seal(s.name, s.password)
			if !ok { ui.toast(.Bad, "The password of %s could not be protected: the list of servers was not saved", label_safe(s.name)); return false }
			field = f
		}
		append(&entries, store.Entry{s.name, fmt.tprintf("%s\t%s", s.url, field)})
	}
	store.replace(&app.stores.servers, entries[:])
	app.servers_in_clear = false
	return true
}

// A password that could not be opened at start (a locked keyring) may open now: asked again when it is needed, the keyring unlocked meanwhile
// needs no restart. (`stored` stays until then.)
server_password_retry :: proc(s: ^Server) {
	if s.password != "" || s.stored == "" { return }
	p, sealed, ok := password_open(s.name, s.stored)
	if !sealed || !ok { return }
	s.password = strings.clone(p)
	delete(s.stored)
	s.stored = ""
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

// Connects to server `i`: the last connection's thread is told to stop, everything read from it is dropped, and the new
// one's event stream loads everything when it connects (stream_up).
server_connect :: proc(app: ^App, i: int) {
	if i < 0 || i >= len(app.servers) { return }
	server_password_retry(&app.servers[i])
	s := app.servers[i]
	c := new(Conn)
	c.app = app
	if !http_init(&c.http, s.url, "opencode", s.password) {
		ui.toast(.Bad, "No HTTP client for %s", s.url)
		free(c)
		return
	}
	if app.conn != nil {
		sync.atomic_store(&app.conn.stop, true)
		server_forget(app)
	}
	app.conn = c
	append(&app.cx.conns, c)
	app.server = i
	if !s.argv { settings_set(app, "server", s.name) }
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
	remote_reset(&app.cx.chat_read)
	for id in app.nav { delete(id) }
	clear(&app.nav)
	for st in app.nav_steps { delete(st.id) }
	clear(&app.nav_steps)
	nav_clear(app)
}

@(private = "file")
server_dialogs_forget :: proc(app: ^App) {
	app.cx.due[.Refresh], app.cx.due[.Facts], app.cx.due[.Children], app.cx.due[.Context] = {}, {}, {}, {}
	app.cx.open[.Picker] = false
	app.cx.open[.Delete], app.cx.open[.Rename], app.rename.at = false, false, .None   // (their ids were that server's: nothing acts on one with what came from the other)
	sidebar_hold_end(app)
	delete(app.cx.fork_prompt)
	app.cx.fork_prompt = ""
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
	app.cx.open[.Pair] = false   // (its code was that server's; the dialog's state is in known, its being open is not)
}

// The window closes. Every connection's threads are told; none is waited for (one may be blocked in a read: the process ends with it).
threads_stop :: proc(app: ^App) {
	for c in app.cx.conns { sync.atomic_store(&c.stop, true) }
	detached_stop(app)
	terminals_stop(app)
	browser_stop(app)
}

////////////////////////////////
// The interface: the status bar's server menu, the dialog that adds or edits one

Server_Edit :: struct {
	index:    int,          // the server edited (-1: a new one)
	name:     ui.Text_Field,
	url:      ui.Text_Field,
	password: ui.Text_Field,
	password_shown: bool,   // the password's eye: shown as text
}

server_edit_open :: proc(app: ^App, i: int) {
	e := &app.server_edit
	app.cx.open[.Server] = true
	e.password_shown = false   // (each time it opens, hidden)
	e.index = i
	if i >= 0 {
		s := app.servers[i]
		ui.field_set(&e.name, s.name)
		ui.field_set(&e.url, s.url)
		ui.field_set(&e.password, s.password)
	} else {
		ui.field_set(&e.name, "")
		ui.field_set(&e.url, "")
		ui.field_set(&e.password, "")
	}
}

server_menu :: proc(app: ^App, key: ui.Key, em: f32) {
	if ui.ctx_menu(key, em * 26) {
		for s, i in app.servers {
			label := fmt.tprintf("%s   %s###srv%d", label_safe(s.name), label_safe(s.url), i)
			if ui.menu_item(label, "", i == app.server, icon = lucide.SERVER).clicked && i != app.server { server_connect(app, i) }
		}
		ui.menu_separator()
		if ui.menu_item("Add a server…", icon = lucide.PLUG).clicked { server_edit_open(app, -1) }
		cur := app.server >= 0 && app.server < len(app.servers) ? app.servers[app.server] : Server{local = true}
		if ui.menu_item("Edit this server…", icon = lucide.PENCIL, enabled = !cur.local && !cur.argv).clicked { server_edit_open(app, app.server) }
	}
}

SERVER_DIALOG_TOP :: 0.2   // of the window's height

server_dialog :: proc(app: ^App, em: f32) {
	e := &app.server_edit
	if ui.modal("server", em * 32, &app.cx.open[.Server], SERVER_DIALOG_TOP) {
		dialog_backdrop()
		ui.spacer(ui.px(em * 1.2))
		pad :: proc(em: f32) { ui.spacer(ui.px(em * DIALOG_MARGIN_EM)) }
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center) {
			pad(em)
			glyph(lucide.GLOBE, accent(), math.round(em * ICON_LARGE))
			ui.spacer(ui.px(em * 0.5))
			text("t", e.index >= 0 ? "Edit the server" : "Add a server", hex(HEX_BRIGHT), ui.Style_Mod{font_size = math.round(em * FS_TITLE), height = ui.px(em * 1.8)})
		}
		ui.spacer(ui.px(em * 0.9))
		field :: proc(id, label, hint: string, f: ^ui.Text_Field, em: f32, secret := false, reveal: ^bool = nil) -> ui.Edit_Result {
			res: ui.Edit_Result
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
			if ui.row(.Center, id = id) {
				ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
				text("k", label, hex(HEX_WEAK), ui.Style_Mod{font_size = math.round(em * FS_NOTE), height = ui.px(em * 1.5)}, ui.px(em * 6))
				ui.next({width = ui.fill(), height = ui.px(math.round(em * FIELD_H_EM)), axis = .X, cross = .Center})
				if well("###w", .X, radius = 7) {
					if ui.tags("bare") {
						ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.5})
						res = ui.line_edit("###e", f, hint, secret = secret, reveal = reveal)
					}
				}
				ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
			}
			ui.spacer(ui.px(em * 0.5))
			return res
		}
		r1 := field("###fn", "Name", "Work laptop", &e.name, em)
		r2 := field("###fu", "Address", "http://host:4096", &e.url, em)
		r3 := field("###fp", "Password", "none", &e.password, em, secret = true, reveal = &e.password_shown)
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row() {
				ui.spacer(ui.px(em * 7.4))
				text("h", "the server's OPENCODE_SERVER_PASSWORD, as user opencode", hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.3)}, ui.fill())
				ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
			}
			if note := password_note(); note != "" {
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
		name := strings.trim_space(ui.field_string(&e.name))
		url := strings.trim_space(ui.field_string(&e.url))
		taken := false
		for s, i in app.servers { if s.name == name && i != e.index { taken = true } }
		valid := name != "" && url != "" && !taken
		save := r1.committed || r2.committed || r3.committed
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center) {
			pad(em)
			if e.index >= 0 {
				if bevel_button("###rm", "Remove", lucide.TRASH_2, .Danger).clicked {
					server_remove(app, e.index)
					app.cx.open[.Server] = false
				}
			}
			ui.spacer(ui.fill())
			if taken { text("tk", "That name is taken", hex(HEX_RED), ui.Style_Mod{font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.5)}); ui.spacer(ui.px(em * 0.6)) }
			if bevel_button("###cancel", "Cancel", "", .Normal).clicked { app.cx.open[.Server] = false }
			ui.spacer(ui.px(em * 0.5))
			if bevel_button("###ok", e.index >= 0 ? "Save and connect" : "Add and connect", lucide.CHECK, .Accent, disabled = !valid).clicked { save = true }
			pad(em)
		}
		if save && valid {
			s := Server{name = strings.clone(name), url = strings.clone(server_normalize(url)), password = strings.clone(ui.field_string(&e.password))}
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
			if servers_save(app) && forget != "" { password_forget(forget) }
			app.cx.open[.Server] = false
			server_connect(app, i)
		}
		ui.spacer(ui.px(em * 1.2))
		dialog_close(&app.cx.open[.Server])
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
	password_forget(s.name)
	delete(s.name); delete(s.url); delete(s.password); delete(s.stored)
	servers_save(app)
	if app.server == i {
		server_connect(app, 0)
	} else if app.server > i {
		app.server -= 1
	}
}

