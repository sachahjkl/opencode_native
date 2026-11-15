package ocn

// The server's terminal shell from its menu (opencode 2.3.0): the menu reads the configuration and the shells when it
// opens; its submenu lists Auto and the shells, a shell the agents cannot use says "terminal only" and can be chosen;
// a choice writes the configuration's "shell", Auto removes it (null).

import "base:runtime"
import "core:strings"
import "core:testing"
import "gt:ui"
import session "gt:testkit/session"
import "gt:testkit/unwatched"

@(test)
the_server_menu_chooses_the_terminal_shell :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		app.conn = bench_conn(app)
		defer { bench_clear(app); app.conn = nil; ui.menu_close() }
		ui.menu_open(SERVER_MENU_KEY, ui.Vec2{40, 40})
		session.frames(s, 3)
		bench_answer(app, bench_take(t, .Cfg), 200, `{"data":[{"type":"document","info":{"shell":"/bin/zsh"}}]}`)
		bench_answer(app, bench_take(t, .Shells), 200, `{"data":[{"name":"zsh","path":"/bin/zsh","acceptable":true},{"name":"fish","path":"/usr/bin/fish","acceptable":false}]}`)
		session.frames(s, 2)
		testing.expect_value(t, bench_count(.Cfg), 0)   // (once per opening)
		session.click_text(s, "Terminal shell")
		session.frames(s, 3)
		session.wait_text(s, "fish  ·  terminal only")
		session.click_text(s, "fish  ·  terminal only")
		session.frames(s, 2)
		r := bench_take(t, .Shell_Set)
		testing.expect_value(t, r.body, `{"shell":"/usr/bin/fish"}`)
		bench_answer(app, r, 204, "")
		testing.expect_value(t, app.facts.shell, "/usr/bin/fish")
		// Auto: the configuration's shell removed
		shell_set(app, {})
		r = bench_take(t, .Shell_Set)
		testing.expect_value(t, r.body, `{"shell":null}`)
		testing.expect(t, strings.contains(shell_label({name = "fish", ok = false}), "terminal only"))
	})
}
