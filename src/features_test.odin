package occ

// What the newer parts decide by themselves, without a window: a diff, the end of a command's output, an address, the links
// of a text, the history's steps.

import "core:strings"
import "core:testing"
import "gt:ui"

@(test)
a_changed_line_is_removed_then_added :: proc(t: ^testing.T) {
	d := diff_lines("a\nb\nc", "a\nx\nc", context.temp_allocator)
	testing.expect_value(t, d, " a\n-b\n+x\n c\n")
}

@(test)
a_server_patch_counts_its_lines_not_its_headers :: proc(t: ^testing.T) {
	p: Part
	part_patch_set(&p, "Index: f\n=====\n--- f\n+++ f\n@@ -1,2 +1,3 @@\n a\n-b\n+c\n+d\n")
	testing.expect_value(t, p.added, 2)
	testing.expect_value(t, p.removed, 1)
}

@(test)
a_call_without_patch_gets_one_from_its_input :: proc(t: ^testing.T) {
	p := Part{tool_name = "edit", input = `{"filePath":"f","oldString":"one","newString":"two"}`}
	testing.expect_value(t, part_patch(&p, context.temp_allocator), "-one\n+two\n")
	testing.expect_value(t, p.added, 1)
	w := Part{tool_name = "write", input = `{"content":"new"}`}
	testing.expect(t, strings.contains(part_patch(&w, context.temp_allocator), "+new"))
}

@(test)
the_tail_of_an_output_has_no_colours_and_no_blank_lines :: proc(t: ^testing.T) {
	lines := tail_lines("one\n\x1b[32mtwo\x1b[0m\r\n\n   \nthree\n", 2)
	testing.expect_value(t, len(lines), 2)
	testing.expect_value(t, lines[0], "two")
	testing.expect_value(t, lines[1], "three")
}

@(test)
an_address_is_completed_as_a_browser_would :: proc(t: ^testing.T) {
	testing.expect_value(t, preview_address("localhost:3000"), "http://localhost:3000")
	testing.expect_value(t, preview_address("example.com"), "https://example.com")
	testing.expect_value(t, preview_address("https://a.b/c"), "https://a.b/c")
	testing.expect_value(t, preview_address("about:blank"), "about:blank")
	testing.expect_value(t, preview_address("  "), "")
}

@(test)
the_first_link_of_a_text_ends_where_it_ends :: proc(t: ^testing.T) {
	testing.expect_value(t, first_url("served on http://localhost:5173/app) now"), "http://localhost:5173/app")
	testing.expect_value(t, first_url("no link here"), "")
}

@(test)
the_history_comes_back_to_what_was_typed :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	chat_reset(&app.chat)
	history_init(app, "")
	history_add(app, "first")
	history_add(app, "second")
	history_add(app, "second")   // (twice in a row: once)
	testing.expect_value(t, len(app.history.sent), 2)
	ui.area_set(&app.composer, "a draft")
	history_step(app, 1)
	testing.expect_value(t, ui.area_string(&app.composer), "second")
	history_step(app, 1)
	testing.expect_value(t, ui.area_string(&app.composer), "first")
	history_step(app, 1)   // (the oldest one stays)
	testing.expect_value(t, ui.area_string(&app.composer), "first")
	history_step(app, -1)
	history_step(app, -1)
	testing.expect_value(t, ui.area_string(&app.composer), "a draft")
	testing.expect(t, !history_browsing(app))
}

@(test)
every_key_of_the_table_is_its_own :: proc(t: ^testing.T) {
	for &a, i in COMMANDS {
		if a.key == .None { continue }
		for &b in COMMANDS[i + 1:] {
			testing.expectf(t, !(a.key == b.key && a.mods == b.mods), "%s and %s share a key", a.id, b.id)
		}
	}
}
