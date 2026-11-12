package ocn

// The event stream: what an event moves in the other windows, what cannot be read, and the memory of each one.

import "base:runtime"
import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"

// A busy stream is mostly the deltas of sessions nobody looks at: those move no window. What the session shown, a sub-agent of it or the
// sidebar shows does; so does any other post (an answer).
@(test)
an_event_no_window_shows_leaves_the_windows_at_rest :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_chat(app, "s")
	bench_clear(app)
	kids, _ := json.parse_string(`{"data":[{"id":"kid","parentID":"s"}]}`, parse_integers = true, allocator = context.temp_allocator)
	children_load(app, kids)

	app.cx.shared_moved = false
	bench_event(app, `{"type":"session.text.delta","data":{"sessionID":"other","assistantMessageID":"a","ordinal":0,"delta":"x"}}`)
	testing.expect(t, !app.cx.shared_moved, "another session's delta")
	bench_event(app, `{"type":"session.reasoning.delta","data":{"sessionID":"kid","assistantMessageID":"a","ordinal":0,"delta":"x"}}`)
	testing.expect(t, !app.cx.shared_moved, "a sub-agent's thought: its card does not show it")
	posts_moved(app, app.cx.events_run)   // (the frame's posts: those events alone)
	testing.expect(t, !app.cx.shared_moved, "counted as posts either")

	bench_event(app, `{"type":"session.step.started","data":{"sessionID":"kid","assistantMessageID":"a","agent":"general","model":{"id":"m","providerID":"p"}}}`)
	testing.expect(t, app.cx.shared_moved, "a sub-agent's step: its card says it")
	app.cx.shared_moved = false
	bench_event(app, `{"type":"session.text.delta","data":{"sessionID":"s","assistantMessageID":"a","ordinal":0,"delta":"x"}}`)
	testing.expect(t, app.cx.shared_moved, "the session shown")
	app.cx.shared_moved = false
	bench_event(app, `{"type":"session.execution.started","data":{"sessionID":"other"}}`)
	testing.expect(t, app.cx.shared_moved, "another session runs: the sidebar")
	app.cx.shared_moved = false
	posts_moved(app, app.cx.events_run + 1)
	testing.expect(t, app.cx.shared_moved, "an answer")
}

// An event, or an answer, that does not read is counted and said once per kind, not dropped without a word.
@(test)
what_does_not_read_is_counted :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	app.cx.shared_moved = false
	e := event_read(app.conn, `{"type":"session.text.delta","data":{"sessionID":"s",`)
	testing.expect(t, e.unreadable)
	event_take(app, e)
	testing.expect_value(t, app.cx.unreadable.count, 1)
	event_take(app, event_read(app.conn, "not json"))
	testing.expect_value(t, app.cx.unreadable.count, 2)
	testing.expect_value(t, len(app.cx.unreadable.said), 1)   // (one kind: said once)
	testing.expect(t, !app.cx.shared_moved, "nothing applied")

	request(app, .Agents, "GET", "/api/agent")
	bench_answer(app, bench_take(t, .Agents), 200, `{"data":[`)
	testing.expect_value(t, app.cx.unreadable.count, 3)
	testing.expect_value(t, len(app.cx.unreadable.said), 2)
}

// What an event was read into goes as soon as it is applied, whatever became of it: applied, unreadable, of a server left.
@(test)
an_events_memory_goes_once_applied :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	open_chat(app, "s")
	bench_clear(app)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, runtime.heap_allocator())
	defer mem.tracking_allocator_destroy(&track)
	big := strings.repeat("x", 3 * EVENT_BLOCK_BYTES, context.temp_allocator)   // (larger than a block: an allocation of its own)
	left: Conn
	Case :: struct { text: string, conn: ^Conn }
	cases := []Case{
		{`{"type":"session.text.delta","data":{"sessionID":"s","assistantMessageID":"a","ordinal":0,"delta":"x"}}`, app.conn},
		{strings.concatenate({`{"type":"session.text.delta","data":{"sessionID":"s","assistantMessageID":"a","ordinal":0,"delta":"`, big, `"}}`}, context.temp_allocator), app.conn},
		{`{"type":"session.text.delta","data":{"sessionID":"s","delta":["x",`, app.conn},
		{`{"type":"session.execution.started","data":{"sessionID":"s"}}`, &left},
	}
	for c, i in cases {
		e := event_read(c.conn, c.text, mem.tracking_allocator(&track))
		testing.expectf(t, len(track.allocation_map) > 0, "case %d: read into its arena", i)
		event_take(app, e)
		testing.expectf(t, len(track.allocation_map) == 0, "case %d: %d allocations left", i, len(track.allocation_map))
	}
	testing.expect_value(t, len(track.bad_free_array), 0)
	m := find_message(&app.chat, "a")
	testing.expect(t, m != nil && len(m.parts) == 1 && len(m.parts[0].text) == 1 + len(big), "what the model keeps is its own copy")
}
