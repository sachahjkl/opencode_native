package ocn

import "base:runtime"
import "core:strings"
import "core:testing"
import remote "gt:remote"

@(test)
a_folders_parent_stops_at_its_root :: proc(t: ^testing.T) {
	cases := [?]struct { path, parent: string, ok: bool }{
		{"/home/x", "/home", true},
		{"/home", "/", true},
		{"/", "", false},
		{"C:/Users/x", "C:/Users", true},
		{"C:/Users", "C:/", true},
		{"C:/", "", false},
		{"", "", false},
	}
	for c in cases {
		parent, ok := folder_parent(c.path)
		testing.expectf(t, parent == c.parent && ok == c.ok, "%q: %q %v", c.path, parent, ok)
	}
	testing.expect_value(t, folder_join("/", "srv"), "/srv")
	testing.expect_value(t, folder_join("C:/", "code"), "C:/code")
	testing.expect_value(t, folder_join("/home/x", "a"), "/home/x/a")
}

// A server on another machine: its folders are read from it, not from this computer's dialog. Opened with no folder known, the
// server's own folder is where it starts, said by its answer; a folder clicked is entered; the one shown is the new session's.
@(test)
a_new_sessions_folder_is_chosen_among_the_servers :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	f := &app.cx.folders
	testing.expect(t, !folders_are_here(app), "the bench's server is elsewhere")
	folder_choose(app, .New_Session)
	testing.expect(t, app.cx.open[.Folders], "the dialog of the server's folders")
	r := bench_take(t, .Folders_List)
	testing.expect_value(t, r.path, "/api/fs/list")
	bench_answer(app, r, 200, `{"location":{"directory":"/home/me"},"data":[{"path":"b.txt","type":"file"},{"path":"src","type":"directory"},{"path":"Docs","type":"directory"}]}`)
	testing.expect_value(t, f.at, "/home/me")
	testing.expect_value(t, len(f.names), 2)
	if len(f.names) == 2 { testing.expect(t, f.names[0] == "Docs" && f.names[1] == "src", "folders only, by name") }

	folders_go(app, folder_join(f.at, "src"))
	r = bench_take(t, .Folders_List)
	testing.expect_value(t, r.path, "/api/fs/list?path=%2Fhome%2Fme%2Fsrc")
	// (entries relative to the server's own folder: their name is what counts)
	bench_answer(app, r, 200, `{"location":{"directory":"/home/me"},"data":[{"path":"src/app","type":"directory"}]}`)
	testing.expect_value(t, f.at, "/home/me/src")
	if len(f.names) == 1 { testing.expect_value(t, f.names[0], "app") }

	folders_commit(app)
	testing.expect(t, !app.cx.open[.Folders], "closed once chosen")
	testing.expect_value(t, app.chat.new_dir, "/home/me/src")
}

// An answer for a folder left is not the folder shown's.
@(test)
a_folder_left_does_not_answer_for_the_next :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	f := &app.cx.folders
	folders_open(app, .New_Session, "", "/srv")
	old := bench_take(t, .Folders_List)
	folders_go(app, "/opt")
	bench_answer(app, old, 200, `{"data":[{"path":"stale","type":"directory"}]}`)
	testing.expect_value(t, len(f.names), 0)
	bench_answer(app, bench_take(t, .Folders_List), 200, `{"data":[{"path":"tools","type":"directory"}]}`)
	testing.expect(t, remote.shows(&f.read))
	if len(f.names) == 1 { testing.expect_value(t, f.names[0], "tools") }
}

// A session moved: it starts at the session's folder, and the one chosen goes to the server as where it moves.
@(test)
a_session_moves_to_a_folder_of_the_server :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	session_move_pick(app, "ses_1")
	testing.expect(t, app.cx.open[.Folders])
	r := bench_take(t, .Folders_List)
	bench_answer(app, r, 200, `{"location":{"directory":"D:\\work"},"data":[]}`)
	testing.expect_value(t, app.cx.folders.at, "D:/work")
	folders_commit(app)
	m := bench_take(t, .Session_Moved)
	testing.expect_value(t, m.path, "/api/session/ses_1/move")
	testing.expect(t, strings.contains(m.body, `"directory":"D:/work"`), m.body)
}

// A server of this computer: the system's dialog shows its folders.
@(test)
a_local_servers_folders_are_this_computers :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	app.conn.http.base = "http://127.0.0.1:4096"
	testing.expect(t, folders_are_here(app))
	app.conn.http.base = "https://box.example:4096"
	testing.expect(t, !folders_are_here(app))
}

// Forgotten with its server: another's folders are not shown, nor chosen.
@(test)
the_folders_go_with_their_server :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	folders_open(app, .Move_Session, "ses_1", "/srv")
	bench_answer(app, bench_take(t, .Folders_List), 200, `{"data":[{"path":"a","type":"directory"}]}`)
	folders_forget(app)
	f := &app.cx.folders
	testing.expect(t, !app.cx.open[.Folders])
	testing.expect(t, f.at == "" && f.session == "" && len(f.names) == 0, "nothing of it left")
	testing.expect_value(t, f.read.state, remote.State.Idle)
}
