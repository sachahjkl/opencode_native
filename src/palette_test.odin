package ocn

import "base:runtime"
import "core:fmt"
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

// Jump to message (src/md/features/jump.md): Ctrl+Alt+G opens a chooser of the session's prompts, the newest first; a
// few words find an earlier one, and Enter takes the conversation there (the first prompt, far above the view).
@(test)
jump_to_message_goes_to_an_earlier_prompt :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		settled :: proc(s: ^session.Session) -> bool {
			j := &(^App)(s.user).jump.pal
			return jump_shown((^App)(s.user)) && ui.palette_ranked_for(j, ui.line_edit_string(&j.field)) && !ui.palette_busy(j)
		}
		session.key(s, .G, {.Ctrl, .Alt})
		session.wait_until(s, settled, "Jump to message open")
		j := &app.jump
		_, newest, _ := ui.palette_row(&j.pal, 0)
		testing.expect_value(t, newest, fmt.tprintf("msg_%d_u", BENCH_TURNS - 1))
		testing.expect(t, session.find(s, "msg_msg_0_u") == nil, "the first prompt is far above the view")
		ui.line_edit_set(&j.pal.field, "Step 0: look")
		session.wait_until(s, settled, "ranked")
		_, first, _ := ui.palette_row(&j.pal, 0)
		testing.expect_value(t, first, "msg_0_u")
		session.key(s, .Return)
		session.wait_until(s, proc(s: ^session.Session) -> bool { return session.find(s, "msg_msg_0_u") != nil }, "the conversation at the first prompt")
		testing.expect(t, !jump_shown(app), "the chooser closed")
	})
}

// The prefixes of the shared table that opencode native fills, each with its name: the server's commands are under `>`
// with the commands, the agents alone under `#` (the models are Set the model's list), `/` is not filled yet (the
// session's files: later).
@(test)
the_palette_has_its_prefixes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	palette_start(app)
	defer palette_destroy(app)
	got := ui.palette_prefixes(&app.palette.pal)
	want := []string{"> Commands", "@ Sessions", "# Agents", ": Settings"}
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
		pane := main_pane(app)
		slash_load(app, []Slash{{strings.clone("review"), strings.clone("Review the changes")}})
		palette_up(s, app)
		palette_type(s, app, ">review")
		row := palette_row_of(app, &app.palette.server, "review")
		if !testing.expect(t, row >= 0, "the server's command") { return }
		app.palette.pal.sel = row
		session.key(s, .Return)
		session.wait_until(s, proc(s: ^session.Session) -> bool { return !palette_shown((^App)(s.user)) }, "the palette closed")
		session.frames(s, 2)
		testing.expect_value(t, ui.text_edit_string(&pane.composer.area), "/review ")
	})
}

// `#` lists the agents; the agent in use is marked (its source says it), another is not.
@(test)
the_agents_are_chosen_under_the_hash :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		pane := main_pane(app)
		append(&app.agents, Agent_Info{id = "build", name = "build"}, Agent_Info{id = "plan", name = "plan"}, Agent_Info{id = "explore", name = "explore", mode = "subagent"})
		app.cx.catalog_version += 1
		palette_up(s, app)
		palette_type(s, app, "#")
		src := &app.palette.agents
		testing.expect(t, palette_row_of(app, src, "build") >= 0 && palette_row_of(app, src, "plan") >= 0, "the agents")
		testing.expect(t, palette_row_of(app, src, "explore") < 0, "not a sub-agent")
		in_use := shown_agent(app, pane)
		if in_use == "" { in_use = "build" }   // (the server's default, as the composer's button says)
		for id in ([]string{"build", "plan"}) { testing.expect_value(t, src.mark(src, id), id == in_use) }
		palette_hide(app)
		session.frames(s, 2)
	})
}

