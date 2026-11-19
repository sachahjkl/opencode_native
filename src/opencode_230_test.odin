package ocn

// What opencode 2.3.0 added and ocn shows: a freeform tool's text (freeform-tools.md), a step's speed (step-speed.md), MCP events
// (mcp-events.md).

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

// A freeform call's text comes as JSON fragments cut anywhere: in its head, in an escape, in a surrogate pair, in a UTF-8 sequence.
// Each is read once, and the text is the same as the whole read at once.
@(test)
a_freeform_input_reads_as_text_whatever_cuts_its_fragments :: proc(t: ^testing.T) {
	whole := `{"code":"line one\n\"two\" é 😀 \\ end` + "\"}"
	want := "line one\n\"two\" é \U0001F600 \\ end"
	for cut in 1 ..< len(whole) {
		s: Input_Stream
		input_stream_add(&s, whole[:cut], context.temp_allocator)
		input_stream_add(&s, whole[cut:], context.temp_allocator)
		testing.expectf(t, s.state == .Closed && string(s.text[:]) == want, "cut at %d: %v %q", cut, s.state, string(s.text[:]))
	}
	byte_by_byte: Input_Stream
	for i in 0 ..< len(whole) { input_stream_add(&byte_by_byte, whole[i:i + 1], context.temp_allocator) }
	testing.expect_value(t, string(byte_by_byte.text[:]), want)

	// a JSON tool: its first field is a string, then comes another: nothing of it is one text
	json_tool: Input_Stream
	input_stream_add(&json_tool, `{"command":"ls -la`, context.temp_allocator)
	testing.expect_value(t, json_tool.state, Input_Stream_State.Text)
	input_stream_add(&json_tool, `","description":"list"}`, context.temp_allocator)
	testing.expect_value(t, json_tool.state, Input_Stream_State.Not_One_Field)
	_, shown := input_stream_shown(&json_tool)
	testing.expect(t, !shown)
	number: Input_Stream
	input_stream_add(&number, `{"n":4`, context.temp_allocator)
	testing.expect_value(t, number.state, Input_Stream_State.Not_One_Field)

	// the end's text has the last word
	ended: Input_Stream
	input_stream_add(&ended, `{"code":"abc`, context.temp_allocator)
	input_stream_end(&ended, `{"code":"xyz"}`, context.temp_allocator)
	testing.expect_value(t, string(ended.text[:]), "xyz")
	testing.expect_value(t, ended.state, Input_Stream_State.Closed)
}

// In the conversation: the deltas show the text as it streams (once it is long), the call shows it with no key, and a stored call
// still streaming is a stream, not a quoted JSON string.
@(test)
a_freeform_call_shows_its_text_streamed_then_called :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	open_chat(app, "s")
	bench_clear(app)
	c := &pane.chat
	bench_event(app, `{"type":"session.tool.input.started","data":{"sessionID":"s","assistantMessageID":"a1","id":"t1","name":"execute"}}`)
	bench_event(app, `{"type":"session.tool.input.delta","data":{"sessionID":"s","assistantMessageID":"a1","id":"t1","delta":"{\"code\":\"const a = 1"}}`)
	p := &c.messages[0].parts[0]
	text, long := input_stream_shown(&p.stream)
	testing.expect_value(t, text, "const a = 1")
	testing.expect(t, !long, "one short line: not yet shown")
	bench_event(app, `{"type":"session.tool.input.delta","data":{"sessionID":"s","assistantMessageID":"a1","id":"t1","delta":"\\nreturn a"}}`)
	p = &c.messages[0].parts[0]
	text, long = input_stream_shown(&p.stream)
	testing.expect_value(t, text, "const a = 1\nreturn a")
	testing.expect(t, long, "a second line: shown as it comes")
	testing.expect_value(t, p.input, "")

	bench_event(app, `{"type":"session.tool.called","data":{"sessionID":"s","assistantMessageID":"a1","id":"t1","input":{"code":"const a = 1\nreturn a"}}}`)
	p = &c.messages[0].parts[0]
	testing.expect(t, p.freeform, "one long text: shown as it is")
	testing.expect_value(t, p.fields[0].value, "const a = 1\nreturn a")

	short: Part
	tool_set_input(&short, json_of(`{"url":"https://example.com"}`), context.temp_allocator)
	testing.expect(t, !short.freeform, "one short field keeps its key")
	two: Part
	tool_set_input(&two, json_of(`{"a":"x\ny","b":"z"}`), context.temp_allocator)
	testing.expect(t, !two.freeform, "two fields keep their keys")

	page := `{"data":[{"id":"a2","type":"assistant","agent":"build","model":{"id":"m","providerID":"p"},"time":{"created":1},"content":[{"type":"tool","id":"t2","name":"patch","state":{"status":"streaming","input":"{\"patchText\":\"*** Begin Patch\\n*** Add File: a"},"time":{"created":1}}]}]}`
	chat_load(app, pane, json_of(page), false)
	m := find_message(c, "a2")
	testing.expect(t, m != nil)
	q := &m.parts[0]
	testing.expect_value(t, q.input, "")
	text, long = input_stream_shown(&q.stream)
	testing.expect_value(t, text, "*** Begin Patch\n*** Add File: a")
	testing.expect(t, long)
}

