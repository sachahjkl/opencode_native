package occ

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import "gt:platform"

@(private = "file")
state_json :: proc(status: string, exit := -1) -> string {
	if exit >= 0 { return fmt.tprintf(`{{"data":{{"id":"sh_1","status":%s,"exit":%d,"time":{{"started":1000,"completed":3000}}}}}}`, jquote(status), exit) }
	return fmt.tprintf(`{{"data":{{"id":"sh_1","status":%s,"time":{{"started":1000}}}}}}`, jquote(status))
}

@(private = "file")
output_json :: proc(text: string, cursor: int, size := -1, truncated := false) -> string {
	return fmt.tprintf(`{{"data":{{"output":%s,"cursor":%d,"size":%d,"truncated":%v}}}}`, jquote(text), cursor, size >= 0 ? size : cursor, truncated)
}

@(private = "file")
running_view :: proc(t: ^testing.T, app: ^App) -> ^Output_View {
	v := output_view_open_shell(app, "sh_1", "cargo build", "S:\\x")
	bench_answer(app, bench_take(t, .Output_State), 200, state_json("running"))
	testing.expect(t, app.cx.outputs.shown == v, "it opens in the dialog")
	return v
}

@(test)
a_command_that_runs_is_followed_and_its_end_is_said :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	v := running_view(t, app)
	testing.expect(t, !v.over)
	r := bench_take(t, .Output_Read)
	testing.expect(t, strings.contains(r.path, "/api/shell/sh_1/output?cursor=0"))
	testing.expect(t, strings.contains(r.path, "location"), "the server has it by folder")
	bench_answer(app, r, 200, output_json("one\n", 4))
	testing.expect_value(t, string(v.raw[:]), "one\n")

	// It printed: read again, from where it stopped. At rest: has it ended?
	r = bench_take(t, .Output_Read)
	testing.expect(t, strings.contains(r.path, "cursor=4"))
	testing.expect_value(t, r.delay, OUTPUT_POLL_MS)
	bench_answer(app, r, 200, output_json("", 4))
	bench_answer(app, bench_take(t, .Output_State), 200, state_json("exited", 0))
	testing.expect(t, !v.over, "what it printed last comes first")
	bench_answer(app, bench_take(t, .Output_Read), 200, output_json("two\n", 8))
	testing.expect(t, v.over && v.seen_end, "seen as it happened: it says so")
	testing.expect_value(t, string(v.raw[:]), "one\ntwo\n")
	word, _ := output_view_word(v)
	testing.expect_value(t, word, "exit 0")
	testing.expect_value(t, bench_count(.Output_Read) + bench_count(.Output_State), 0)   // (nothing more is asked)
	output_view_close(app, v)
	output_views_tick(app)
	testing.expect_value(t, len(app.cx.outputs.list), 0)
}

@(test)
a_command_ended_before_it_opened_announces_nothing :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	v := output_view_open_shell(app, "sh_1", "ls", "")
	bench_answer(app, bench_take(t, .Output_State), 200, state_json("exited", 3))
	bench_answer(app, bench_take(t, .Output_Read), 200, output_json("a\n", 2))
	testing.expect(t, v.over && !v.seen_end)
	word, _ := output_view_word(v)
	testing.expect_value(t, word, "exit 3")
}

@(test)
what_is_large_is_read_to_its_end_at_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	_ = running_view(t, app)
	bench_answer(app, bench_take(t, .Output_Read), 200, output_json("a", 1, size = 5))
	testing.expect_value(t, bench_take(t, .Output_Read).delay, 0)
}

// The server's list keeps a command for a while: past that, what the call handed back is what there is.
@(test)
a_command_the_server_forgot_shows_what_the_call_handed_back :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	v := output_view_open_shell(app, "sh_1", "ls", "", fallback = "from the call\n")
	bench_answer(app, bench_take(t, .Output_State), 404, `{"_tag":"ShellNotFoundError"}`)
	testing.expect(t, v.over && v.lost)
	testing.expect_value(t, string(v.raw[:]), "from the call\n")
}

