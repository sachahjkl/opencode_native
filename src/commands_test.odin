package ocn

import "base:runtime"
import "core:testing"
import "gt:ui"
import session "gt:testkit/session"
import "gt:testkit/unwatched"

// The composer has the keyboard most of the time: a command's key that types text would go to it and never run the
// command (gui_toolkit's src/md/features/commands.md). No command has one.
@(test)
no_command_key_types_text :: proc(t: ^testing.T) {
	for c in COMMANDS {
		for k in c.keys { testing.expectf(t, !ui.command_key_types_text(k), "%s: %v types text", c.id, k) }
	}
}

// Every command has an id of its own (the keymap's and the usage memory's key): two commands with one id would share a
// person's key.
@(test)
the_command_ids_are_valid_and_unique :: proc(t: ^testing.T) {
	table := make([]ui.Command, len(COMMANDS), context.temp_allocator)
	for c, i in COMMANDS { table[i] = {id = c.id, label = c.title, keys = c.keys} }
	for line in ui.command_ids_check(table) { testing.expectf(t, false, "%s", line) }
}

// A person's key set from the palette replaces a command's own, and takes that chord from another: the keys read are the
// keymap's, the menus and the help say them. A command whose own keys are read elsewhere (Ctrl+T, the Preview's address
// bar) shows them and acts on a person's key.
@(test)
a_persons_key_replaces_the_commands_own :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		session.frames(s, 2)
		testing.expect_value(t, command_shortcut(app, "view.preview_tab"), ui.chord_text({.T, {.Ctrl}}))
		testing.expect_value(t, command_shortcut(app, "session.find"), ui.chord_text({.F, {.Ctrl}}))
		// (the sidebar's Ctrl+B given to the help; the help's F1 no longer acts)
		ui.keymap_bind(&app.keymap, "app.help", {chords = {{.B, {.Ctrl}}, {}}})
		testing.expect_value(t, command_shortcut(app, "app.help"), ui.chord_text({.B, {.Ctrl}}))
		testing.expect_value(t, command_shortcut(app, "view.sidebar"), "")
		sidebar := ui.view_is_open(&app.program_views, SIDEBAR_VIEW)
		session.key(s, .B, {.Ctrl})
		session.frames(s, 2)
		testing.expect(t, ui.view_is_open(&app.program_views, HELP_VIEW), "Ctrl+B opens the help")
		testing.expect_value(t, ui.view_is_open(&app.program_views, SIDEBAR_VIEW), sidebar)
		ui.view_close(&app.program_views, HELP_VIEW)
		session.frames(s, 2)
		session.key(s, .F1)
		session.frames(s, 2)
		testing.expect(t, !ui.view_is_open(&app.program_views, HELP_VIEW), "F1 is the help's no more")
		// (a person's key on a command whose own keys are read elsewhere, the conversation's zone's, acts)
		zone := &main_pane(app).zone
		before := ui.zoom_zone_value(zone)
		ui.keymap_bind(&app.keymap, "view.content_in", {chords = {{.F7, {}}, {}}})
		session.key(s, .F7)
		session.frames(s, 2)
		testing.expect(t, ui.zoom_zone_value(zone) > before, "F7 zooms the conversation in")
		custom, _ := ui.keymap_texts(&app.keymap)
		testing.expect_value(t, custom, "app.help=Ctrl+B;view.content_in=F7")
	})
}

// The keys, the settings and quit are the window's: their keys work over the settings and every view shown as a dialog
// (command_keyed). The palette's is the toolkit's (ui.palette_command): the table has no line for it.
@(test)
the_window_commands :: proc(t: ^testing.T) {
	testing.expect(t, command_find("app.palette") == nil, "the palette's command is the toolkit's")
	for c in COMMANDS {
		want := c.id == "app.help" || c.id == "app.settings" || c.id == "app.quit"
		testing.expectf(t, (c.scope == .Window) == want, "%s: the window's is %v", c.id, want)
		if c.scope == .Window { testing.expectf(t, c.over == nil, "%s: a window command works over a dialog already", c.id) }
	}
}