// The composer's model button opens Set the model's form straight away (no list of commands under it): Escape closes
// the palette and sets nothing; a click on the button again closes it too; a model found by its provider and Enter
// give it to the composer's session. Its agent button opens a chooser of the agents but the sub-agents, the one in use
// marked; Escape closes it.
@(test)
the_composer_chooses_its_model_and_its_agent :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		pane := main_pane(app)
		app.conn = bench_conn(app)
		defer { bench_clear(app); app.conn = nil }
		settled :: proc(s: ^session.Session) -> bool {
			c := &(^App)(s.user).palette.chooser
			return ui.palette_is_open(c) && ui.palette_ranked_for(c, ui.line_edit_string(&c.field)) && !ui.palette_busy(c)
		}
		row_of :: proc(app: ^App, src: ^ui.Palette_Source, id: string) -> int {
			c := &app.palette.chooser
			for i in 0 ..< ui.palette_row_count(c) {
				if rs, rid, ok := ui.palette_row(c, i); ok && rs == src && rid == id { return i }
			}
			return -1
		}
		form :: proc(s: ^session.Session) -> bool { app := (^App)(s.user); return model_form_shows(app, main_pane(app)) }
		closed :: proc(s: ^session.Session) -> bool { return !palette_shown((^App)(s.user)) }
		append(&app.models, Model_Info{id = strings.clone("swift"), provider = strings.clone("zeta"), name = strings.clone("Swift")},
			Model_Info{id = strings.clone("steady"), provider = strings.clone("omega"), name = strings.clone("Steady")})
		append(&app.agents, Agent_Info{id = "build", name = "build"}, Agent_Info{id = "plan", name = "plan"}, Agent_Info{id = "explore", name = "explore", mode = "subagent"})
		app.cx.catalog_version += 1
		choose_model(app, pane, app.models[0])
		p := &app.palette
		session.frames(s, 2)
		// Escape: the palette closed, nothing set
		session.click(s, "model")
		session.wait_until(s, form, "Set the model's form")
		testing.expect(t, session.find_text(s, "omega/Steady") != nil, "the models listed")
		session.type_text(s, "omega")
		session.frames(s, 3)
		session.key(s, .Escape)
		session.wait_until(s, closed, "closed by Escape at its argument")
		model, provider := shown_model(app, pane)
		testing.expect(t, model == "swift" && provider == "zeta", "the model in use kept")
		// its button again: closed
		session.click(s, "model")
		session.wait_until(s, form, "Set the model's form")
		session.click(s, "model")
		session.wait_until(s, closed, "closed by its button")
		// Enter: the model set
		session.click(s, "model")
		session.wait_until(s, form, "Set the model's form")
		session.type_text(s, "omega")
		session.frames(s, 3)
		session.key(s, .Return)
		session.wait_until(s, closed, "closed by the choice")
		model, provider = shown_model(app, pane)
		testing.expect(t, model == "steady" && provider == "omega", "the composer's model")
		chooser_toggle(app, pane)
		session.wait_until(s, settled, "the agents' chooser")
		testing.expect(t, row_of(app, &p.chooser_agents, "build") >= 0 && row_of(app, &p.chooser_agents, "plan") >= 0, "the agents")
		testing.expect(t, row_of(app, &p.chooser_agents, "explore") < 0, "not a sub-agent")
		in_use := shown_agent(app, pane)
		if in_use == "" { in_use = "build" }
		for id in ([]string{"build", "plan"}) { testing.expect_value(t, p.chooser_agents.mark(&p.chooser_agents, id), id == in_use) }
		session.key(s, .Escape)
		session.wait_until(s, proc(s: ^session.Session) -> bool { return !ui.palette_is_open(&(^App)(s.user).palette.chooser) }, "closed by Escape")
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
		pane := main_pane(app)
		shown := find_session(app, pane.chat.id)
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

// The palette's command `id` found by `typed` and its form opened by Enter.
@(private = "file")
palette_form_open :: proc(t: ^testing.T, s: ^session.Session, app: ^App, typed, id: string) -> bool {
	palette_type(s, app, typed)
	row := palette_row_of(app, &app.palette.pal.commands.source, id)
	if !testing.expectf(t, row >= 0, "%s: listed", id) { return false }
	app.palette.pal.sel = row
	session.key(s, .Return)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.palette_run_level(&(^App)(s.user).palette.pal) == .Form }, "its form")
	return true
}

// Rename the session in the palette: Enter opens its form on the title in use, the new title is typed there, and Enter
// renames the session shown, with no dialog over the window (src/md/features/palette.md).
@(test)
the_palette_renames_the_session_in_its_form :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		app.conn = bench_conn(app)
		defer { bench_clear(app); app.conn = nil }
		bench_clear(app)
		shown := find_session(app, main_pane(app).chat.id)
		if !testing.expect(t, shown != nil && shown.title != "", "a session shown, with a title") { return }
		palette_up(s, app)
		if !palette_form_open(t, s, app, ">rename the session", "session.rename") { return }
		testing.expect(t, !ui.view_is_open(&app.program_views, RENAME_VIEW), "no dialog")
		testing.expect_value(t, ui.line_edit_string(&app.palette.pal.field), shown.title)   // (the title in use, to edit)
		session.key(s, .A, {.Ctrl})
		session.type_text(s, "  A new title ")
		session.key(s, .Return)
		session.wait_until(s, proc(s: ^session.Session) -> bool { return bench_count(.Action) > 0 }, "the session renamed")
		sent := bench_take(t, .Action)
		testing.expect_value(t, sent.method, "PATCH")
		testing.expect_value(t, sent.path, fmt.tprintf("/api/session/%s", BENCH_CHAT_ID))
		testing.expect_value(t, sent.body, `{"title":"A new title"}`)
		testing.expect(t, !palette_shown(app), "the palette closed")
		testing.expect(t, !ui.view_is_open(&app.program_views, RENAME_VIEW), "no dialog after it either")
	})
}

