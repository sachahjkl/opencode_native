package occtools

// The real program against the real server, with what goes wrong made to go wrong: nothing here waits for a delay to run out.
// Each step waits for a condition, under a limit: a limit reached is a failure, a condition met goes on at once.

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"

DEMO_DIR        :: "S:\\demo-clock"
DEMO_SESSION    :: "ses_e5584daa0ffe0rZ9lqsYByWGPw"
LIVE_DIR        :: "build/occtools"
SNAPSHOT        :: LIVE_DIR + "/before.txt"
START_LIMIT     :: 20 * time.Second
STEP_LIMIT      :: 20 * time.Second
BACK_LIMIT      :: 15 * time.Second
TURN_LIMIT      :: 60 * time.Second
NEVER_LIMIT     :: 100 * time.Millisecond
START_POLL      :: 2 * time.Millisecond    // (a start is measured: this must not be what it measures)
POLL            :: 50 * time.Millisecond   // (what is looked at here, not in the window: a counter, the server's list)
TURN_MESSAGES   :: 3
BROWSER_TURN_LIMIT :: 150 * time.Second
TOOLS_OFFERED   :: 3 * time.Second

Live :: struct {
	exe, session, dir: string,
	server:            net.Endpoint,
	url, password:     string,
	auth:              string,
	failed:            int,
}

App :: struct {
	process:  os.Process,
	dt:       Dt,
	log:      string,
	settings: string,
	started:  time.Time,
}

@(private = "file")
expect :: proc(l: ^Live, ok: bool, what: string) {
	fmt.printfln("%s %s", ok ? "  ok  " : "  FAIL", what)
	if !ok { l.failed += 1 }
}

// The ids of `now` that `before` does not have. What was there before is nobody's business here.
new_ids :: proc(before, now: []string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	next: for id in now {
		for b in before {
			if b == id { continue next }
		}
		append(&out, id)
	}
	return out[:]
}

// "pty abc" and "session def" lines: what the snapshot holds.
snapshot_text :: proc(ptys, sessions: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for id in ptys { fmt.sbprintf(&b, "pty %s\n", id) }
	for id in sessions { fmt.sbprintf(&b, "session %s\n", id) }
	return strings.to_string(b)
}

snapshot_read :: proc(text: string) -> (ptys, sessions: []string) {
	p := make([dynamic]string, context.temp_allocator)
	s := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines(text, context.temp_allocator) {
		if strings.has_prefix(line, "pty ") { append(&p, line[len("pty "):]) }
		if strings.has_prefix(line, "session ") { append(&s, line[len("session "):]) }
	}
	return p[:], s[:]
}

// The ids in what the server lists: {"data":[...]} or the array itself.
ids_of :: proc(body: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	v, err := json.parse(transmute([]byte)body, allocator = context.temp_allocator)
	if err != nil { return nil }
	list, is_list := v.(json.Array)
	if !is_list {
		o, _ := v.(json.Object)
		list, _ = o["data"].(json.Array)
	}
	for item in list {
		o, _ := item.(json.Object)
		if id, ok := o["id"].(json.String); ok { append(&out, id) }
	}
	return out[:]
}

// The server's list of sessions is the whole server's, whatever folder is asked for: what is not of `dir` is none of ours, and
// must never reach what removes. (Its shells are the folder's.)
ids_in :: proc(body, dir: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	v, err := json.parse(transmute([]byte)body, allocator = context.temp_allocator)
	if err != nil { return nil }
	list, is_list := v.(json.Array)
	if !is_list {
		o, _ := v.(json.Object)
		list, _ = o["data"].(json.Array)
	}
	for item in list {
		o, _ := item.(json.Object)
		where_, _ := o["location"].(json.Object)
		folder, _ := where_["directory"].(json.String)
		if id, ok := o["id"].(json.String); ok && folder == dir { append(&out, id) }
	}
	return out[:]
}

location :: proc(l: ^Live) -> string {
	return fmt.tprintf("location[directory]=%s", net.percent_encode(l.dir, context.temp_allocator))
}

