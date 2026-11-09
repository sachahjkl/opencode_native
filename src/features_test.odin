package ocn

// What the newer parts decide by themselves, without a window: a diff, the end of a command's output, an address, the links
// of a text, the history's steps.

import "base:runtime"
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

// Up goes through the prompts of the session shown, newest first, each once; another session's are not there. Down past the
// newest one gives back what was being typed.
@(test)
the_history_is_the_sessions_own :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (the App keeps what it made, as the program does, till it ends)
	app := new(App)
	defer free(app)
	chat_reset(&app.chat)
	app.chat.id = "ses_a"
	append(&app.chat.messages, Message{id = "m1", kind = .User, text = "first"}, Message{id = "m2", kind = .Assistant},
		Message{id = "m3", kind = .User, text = " second "}, Message{id = "m4", kind = .User, text = "second"})
	ui.area_set(&app.composer, "a draft")
	history_step(app, -1)   // (nothing newer than what is typed)
	testing.expect(t, !history_browsing(app))
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

	// another session: only its own prompts, and none at all for a new one
	chat_reset(&app.chat)
	app.chat.id = "ses_b"
	append(&app.chat.messages, Message{id = "m9", kind = .User, text = "other"})
	history_step(app, 1)
	testing.expect_value(t, ui.area_string(&app.composer), "other")
	history_step(app, 1)
	testing.expect_value(t, ui.area_string(&app.composer), "other")
	history_leave(app, true)
	chat_reset(&app.chat)
	history_step(app, 1)
	testing.expect(t, !history_browsing(app))
	testing.expect_value(t, ui.area_string(&app.composer), "a draft")
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
	testing.expect_value(t, prompt_fields(nil, m.chosen[:], "\u00e9\U0001F600 @a.txt and @explore"),
		`,"files":[{"uri":"file:///d/a.txt","name":"a.txt","mention":{"start":4,"end":10,"text":"@a.txt"}}],"agents":[{"name":"explore","mention":{"start":15,"end":23,"text":"@explore"}}]`)
	testing.expect_value(t, prompt_fields(nil, m.chosen[:], "nothing"), "")
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
		n.step = Connect_Choose{}
		integrations_load(app, json.Object{})
		delete(n.list)
		delete(n.active.message)   // (no server here: the reading of the accounts says so)
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

	n.step = Connect_Fill{}
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
	testing.expect_value(t, size_of(Vt_Style), 16)
	testing.expect_value(t, size_of(Vt_Style_Color), 4)
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


// The options go in beside what the file says: its comments, its order, what was set by hand.
@(test)
the_experimental_options_go_in_beside_what_is_there :: proc(t: ^testing.T) {
	keys := []string{"schedules", "artifacts", "todo"}
	before := "{\n  // mine\n  \"plugins\": [\"a\"],\n  \"experimental\": {\n    // kept\n    \"todo\": true\n  },\n  \"mcp\": {\"x\": {\"experimental\": {\"schedules\": false}}}\n}\n"
	after := config_with_experimental(before, keys)
	testing.expect_value(t, after, "{\n  // mine\n  \"plugins\": [\"a\"],\n  \"experimental\": {\n    \"schedules\": true,\n    \"artifacts\": true,\n    // kept\n    \"todo\": true\n  },\n  \"mcp\": {\"x\": {\"experimental\": {\"schedules\": false}}}\n}\n")
	_, bad := json.parse_string(after, .JSON5, allocator = context.temp_allocator)
	testing.expect_value(t, bad, json.Error.None)
	testing.expect_value(t, config_with_experimental(after, keys), "")   // (the second time: nothing)
}

// What was set by hand stays, a false above all.
@(test)
an_option_turned_off_stays_off :: proc(t: ^testing.T) {
	text := "{\"experimental\": {\"schedules\": false, \"artifacts\": false}}"
	testing.expect_value(t, config_with_experimental(text, {"schedules", "artifacts"}), "")
	testing.expect(t, !strings.contains(config_with_experimental(text, {"schedules", "todo"}), "\"schedules\": true"), "not turned on")
}

// No object yet, an empty one, an empty file; a comment that says the key is no key; what is not an object is left alone.
@(test)
the_experimental_options_find_their_place :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, text: string) {
		out := config_with_experimental(text, {"schedules"})
		v, bad := json.parse_string(out, .JSON5, allocator = context.temp_allocator)
		testing.expect_value(t, bad, json.Error.None)
		on, _ := jget(v, "experimental", "schedules").(json.Boolean)
		testing.expect(t, bool(on), text)
	}
	check(t, "{\n  \"a\": 1\n}\n")
	check(t, "{}")
	check(t, "{ \"experimental\": {} }")
	check(t, "{\n  // \"experimental\": { \"x\": true }\n  \"a\": \"experimental\"\n}")
	testing.expect_value(t, config_with_experimental("[1]", {"schedules"}), "")
	testing.expect_value(t, config_with_experimental("{\"experimental\": 1}", {"schedules"}), "")
}

