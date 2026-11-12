// What the program remembers beside its preferences (prefs.txt is gt:config's), in its own folder (config_dir):
//   settings.txt        "key=value" lines: the Setup dialog's answer, the last session, the last server
//   palette_usage.txt   "kind:id<TAB>weight<TAB>time" lines: what the palette ranks first (palette.odin)
//   terminal_zoom.txt   "id<TAB>zoom" lines: each shell's zoom (terminal.odin)
//   session_zoom.txt    "id<TAB>zoom" lines: each session's conversation zoom (commands.odin)
//   servers.txt         "name<TAB>url<TAB>protected password" lines, readable by the user only (servers.odin)
//   drafts.json         what was typed in each session (drafts.odin)
//   notices.txt         what the person missed, and what they acknowledged (gt:notices: missed.odin)
// Each is read once, at the start, before the window: the first frame needs them (the server to connect, the session to
// show) and no frame waits yet. Then they are kept in memory and written by gt:store's workers, once the changes rest,
// through a temporary file renamed over them: the interface's thread never waits on the disk, and a crash leaves the old
// file or the new one.
package ocn

import "base:runtime"
import "core:path/filepath"
import "core:strings"
import store "gt:store"
import "gt:fsx"
import "gt:ui"

Stores :: struct {
	settings:    store.Store,
	palette:     store.Store,
	zooms:       store.Store,
	session_zooms: store.Store,
	servers:     store.Store,
	drafts:      store.Writer,
	drafts_read: string,   // drafts.json as it was at the start, until drafts_load takes it (owned)
}

// At the start, before the window. A test opens none: its stores are in memory (zero Stores), its drafts nowhere.
stores_open :: proc(app: ^App) {
	dir := config_dir()
	st := &app.stores
	store.open(&st.settings, settings_path(), '=', on_failed = store_failed, user = app)
	store.open(&st.palette, pjoin({dir, "palette_usage.txt"}), on_failed = store_failed, user = app)
	store.open(&st.zooms, pjoin({dir, "terminal_zoom.txt"}), on_failed = store_failed, user = app)
	store.open(&st.session_zooms, pjoin({dir, "session_zoom.txt"}), on_failed = store_failed, user = app)
	store.open(&st.servers, servers_path(), private = true, on_failed = store_failed, user = app)
	path := pjoin({dir, "drafts.json"})
	if data, ok := fsx.read_all(path, context.temp_allocator); ok { st.drafts_read = strings.clone(string(data)) }
	// (drafts_save hands it the whole file a second after the typing stops: it writes at once, on its worker)
	store.writer_open(&st.drafts, path, on_failed = store_failed, user = app)
	missed_open(app, pjoin({dir, MISSED_FILE}))
}

// At the end: what was set last is on the disk when it returns (the process ends right after).
stores_close :: proc(app: ^App) {
	st := &app.stores
	store.close(&st.settings)
	store.close(&st.palette)
	store.close(&st.zooms)
	store.close(&st.session_zooms)
	store.close(&st.servers)
	store.writer_close(&st.drafts)
	missed_close(app)
	delete(st.drafts_read)
	st.drafts_read = ""
}

// On a store's worker: the interface says it.
@(private = "file")
store_failed :: proc(user: rawptr, path: string) {
	app := (^App)(user)
	// (the heap's on both sides: the worker's context and the interface's need not share an allocator)
	name := strings.clone(filepath.base(path), runtime.heap_allocator())
	if !ui.post(&app.state, store_failed_say, raw_data(name), u64(len(name))) { delete(name, runtime.heap_allocator()) }
}

@(private = "file")
store_failed_say :: proc(data: rawptr, word: u64) {
	name := strings.string_from_ptr((^u8)(data), int(word))
	ui.toast(.Bad, "%s could not be saved", name)
	delete(name, runtime.heap_allocator())
}

////////////////////////////////
// settings.txt

settings_path :: proc() -> string { return pjoin({config_dir(), "settings.txt"}) }

settings_get :: proc(app: ^App, key: string) -> string {
	v, _ := store.get(&app.stores.settings, key)
	return v
}

settings_set :: proc(app: ^App, key, value: string) { store.set(&app.stores.settings, key, value) }