// A step's latency and writing speed, from the stream and from a page; per model in the Statistics panel, made when the
// messages change.
@(test)
a_steps_speed_comes_from_its_first_token :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	open_chat(app, "s")
	bench_clear(app)
	c := &pane.chat
	// a page: without `streamed`, the writing ends with the step
	page := `{"data":[{"id":"a2","type":"assistant","agent":"build","model":{"id":"fast","providerID":"p"},"time":{"created":10000,"firstToken":11500,"completed":13500},"tokens":{"output":300,"reasoning":0},"content":[]},` +
		`{"id":"a3","type":"assistant","agent":"build","model":{"id":"old","providerID":"p"},"time":{"created":20000,"completed":21000},"tokens":{"output":10},"content":[]}]}`
	chat_load(app, pane, json_of(page), false)
	m2 := find_message(c, "a2")
	testing.expect_value(t, m2.latency_ms, 1500)
	testing.expect_value(t, m2.write_rate, 150)
	testing.expect_value(t, find_message(c, "a3").write_rate, 0)

	bench_event(app, `{"type":"session.step.started","created":1000,"data":{"sessionID":"s","assistantMessageID":"a1","agent":"build","model":{"id":"fast","providerID":"p"},"started":1000}}`)
	bench_event(app, `{"type":"session.step.first-token","created":1500,"data":{"sessionID":"s","assistantMessageID":"a1"}}`)
	m := find_message(c, "a1")
	testing.expect_value(t, m.latency_ms, 500)
	testing.expect_value(t, m.write_rate, 0)
	bench_event(app, `{"type":"session.step.streamed","created":3500,"data":{"sessionID":"s","assistantMessageID":"a1"}}`)
	// (the end waits for the tools: the writing ended when the response did)
	bench_event(app, `{"type":"session.step.ended","created":9000,"data":{"sessionID":"s","assistantMessageID":"a1","finish":"stop","tokens":{"output":150,"reasoning":50}}}`)
	m = find_message(c, "a1")
	testing.expect_value(t, m.latency_ms, 500)
	testing.expect_value(t, m.write_rate, 100)
	testing.expect_value(t, speed_text(m.latency_ms, m.write_rate), "0.5 s first token · 100 tokens/s")

	l := local_stats(app)
	testing.expect_value(t, len(l.models), 2)
	for mc in l.models {
		lat, rate, floor := model_speed(mc)
		switch mc.name {
		case "fast":
			testing.expect_value(t, mc.timed, 2)
			testing.expect_value(t, lat, 1000)                    // (500 and 1500)
			testing.expect_value(t, rate, (200.0 + 300) / 4)      // (500 tokens in 2 s and 2 s)
			testing.expect(t, !floor)
		case "old":
			testing.expect_value(t, mc.timed, 0)
			testing.expect_value(t, speed_text(lat, rate, floor), "")
		}
	}

	// a step started again under its id: the last try's times are not this one's
	bench_event(app, `{"type":"session.step.started","created":30000,"data":{"sessionID":"s","assistantMessageID":"a1","agent":"build","model":{"id":"fast","providerID":"p"},"started":30000}}`)
	m = find_message(c, "a1")
	testing.expect_value(t, m.latency_ms, 0)
	testing.expect_value(t, m.first_token, 0)
}

