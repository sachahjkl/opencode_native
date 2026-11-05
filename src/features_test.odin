package occ

// What the newer parts decide by themselves, without a window: a diff, the end of a command's output, an address, the links
// of a text, the history's steps.

import "core:encoding/json"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "gt:platform"
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

// `@` names something at the start of a word only, up to the caret.
@(test)
the_word_after_an_at_is_a_mention :: proc(t: ^testing.T) {
	start, q, ok := mention_word("see @src/ma", 11)
	testing.expect(t, ok, "at the end of a word")
	testing.expect_value(t, start, 4)
	testing.expect_value(t, q, "src/ma")
	_, q, ok = mention_word("@", 1)
	testing.expect(t, ok && q == "", "alone: the folder's files")
	_, _, ok = mention_word("me@host.org", 11)
	testing.expect(t, !ok, "a mail address")
	_, _, ok = mention_word("@a b", 4)
	testing.expect(t, !ok, "the word is over")
	_, q, ok = mention_word("@abc", 2)
	testing.expect(t, ok && q == "a", "up to the caret")
}

// The server takes a file by its absolute uri, what a uri cannot hold escaped.
@(test)
a_file_goes_as_its_absolute_uri :: proc(t: ^testing.T) {
	testing.expect_value(t, file_uri(`S:\demo\`, `src\a b.txt`), "file:///S:/demo/src/a%20b.txt")
	testing.expect_value(t, file_uri("/home/me", "#1.txt"), "file:///home/me/%231.txt")
}

// A file too long is cut between two characters; a file with a zero byte, or not in UTF-8, is no text.
@(test)
what_is_shown_of_a_file :: proc(t: ^testing.T) {
	s, ok := file_text("plain")
	testing.expect(t, ok && s == "plain", "text")
	_, ok = file_text("a\x00b")
	testing.expect(t, !ok, "a zero byte")
	_, ok = file_text("caf\xe9")
	testing.expect(t, !ok, "not UTF-8")
	long := strings.concatenate({strings.repeat("a", FILE_VIEW_MAX_BYTES - 1, context.temp_allocator), "\u00e9\u00e9"}, context.temp_allocator)
	s, ok = file_text(long)
	testing.expect(t, ok, "cut on a character")
	testing.expect_value(t, len(s), FILE_VIEW_MAX_BYTES - 1)
}

// A prompt says the files and agents still in its text, where they stand as the server counts; the others are forgotten.
@(test)
a_prompt_says_what_it_mentions :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	defer mentions_destroy(app)
	defer delete(app.cx.attachments)
	m := &app.cx.mentions
	append(&m.chosen, Mention{.File, strings.clone("@a.txt"), strings.clone("file:///d/a.txt"), strings.clone("a.txt")})
	append(&m.chosen, Mention{.File, strings.clone("@gone.txt"), strings.clone("file:///d/gone.txt"), strings.clone("gone.txt")})
	append(&m.chosen, Mention{.Agent, strings.clone("@explore"), strings.clone("explore"), strings.clone("")})
	testing.expect_value(t, attachments_take(app, "\u00e9\U0001F600 @a.txt and @explore"),
		`,"files":[{"uri":"file:///d/a.txt","name":"a.txt","mention":{"start":4,"end":10,"text":"@a.txt"}}],"agents":[{"name":"explore","mention":{"start":15,"end":23,"text":"@explore"}}]`)
	testing.expect_value(t, len(m.chosen), 0)
	testing.expect_value(t, attachments_take(app, "nothing"), "")
}

// Those connected come first; the list does not change under what is being filled in, it comes after.
@(test)
the_integrations_connected_come_first :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	n := &app.cx.integrations
	v, _ := json.parse_string(`{"data":[
		{"id":"a","name":"A","methods":[{"type":"key"},{"type":"env","names":["A_KEY"]},{"type":"unknown"}],"connections":[]},
		{"id":"b","name":"B","methods":[{"type":"oauth","id":"web","label":"Sign in","form":[{"key":"host","type":"string","required":true}]}],
		 "connections":[{"type":"credential","id":"c1","label":"work","method":"oauth","status":{"status":"needs_auth","message":"again"}},{"type":"env","name":"B_KEY"}]}
	]}`, parse_integers = true, allocator = context.temp_allocator)
	integrations_load(app, v)
	defer {
		n.step = .Choose
		integrations_load(app, json.Object{})
		delete(n.list)
	}
	testing.expect_value(t, len(n.list), 2)
	testing.expect_value(t, n.list[0].id, "b")
	testing.expect(t, n.list[0].connections[0].needs_auth, "it must sign in again")
	testing.expect(t, !n.list[0].connections[1].credential, "from the environment")
	testing.expect_value(t, n.list[0].connections[1].label, "B_KEY")
	testing.expect_value(t, len(n.list[1].methods), 2)   // (a kind it does not know is left out)
	testing.expect_value(t, n.list[1].methods[1].names[0], "A_KEY")

	c, _ := json.parse_string(`{"data":[{"id":"c1","integrationID":"b","label":"work","active":true,"value":{"type":"key","key":"SECRET"}}]}`, parse_integers = true, allocator = context.temp_allocator)
	credentials_load(app, c)
	testing.expect(t, n.list[0].connections[0].active, "in use")

	n.step = .Fill
	integrations_load(app, v)
	testing.expect(t, n.dirty, "for later")
	testing.expect_value(t, len(n.list), 2)
	n.dirty = false
}

// What a way of connecting asks goes as its answer; what is missing stops it.
@(test)
what_a_method_asks_goes_with_it :: proc(t: ^testing.T) {
	v, _ := json.parse_string(`[{"key":"host","type":"string","required":true,"title":"Host"}]`, parse_integers = true, allocator = context.temp_allocator)
	list, _ := v.(json.Array)
	f := form_new("", "", "", false, list)
	defer form_free(f)
	_, problem := connect_extra(f, "")
	testing.expect(t, problem != "", "the host is required")
	ui.field_set(&f.fields[0].text, "a.example")
	extra, none := connect_extra(f, " work ")
	testing.expect_value(t, none, "")
	testing.expect_value(t, extra, `"answer":{"host":"a.example"},"label":"work"`)
	bare, _ := connect_extra(nil, "")
	testing.expect_value(t, bare, `"answer":{}`)
}

// A login: its details are kept, an answer for another attempt says nothing, and what ends it says why.
@(test)
a_login_is_followed_until_it_ends :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	n := &app.cx.integrations
	json_of :: proc(s: string) -> json.Value {
		v, _ := json.parse_string(s, parse_integers = true, allocator = context.temp_allocator)
		return v
	}
	n.step = .Sending
	connect_begun(app, "oauth", json_of(`{"data":{"attemptID":"a1","url":"","instructions":"Enter the code ABCD","mode":"auto"}}`))
	testing.expect_value(t, n.step, Connect_Step.Waiting)
	testing.expect_value(t, n.instructions, "Enter the code ABCD")
	testing.expect(t, !n.by_code, "it ends by itself")
	connect_status(app, "oauth old", json_of(`{"data":{"status":"failed","message":"no"}}`))
	testing.expect_value(t, n.step, Connect_Step.Waiting)
	connect_status(app, "oauth a1", json_of(`{"data":{"status":"pending"}}`))
	testing.expect_value(t, n.step, Connect_Step.Waiting)
	connect_status(app, "oauth a1", json_of(`{"data":{"status":"failed","message":"refused"}}`))
	testing.expect_value(t, n.step, Connect_Step.Choose)
	testing.expect_value(t, n.failed, "refused")
	testing.expect_value(t, n.attempt, "")

	n.step = .Sending
	connect_begun(app, "oauth", json_of(`{"data":{"attemptID":"a2","url":"","instructions":"","mode":"code"}}`))
	testing.expect(t, n.by_code, "a code to paste")
	connect_status(app, "oauth a2", json_of(`{"data":{"status":"expired"}}`))
	testing.expect(t, strings.contains(n.failed, "expired"), "it says so")

	n.step = .Sending
	connect_failed(app)
	testing.expect_value(t, n.step, Connect_Step.Fill)
	n.step = .Choose
}

// A file of an artifact is named by an agent: it stays under its folder, whatever it says.
@(test)
an_artifact_stays_in_its_folder :: proc(t: ^testing.T) {
	for good in ([]string{"index.html", "css/style.css", "a..b/c.txt", "..hidden"}) { testing.expect(t, artifact_path_safe(good), good) }
	for bad in ([]string{"", "../evil.txt", "a/../../evil", `a\..\..\evil`, "/etc/passwd", `\\host\share\x`, `C:\Windows\x`, "C:x"}) { testing.expect(t, !artifact_path_safe(bad), bad) }
}

// What the server takes, and what it does not have to refuse.
@(test)
a_schedule_says_what_and_when :: proc(t: ^testing.T) {
	body, problem := schedule_body("s", " hello ", "", " 2 hours ", .In)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, body, `{"sessionID":"s","when":{"in":"2 hours"},"prompt":"hello"}`)
	body, _ = schedule_body("s", "x", "morning", "0 9 * * 1", .Cron)
	testing.expect_value(t, body, `{"sessionID":"s","name":"morning","when":{"cron":"0 9 * * 1"},"prompt":"x"}`)
	_, problem = schedule_body("s", " ", "", "1 day", .Every)
	testing.expect(t, problem != "", "no prompt")
	_, problem = schedule_body("s", "x", "", "", .Every)
	testing.expect(t, problem != "", "no time")

	w, _ := json.parse_string(`{"type":"every","every":"1 day"}`, allocator = context.temp_allocator)
	testing.expect_value(t, when_text(w), "every 1 day")
	testing.expect_value(t, due_text(0, 1000), "due now")
	testing.expect_value(t, due_text(30 * 60000, 0), "in 30 min")
	testing.expect_value(t, due_text(24 * 3600000, 0), "in 24 h")
	testing.expect_value(t, due_text(3 * 86400000, 0), "in 3 days")
}

// Those one chose first, with what they say of themselves.
@(test)
the_plugins_one_chose_come_first :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	p := &app.cx.plugins
	v, _ := json.parse_string(`{"data":[
		{"id":"opencode.plan","source":{"type":"builtin"},"features":{"server":true},"state":{"status":"active"}},
		{"id":"mine","source":{"type":"package","target":"mine@1","version":"1.0.0","outdated":true},"features":{"server":true,"gui":true},"state":{"status":"failed","error":"it broke"}}
	]}`, parse_integers = true, allocator = context.temp_allocator)
	plugins_load(app, v)
	defer {
		virtual.arena_destroy(&p.arena)
		delete(p.list)
	}
	testing.expect_value(t, p.list[0].id, "mine")
	testing.expect(t, p.list[0].outdated && p.list[0].failed, "what it says of itself")
	testing.expect_value(t, p.list[0].error, "it broke")
	testing.expect_value(t, p.list[0].features, "server, gui")
	testing.expect_value(t, p.list[1].kind, "builtin")
}


// The ABI of libghostty-vt: what is passed by value or filled by size must be as big as in its headers (a C compiler says these).
@(test)
the_terminal_structs_are_those_of_the_headers :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Vt_Style), 72)
	testing.expect_value(t, size_of(Vt_Style_Color), 16)
	testing.expect_value(t, size_of(Vt_Colors), 792)
	testing.expect_value(t, size_of(Vt_Scroll), 24)
	testing.expect_value(t, size_of(Vt_Mode), 4)
	testing.expect_value(t, size_of(Vt_Mouse_Size), 40)
}

// What the shell gets, byte for byte: a wrong number of a key sends something else without a word.
@(test)
a_key_says_what_a_terminal_says :: proc(t: ^testing.T) {
	term := term_new("x", "t", "")
	defer term_free(term)
	expect :: proc(t: ^testing.T, term: ^Term, k: platform.Key, mods: platform.Modifiers, want: string) {
		testing.expect_value(t, term_encode_key(term, k, mods, false), want)
	}
	expect(t, term, .Return, {}, "\r")
	expect(t, term, .Backspace, {}, "\x7f")
	expect(t, term, .Tab, {}, "\t")
	expect(t, term, .Escape, {}, "\x1b")
	expect(t, term, .Up, {}, "\x1b[A")
	expect(t, term, .Left, {}, "\x1b[D")
	expect(t, term, .Home, {}, "\x1b[H")
	expect(t, term, .End, {}, "\x1b[F")
	expect(t, term, .Delete, {}, "\x1b[3~")
	expect(t, term, .Page_Up, {}, "\x1b[5~")
	expect(t, term, .F1, {}, "\x1bOP")
	expect(t, term, .F5, {}, "\x1b[15~")
	expect(t, term, .C, {.Ctrl}, "\x03")
	expect(t, term, .K, {.Ctrl}, "\x0b")
	expect(t, term, .Z, {.Ctrl}, "\x1a")
	expect(t, term, .B, {.Alt}, "\x1bb")
	expect(t, term, .A, {}, "")                  // (its character comes by the Text event)
	expect(t, term, .N2, {.Ctrl, .Alt}, "")      // (AltGr: a character too)
	term_feed(term, "\x1b[?1h")                  // (application cursor keys)
	expect(t, term, .Up, {}, "\x1bOA")
}

// Without brackets a line break in a paste runs what comes before it: the program that asks for them gets them.
@(test)
a_paste_is_what_the_program_asked_for :: proc(t: ^testing.T) {
	term := term_new("x", "t", "")
	defer term_free(term)
	testing.expect_value(t, term_paste_text(term, "a\nb"), "a\rb")
	term_feed(term, "\x1b[?2004h")
	testing.expect_value(t, term_paste_text(term, "a\nb"), "\x1b[200~a\nb\x1b[201~")
}

