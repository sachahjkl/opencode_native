package occ

// What the newer parts decide by themselves, without a window: a diff, the end of a command's output, an address, the links
// of a text, the history's steps.

import "core:encoding/json"
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

// Back and Forward: a browser's history. Going somewhere from the middle forgets what was ahead; a step adds nothing; a place twice in
// a row counts once; a session deleted leaves it, and what it separated does not stand twice; the oldest go past the limit.
@(test)
the_history_goes_back_and_forward :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	defer nav_clear(app)
	defer delete(app.cx.nav_hist)
	defer delete(app.nav_steps)
	testing.expect(t, !nav_can(app, -1) && !nav_can(app, 1), "nowhere yet")

	take :: proc(app: ^App) -> string {   // the step asked for, as nav_apply would see it
		st := pop(&app.nav_steps)
		defer delete(st.id)
		return strings.clone(st.id, context.temp_allocator)
	}
	nav_visit(app, "", "a")   // from the home page
	nav_visit(app, "a", "b")
	nav_visit(app, "b", "b")
	testing.expect_value(t, len(app.cx.nav_hist), 3)
	testing.expect(t, nav_can(app, -1) && !nav_can(app, 1), "at the end")

	nav_step(app, -1)
	testing.expect_value(t, take(app), "a")
	nav_step(app, -1)
	testing.expect_value(t, take(app), "")
	testing.expect(t, !nav_can(app, -1) && nav_can(app, 1), "at the start")
	nav_step(app, -1)
	testing.expect_value(t, len(app.nav_steps), 0)
	nav_step(app, 1)
	testing.expect_value(t, take(app), "a")

	// a step adds nothing
	app.cx.nav_moving = true
	nav_visit(app, "a", "z")
	app.cx.nav_moving = false
	testing.expect_value(t, len(app.cx.nav_hist), 3)

	// from the middle: what was ahead is forgotten
	nav_visit(app, "a", "c")
	testing.expect_value(t, len(app.cx.nav_hist), 3)
	testing.expect_value(t, app.cx.nav_hist[2].id, "c")
	testing.expect(t, !nav_can(app, 1), "b is gone")

	// a session deleted: home, a, c, a -> home, a once c is gone, and where one is stays right
	nav_visit(app, "c", "a")
	nav_forget(app, "c")
	testing.expect_value(t, len(app.cx.nav_hist), 2)
	testing.expect_value(t, app.cx.nav_hist[app.cx.nav_at].id, "a")

	// the limit
	for i in 0 ..< NAV_HISTORY_MAX + 20 { nav_visit(app, "", i % 2 == 0 ? "x" : "y") }
	testing.expect_value(t, len(app.cx.nav_hist), NAV_HISTORY_MAX)
	testing.expect_value(t, app.cx.nav_at, NAV_HISTORY_MAX - 1)
}

// A form as the server sends it: defaults taken, a field that depends on another, the answer as JSON, and what is missing says where.
@(test)
a_form_is_answered :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	defer delete(app.cx.forms)
	defer forms_clear(app)
	v, err := json.parse_string(`{"id":"frm_1","sessionID":"s","title":"Deploy","fields":[
		{"key":"name","type":"string","required":true},
		{"key":"env","type":"string","options":[{"value":"prod","label":"Production"},{"value":"test","label":"Test"}],"default":"test"},
		{"key":"why","type":"string","when":[{"key":"env","op":"eq","value":"prod"}]},
		{"key":"n","type":"integer","minimum":1,"maximum":5},
		{"key":"fast","type":"boolean","default":true},
		{"key":"tags","type":"multiselect","options":[{"value":"a","label":"Alpha"},{"value":"b","label":"Beta"}],"default":["b"]}
	]}`, parse_integers = true, allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	form_add(app, v)
	form_add(app, v)
	testing.expect_value(t, len(app.cx.forms), 1)
	f := app.cx.forms[0]

	testing.expect(t, !field_shown(f, &f.fields[2]), "the reason, only for production")
	_, problem, at := form_answer(f)
	testing.expect(t, problem != "", "the name is required")
	testing.expect_value(t, at, 0)

	ui.field_set(&f.fields[0].text, "first")
	f.fields[1].choice = 0
	testing.expect(t, field_shown(f, &f.fields[2]), "production: the reason is asked")
	ui.field_set(&f.fields[3].text, "9")
	_, problem, at = form_answer(f)
	testing.expect(t, problem != "", "9 is over the maximum")
	testing.expect_value(t, at, 2 + 1)   // (its page among those shown: the reason counts now)
	ui.field_set(&f.fields[3].text, "2.5")
	_, problem, _ = form_answer(f)
	testing.expect(t, problem != "", "not a whole number")

	ui.field_set(&f.fields[3].text, "3")
	body: string
	body, problem, _ = form_answer(f)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, body, `{"answer":{"name":"first","env":"prod","n":3,"fast":true,"tags":["b"]}}`)

	form_remove(app, "frm_1")
	testing.expect_value(t, len(app.cx.forms), 0)
}