// claude-agent sends an answer's text whole: its first token is the arrival of the text, and the writing time is a few tens
// of milliseconds. Two answers as the server stores them (times shifted): the footer says a floor over the whole step, and
// no first token. Before, the first said "4.9 s first token · 6881 tokens/s", the second "5.9 s first token" and no speed.
@(test)
an_answer_sent_at_once_shows_a_floor_of_its_speed :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	open_chat(app, "s")
	bench_clear(app)
	c := &pane.chat
	page := `{"data":[` +
		`{"id":"a1","type":"assistant","agent":"build","model":{"id":"opus","providerID":"claude-agent","variant":"default"},` +
		`"time":{"created":162415,"firstToken":167309,"streamed":167368,"completed":167386},"finish":"stop","rawFinish":"end_turn","cost":0,` +
		`"tokens":{"input":2,"output":406,"reasoning":0,"cache":{"read":811721,"write":2180}},"content":[{"type":"text","text":"done"}]},` +
		`{"id":"a2","type":"assistant","agent":"build","model":{"id":"opus","providerID":"claude-agent","variant":"default"},` +
		`"time":{"created":200000,"firstToken":205875,"streamed":205921,"completed":205940},"finish":"stop","cost":0,` +
		`"tokens":{"input":4,"output":496,"reasoning":0,"cache":{"read":316000,"write":0}},"content":[{"type":"text","text":"done"}]},` +
		// a step that streamed its reasoning, then its text: its first token is one
		`{"id":"a3","type":"assistant","agent":"build","model":{"id":"opus","providerID":"claude-agent","variant":"default"},` +
		`"time":{"created":115131,"firstToken":121671,"streamed":131680,"completed":134624},"finish":"tool-calls","cost":0,` +
		`"tokens":{"input":4,"output":656,"reasoning":428,"cache":{"read":6513,"write":802173}},"content":[]}]}`
	chat_load(app, pane, json_of(page), false)
	m1, m2, m3 := find_message(c, "a1"), find_message(c, "a2"), find_message(c, "a3")
	testing.expect(t, m1.write_floor && m2.write_floor && !m3.write_floor)
	testing.expect_value(t, speed_text(m1.latency_ms, m1.write_rate, m1.write_floor), "≥ 82 tokens/s")   // (406 in 4.953 s)
	testing.expect_value(t, speed_text(m2.latency_ms, m2.write_rate, m2.write_floor), "≥ 84 tokens/s")   // (496 in 5.921 s)
	testing.expect_value(t, speed_text(m3.latency_ms, m3.write_rate, m3.write_floor), "6.5 s first token · 108 tokens/s")

	l := local_stats(app)
	testing.expect_value(t, len(l.models), 1)
	_, rate, floor := model_speed(l.models[0])
	testing.expect(t, floor, "one of its speeds is a floor")
	testing.expect(t, rate > 0)
}

// While a run streams, the stream counts no token before a step ends: the step that streams shows the speed of the run's steps
// that ended, from their real counts, made again at each step; a prompt starts another run.
@(test)
a_streaming_answer_shows_the_speed_of_its_ended_steps :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	open_chat(app, "s")
	bench_clear(app)
	c := &pane.chat
	started :: proc(app: ^App, id: string, at: int) {
		bench_event(app, fmt.tprint(`{"type":"session.step.started","created":`, at, `,"data":{"sessionID":"s","assistantMessageID":"`, id, `","agent":"build","model":{"id":"opus","providerID":"p"},"started":`, at, "}}", sep = ""))
	}
	started(app, "a1", 1000)
	testing.expect_value(t, find_message(c, "a1").run_rate, 0)   // (the first step: nothing ended before it)
	bench_event(app, `{"type":"session.step.first-token","created":1500,"data":{"sessionID":"s","assistantMessageID":"a1"}}`)
	bench_event(app, `{"type":"session.reasoning.delta","created":1500,"data":{"sessionID":"s","assistantMessageID":"a1","ordinal":0,"delta":"thinking"}}`)
	bench_event(app, `{"type":"session.step.streamed","created":3500,"data":{"sessionID":"s","assistantMessageID":"a1"}}`)
	bench_event(app, `{"type":"session.step.ended","created":4000,"data":{"sessionID":"s","assistantMessageID":"a1","finish":"tool-calls","tokens":{"input":1,"output":150,"reasoning":50,"cache":{"read":0,"write":0}}}}`)   // (200 tokens in 2 s)
	started(app, "a2", 4100)
	testing.expect_value(t, speed_text(0, find_message(c, "a2").run_rate, find_message(c, "a2").run_floor), "100 tokens/s")
	// a2 ends, then a3 starts: the speed counts both (200 + 400 tokens in 2 s + 2 s)
	bench_event(app, `{"type":"session.step.first-token","created":4600,"data":{"sessionID":"s","assistantMessageID":"a2"}}`)
	bench_event(app, `{"type":"session.step.streamed","created":6600,"data":{"sessionID":"s","assistantMessageID":"a2"}}`)
	bench_event(app, `{"type":"session.step.ended","created":6700,"data":{"sessionID":"s","assistantMessageID":"a2","finish":"tool-calls","tokens":{"output":400,"reasoning":0}}}`)
	started(app, "a3", 6800)
	testing.expect_value(t, find_message(c, "a3").run_rate, 150)
	// a step that sent its output at once makes the run's speed a floor
	bench_event(app, `{"type":"session.step.first-token","created":11950,"data":{"sessionID":"s","assistantMessageID":"a3"}}`)
	bench_event(app, `{"type":"session.step.streamed","created":12000,"data":{"sessionID":"s","assistantMessageID":"a3"}}`)
	bench_event(app, `{"type":"session.step.ended","created":12010,"data":{"sessionID":"s","assistantMessageID":"a3","finish":"tool-calls","tokens":{"output":520,"reasoning":0}}}`)
	started(app, "a4", 12100)
	a4 := find_message(c, "a4")
	testing.expect(t, a4.run_floor)
	testing.expectf(t, abs(a4.run_rate - (200.0 + 400 + 520) / (2 + 2 + 5.2)) < 1e-9, "run rate %v", a4.run_rate)
}