api_list :: proc(l: ^Live, what: string) -> (ids: []string, ok: bool) {
	limit := what == "session" ? "&limit=200" : ""
	status, body, got := http_at(l.server, "GET", fmt.tprintf("/api/%s?%s%s", what, location(l), limit), l.auth)
	if !got || status != 200 {
		fmt.eprintfln("%s on %v: %s, status %d: %s", what, l.server, got ? "answered" : "no answer", status, body[:min(len(body), 200)])
		return nil, false
	}
	return what == "session" ? ids_in(body, l.dir) : ids_of(body), true
}

api_delete :: proc(l: ^Live, what, id: string) -> bool {
	status, _, got := http_at(l.server, "DELETE", fmt.tprintf("/api/%s/%s?%s", what, id, location(l)), l.auth)
	return got && status >= 200 && status < 300
}

live_setup :: proc(l: ^Live, args: []string) -> bool {
	l.exe, l.session, l.dir = CHECK_OUT, DEMO_SESSION, DEMO_DIR
	home := os.get_env("USERPROFILE", context.temp_allocator)
	if home == "" { home = os.get_env("HOME", context.temp_allocator) }
	text := read_text(fmt.tprintf("%s/.local/state/opencode/service.json", home))
	text = strings.trim_prefix(text, "\uFEFF")
	Service :: struct {
		url, password: string,
	}
	s: Service
	if json.unmarshal(transmute([]byte)text, &s) != nil { fmt.eprintln("live: no local server: service.json is not there"); return false }
	l.url, l.password = s.url, s.password
	at, ok := net.parse_endpoint(strings.trim_prefix(strings.trim_right(s.url, "/"), "http://"))
	if !ok { fmt.eprintfln("live: the server is not on plain HTTP here"); return false }
	at.address = net.IP4_Loopback   // (the file says where it listens, 0.0.0.0 among others: this tool only ever talks to this machine)
	l.server = at
	l.url = fmt.tprintf("http://127.0.0.1:%d", at.port)
	l.auth = basic_auth("opencode", s.password)
	return true
}

@(private = "file")
free_port :: proc() -> int {
	sock, err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	if err != nil { return 0 }
	defer net.close(sock)
	at, bound := net.bound_endpoint(sock)
	return bound == nil ? at.port : 0
}

// A copy with nothing of the user's: its settings in a folder of its own. What it says goes to a file, kept.
launch :: proc(l: ^Live, name: string, args: ..string) -> (app: App, ok: bool) {
	port := free_port()
	here, _ := os.get_working_directory(context.temp_allocator)
	app.settings = fmt.tprintf("%s/%s/settings_%d", here, LIVE_DIR, port)
	if !make_folder(app.settings) { return }
	app.log = fmt.tprintf("%s/%s.log", LIVE_DIR, name)
	log, err := os.open(app.log, os.O_WRONLY | os.O_CREATE | os.O_TRUNC | os.O_INHERITABLE, os.Permissions_Read_Write_All)   // (a child only writes to what it may inherit)
	if err != nil { fmt.eprintfln("live: %s: %v", app.log, err); return }
	defer os.close(log)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, l.exe, "--size=1460x920", "--pref", "browser.tools=false", "--pref", "notify.finished=off")
	append(&cmd, ..args)
	env := env_with({"APPDATA", "XDG_CONFIG_HOME", "TOOLKIT_DEVTOOLS", "OPENCODE_NATIVE_NO_SETUP"},
		fmt.tprintf("APPDATA=%s", app.settings), fmt.tprintf("XDG_CONFIG_HOME=%s", app.settings), fmt.tprintf("TOOLKIT_DEVTOOLS=%d", port), "OPENCODE_NATIVE_NO_SETUP=1")
	app.started = time.now()
	p, start_err := os.process_start({command = cmd[:], env = env, stdout = log, stderr = log})
	if start_err != nil { fmt.eprintfln("live: %s does not start: %v", l.exe, start_err); return }
	app.process = p
	begun := time.now()
	for time.since(begun) < START_LIMIT {
		if d, connected := dt_connect(port); connected { app.dt = d; return app, true }
		if state, _ := os.process_wait(p, 0); state.exited {
			fmt.eprintfln("live: the program ended at the start, code %d: see %s", state.exit_code, app.log)
			return
		}
		time.sleep(START_POLL)
	}
	fmt.eprintfln("live: no devtools on port %d, the program alive: see %s", port, app.log)
	_ = os.process_kill(p)
	return
}

