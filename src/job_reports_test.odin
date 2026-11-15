package ocn

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:testing"
import "gt:ui"
import session "gt:testkit/session"
import "gt:testkit/unwatched"

@(test)
a_shell_report_reads_its_attributes_and_its_output :: proc(t: ^testing.T) {
	s := `<shell id="sh_1db" state="completed" command="cd ~/p &amp;&amp; echo &quot;a &gt; b&quot; > out">  first line
second line
</shell>`
	jobs, ok := jobs_parse(s, context.temp_allocator)
	if !testing.expect(t, ok && len(jobs) == 1, "one report") { return }
	r := jobs[0]
	testing.expect_value(t, r.kind, Job_Kind.Shell)
	testing.expect_value(t, r.id, "sh_1db")
	testing.expect_value(t, r.state, Sub_State.Done)
	testing.expect_value(t, r.command, `cd ~/p && echo "a > b" > out`)
	testing.expect_value(t, r.body, "  first line\nsecond line")
}

// The harness does not escape a command's own quotes: the value ends at the quote followed by the tag's end and its line's.
@(test)
a_command_with_quotes_of_its_own_is_read_whole :: proc(t: ^testing.T) {
	s := `<shell id="sh_1dba33fe5001" state="completed" command="cd ~/k && nix flake check > /tmp/f.log 2>&1; grep -a "Error\|FAIL" /tmp/f.log | cut -c1-80; bash -c 'echo "x"'">
tk ci 1
 - a_test	FAIL: "it broke"
</shell>`
	jobs, ok := jobs_parse(s, context.temp_allocator)
	if !testing.expect(t, ok && len(jobs) == 1, "one report") { return }
	testing.expect_value(t, jobs[0].id, "sh_1dba33fe5001")
	testing.expect_value(t, jobs[0].state, Sub_State.Done)
	testing.expect_value(t, jobs[0].command, `cd ~/k && nix flake check > /tmp/f.log 2>&1; grep -a "Error\|FAIL" /tmp/f.log | cut -c1-80; bash -c 'echo "x"'`)
	testing.expect_value(t, jobs[0].body, "tk ci 1\n - a_test\tFAIL: \"it broke\"")
	// (a quote of the command followed by what looks like an attribute of the tag's own, the next one)
	two, two_ok := jobs_parse(`<shell id="a" command="echo "hi" there" state="failed">x</shell>`, context.temp_allocator)
	if testing.expect(t, two_ok && len(two) == 1, "one report") {
		testing.expect_value(t, two[0].command, `echo "hi" there`)
		testing.expect_value(t, two[0].state, Sub_State.Failed)
	}
}

@(test)
a_report_takes_single_quotes_and_numeric_references :: proc(t: ^testing.T) {
	jobs, ok := jobs_parse(`<shell id='x' command='echo "hi" &#39;there&#x27;' exit="2"></shell>`, context.temp_allocator)
	if !testing.expect(t, ok && len(jobs) == 1, "one report") { return }
	testing.expect_value(t, jobs[0].command, `echo "hi" 'there'`)
	testing.expect_value(t, jobs[0].state, Sub_State.Failed)   // (exit 2: failed, whatever the state says)
	testing.expect_value(t, jobs[0].body, "")
}

@(test)
a_subagent_report_in_error_says_why :: proc(t: ^testing.T) {
	s := `<subagent sessionID="ses_9" state="error" description="Look for the loader">The file was gone.

More.</subagent>`
	jobs, ok := jobs_parse(s, context.temp_allocator)
	if !testing.expect(t, ok && len(jobs) == 1, "one report") { return }
	r := &jobs[0]
	testing.expect_value(t, r.kind, Job_Kind.Subagent)
	testing.expect_value(t, r.id, "ses_9")
	testing.expect_value(t, r.state, Sub_State.Failed)
	testing.expect_value(t, r.description, "Look for the loader")
	testing.expect_value(t, r.body, "The file was gone.\n\nMore.")
	testing.expect_value(t, job_title(r), "Sub-agent stopped: The file was gone.")
}

@(test)
several_reports_in_a_row_are_each_read :: proc(t: ^testing.T) {
	s := "<shell id=\"a\" state=\"completed\" command=\"ls\">x</shell>\n\n<subagent sessionID=\"b\" state=\"completed\" description=\"d\">done</subagent>"
	jobs, ok := jobs_parse(s, context.temp_allocator)
	if !testing.expect(t, ok && len(jobs) == 2, "two reports") { return }
	testing.expect_value(t, jobs[0].kind, Job_Kind.Shell)
	testing.expect_value(t, jobs[0].body, "x")
	testing.expect_value(t, jobs[1].kind, Job_Kind.Subagent)
	testing.expect_value(t, jobs[1].body, "done")
}

@(test)
a_report_without_its_closing_tag_holds_the_rest :: proc(t: ^testing.T) {
	jobs, ok := jobs_parse("<shell id=\"a\" state=\"completed\" command=\"make\">built\nall", context.temp_allocator)
	if !testing.expect(t, ok && len(jobs) == 1, "one report") { return }
	testing.expect_value(t, jobs[0].body, "built\nall")
}