// The list is the server's: its plain switches, nothing else.
@(test)
the_options_are_those_of_the_schema :: proc(t: ^testing.T) {
	v, _ := json.parse_string(`{"components":{"schemas":{"Config.InfoEncoded":{"properties":{"experimental":{"properties":{
		"schedules":{"type":"boolean"},"subagent_depth":{"type":"integer"},"image_generate":{"anyOf":[{"type":"boolean"}]}}}}}}}}`, allocator = context.temp_allocator)
	keys := experimental_keys(v)
	testing.expect_value(t, len(keys), 1)
	testing.expect_value(t, keys[0], "schedules")
	testing.expect(t, url_is_here("http://127.0.0.1:4096") && url_is_here("https://localhost") && url_is_here("http://[::1]:4096"), "here")
	testing.expect(t, !url_is_here("https://box.example:4096") && !url_is_here("http://192.168.1.2:4096"), "elsewhere")
}


// The logo's edge takes the accent, its soft pixels in proportion; what is grey does not move, nor does anything's opacity.
@(test)
the_logo_takes_the_accent :: proc(t: ^testing.T) {
	px := []u8{0xe8, 0x93, 0x5a, 200,   0x80, 0x80, 0x80, 255,   0x12, 0x12, 0x12, 255,   0x75, 0x60, 0x2c, 100}
	logo_tint_pixels(px, 0x10203040)
	testing.expect_value(t, px[0], 0x10)   // (all the way: the accent itself)
	testing.expect_value(t, px[1], 0x20)
	testing.expect_value(t, px[2], 0x30)
	testing.expect_value(t, px[3], 200)
	testing.expect_value(t, px[4], 0x80)   // (grey stays)
	testing.expect_value(t, px[8], 0x12)
	testing.expect(t, px[12] < 0x2c, "half of a soft pixel: between its grey and the accent")
	testing.expect_value(t, px[15], 100)
}

// A long list of models looked through by hand: headers that fold, nothing typed. Typing goes through them all.
@(test)
a_pickers_groups_fold_while_nothing_is_typed :: proc(t: ^testing.T) {
	p: Picker
	defer { for k in p.unfolded { delete(k) }; delete(p.unfolded) }
	items := []Pick_Item{{label = "a1", group = "alpha"}, {label = "a2", group = "alpha"}, {label = "b1", group = "beta"}}
	hits := []Hit{{index = 0}, {index = 1}, {index = 2}}
	rows := picker_rows(&p, items, hits, false)
	testing.expect_value(t, len(rows), 2)   // (two headers)
	testing.expect_value(t, rows[0].count, 2)
	testing.expect_value(t, rows[1].group, "beta")
	testing.expect_value(t, picker_take(&p, items, hits, rows, 0), -1)   // (a header chooses nothing)
	rows = picker_rows(&p, items, hits, false)
	testing.expect_value(t, len(rows), 4)
	testing.expect_value(t, picker_take(&p, items, hits, rows, 2), 1)    // (a2, under its open header)
	testing.expect_value(t, picker_take(&p, items, hits, rows, 0), -1)
	testing.expect_value(t, len(picker_rows(&p, items, hits, false)), 2)
	testing.expect_value(t, len(picker_rows(&p, items, hits, true)), 3)  // (typed: the hits, whatever is folded)
	agents := []Pick_Item{{label = "build"}, {label = "plan"}}
	testing.expect_value(t, len(picker_rows(&p, agents, hits[:2], false)), 2)   // (no group: no header)
}