@(private = "file")
close_app :: proc(l: ^Live, app: ^App) {
	state, _ := os.process_wait(app.process, 0)
	expect(l, !state.exited, "the program is still alive")
	if state.exited { fmt.printfln("        it ended with code %d: see %s", state.exit_code, app.log) }
	app_end(app)
}

app_end :: proc(app: ^App) {
	dt_close(&app.dt)
	_ = os.process_kill(app.process)
	_, _ = os.process_wait(app.process, 5 * time.Second)
	if app.settings != "" { _ = os.remove_all(app.settings) }   // (a program in WSL has its own, there)
}

@(private = "file")
reconnects :: proc(p: ^Proxy, dt: ^Dt, was: int) -> bool {
	begun := time.now()
	for proxy_opened(p) <= was {
		if time.since(begun) > BACK_LIMIT { return false }
		time.sleep(POLL)
	}
	return dt_wait_for(dt, "connected", BACK_LIMIT)
}

// A shell open, the link cut, then gone mute and given up on. A silence past its limit ends in that same failure of a read
// (native/occ_native: a_silent_stream_ends): the limit itself is tested there, its effect here.
@(private = "file")
scenario_link :: proc(l: ^Live) {
	fmt.println("=== the link")
	p, ok := proxy_start(l.server)
	if !ok { expect(l, false, "the proxy"); return }
	app, started := launch(l, "link", fmt.tprintf("--session=%s", l.session), fmt.tprintf("--url=http://127.0.0.1:%d", p.port), fmt.tprintf("--password=%s", l.password))
	if !started { expect(l, false, "the program answers"); return }
	dt := &app.dt
	expect(l, dt_wait_for(dt, "connected", STEP_LIMIT), "connected through the proxy")
	expect(l, !dt_wait_for(dt, "occtools-no-such-text", NEVER_LIMIT), "a text that is not there is not found (else nothing here proves anything)")
	dt_key(dt, "ctrl+shift+t")
	expect(l, dt_wait_name(dt, "term_box", STEP_LIMIT), "a shell opens")

	was := proxy_opened(p)
	proxy_drop(p)
	expect(l, reconnects(p, dt, was), "cut: connected again")
	expect(l, dt_wait_for(dt, "(lost)", BACK_LIMIT, gone = true), "cut: the shell's tab is not lost")
	expect(l, !dt_has(dt, "(ended)"), "cut: the shell has not ended")

	was = proxy_opened(p)
	proxy_mute(p)
	proxy_drop(p)
	expect(l, reconnects(p, dt, was), "mute: connected again")
	expect(l, dt_wait_for(dt, "(lost)", BACK_LIMIT, gone = true), "mute: the shell's tab is not lost")
	dt_shot(dt, LIVE_DIR + "/link.png")
	close_app(l, &app)
}

DIFF_ROWS      :: 20000
DIFF_FRAME_MAX :: 16.0   // ms of a frame's build: a 60 Hz budget, whatever the length of the diff

// The text of a big patch: a changed line every third one.
big_patch :: proc(rows: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "@@ -1,%d +1,%d @@\n", rows, rows)
	for i in 0 ..< rows {
		if i % 3 == 0 {
			fmt.sbprintf(&b, "-old line number %d of the file\n+new line number %d of the file\n", i, i)
		} else {
			fmt.sbprintf(&b, " the same line %d\n", i)
		}
	}
	return strings.to_string(b)
}

@(private = "file")
frame_p95 :: proc(dt: ^Dt) -> f64 {
	r, ok := dt_call(dt, "Toolkit.metrics", `{"reset":true}`)
	if !ok { return -1 }
	o, _ := r.(json.Object)
	t, _ := o["totalMs"].(json.Object)
	return json_num(t["p95"])
}