// Rename's form starts on the title in use when it opens: a title changed between two opens gives the new one.
@(test)
the_rename_form_starts_on_the_title_of_now :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		shown := find_session(app, main_pane(app).chat.id)
		if !testing.expect(t, shown != nil && shown.title != "", "a session shown, with a title") { return }
		palette_up(s, app)
		if !palette_form_open(t, s, app, ">rename the session", "session.rename") { return }
		testing.expect_value(t, ui.line_edit_string(&app.palette.pal.field), shown.title)
		session.key(s, .Escape)
		session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.palette_run_level(&(^App)(s.user).palette.pal) == .Closed }, "back to the list")
		shown.title = "Renamed elsewhere"   // (the sessions' strings are their list's arena's: none freed alone)
		session.frames(s, 2)
		if !palette_form_open(t, s, app, ">rename the session", "session.rename") { return }
		testing.expect_value(t, ui.line_edit_string(&app.palette.pal.field), "Renamed elsewhere")
		palette_hide(app)
		session.frames(s, 2)
	})
}

// Escape in Rename's form steps back to the list: nothing is sent, the title stays.
@(test)
escape_in_the_rename_form_renames_nothing :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		app.conn = bench_conn(app)
		defer { bench_clear(app); app.conn = nil }
		bench_clear(app)
		palette_up(s, app)
		if !palette_form_open(t, s, app, ">rename the session", "session.rename") { return }
		session.key(s, .A, {.Ctrl})
		session.type_text(s, "Not this one")
		session.key(s, .Escape)
		session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.palette_run_level(&(^App)(s.user).palette.pal) == .Closed }, "back to the list")
		session.frames(s, 3)
		testing.expect_value(t, bench_count(.Action), 0)
		testing.expect(t, palette_shown(app), "the palette stays, on its list")
		palette_hide(app)
		session.frames(s, 2)
	})
}

// Set the model in the palette: Enter opens its form, a list of the models the server lists with the one in use
// selected; a few letters filter it, and Enter sets the main view's model. `#` lists no model: the command's list is
// the palette's one way to them. Escape in the form sets nothing.
@(test)
the_palette_sets_the_model_in_its_form :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		pane := main_pane(app)
		append(&app.models, Model_Info{id = strings.clone("swift"), provider = strings.clone("zeta"), name = strings.clone("Swift")},
			Model_Info{id = strings.clone("steady"), provider = strings.clone("omega"), name = strings.clone("Steady")})
		app.cx.catalog_version += 1
		choose_model(app, pane, app.models[0])
		palette_up(s, app)
		palette_type(s, app, "#steady")
		for i in 0 ..< ui.palette_row_count(&app.palette.pal) {
			if src, _, ok := ui.palette_row(&app.palette.pal, i); ok { testing.expect(t, src.name != "model", "no model under #") }
		}
		// Escape at the argument: nothing set
		if !palette_form_open(t, s, app, ">set the model", "session.set_model") { return }
		session.type_text(s, "omega")
		session.frames(s, 3)
		session.key(s, .Escape)
		session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.palette_run_level(&(^App)(s.user).palette.pal) == .Closed }, "back to the list")
		session.frames(s, 2)
		model, provider := shown_model(app, pane)
		testing.expect(t, model == "swift" && provider == "zeta", "the model in use kept")
		// Enter on the filtered list: the model set
		if !palette_form_open(t, s, app, ">set the model", "session.set_model") { return }
		labels, values := ui.palette_command_choices(&app.palette.pal, command_index_of(command_find("session.set_model")), "model")
		testing.expect_value(t, len(values), 2)
		if len(labels) == 2 { testing.expect_value(t, labels[1], "omega/Steady") }
		testing.expect(t, session.find_text(s, "zeta/Swift") != nil && session.find_text(s, "omega/Steady") != nil, "the models listed")
		session.type_text(s, "omega")
		session.frames(s, 3)
		session.key(s, .Return)
		session.wait_until(s, proc(s: ^session.Session) -> bool { return !palette_shown((^App)(s.user)) }, "the palette closed")
		session.frames(s, 2)
		model, provider = shown_model(app, pane)
		testing.expect(t, model == "steady" && provider == "omega", "the model set")
	})
}

// The buttons that run a palette command name it, so Shift+Enter on the command goes to them; a command on the main
// view is the main composer's, not the panel's.
@(test)
the_buttons_name_their_commands :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		session.frames(s, 2)
		for id in ([]string{"nav.back", "nav.forward", "nav.home", "view.notices", "session.rename", "composer.attach", "session.set_model", "view.terminal", "session.new", "app.refresh", "app.settings"}) {
			testing.expectf(t, ui.act_shown(fmt.tprintf("command:%s", id)), "%s: its button named", id)
		}
		// Shift+Enter on New session: the sidebar's button lit
		palette_up(s, app)
		palette_type(s, app, ">new session")
		row := palette_row_of(app, &app.palette.pal.commands.source, "session.new")
		if !testing.expect(t, row >= 0, "the command") { return }
		app.palette.pal.sel = row
		session.key(s, .Return, {.Shift})
		session.wait_until(s, proc(s: ^session.Session) -> bool { return s.state.act_light.key != 0 }, "lit")
		lit := s.state.boxes[s.state.act_light.key] or_else nil
		testing.expect(t, lit != nil && lit.name == "new", "the sidebar's New session")
		testing.expect(t, !palette_shown(app), "the palette closed")
	})
}

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
