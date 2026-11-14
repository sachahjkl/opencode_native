package ocn

import "base:runtime"
import "core:strings"
import "core:testing"
import prefs_page "gt:prefs_page"
import "gt:config"
import "gt:ui"
import session "gt:testkit/session"
import "gt:testkit/unwatched"

// The list shown is the one of the field's text, and no source of it still reads: what a test waits for (bounded).
@(private)
palette_settled :: proc(s: ^session.Session) -> bool {
	p := &(^App)(s.user).palette.pal
	return ui.palette_ranked_for(p, ui.line_edit_string(&p.field)) && !ui.palette_busy(p)
}

// `text` typed in the open palette, its list waited for.
@(private)
palette_type :: proc(s: ^session.Session, app: ^App, text: string) {
	ui.line_edit_set(&app.palette.pal.field, text)
	session.wait_until(s, palette_settled, "the palette's list ranked")
}

// The row of the list whose item is `id` of `src` (-1: none).
@(private)
palette_row_of :: proc(app: ^App, src: ^ui.Palette_Source, id: string) -> int {
	p := &app.palette.pal
	for i in 0 ..< ui.palette_row_count(p) {
		if rs, rid, ok := ui.palette_row(p, i); ok && rs == src && rid == id { return i }
	}
	return -1
}

// The palette opened (palette_show), its first list waited for.
@(private)
palette_up :: proc(s: ^session.Session, app: ^App) {
	palette_show(app)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return palette_shown((^App)(s.user)) && palette_settled(s) }, "the palette open")
}

// The prefixes of the shared table that opencode native fills, each with its name: the server's commands are under `>`
// with the commands, the agents under `#` with the models, `/` is not filled yet (the session's files: later).
@(test)
the_palette_has_its_prefixes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	palette_start(app)
	defer palette_destroy(app)
	got := ui.palette_prefixes(&app.palette.pal)
	want := []string{"> Commands", "@ Sessions", "# Choose", ": Settings"}
	testing.expectf(t, len(got) == len(want), "%v", got)
	for w, i in want { if i < len(got) { testing.expect_value(t, got[i], w) } }
}

// A command is found by its tags ("exit" for Quit) and with a slip ("Qestart pencode native" for the restart).
@(test)
the_palette_finds_a_command_by_its_tags_or_a_slip :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		palette_up(s, app)
		src := &app.palette.pal.commands.source
		for c in ([][2]string{{"exit", "app.quit"}, {"Qestart pencode native", "app.restart"}, {"restart opencode", "app.restart"}}) {
			palette_type(s, app, c[0])
			testing.expectf(t, palette_row_of(app, src, c[1]) == 0, "%q: %s first", c[0], c[1])
		}
		palette_hide(app)
		session.frames(s, 2)
	})
}

// `:` lists the settings, a choice among values too ("animation": the animations' setting, not a switch).
@(test)
a_setting_that_is_no_switch_is_found :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		palette_up(s, app)
		palette_type(s, app, ":animation")
		testing.expect(t, palette_row_of(app, &app.palette.settings.source, "appearance.animations") >= 0, "the animations' setting")
		palette_hide(app)
		session.frames(s, 2)
	})
}

// A switch chosen flips, and the palette stays open on it.
@(test)
a_switch_flips_and_the_palette_stays :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		if !testing.expect(t, config.bool_of(&app.cfg_prefs, "conversation.usage"), "on, as by default") { return }
		palette_up(s, app)
		palette_type(s, app, ":conversation.usage")
		row := palette_row_of(app, &app.palette.settings.source, "conversation.usage")
		if !testing.expect(t, row >= 0, "the switch") { return }
		app.palette.pal.sel = row
		session.key(s, .Return)
		session.wait_until(s, proc(s: ^session.Session) -> bool { return !config.bool_of(&(^App)(s.user).cfg_prefs, "conversation.usage") }, "the switch flipped")
		session.frames(s, 2)
		testing.expect(t, palette_shown(app), "the palette stays")
		pref_set(app, "conversation.usage", "true")
		palette_hide(app)
		session.frames(s, 2)
	})
}