// Scrolled, turned, a text dragged over, closed: a diff no one would read, so that one that is read is nothing.
@(private = "file")
scenario_diff :: proc(l: ^Live) {
	fmt.println("=== a diff of", DIFF_ROWS, "lines")
	path := LIVE_DIR + "/big.patch"
	if os.write_entire_file(path, transmute([]byte)big_patch(DIFF_ROWS)) != nil { expect(l, false, "the patch is written"); return }
	app, started := launch(l, "diff", fmt.tprintf("--diff=%s", path))
	if !started { expect(l, false, "the program answers"); return }
	defer close_app(l, &app)
	dt := &app.dt
	begun := time.now()
	expect(l, dt_wait_for(dt, "big.patch", STEP_LIMIT), "the view opens")
	dt_call(dt, "Toolkit.waitIdle", `{"timeout":5000}`)
	fmt.printfln("        open and at rest, from the start: %d ms", int(time.duration_milliseconds(time.since(app.started))))
	_ = begun
	r, _ := dt_call(dt, "Toolkit.state")
	o, _ := r.(json.Object)
	w, h := json_num(o["width"]), json_num(o["height"])
	frame_p95(dt)
	for _ in 0 ..< 40 {
		dt_call(dt, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"mouseWheel","x":%d,"y":%d,"deltaX":0,"deltaY":1500}}`, int(w / 2), int(h / 2)))
		time.sleep(POLL / 2)
	}
	dt_call(dt, "Toolkit.waitIdle", `{"timeout":5000}`)
	stacked := frame_p95(dt)
	expect(l, stacked >= 0 && stacked < DIFF_FRAME_MAX, fmt.tprintf("stacked, scrolled: 95 %% of the frames under %.1f ms", stacked))
	dt_call(dt, "Toolkit.click", `{"text":"Split","index":0,"count":1,"button":"left"}`)
	dt_call(dt, "Toolkit.waitIdle", `{"timeout":5000}`)
	frame_p95(dt)
	for _ in 0 ..< 40 {
		dt_call(dt, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"mouseWheel","x":%d,"y":%d,"deltaX":0,"deltaY":-1500}}`, int(w / 2), int(h / 2)))
		time.sleep(POLL / 2)
	}
	dt_call(dt, "Toolkit.waitIdle", `{"timeout":5000}`)
	split := frame_p95(dt)
	expect(l, split >= 0 && split < DIFF_FRAME_MAX, fmt.tprintf("split, scrolled: 95 %% of the frames under %.1f ms", split))
	y := int(h * 0.5)
	dt_call(dt, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"mouseMoved","x":%d,"y":%d}}`, int(w * 0.62), y))
	dt_call(dt, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"mousePressed","x":%d,"y":%d,"button":"left","buttons":1,"clickCount":1}}`, int(w * 0.62), y))
	dt_call(dt, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"mouseMoved","x":%d,"y":%d,"buttons":1}}`, int(w * 0.8), y + int(h * 0.15)))
	dt_call(dt, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"mouseReleased","x":%d,"y":%d,"button":"left","buttons":0,"clickCount":1}}`, int(w * 0.8), y + int(h * 0.15)))
	dt_call(dt, "Toolkit.waitIdle", `{"timeout":3000}`)
	dt_shot(dt, LIVE_DIR + "/diff_selected.png")
	dt_key(dt, "Escape")
	expect(l, dt_wait_for(dt, "big.patch", STEP_LIMIT, gone = true), "Escape closes it")
}

@(private = "file")
scenario_password :: proc(l: ^Live) {
	fmt.println("=== a wrong password")
	app, started := launch(l, "password", fmt.tprintf("--url=%s", l.url), "--password=wrong-on-purpose")
	if !started { expect(l, false, "the program answers"); return }
	expect(l, dt_wait_for(&app.dt, "auth refused", STEP_LIMIT), "it says so")
	close_app(l, &app)
}

