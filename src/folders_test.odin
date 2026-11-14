package ocn

import "base:runtime"
import "core:strings"
import "core:testing"

// A server of this computer: the toolkit's local source reads its folders; another's are read from it.
@(test)
a_local_servers_folders_are_this_computers :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	app.conn.http.base = "http://127.0.0.1:4096"
	testing.expect(t, folders_are_here(app))
	app.conn.http.base = "https://box.example:4096"
	testing.expect(t, !folders_are_here(app))
}

// A session moved: the folder chosen goes to the server as where it moves.
@(test)
a_session_moves_to_the_folder_chosen :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	folder_chosen(app, .Move_Session, "ses_1", "D:/work")
	m := bench_take(t, .Session_Moved)
	testing.expect_value(t, m.path, "/api/session/ses_1/move")
	testing.expect(t, strings.contains(m.body, `"directory":"D:/work"`), m.body)
	folder_chosen(app, .New_Session, "", "/srv/a")
	testing.expect_value(t, app.chat.new_dir, "/srv/a")
}