// The server's commands are under `>`, in their group: one chosen is written in the composer, as `/` there would.
@(test)
a_server_command_goes_in_the_composer :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		slash_load(app, []Slash{{strings.clone("review"), strings.clone("Review the changes")}})
		palette_up(s, app)
		palette_type(s, app, ">review")
		row := palette_row_of(app, &app.palette.server, "review")
		if !testing.expect(t, row >= 0, "the server's command") { return }
		app.palette.pal.sel = row
		session.key(s, .Return)
		session.wait_until(s, proc(s: ^session.Session) -> bool { return !palette_shown((^App)(s.user)) }, "the palette closed")
		session.frames(s, 2)
		testing.expect_value(t, ui.text_edit_string(&app.composer.area), "/review ")
	})
}

// `#` lists the models and the agents; the agent in use is marked (its source says it), another is not.
@(test)
the_agents_are_chosen_under_the_hash :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		append(&app.agents, Agent_Info{id = "build", name = "build"}, Agent_Info{id = "plan", name = "plan"}, Agent_Info{id = "explore", name = "explore", mode = "subagent"})
		app.cx.catalog_version += 1
		palette_up(s, app)
		palette_type(s, app, "#")
		src := &app.palette.agents
		testing.expect(t, palette_row_of(app, src, "build") >= 0 && palette_row_of(app, src, "plan") >= 0, "the agents")
		testing.expect(t, palette_row_of(app, src, "explore") < 0, "not a sub-agent")
		in_use := shown_agent(app)
		for id in ([]string{"build", "plan"}) { testing.expect_value(t, src.mark(src, id), id == in_use) }
		palette_hide(app)
		session.frames(s, 2)
	})
}

// A command with a state on or off is a switch: its row has the mark of its state, choosing it flips the state, and the
// palette stays open.
@(test)
a_toggle_command_shows_its_mark_and_flips :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		if !testing.expect(t, app.prefs.prompt_rail, "the prompt marks shown, as by default") { return }
		palette_up(s, app)
		palette_type(s, app, "prompt marks")
		src := &app.palette.pal.commands.source
		row := palette_row_of(app, src, "view.prompt_rail")
		if !testing.expect(t, row >= 0, "the command") { return }
		testing.expect(t, src.mark(src, "view.prompt_rail"), "its mark: on")
		testing.expect(t, !src.mark(src, "session.new"), "no mark on a command that is no switch")
		app.palette.pal.sel = row
		session.key(s, .Return)
		session.wait_until(s, proc(s: ^session.Session) -> bool { return !(^App)(s.user).prefs.prompt_rail }, "the marks hidden")
		session.frames(s, 2)
		testing.expect(t, palette_shown(app), "the palette stays")
		testing.expect(t, !src.mark(src, "view.prompt_rail"), "its mark: off")
		pref_set(app, "conversation.prompt_rail", "true")
		palette_hide(app)
		session.frames(s, 2)
	})
}

// A session's command says the session it acts on, the one shown, after its title.
@(test)
a_session_command_shows_its_session :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		shown := find_session(app, app.chat.id)
		if !testing.expect(t, shown != nil && shown.title != "", "a session shown, with a title") { return }
		palette_up(s, app)
		palette_type(s, app, "fork the session")
		fork := command_find("session.fork")
		if !testing.expect(t, fork != nil, "the command") { return }
		testing.expect(t, palette_row_of(app, &app.palette.pal.commands.source, "session.fork") >= 0, "listed")
		want := strings.concatenate({"Session · ", ellipsize(shown.title, PALETTE_SESSION_CHARS)}, context.temp_allocator)
		testing.expect_value(t, app.palette.details[command_index_of(fork)], want)
		testing.expect_value(t, app.palette.details[command_index_of(command_find("app.help"))], "")
		session.wait_idle(s)
		testing.expect(t, session.find_text(s, "Session · ") != nil, "shown after its title (cut to its row)")
		palette_hide(app)
		session.frames(s, 2)
	})
}

@(private = "file")
command_index_of :: proc(c: ^Command) -> int { return int((uintptr(c) - uintptr(&COMMANDS[0])) / size_of(Command)) }

// Every setting the palette lists (not a hidden one) is on a page of the settings (SETTINGS_PAGES), where
// prefs_page.show finds it; a hidden one is on none.
@(test)
every_setting_of_the_palette_is_on_a_page :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	prefs_register(&p)
	for &e in p.entries {
		found := false
		for pg in SETTINGS_PAGES {
			for name in prefs_page.page_names(&p, pg) { if name == e.def.name { found = true } }
		}
		if e.def.hidden {
			testing.expectf(t, !found, "%s is hidden: on no page", e.def.name)
		} else {
			testing.expectf(t, found, "%s: on a page of the settings", e.def.name)
		}
	}
}
