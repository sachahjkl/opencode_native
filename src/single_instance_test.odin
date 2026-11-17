package ocn

import "base:runtime"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import instance "gt:instance"
import process "gt:process"
import "gt:ui"
import session "gt:testkit/session"
import "gt:testkit/unwatched"

// An installer's --quit (instance.MESSAGE_QUIT) runs Quit, once the interface's thread runs the post; --status's
// MESSAGE_PING changes nothing (src/md/features/single-instance.md).
@(test)
a_quit_message_runs_quit :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		instance_message(app, transmute([]u8)string(instance.MESSAGE_PING))
		session.frames(s, 2)
		testing.expect(t, !app.quit, "ping: still running")
		instance_message(app, transmute([]u8)string(instance.MESSAGE_QUIT))
		session.wait_until(s, proc(s: ^session.Session) -> bool { return (^App)(s.user).quit }, "Quit run by --quit")
		testing.expect_value(t, app.launch_after, "")
	})
}

// Restart starts the place the program started from, held to main's end: read at Restart, the name was the frame's
// temp memory (gone by then), and after an update on Windows it named the running file moved aside (<exe>.old).
@(test)
restart_starts_the_place_it_started_from :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		started := strings.clone(process.executable_path(), context.temp_allocator)
		testing.expect(t, app.exe != "" && app.exe == started, "the place, read at the start")
		app_restart(app)
		session.frames(s, 4)   // (each frame frees its temp memory)
		testing.expect_value(t, app.launch_after, started)
		testing.expect(t, raw_data(app.launch_after) == raw_data(app.exe), "held by the app, not a frame")
		app.quit, app.launch_after = false, ""
	})
}

// A second start's options, through a real instance served on its own thread, reach the window that runs: its find bar
// opens with the text, and the sidebar's search takes its own.
@(test)
a_second_start_reaches_the_first :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		name := fmt.tprintf("ocn.test.instance.%d", time.to_unix_nanoseconds(time.now()))
		outcome, owner := instance.acquire({name = name, wait_ms = 1000}, nil)
		testing.expect_value(t, outcome, instance.Outcome.First)
		server := instance.serve_start(owner, instance_message, app)
		testing.expect(t, server != nil, "served")
		defer instance.serve_stop(server)
		message := instance_message_make({find = "needle", search = "haystack", frames = -1}, "")
		testing.expect_value(t, instance.send({name = name, wait_ms = 2000}, transmute([]u8)message), instance.Outcome.Forwarded)
		session.wait_until(s, proc(s: ^session.Session) -> bool {
			return ui.find_is_open(main_pane((^App)(s.user)).conversation.scroll_key) && ui.find_needle() == "needle"
		}, "the find bar open with the second start's text")
		testing.expect_value(t, ui.line_edit_string(&app.sidebar.search), "haystack")
	})
}

// The message is the command line's options: a value with a new line comes whole, a path comes absolute, the token apart.
@(test)
the_message_carries_the_options :: proc(t: ^testing.T) {
	message := instance_message_make({session = "ses_1", find = "two\nlines", attach = {"a.png"}, settings = true, frames = -1}, "tok")
	token, o := instance_message_read(message)
	testing.expect_value(t, token, "tok")
	testing.expect_value(t, o.session, "ses_1")
	testing.expect_value(t, o.find, "two\nlines")
	testing.expect(t, o.settings && o.settings_page == "", "--settings without a page")
	testing.expect_value(t, len(o.attach), 1)
	if len(o.attach) == 1 { testing.expectf(t, filepath.is_abs(o.attach[0]), "the attachment's path is absolute: %q", o.attach[0]) }
	testing.expect(t, !instance_own_run(o), "what to show is handed over")
	testing.expect(t, instance_own_run({url = "http://h:4096", frames = -1}), "another server runs on its own")
	testing.expect(t, instance_own_run({frames = 3}), "a check runs on its own")
}