// A question of the agent must have an answer, even with nothing `required`, and one's own words replace the option.
@(test)
a_question_wants_an_answer :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	defer delete(app.cx.forms)
	defer forms_clear(app)
	v, _ := json.parse_string(`{"id":"frm_2","sessionID":"s","title":"Questions","metadata":{"kind":"question"},"fields":[
		{"key":"q0","type":"string","options":[{"value":"Red","label":"Red"}],"custom":true}]}`, parse_integers = true, allocator = context.temp_allocator)
	form_add(app, v)
	f := app.cx.forms[0]
	testing.expect(t, f.question, "a question")
	_, problem, _ := form_answer(f)
	testing.expect(t, problem != "", "no answer yet")
	ui.field_set(&f.fields[0].text, "Teal")
	body, _, _ := form_answer(f)
	testing.expect_value(t, body, `{"answer":{"q0":"Teal"}}`)
}

// What goes in the file is what the import takes, under no "data"; a title makes a file name.
@(test)
an_export_is_what_the_import_takes :: proc(t: ^testing.T) {
	testing.expect_value(t, export_body(`{"data":{"info":{"id":"s"},"messages":[]}}`), `{"info":{"id":"s"},"messages":[]}`)
	testing.expect_value(t, file_safe(`a/b: "c"?`), `a-b- -c--`)
}

// A stage writes the files back at once: closed while it is on its way, it must still be known, for the dialog to cancel it.
@(test)
a_stage_closed_on_its_way_is_cancelled :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	c := &app.cx.changes
	v, _ := json.parse_string(`{"data":{"messageID":"m","snapshot":"abc","files":[{"file":"a.txt","patch":"","additions":1,"deletions":2,"status":"modified","more":true}]}}`, parse_integers = true, allocator = context.temp_allocator)

	revert_stage(app, "s", "m", "the prompt")
	testing.expect(t, c.open && c.loading && !c.staged, "on its way")
	c.open = false
	changes_open(app, "other")
	testing.expect_value(t, c.session, "s")   // (nothing else takes its place meanwhile)
	changes_load(app, "s", v)
	testing.expect(t, c.staged && !c.loading, "known as staged, so the next frame cancels it")

	c.open, c.staged = true, false
	changes_failed(app)
	revert_stage(app, "s", "m", "the prompt")
	changes_load(app, "s", v)
	testing.expect(t, c.staged, "staged")
	testing.expect_value(t, len(c.files), 1)
	testing.expect(t, c.files[0].more, "the patch is cut")
	testing.expect(t, strings.contains(changes_say(c), "written back on disk already"), "it says what is done")
	revert_gone(app, "s")
	testing.expect(t, !c.staged && !c.open, "done elsewhere: nothing to cancel")
	changes_open(app, "s")
	changes_failed(app)
	changes_open(app, "s")
	c.open, c.loading = false, false
	revert_found(app, "s", jget(v, "data"))
	testing.expect(t, c.open && c.staged && c.found, "found on opening the session")
	testing.expect(t, strings.has_prefix(changes_say(c), "This session was left going back."), "it says so")
	c.staged = false
	c.open = false
	revert_found(app, "s", jget(v, "data"))
	c.staged, c.open = false, false
	changes_open(app, "s", "m")
	c.loading = false
	testing.expect_value(t, changes_say(c), "No change recorded. Only a git folder keeps them.")
	c.loading, c.open = false, false
	changes_open(app, "s", "")
	c.open, c.loading = false, false
}

// A folder without snapshots: the files do not go back, and the dialog must not say they do.
@(test)
a_stage_without_snapshot_says_only_the_conversation_goes_back :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	c := &app.cx.changes
	v, _ := json.parse_string(`{"data":{"messageID":"m","files":[]}}`, parse_integers = true, allocator = context.temp_allocator)
	revert_stage(app, "s", "m", "")
	changes_load(app, "s", v)
	testing.expect(t, c.no_snapshot, "no snapshot")
	testing.expect(t, strings.contains(changes_say(c), "keeps no snapshots"), "it says so")
}

// A patch from git, as a session's diff gives it: only its lines are shown, from the first one.
@(test)
a_git_patch_shows_only_its_lines :: proc(t: ^testing.T) {
	lines := diff_parse("diff --git a/p.txt b/p.txt\nindex 26af6a8..43dd47e 100644\n--- a/p.txt\n+++ b/p.txt\n@@ -1 +1 @@\n-zero\n+index one\n\\ No newline at end of file\n")
	testing.expect_value(t, len(lines), 2)
	testing.expect_value(t, lines[0].sign, '-')
	testing.expect_value(t, lines[1].text, "index one")
}