// A real turn of a real model, the one thing here that takes the time it takes.
@(private = "file")
scenario_prompt :: proc(l: ^Live) {
	fmt.println("=== a real prompt, in a session of its own")
	before, listed := api_list(l, "session")
	if !listed { expect(l, false, "the server lists its sessions"); return }
	app, started := launch(l, "prompt", fmt.tprintf("--session=%s", l.session))
	if !started { expect(l, false, "the program answers"); return }
	dt := &app.dt
	expect(l, dt_wait_for(dt, "connected", STEP_LIMIT), "connected")
	dt_key(dt, "ctrl+n")
	expect(l, dt_wait_name(dt, "composer", STEP_LIMIT), "a new session's composer")
	public_model(dt)   // (the server's default may be down, or private: this tests the program, not that)
	dt_click_name(dt, "composer")
	dt_type(dt, "Reply with the single word: ok")
	dt_key(dt, "Enter")
	dt_key(dt, "Enter")   // (twice: one session all the same)

	fresh: []string
	messages := 0
	begun := time.now()
	for time.since(begun) < TURN_LIMIT && messages < TURN_MESSAGES {
		now, _ := api_list(l, "session")
		fresh = new_ids(before, now)
		if len(fresh) > 0 {
			status, body, got := http_at(l.server, "GET", fmt.tprintf("/api/session/%s/message?%s", fresh[0], location(l)), l.auth)
			if got && status == 200 { messages = len(ids_of(body)) }
		}
		time.sleep(POLL * 4)
	}
	expect(l, len(fresh) == 1, fmt.tprintf("one session after a double Enter (%d)", len(fresh)))
	expect(l, messages >= TURN_MESSAGES, fmt.tprintf("the model answered (%d messages)", messages))
	close_app(l, &app)
}

// What the agent is asked, by the tools' full names: other servers of the user's may offer browsers of their own (a "browse"), and a model
// that looks there finds none of ours. (The client offers its tools under BROWSER_NAME, "preview".)
BROWSER_ASK :: "Use the tools of the MCP server named preview, not any other browser. Call preview_tabs_open with the url https://example.com. "

// A real agent, its session left while it works: the page it opens is its session's, and not the one shown. (Asked for by name: it costs a
// real turn of a model, and a turn with tools takes its time.)
@(private = "file")
scenario_browser :: proc(l: ^Live) {
	fmt.println("=== an agent's page, in its own session")
	before, listed := api_list(l, "session")
	if !listed { expect(l, false, "the server lists its sessions"); return }
	app, started := launch(l, "browser", fmt.tprintf("--session=%s", l.session), "--pref", "browser.tools=true", "--search=Python clock")
	if !started { expect(l, false, "the program answers"); return }
	dt := &app.dt
	expect(l, dt_wait_for(dt, "connected", STEP_LIMIT), "connected")
	time.sleep(TOOLS_OFFERED)   // (the socket that offers the tools opens on a thread of its own: nothing says it did)
	dt_key(dt, "ctrl+n")
	expect(l, dt_wait_name(dt, "composer", STEP_LIMIT), "a new session's composer")
	public_model(dt)
	dt_click_name(dt, "composer")
	dt_type(dt, BROWSER_ASK + "Then call preview_tabs_list. Then reply with the single word: done")
	dt_key(dt, "Enter")

	fresh: []string
	begun := time.now()
	for time.since(begun) < TURN_LIMIT && len(fresh) == 0 {
		now, _ := api_list(l, "session")
		fresh = new_ids(before, now)
		time.sleep(POLL)
	}
	expect(l, len(fresh) == 1, "the prompt made a session")
	if len(fresh) != 1 { close_app(l, &app); return }
	// away, at once: what the agent does now, it does in a session that is not shown
	dt_key(dt, "alt+ArrowLeft")
	expect(l, dt_wait_for(dt, "UTC flag", STEP_LIMIT), "another session is shown")

	body := ""
	done := false
	for time.since(begun) < BROWSER_TURN_LIMIT && !done {
		status, text, got := http_at(l.server, "GET", fmt.tprintf("/api/session/%s/message?%s", fresh[0], location(l)), l.auth)
		if got && status == 200 { body = text; done = strings.contains(body, "done") && strings.contains(body, "focusedTabID") }
		time.sleep(POLL * 4)
	}
	expect(l, strings.contains(body, "focusedTabID"), "the agent had the tools: what tabs_list says is ours")
	if !strings.contains(body, "focusedTabID") { fmt.printfln("        what it said: %s", tool_words(body)) }
	expect(l, strings.contains(body, "example.com"), "it opened the page")
	expect(l, done, "it finished its turn")
	expect(l, !dt_has(dt, "Example Domain"), "the session shown has not its page")
	expect(l, !dt_wait_name(dt, "pv_url", NEVER_LIMIT), "nor a browser")

	dt_key(dt, "alt+ArrowRight")
	expect(l, dt_wait_name(dt, "pv_url", STEP_LIMIT), "back in its session: its browser")
	expect(l, dt_wait_for(dt, "Example Domain", STEP_LIMIT), "with its page")
	dt_shot(dt, LIVE_DIR + "/browser_back.png")
	close_app(l, &app)
}