@(test)
a_server_out_of_reach_is_asked_again :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	v := running_view(t, app)
	bench_lost(app, bench_take(t, .Output_Read))
	testing.expect(t, !v.over)
	testing.expect_value(t, bench_take(t, .Output_Read).delay, OUTPUT_POLL_MS)
}

@(test)
a_view_closed_drops_what_comes_after_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	v := running_view(t, app)
	r := bench_take(t, .Output_Read)
	output_view_close(app, v)
	testing.expect(t, app.cx.outputs.shown == nil)
	output_views_tick(app)
	bench_answer(app, r, 200, output_json("late", 4))
	testing.expect_value(t, bench_count(.Output_Read), 0)
}

@(test)
a_line_end_gets_its_return_even_between_two_reads :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	v := running_view(t, app)
	output_view_feed(v, "a\r")
	output_view_feed(v, "\nb\n")
	testing.expect_value(t, v.last, u8('\n'))
	testing.expect_value(t, string(v.raw[:]), "a\r\nb\n")   // (Copy has what came)
}

@(test)
what_is_kept_for_copy_stops_at_its_limit :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	v := running_view(t, app)
	chunk := strings.repeat("x", OUTPUT_KEEP_BYTES / 2 + 1)
	defer delete(chunk)
	output_view_feed(v, chunk)
	output_view_feed(v, chunk)
	testing.expect_value(t, len(v.raw), OUTPUT_KEEP_BYTES)
}

// What is typed goes nowhere, and what is not for reading goes on: Escape closes the dialog.
@(test)
the_keys_are_for_reading_only :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	_ = running_view(t, app)
	ev := []platform.Event{{kind = .Text, text = 'x'}, {kind = .Key_Press, key = .Escape}, {kind = .Key_Release, key = .Escape}}
	left := output_view_events(app, ev)
	testing.expect_value(t, len(left), 3)
	testing.expect(t, app.cx.terms.only == nil && app.cx.terms.focused == nil, "the shells' keyboard is as it was")
	testing.expect(t, overlay_open(app), "it is a dialog: the keys of the program wait")
}

// A second click comes back to the same view.
@(test)
a_command_has_one_view :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	v := running_view(t, app)
	testing.expect(t, output_view_open_shell(app, "sh_1", "cargo build", "S:\\x") == v)
	testing.expect_value(t, len(app.cx.outputs.list), 1)
}

@(test)
a_call_says_which_command_it_runs :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	p: Part
	tool_set_meta(&p, nil, context.allocator)
	testing.expect(t, !output_view_can(&p), "nothing to look at yet")
	bench_meta(&p, `{"shellID":"sh_9"}`)
	testing.expect_value(t, p.shell_id, "sh_9")
	testing.expect(t, output_view_can(&p))
}

// A call the server gives no command for: its text, in the same view.
@(test)
a_call_with_only_its_text_shows_that :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	p := Part{tool_id = "c1", output = "hello\n", status = .Error, input = `{"command":"false"}`}
	output_view_open_part(app, &p)
	v := app.cx.outputs.shown
	testing.expect(t, v != nil && v.over && !v.seen_end)
	testing.expect_value(t, v.command, "false")
	word, _ := output_view_word(v)
	testing.expect_value(t, word, "exit 1")
	testing.expect_value(t, bench_count(.Output_Read) + bench_count(.Output_State), 0)
}

@(test)
leaving_the_server_closes_the_views :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	v := running_view(t, app)
	server_forget(app)
	testing.expect(t, v.gone && app.cx.outputs.shown == nil)
	output_views_tick(app)
	testing.expect_value(t, len(app.cx.outputs.list), 0)
}

@(private = "file")
bench_meta :: proc(p: ^Part, meta: string) {
	v, _ := json.parse_string(meta, parse_integers = true, allocator = context.temp_allocator)
	tool_set_meta(p, v, context.allocator)
}
