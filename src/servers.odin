// Several opencode servers: the desktop app's on this computer (service.json, always first), those the user added
// (%APPDATA%\opencode-native\servers.txt), the one of --url. One is connected at a time; switching drops everything
// read from the last one and reads the new one.
package occ

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "gt:ui"

Server :: struct {
	name:     string,
	url:      string,   // "http(s)://host[:port]"
	password: string,   // Basic authentication as "opencode" ("" : none)
	local:    bool,     // the desktop app's (found again at every start, not saved)
	argv:     bool,     // given by --url (not saved)
}

// One connection: its HTTP client and its event thread. Never freed while the program runs: a request's worker or the
// thread of a server left may still be using it (they end on their own; what they bring back is dropped).
Conn :: struct {
	http:   Http,
	stop:   bool,      // (atomic) the event thread stops at its next event or retry
	server: int,       // its index in app.servers when it was made
}

servers_path :: proc() -> string {
	return pjoin({config_dir(), "servers.txt"})
}

// The list at start: this computer's server, the saved ones (a line "name<TAB>url<TAB>password"), then --url's.
servers_init :: proc(app: ^App) {
	cfg := discover_server()
	argv := false
	for a in os.args[1:] { if strings.has_prefix(a, "--url=") { argv = true } }
	local := argv ? local_server_config() : cfg
	append(&app.servers, Server{name = strings.clone("This computer"), url = server_url(local), password = strings.clone(local.password), local = true})
	if data, err := os.read_entire_file(servers_path(), context.temp_allocator); err == nil {
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			f := strings.split(line, "\t", context.temp_allocator)
			if len(f) < 2 || strings.trim_space(f[0]) == "" { continue }
			append(&app.servers, Server{name = strings.clone(f[0]), url = strings.clone(f[1]), password = strings.clone(len(f) > 2 ? f[2] : "")})
		}
	}
	app.server = 0
	if argv {
		append(&app.servers, Server{name = strings.clone("Command line"), url = server_url(cfg), password = strings.clone(cfg.password), argv = true})
		app.server = len(app.servers) - 1
	} else if last := settings_get("server"); last != "" {
		for s, i in app.servers { if s.name == last { app.server = i } }
	}
	for a in os.args[1:] {   // --server=<name>: that one at start
		if strings.has_prefix(a, "--server=") {
			for s, i in app.servers { if s.name == a[len("--server="):] { app.server = i } }
		}
	}
}

// This computer's server as its files say now, whatever --url / --password say.
local_server_config :: proc() -> Server_Config {
	saved_args := os.args
	os.args = os.args[:1]
	defer os.args = saved_args
	return discover_server()
}

REDISCOVER_MS :: 2500

// While this computer's server does not answer, look again every few seconds where it runs: the service may have
// started since, or restarted on another port. A new address reconnects at once.
servers_rediscover :: proc(app: ^App) {
	if app.online || app.server < 0 || app.server >= len(app.servers) || !app.servers[app.server].local { return }
	now := ui.now_ms()
	if now - app.rediscover_ms < REDISCOVER_MS { return }
	app.rediscover_ms = now
	cfg := local_server_config()
	url := server_url(cfg)
	s := &app.servers[app.server]
	if url == s.url && cfg.password == s.password { delete(url); return }
	delete(s.url); delete(s.password)
	s.url, s.password = url, strings.clone(cfg.password)
	server_connect(app, app.server)
}

servers_save :: proc(app: ^App) {
	b := strings.builder_make(context.temp_allocator)
	for s in app.servers {
		if s.local || s.argv { continue }
		fmt.sbprintf(&b, "%s\t%s\t%s\n", s.name, s.url, s.password)
	}
	_ = os.make_directory_all(filepath.dir(servers_path()))
	_ = os.write_entire_file(servers_path(), transmute([]u8)strings.to_string(b))
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
// one's event stream loads everything when it connects (stream_state).
server_connect :: proc(app: ^App, i: int) {
	if i < 0 || i >= len(app.servers) { return }
	s := app.servers[i]
	c := new(Conn)
	c.server = i
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
	app.server = i
	if !s.argv { settings_set("server", s.name) }
	thread.create_and_start_with_data(c, events_thread, self_cleanup = true)
}

// What was read from the server left: sessions, the conversation, agents, models, projects, the settings' facts.
@(private = "file")
server_forget :: proc(app: ^App) {
	app.online = false
	app.auth_failed = false
	delete(app.server_version)
	app.server_version = ""
	chat_reset(&app.chat)
	for id in app.nav { delete(id) }
	clear(&app.nav)
	permissions_clear(app)
	app.sessions = nil
	app.sessions_loaded = false
	app.opened_first = false
	app.start_session = ""
	for k in app.busy { delete(k) }
	clear(&app.busy)
	for a in app.agents { delete(a.id); delete(a.name); delete(a.description); delete(a.mode) }
	clear(&app.agents)
	for m in app.models { delete(m.id); delete(m.provider); delete(m.name); delete(m.family) }
	clear(&app.models)
	app.have_agents, app.have_models = false, false
	app.projects = nil
	server_facts_reset(app)
	app.stats_open = false
}

////////////////////////////////
// The interface: the status bar's server menu, the dialog that adds or edits one

Server_Edit :: struct {
	open:     bool,
	index:    int,          // the server edited (-1: a new one)
	name:     ui.Text_Field,
	url:      ui.Text_Field,
	password: ui.Text_Field,
}

server_edit_open :: proc(app: ^App, i: int) {
	e := &app.server_edit
	e.open = true
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
			label := fmt.tprintf("%s   %s###srv%d", s.name, s.url, i)
			if ui.menu_item(label, "", i == app.server).clicked && i != app.server { server_connect(app, i) }
		}
		ui.menu_separator()
		if ui.menu_item("Add a server…").clicked { server_edit_open(app, -1) }
		cur := app.server >= 0 && app.server < len(app.servers) ? app.servers[app.server] : Server{local = true}
		if ui.menu_item("Edit this server…", enabled = !cur.local && !cur.argv).clicked { server_edit_open(app, app.server) }
	}
}