// A real agent, and another folder shown while it works: its tools stay, the next call of its turn is answered.
@(private = "file")
scenario_folders :: proc(l: ^Live) {
	fmt.println("=== an agent's tools, another folder shown")
	here, _ := os.get_working_directory(context.temp_allocator)
	other := fmt.tprintf("%s/%s/other_folder", here, LIVE_DIR)
	if !make_folder(other) { expect(l, false, "a folder"); return }
	where_ := fmt.tprintf("location[directory]=%s", net.percent_encode(other, context.temp_allocator))
	status, made, got := http_at(l.server, "POST", fmt.tprintf("/api/session?%s", where_), l.auth, fmt.tprintf(`{{"title":"occtools other folder","location":{{"directory":%q}}}}`, other))
	v, _ := json.parse(transmute([]byte)made, allocator = context.temp_allocator)
	top, _ := v.(json.Object)
	data, _ := top["data"].(json.Object)
	id, _ := data["id"].(json.String)
	if !got || status != 200 || id == "" { expect(l, false, "a session in another folder"); return }
	defer { _, _, _ = http_at(l.server, "DELETE", fmt.tprintf("/api/session/%s?%s", id, where_), l.auth) }
	before, listed := api_list(l, "session")
	if !listed { expect(l, false, "the server lists its sessions"); return }
	app, started := launch(l, "folders", fmt.tprintf("--session=%s", l.session), "--pref", "browser.tools=true", "--search=occtools other")
	if !started { expect(l, false, "the program answers"); return }
	dt := &app.dt
	expect(l, dt_wait_for(dt, "connected", STEP_LIMIT), "connected")
	expect(l, dt_wait_for(dt, "occtools other folder", STEP_LIMIT), "the other folder's session is in the list")
	time.sleep(TOOLS_OFFERED)
	dt_key(dt, "ctrl+n")
	expect(l, dt_wait_name(dt, "composer", STEP_LIMIT), "a new session's composer")
	public_model(dt)
	dt_click_name(dt, "composer")
	dt_type(dt, BROWSER_ASK + "Then run this shell command: Start-Sleep -Seconds 25. Then call preview_tabs_list. Then reply with the single word: done")
	dt_key(dt, "Enter")
	fresh: []string
	begun := time.now()
	for time.since(begun) < TURN_LIMIT && len(fresh) == 0 {
		now, _ := api_list(l, "session")
		fresh = new_ids(before, now)
		time.sleep(POLL)
	}
	expect(l, len(fresh) == 1, "the prompt made a session")
	if len(fresh) != 1 { close_app(l, &app); return }
	body := ""
	opened := false
	for time.since(begun) < BROWSER_TURN_LIMIT && !opened {
		status2, text, ok := http_at(l.server, "GET", fmt.tprintf("/api/session/%s/message?%s", fresh[0], location(l)), l.auth)
		if ok && status2 == 200 { body = text; opened = strings.contains(body, "Start-Sleep") }
		time.sleep(POLL)
	}
	expect(l, opened, "it opened its page and went on to its command")
	dt_call(dt, "Toolkit.click", `{"text":"occtools other folder","index":0,"count":1,"button":"left"}`)
	expect(l, dt_wait_for(dt, "other_folder", STEP_LIMIT), "the other folder is shown while it works")
	done := false
	for time.since(begun) < BROWSER_TURN_LIMIT && !done {
		status2, text, ok := http_at(l.server, "GET", fmt.tprintf("/api/session/%s/message?%s", fresh[0], location(l)), l.auth)
		if ok && status2 == 200 { body = text; done = strings.contains(body, "focusedTabID") }
		time.sleep(POLL * 4)
	}
	expect(l, done, "its next call was answered, the other folder shown")
	if !done { fmt.printfln("        the end of what it said: %s", body[max(0, len(body) - 600):]) }
	close_app(l, &app)
}