@(test)
a_model_says_what_it_is :: proc(t: ^testing.T) {
	m := Model_Info{
		ctx_len = 1000000, out_len = 128000, priced = true, price_in = 2, price_out = 10, price_cached = 0.25,
		inputs = "text, image", tools_known = true, tools = true, efforts = "low, high", released = 1767225600000, status = "beta",
	}
	facts := model_facts(m)
	testing.expect_value(t, facts[0], Model_Fact{"Context", "1M"})
	testing.expect_value(t, facts[1], Model_Fact{"Output", "128k"})
	testing.expect_value(t, facts[2], Model_Fact{"Price", "$2 in, $10 out per M"})
	testing.expect_value(t, facts[3], Model_Fact{"Cached", "$0.25 per M"})
	testing.expect_value(t, facts[4], Model_Fact{"Reads", "text, image"})
	testing.expect_value(t, facts[5], Model_Fact{"Tools", "yes"})
	testing.expect_value(t, facts[6], Model_Fact{"Thinking", "low, high"})
	testing.expect_value(t, facts[7], Model_Fact{"Released", "2026-01"})
	testing.expect_value(t, facts[8], Model_Fact{"Status", "beta"})
	free := model_facts({priced = true})
	testing.expect_value(t, len(free), 1)
	testing.expect_value(t, free[0], Model_Fact{"Price", "free"})
	testing.expect_value(t, len(model_facts({})), 0)   // (nothing said, nothing invented)
}

// What a file goes as: an image or a PDF by its extension, text when it is UTF-8 without a NUL, else nothing (its path).
@(test)
an_attached_file_goes_as_its_type :: proc(t: ^testing.T) {
	testing.expect_value(t, attach_mime("/a/shot.PNG", nil), "image/png")
	testing.expect_value(t, attach_mime("/a/paper.pdf", transmute([]u8)string("%PDF-1.7\x00")), "application/pdf")
	testing.expect_value(t, attach_mime("/a/notes.md", transmute([]u8)string("# Notes, été\n")), "text/plain")
	testing.expect_value(t, attach_mime("/a/Makefile", transmute([]u8)string("all:\n\tcc x.c\n")), "text/plain")
	testing.expect_value(t, attach_mime("/a/prog", transmute([]u8)string("\x7fELF\x02\x01\x00")), "")
	testing.expect_value(t, attach_mime("/a/latin1.txt", []u8{'c', 0xe9}), "")
}

// `/` at the start of the composer proposes the server's commands that match what follows it, best first.
@(test)
a_slash_proposes_the_commands :: proc(t: ^testing.T) {
	q, ok := slash_word("/rev", 4)
	testing.expect(t, ok && q == "rev")
	_, ok = slash_word("/review this", 12)
	testing.expect(t, !ok, "past the command's word")
	_, ok = slash_word("see /review", 11)
	testing.expect(t, !ok, "only at the start")
	q, ok = slash_word("/", 1)
	testing.expect(t, ok && q == "", "the `/` alone lists them all")

	context.allocator = runtime.heap_allocator()
	app := new(App)
	defer free(app)
	slash_load(app, []Slash{{strings.clone("init"), strings.clone("")}, {strings.clone("review"), strings.clone("")}, {strings.clone("compact"), strings.clone("")}})
	defer { slash_forget(app); delete(app.cx.slash) }
	hits := slash_matches(app, "rv")
	testing.expect_value(t, len(hits), 1)
	if len(hits) == 1 { testing.expect_value(t, app.cx.slash[hits[0]].name, "review") }
	testing.expect_value(t, len(slash_matches(app, "")), 3)
}

// A table copied: a plain HTML grid (no colour, no font), the header row as th, each column aligned as written, bold and code kept,
// what is HTML in a cell escaped.
@(test)
a_table_copies_as_a_plain_grid :: proc(t: ^testing.T) {
	cell :: proc(runs: ..ui.Rich_Run) -> [dynamic]ui.Rich_Run {
		out := make([dynamic]ui.Rich_Run, context.temp_allocator)
		append(&out, ..runs)
		return out
	}
	cells := [][][dynamic]ui.Rich_Run{
		{cell({text = "Name", style = {bold = true}}), cell({text = "Size", style = {bold = true}})},
		{cell({text = "a<b & c"}), cell({text = "12", style = {code = true}})},
		{cell({text = "big", style = {bold = true}}), cell({text = "3"})},
	}
	html := table_html(cells, {.Left, .Right})
	testing.expect(t, strings.has_prefix(html, `<table style="border-collapse:collapse"><thead><tr><th style="border:1px solid #bbb;padding:4px 8px;text-align:left">Name</th>`), html)
	testing.expect(t, strings.contains(html, `text-align:right">Size</th>`), html)
	testing.expect(t, strings.contains(html, `>a&lt;b &amp; c</td>`), html)
	testing.expect(t, strings.contains(html, `<code>12</code>`), html)
	testing.expect(t, strings.contains(html, `<b>big</b>`), html)
	testing.expect(t, !strings.contains(html, "color") && !strings.contains(html, "font"), "no colour, no font: the program it is pasted in gives them")
	testing.expect(t, strings.has_suffix(html, "</tbody></table>"), html)
}
