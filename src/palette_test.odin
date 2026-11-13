package ocn

import "base:runtime"
import "core:strings"
import "core:testing"
import prefs_page "gt:prefs_page"
import "gt:config"
import "gt:ui"

// A switch of the palette shows the setting's title, as the settings say it, not its name ("window.system_title").
@(test)
a_palette_switch_shows_its_title :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	prefs_register(&p)
	found := 0
	for &e in p.entries {
		d := e.def
		if d.name != "window.system_title" && d.name != "notify.permission" { continue }
		found += 1
		title := setting_title(&p, d)
		testing.expectf(t, !strings.contains(title, ".") && !strings.contains(title, "_"), "a title, not the name: %q", title)
		testing.expectf(t, strings.contains(title, " › "), "its group, then its words: %q", title)
		testing.expectf(t, strings.has_suffix(title, config.title_of(d)), "the settings' words: %q", title)
	}
	testing.expect_value(t, found, 2)
}

// "animation" finds the animations' setting (a choice, not a switch: it was not listed).
@(test)
a_setting_that_is_no_switch_is_found :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	prefs_register(&p)
	found := false
	for &e in p.entries {
		d := e.def
		if d.name != "appearance.animations" { continue }
		found = true
		testing.expect(t, !d.hidden && d.kind != .Bool, "a choice")
		_, _, ok := ui.fuzzy_words("animation", setting_title(&p, d))
		testing.expectf(t, ok, "found by its title: %q", setting_title(&p, d))
	}
	testing.expect(t, found, "appearance.animations")
}

// The palette finds words, whole or as pieces that each begin a word, the whole first; letters scattered in a word find nothing
// ("prio" no longer found "Previous section").
@(test)
the_palette_finds_words_not_scattered_letters :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	items := []Pal_Item{
		{kind = .Command, id = "a", title = "Open a terminal in the session's folder"},
		{kind = .Command, id = "b", title = "Keyboard shortcuts"},
		{kind = .Command, id = "c", title = "Previous section"},
		{kind = .Command, id = "d", title = "Terminal"},
	}
	hits := palette_hits(app, items, "terminal")
	testing.expect_value(t, len(hits), 2)
	if len(hits) == 2 { testing.expect_value(t, items[hits[0].index].id, "d") }   // (at the start of its text)
	hits = palette_hits(app, items, "kesh")
	testing.expect_value(t, len(hits), 1)   // (keyboard shortcuts: pieces that begin its words)
	testing.expect_value(t, len(palette_hits(app, items, "pvsc")), 0)   // (scattered in its words: nothing)
}

// A command is found by its tags ("exit" for Quit) and with a slip ("Qestart pencode native" for the restart).
@(test)
the_palette_finds_a_command_by_its_tags_or_a_slip :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	items := make([dynamic]Pal_Item, context.temp_allocator)
	for &c in COMMANDS { append(&items, Pal_Item{kind = .Command, id = c.id, title = c.title, cmd = &c, tags = strings.fields(c.tags, context.temp_allocator)}) }
	app := new(App)
	defer free(app)
	first :: proc(hits: []ui.Rank_Hit, items: []Pal_Item) -> string { return len(hits) > 0 ? items[hits[0].index].id : "" }
	testing.expect_value(t, first(palette_hits(app, items[:], "exit"), items[:]), "app.quit")
	testing.expect_value(t, first(palette_hits(app, items[:], "Qestart pencode native"), items[:]), "app.restart")
	testing.expect_value(t, first(palette_hits(app, items[:], "restart opencode"), items[:]), "app.restart")
}

// A session's command says which session it acts on: the one shown, by its title, beside it.
@(test)
a_session_command_names_its_session :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	append(&app.sessions, Session_Info{id = "s1", title = "The blend of the pane"})
	sessions_changed(app)
	app.chat.id = "s1"
	items := palette_items(app, 0, false)
	fork := ""
	for it in items { if it.id == "session.fork" { fork = it.detail } }
	testing.expect_value(t, fork, "Session · The blend of the pane")
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