@(test)
a_text_that_is_not_only_reports_is_none :: proc(t: ^testing.T) {
	for s in ([]string{
		"",
		"just a note",
		"before <shell id=\"a\">x</shell>",
		"<shellfish id=\"a\">x</shellfish>",
		"<shell id=\"a",                                     // (its quote is not closed)
		"<shell id=\"a\" state=\"completed\"",               // (its opening tag has no end)
		"<shell id=\"a\">x</shell> and after",
		"<shell =\"a\">x</shell>",
	}) {
		_, ok := jobs_parse(s, context.temp_allocator)
		testing.expectf(t, !ok, "no report in %q", s)
	}
}

// Reports in the conversation: one line each, folded; a click opens one, its output then shows in a selectable well,
// a sub-agent's report as selectable Markdown.
@(test)
job_reports_show_folded_and_open_on_a_click :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		text := "<shell id=\"sh_1\" state=\"completed\" command=\"make all\">line one\nline two</shell>\n<subagent sessionID=\"ses_2\" state=\"completed\" description=\"Read the docs\">The **report**.</subagent>"
		page := fmt.tprintf(`{{"data":[{{"id":"msg_j","type":"synthetic","text":%s,"time":{{"created":1}}}}],"cursor":{{"next":""}}}}`, jquote(text))
		v, err := json.parse_string(page, allocator = context.temp_allocator)
		testing.expect(t, err == nil)
		chat_load(app, v, false)
		chat_scroll_event(app, Scroll_Signal.Snap)
		session.wait_until(s, proc(s: ^session.Session) -> bool { return session.find(s, "job_msg_j_1") != nil }, "the two cards")
		first, second := session.find(s, "job_msg_j_0"), session.find(s, "job_msg_j_1")
		if !testing.expect(t, first != nil && second != nil, "two cards") { return }
		testing.expect(t, session.find(s, "jobb_msg_j_0") == nil && session.find(s, "jobb_msg_j_1") == nil, "folded")
		if head := session.find(s, "head", within = first); testing.expect(t, head != nil, "a header") {
			card_h, head_h := first.rect.max.y - first.rect.min.y, head.rect.max.y - head.rect.min.y
			testing.expectf(t, card_h <= head_h + 1, "folded: its header alone (%v px, the header %v px)", card_h, head_h)
		}

		for k in 0 ..< 2 {
			card := session.find(s, fmt.tprintf("job_msg_j_%d", k))
			head := session.find(s, "head", within = card)
			if !testing.expect(t, head != nil, "a header") { return }
			session.click_at(s, session.center(head))
			session.wait_idle(s)
			testing.expect(t, part_open(app, fmt.tprintf("msg_j_job%d", k)), "a click opens it")
		}
		out := session.find(s, "output", within = session.find(s, "jobb_msg_j_0"))
		if !testing.expect(t, out != nil, "the command's output") { return }
		line := session.find(s, "t", within = out)
		testing.expect(t, line != nil && .Selectable in line.flags, "the output is selectable")
		report := session.find(s, "jobb_msg_j_1")
		if !testing.expect(t, report != nil, "the report") { return }
		testing.expect(t, selectable_within(report), "the report is selectable")
	})
}

// What the cards show is what Copy gives: a command and its output, a sub-agent's report; never their markup.
@(test)
the_text_of_job_reports_is_what_their_cards_show :: proc(t: ^testing.T) {
	s := "<shell id=\"sh_1\" state=\"completed\" command=\"make all\">line one\nline two</shell>\n<subagent sessionID=\"ses_2\" state=\"completed\" description=\"Read the docs\">The **report**.</subagent>"
	jobs, ok := jobs_parse(s, context.temp_allocator)
	if !testing.expect(t, ok && len(jobs) == 2, "two reports") { return }
	testing.expect_value(t, jobs_text(jobs), "$ make all\nline one\nline two\n\nThe **report**.")
	only, _ := jobs_parse(`<shell id="a" state="completed" command="true"></shell>`, context.temp_allocator)
	testing.expect_value(t, jobs_text(only), "$ true")
}

// The message's Copy, from its menu on a card: the cards' text in the clipboard, not the markup they came in.
@(test)
copy_on_a_job_report_copies_what_it_shows :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		text := "<shell id=\"sh_1\" state=\"completed\" command=\"make all\">line one\nline two</shell>"
		page := fmt.tprintf(`{{"data":[{{"id":"msg_j","type":"synthetic","text":%s,"time":{{"created":1}}}}],"cursor":{{"next":""}}}}`, jquote(text))
		v, err := json.parse_string(page, allocator = context.temp_allocator)
		testing.expect(t, err == nil)
		chat_load(app, v, false)
		chat_scroll_event(app, Scroll_Signal.Snap)
		session.wait_until(s, proc(s: ^session.Session) -> bool { return session.find(s, "job_msg_j_0") != nil }, "the card")
		session.wait_idle(s)
		head := session.find(s, "head", within = session.find(s, "job_msg_j_0"))
		if !testing.expect(t, head != nil, "its header") { return }
		session.click_at(s, session.center(head), .Right)
		session.wait_until(s, proc(s: ^session.Session) -> bool { return session.find_text(s, "Copy") != nil }, "the message's menu")
		session.click_text(s, "Copy")
		session.frames(s, 2)
		testing.expect_value(t, session.clipboard(s), "$ make all\nline one\nline two")
	})
}

@(private = "file")
selectable_within :: proc(b: ^ui.Box) -> bool {
	if .Selectable in b.flags { return true }
	for c := b.first; c != nil; c = c.next { if selectable_within(c) { return true } }
	return false
}