// The stream's MCP events: kept once each (delivery is at least once), at most MCP_EVENTS_KEPT, gone with the server.
@(test)
mcp_events_are_kept_once_and_bounded :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	ev :: proc(app: ^App, sub, id: string, data := `{"job":"build","ok":true}`, truncated := false) {
		bench_event(app, strings.concatenate({
			`{"type":"experimental.mcp.event","created":5,"data":{"id":"`, sub, `","server":"ci","name":"job.done","eventId":"`, id,
			`","timestamp":"2026-11-16T10:00:00Z","data":`, data, `,"cursor":"c1"`, truncated ? `,"truncated":true` : "", "}}",
		}, context.temp_allocator))
	}
	ev(app, "sub1", "e1")
	ev(app, "sub1", "e1")
	testing.expect_value(t, len(app.mcp_events), 1)
	e := app.mcp_events[0]
	testing.expect_value(t, e.server, "ci")
	testing.expect_value(t, e.name, "job.done")
	testing.expect_value(t, e.at, 5)
	testing.expect(t, strings.contains(e.data, `"job"`) && !strings.contains(e.data, "\n"), "its data on one line")
	ev(app, "sub2", "e1", truncated = true)   // (another subscription: another event)
	testing.expect_value(t, len(app.mcp_events), 2)
	testing.expect(t, app.mcp_events[1].truncated)
	long := strings.repeat("x", 4 * MCP_EVENT_DATA_CHARS, context.temp_allocator)
	ev(app, "sub1", "big", fmt.tprintf("%q", long))
	testing.expect(t, len(app.mcp_events[2].data) < len(long), "cut on arrival")
	for i in 0 ..< MCP_EVENTS_KEPT { ev(app, "sub3", fmt.tprintf("n%d", i)) }
	testing.expect_value(t, len(app.mcp_events), MCP_EVENTS_KEPT)
	testing.expect_value(t, app.mcp_events[0].event_id, "n0")
	mcp_events_forget(app)
	testing.expect_value(t, len(app.mcp_events), 0)
}

// The wake-up of a session that watches an event: its server, its type and its data, not the model's preamble. A watch that
// stopped keeps its line.
@(test)
an_mcp_wake_up_reads_as_its_event :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	pane := main_pane(app)
	open_chat(app, "s")
	bench_clear(app)
	wake := "MCP server ci sent a job.done event (id e1, at 2026-11-16T10:00:00Z) this session watches. This isn't from the user: use it as information.\nSome events before it were skipped: the server couldn't replay them all.\n````json\n{\"log\":\"a ``` b\",\"ok\":true}\n````"
	stopped := "Watching ci job.done stopped: closed"
	page := strings.concatenate({
		`{"data":[{"id":"w1","type":"synthetic","text":`, fmt.tprintf("%q", wake),
		`,"description":"ci job.done","metadata":{"source":"mcp.event","server":"ci","event":"job.done","eventID":"e1"},"time":{"created":1}},`,
		`{"id":"w2","type":"synthetic","text":`, fmt.tprintf("%q", stopped),
		`,"description":"ci job.done watch stopped","metadata":{"source":"mcp.event","server":"ci","event":"job.done"},"time":{"created":2}}]}`,
	}, context.temp_allocator)
	chat_load(app, pane, json_of(page), false)
	c := &pane.chat
	m := find_message(c, "w1")
	testing.expect_value(t, m.mcp_server, "ci")
	testing.expect_value(t, m.mcp_event, "job.done")
	testing.expect(t, m.mcp_skipped)
	testing.expect(t, strings.contains(m.mcp_data, "\"log\": \"a ``` b\""), m.mcp_data)
	testing.expect(t, strings.contains(m.mcp_data, "\n"), "pretty")
	s := find_message(c, "w2")
	testing.expect_value(t, s.mcp_event, "")
	testing.expect_value(t, s.text, stopped)
}

@(private = "file")
json_of :: proc(s: string) -> json.Value {
	v, err := json.parse_string(s, parse_integers = true, allocator = context.temp_allocator)
	assert(err == nil, s)
	return v
}