SERVER_DIALOG_TOP :: 0.2   // of the window's height

server_dialog :: proc(app: ^App, em: f32) {
	e := &app.server_edit
	if ui.modal("server", em * 32, &e.open, SERVER_DIALOG_TOP) {
		dialog_backdrop()
		ui.spacer(ui.px(em * 1.2))
		pad :: proc(em: f32) { ui.spacer(ui.px(em * DIALOG_MARGIN_EM)) }
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center) {
			pad(em)
			glyph(ICO_GLOBE, accent(), math.round(em * 1.1))
			ui.spacer(ui.px(em * 0.5))
			text("t", e.index >= 0 ? "Edit the server" : "Add a server", hex(HEX_BRIGHT), ui.Style_Mod{font_size = math.round(em * 1.2), height = ui.px(em * 1.8)})
		}
		ui.spacer(ui.px(em * 0.9))
		field :: proc(id, label, hint: string, f: ^ui.Text_Field, em: f32, secret := false) -> ui.Edit_Result {
			res: ui.Edit_Result
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
			if ui.row(.Center, id = id) {
				ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
				text("k", label, hex(HEX_WEAK), ui.Style_Mod{font_size = math.round(em * 0.88), height = ui.px(em * 1.5)}, ui.px(em * 6))
				ui.next({width = ui.fill(), height = ui.px(math.round(em * FIELD_H_EM)), axis = .X, cross = .Center})
				if well("###w", .X, radius = 7) {
					if ui.tags("bare") {
						ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.5})
						res = ui.line_edit("###e", f, hint, secret = secret)
					}
				}
				ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
			}
			ui.spacer(ui.px(em * 0.5))
			return res
		}
		r1 := field("###fn", "Name", "Work laptop", &e.name, em)
		r2 := field("###fu", "Address", "http://host:4096", &e.url, em)
		r3 := field("###fp", "Password", "none", &e.password, em, secret = true)
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row() {
				ui.spacer(ui.px(em * 7.4))
				text("h", "the server's OPENCODE_SERVER_PASSWORD, as user opencode", hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * 0.78), height = ui.px(em * 1.3)}, ui.fill())
				ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
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
				if bevel_button("###rm", "Remove", ICO_DELETE, .Danger).clicked {
					server_remove(app, e.index)
					e.open = false
				}
			}
			ui.spacer(ui.fill())
			if taken { text("tk", "That name is taken", hex(HEX_RED), ui.Style_Mod{font_size = math.round(em * 0.8), height = ui.px(em * 1.5)}); ui.spacer(ui.px(em * 0.6)) }
			if bevel_button("###cancel", "Cancel", "", .Normal).clicked { e.open = false }
			ui.spacer(ui.px(em * 0.5))
			if bevel_button("###ok", e.index >= 0 ? "Save and connect" : "Add and connect", ICO_CHECK, .Accent, disabled = !valid).clicked { save = true }
			pad(em)
		}
		if save && valid {
			s := Server{name = strings.clone(name), url = strings.clone(server_normalize(url)), password = strings.clone(ui.field_string(&e.password))}
			i := e.index
			if i >= 0 {
				old := app.servers[i]
				delete(old.name); delete(old.url); delete(old.password)
				app.servers[i] = s
			} else {
				append(&app.servers, s)
				i = len(app.servers) - 1
			}
			servers_save(app)
			e.open = false
			server_connect(app, i)
		}
		ui.spacer(ui.px(em * 1.2))
		dialog_close(&e.open)
	}
}

@(private = "file")
server_remove :: proc(app: ^App, i: int) {
	if i <= 0 || i >= len(app.servers) || app.servers[i].local { return }
	s := app.servers[i]
	ordered_remove(&app.servers, i)
	delete(s.name); delete(s.url); delete(s.password)
	servers_save(app)
	if app.server == i {
		server_connect(app, 0)
	} else if app.server > i {
		app.server -= 1
	}
	if app.conn != nil { app.conn.server = app.server }
}