// What an agent called and said, short: what a failure is about.
tool_words :: proc(body: string) -> string {
	v, err := json.parse(transmute([]byte)body, allocator = context.temp_allocator)
	if err != nil { return body[:min(len(body), 400)] }
	top, _ := v.(json.Object)
	data, _ := top["data"].(json.Array)
	b := strings.builder_make(context.temp_allocator)
	for m in data {
		mo, _ := m.(json.Object)
		content, _ := mo["content"].(json.Array)
		for c in content {
			co, _ := c.(json.Object)
			kind, _ := co["type"].(json.String)
			switch kind {
			case "tool":
				name, _ := co["name"].(json.String)
				st, _ := co["state"].(json.Object)
				out, _ := st["content"].(json.String)
				fmt.sbprintf(&b, "[tool %s: %s] ", name, out[:min(len(out), 160)])
			case "text":
				text, _ := co["text"].(json.String)
				fmt.sbprintf(&b, "[text %s] ", text[:min(len(text), 300)])
			}
		}
	}
	return strings.to_string(b)
}

clean_now :: proc(l: ^Live) -> int {
	text := read_text(SNAPSHOT)
	if text == "" && !os.exists(SNAPSHOT) { fmt.println("clean: no snapshot, nothing touched"); return 0 }
	before_ptys, before_sessions := snapshot_read(text)
	ptys, ok_ptys := api_list(l, "pty")
	sessions, ok_sessions := api_list(l, "session")
	if !ok_ptys || !ok_sessions { fmt.eprintln("clean: no answer from the server, the snapshot is kept"); return 1 }
	failed := 0
	for id in new_ids(before_ptys, ptys) {
		ok := api_delete(l, "pty", id)
		fmt.printfln("clean: shell %s %s", id, ok ? "removed" : "NOT removed")
		if !ok { failed += 1 }
	}
	for id in new_ids(before_sessions, sessions) {
		ok := api_delete(l, "session", id)
		fmt.printfln("clean: session %s %s", id, ok ? "removed" : "NOT removed")
		if !ok { failed += 1 }
	}
	if failed > 0 { return 1 }
	_ = os.remove(SNAPSHOT)
	return 0
}

// What is there now: what clean will leave alone.
snapshot_take :: proc(l: ^Live) -> bool {
	if os.exists(SNAPSHOT) { fmt.eprintln("a snapshot is there from a run that did not end: occtools clean first"); return false }
	ptys, ok_ptys := api_list(l, "pty")
	sessions, ok_sessions := api_list(l, "session")
	if !ok_ptys || !ok_sessions { fmt.eprintln("no answer from the server"); return false }
	return os.write_entire_file(SNAPSHOT, transmute([]byte)snapshot_text(ptys, sessions)) == nil
}

run_clean :: proc(args: []string) -> int {
	l: Live
	if !live_setup(&l, args) { return 1 }
	return clean_now(&l)
}

run_live :: proc(args: []string) -> int {
	l: Live
	if !live_setup(&l, args) { return 1 }
	only := ""
	for i := 0; i < len(args); i += 1 {
		switch {
		case args[i] == "--exe" && i + 1 < len(args):
			i += 1
			l.exe = args[i]
		case only == "":
			only = args[i]
		case:
			fmt.eprintfln("live: what is %s?", args[i])
			return EXIT_USAGE
		}
	}
	if only != "" && only != "link" && only != "password" && only != "prompt" && only != "diff" && only != "browser" && only != "folders" { fmt.eprintfln("live: no scenario %s", only); return EXIT_USAGE }
	if !os.exists(l.exe) { fmt.eprintfln("live: no %s: occtools check builds it", l.exe); return 1 }
	if !make_folder(LIVE_DIR) { return 1 }
	if !snapshot_take(&l) { return 1 }

	begun := time.now()
	if only == "" || only == "link" { scenario_link(&l) }
	if only == "" || only == "password" { scenario_password(&l) }
	if only == "" || only == "prompt" { scenario_prompt(&l) }
	if only == "" || only == "diff" { scenario_diff(&l) }
	if only == "browser" { scenario_browser(&l) }
	if only == "folders" { scenario_folders(&l) }
	cleaned := clean_now(&l)
	fmt.printfln("live: %d failed, in %d s", l.failed, int(time.duration_seconds(time.since(begun))))
	return l.failed > 0 || cleaned != 0 ? 1 : 0
}
