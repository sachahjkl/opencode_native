package occtools

// The site in a real browser, Chrome or Edge with no window, on the pages made of it (in a folder of its own, removed after).
// The image viewer (site/gallery.js), on the home page and the classic screenshots: a click on a capture opens it, the picture
// loads at its own size, the arrows go through the captures, Esc closes and gives the keyboard back to the link. Every page: its
// links, pictures, styles and scripts are there, and the anchors they point at; it links the same page in the other presentation
// ("Classic version", "Modern version"). The classic pages: no sideways scrolling on a phone or a desktop, a skip link the
// keyboard reaches first and shows, a main landmark, a text for every picture, light and dark; the classic home about a screen
// high. The home page's download, as each system's browser sees it: Windows and Linux their file, the other one's as a small link;
// macOS (no version for it) the section that says which there are. Exit code 1 if something differs. Nothing is published: the folder is served on 127.0.0.1 for the time of the check.
// Like `live`, nothing waits for a delay to run out: what a step leads to is awaited, under a limit.

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

SITE_DIR           :: "site"
SITE_CLASSIC       :: "classic/"
SITE_MADE_TEMP     :: "occtools_site_check_pages_*"
SITE_PROFILE_NAME  :: "occtools_site_check_profile_"
SITE_PROFILE_TEMP  :: SITE_PROFILE_NAME + "*"
SITE_PORT_FILE     :: "DevToolsActivePort"
SITE_HOME_SCREENS  :: 1.5   // the classic home's height, in screens of the desktop at most
SITE_HEAD_MAX      :: 8 * 1024
SITE_REST_MS       :: "10000"   // (read by the page's own clock, in its text)
SITE_START_LIMIT   :: 30 * time.Second
SITE_PAGE_LIMIT    :: 15 * time.Second
SITE_PICTURE_LIMIT :: 5 * time.Second
SITE_INPUT_LIMIT   :: 2 * time.Second   // (a key's effect is there when the call ends: this is for a viewer that does not answer)
SITE_READ_LIMIT    :: 5 * time.Second
SITE_CLOSE_LIMIT   :: 5 * time.Second
SITE_GONE_LIMIT    :: 30 * time.Second   // (reached only by what a slow disk holds up: it costs nothing when all is well)
SITE_REMOVE_LIMIT  :: 30 * time.Second   // (the browser's helpers let go of the profile a moment after it ends)

// The third capture: where it stays. The lazy pictures above it load as it comes into view, and move it.
SITE_REST :: `new Promise((ok) => {
	const a = document.querySelectorAll('.shot a.frame')[2]
	const end = Date.now() + ` + SITE_REST_MS + `
	let last = '', still = 0
	const f = () => {
		a.scrollIntoView({ block: 'center', behavior: 'instant' })
		const r = a.getBoundingClientRect(), now = r.x + ',' + r.y
		still = now === last ? still + 1 : 0
		last = now
		still >= 6 ? ok([r.x + r.width / 2, r.y + r.height / 2]) : Date.now() > end ? ok(null) : setTimeout(f, 50)
	}
	f()
})`
// (the event is kept before the page's own handlers run: what they did to it is read after them)
SITE_CLICK_KEPT  :: `addEventListener('click', (e) => { window.occClick = e }, { capture: true, once: true })`
SITE_OPEN        :: `document.querySelector('dialog.lightbox').open`
SITE_LOADED      :: `(() => { const i = document.querySelector('.lightbox img'); return i.complete && i.naturalWidth > 0 })()`
SITE_COUNT       :: `document.querySelector('.lightbox-count').textContent`
SITE_NO_SIDEWAYS :: `document.documentElement.scrollWidth <= innerWidth`
SITE_FILLS       :: `(() => { const i = document.querySelector('.lightbox img').getBoundingClientRect(); return i.width > 900 && i.bottom <= innerHeight })()`
SITE_FOCUS_BACK  :: `document.activeElement === document.querySelectorAll('.shot a.frame')[0]`
SITE_SCROLLS     :: `!document.documentElement.classList.contains('lightbox-open')`
SITE_LINKS       :: `[...document.querySelectorAll('a[href], img[src], link[href], script[src]')].map((e) => new URL(e.href || e.src)).filter((u) => u.origin === location.origin).map((u) => [u.pathname, decodeURIComponent(u.hash.slice(1))])`
SITE_LANDMARKS   :: `document.querySelectorAll('main#main').length === 1 && !!document.querySelector('header') && !!document.querySelector('nav[aria-label]') && !!document.querySelector('footer')`
SITE_ALT_TEXTS   :: `[...document.images].filter((i) => i.hasAttribute('src')).every((i) => i.hasAttribute('alt'))`
SITE_SKIP_LINK   :: `(() => { const a = document.activeElement, r = a.getBoundingClientRect(); return a.matches('a.skip[href="#main"]') && r.left >= 0 && r.top >= 0 && getComputedStyle(a).outlineStyle !== 'none' })()`
SITE_HIGH        :: `document.documentElement.scrollHeight / innerHeight`
SITE_COLORS      :: `getComputedStyle(document.body).backgroundColor + ' ' + getComputedStyle(document.body).color`

Site_View :: struct {
	width, height: int,
	mobile:        bool,
}

SITE_DESKTOP :: Site_View{width = 1400, height = 900}
SITE_PHONE   :: Site_View{width = 375, height = 812, mobile = true}

Site_Link :: struct {
	path, anchor: string,
}

Site_Server :: struct {
	root:     string,
	listener: net.TCP_Socket,
	port:     int,
	accepter: ^thread.Thread,
	stop:     bool,   // (atomic)
	serving:  int,    // connections being answered (atomic)
}

@(private = "file")
Site_Client :: struct {
	server: ^Site_Server,
	sock:   net.TCP_Socket,
}

Site_Run :: struct {
	dt:             Dt,
	browser:        os.Process,
	started, ended: bool,
	connected:      bool,
	origin, root:   string,
	shot:           string,
	threw:          string,   // what the last expression threw
	passed, failed: int,
	left_behind:    bool,     // a process or a folder that would not go: the run failed, whatever its checks said
}

// The one step that needs Node for now.
site_generate :: proc(site, out: string) -> bool { return site_changelog(site, out) == 0 }

// The file of a path of the site, or !ok: what comes from a browser or a page never leaves `root`. A folder is its index. A
// backslash separates on Windows, a colon names a stream or a drive, and a name's trailing dots and spaces are dropped there:
// ".. " would be "..".
site_file :: proc(root, path: string) -> (file: string, ok: bool) {
	whole := strings.has_suffix(path, "/") ? strings.concatenate({path, "index.html"}, context.temp_allocator) : path
	slashes, _ := strings.replace_all(whole, "\\", "/", context.temp_allocator)
	parts := make([dynamic]string, context.temp_allocator)
	for part in strings.split(slashes, "/", context.temp_allocator) {
		switch part {
		case "", ".":
		case "..":
			if len(parts) == 0 { return "", false }
			pop(&parts)
		case:
			if strings.contains_any(part, ":\x00") || part[len(part) - 1] == '.' || part[len(part) - 1] == ' ' { return "", false }
			append(&parts, part)
		}
	}
	if len(parts) == 0 { return "", false }
	return fmt.tprintf("%s/%s", root, strings.join(parts[:], "/", context.temp_allocator)), true
}

site_mime :: proc(path: string) -> string {
	switch {
	case strings.has_suffix(path, ".html"): return "text/html"
	case strings.has_suffix(path, ".css"):  return "text/css"
	case strings.has_suffix(path, ".js"):   return "text/javascript"
	case strings.has_suffix(path, ".png"):  return "image/png"
	}
	return "application/octet-stream"
}

// The path a request asks for, decoded, without its query.
site_request_path :: proc(head: string) -> (path: string, ok: bool) {
	line := head[:max(strings.index(head, "\r\n"), 0)]
	fields := strings.fields(line, context.temp_allocator)
	if len(fields) != 3 || !strings.has_prefix(fields[1], "/") { return "", false }
	target := fields[1]
	if at := strings.index_any(target, "?#"); at >= 0 { target = target[:at] }
	return net.percent_decode(target, context.temp_allocator)
}

@(private = "file")
site_answer :: proc(c: ^Site_Client) {
	defer free(c)
	defer sync.atomic_sub(&c.server.serving, 1)
	defer net.close(c.sock)
	_ = net.set_option(c.sock, .Receive_Timeout, SITE_READ_LIMIT)
	head: [SITE_HEAD_MAX]byte
	got := 0
	for !strings.contains(string(head[:got]), "\r\n\r\n") {
		n, err := net.recv_tcp(c.sock, head[got:])
		if err != nil || n == 0 { return }   // (a browser opens connections ahead of what it asks)
		got += n
		if got == len(head) { return }
	}
	path, asked := site_request_path(string(head[:got]))
	file, inside := site_file(c.server.root, path)
	if asked && inside && os.is_file(file) {
		if data, err := os.read_entire_file(file, context.temp_allocator); err == nil {
			answer := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", site_mime(file), len(data))
			if _, e := net.send_tcp(c.sock, transmute([]byte)answer); e != nil { return }
			_, _ = net.send_tcp(c.sock, data)
			return
		}
	}
	answer := "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
	_, _ = net.send_tcp(c.sock, transmute([]byte)answer)
}

// One thread a connection: one the browser opened ahead and leaves silent must hold nothing up.
@(private = "file")
site_accept :: proc(srv: ^Site_Server) {
	for {
		client, _, err := net.accept_tcp(srv.listener)
		if sync.atomic_load(&srv.stop) {
			if err == nil { net.close(client) }
			return
		}
		if err != nil { return }
		c := new(Site_Client)
		c^ = {srv, client}
		sync.atomic_add(&srv.serving, 1)
		thread.create_and_start_with_poly_data(c, site_answer, self_cleanup = true)
	}
}

site_serve :: proc(root: string) -> (srv: ^Site_Server, ok: bool) {
	listener, err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	if err != nil { return nil, false }
	at, bound := net.bound_endpoint(listener)
	if bound != nil { net.close(listener); return nil, false }
	srv = new(Site_Server)
	srv.root, srv.listener, srv.port = root, listener, at.port
	srv.accepter = thread.create_and_start_with_poly_data(srv, site_accept)
	return srv, true
}

// (accept may be waiting for someone, and closing the socket under it ends that on Windows only: someone comes)
site_serve_end :: proc(srv: ^Site_Server) {
	sync.atomic_store(&srv.stop, true)
	if wake, err := net.dial_tcp_from_endpoint(net.Endpoint{address = net.IP4_Loopback, port = srv.port}); err == nil { net.close(wake) }
	net.close(srv.listener)
	thread.join(srv.accepter)
	thread.destroy(srv.accepter)
	begun := time.now()
	for sync.atomic_load(&srv.serving) > 0 && time.since(begun) < SITE_CLOSE_LIMIT { time.sleep(POLL) }
}

// The site's pages under `dir`, as paths from `root`, in no order.
@(private = "file")
site_pages_in :: proc(root, dir: string, out: ^[dynamic]string) -> bool {
	at := dir == "" ? root : fmt.tprintf("%s/%s", root, dir)
	entries, err := os.read_all_directory_by_path(at, context.temp_allocator)
	if err != nil { return false }
	for e in entries {
		path := dir == "" ? e.name : fmt.tprintf("%s/%s", dir, e.name)
		if e.type == .Directory {
			if !site_pages_in(root, path, out) { return false }
		} else if strings.has_suffix(e.name, ".html") {
			append(out, path)
		}
	}
	return true
}

site_pages :: proc(root: string) -> (pages: []string, ok: bool) {
	out := make([dynamic]string, context.temp_allocator)
	if !site_pages_in(root, "", &out) { return nil, false }
	slice.sort(out[:])
	return out[:], true
}

// What the page gives for SITE_LINKS: [path, anchor] pairs.
site_links :: proc(v: json.Value) -> []Site_Link {
	list, _ := v.(json.Array)
	out := make([]Site_Link, len(list), context.temp_allocator)
	for item, i in list {
		pair, _ := item.(json.Array)
		if len(pair) != 2 { continue }
		path, _ := pair[0].(json.String)
		anchor, _ := pair[1].(json.String)
		out[i] = {path, anchor}
	}
	return out
}

site_anchor_in :: proc(html, anchor: string) -> bool {
	return strings.contains(html, fmt.tprintf(`id="%s"`, anchor))
}

site_link_resolves :: proc(root: string, link: Site_Link) -> bool {
	file, inside := site_file(root, link.path)
	if !inside || !os.exists(file) { return false }
	return link.anchor == "" || site_anchor_in(read_text(file), link.anchor)
}

site_link_text :: proc(link: Site_Link) -> string {
	return link.anchor == "" ? link.path : fmt.tprintf("%s#%s", link.path, link.anchor)
}

// What a browser leaves in its profile about the port it chose: the port, then the path of its own socket.
site_port_file :: proc(text: string) -> (port: int, path: string, ok: bool) {
	lines := strings.split_lines(text, context.temp_allocator)
	if len(lines) < 2 { return }
	parsed, is_port := strconv.parse_int(strings.trim_space(lines[0]), 10)
	path = strings.trim_space(lines[1])
	if !is_port || parsed <= 0 || !strings.has_prefix(path, "/devtools/browser/") { return 0, "", false }
	return parsed, path, true
}

@(private = "file")
site_find_browser :: proc() -> string {
	places := [?]string{
		os.get_env("CHROME", context.temp_allocator),
		"C:/Program Files/Google/Chrome/Application/chrome.exe",
		"C:/Program Files (x86)/Google/Chrome/Application/chrome.exe",
		"C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
		"C:/Program Files/Microsoft/Edge/Application/msedge.exe",
		"/usr/bin/google-chrome",
		"/usr/bin/chromium",
		"/usr/bin/chromium-browser",
	}
	for place in places {
		if place != "" && os.exists(place) { return place }
	}
	return ""
}

// (once ended its handle is closed: it must not be asked twice)
@(private = "file")
site_gone :: proc(s: ^Site_Run) -> bool {
	if s.ended { return true }
	state, err := os.process_wait(s.browser, 0)
	s.ended = state.exited || (err != nil && err != os.General_Error.Timeout)
	return s.ended
}

@(private = "file")
site_browser_start :: proc(s: ^Site_Run, program, profile: string) -> bool {
	cmd := []string{program, "--headless=new", "--remote-debugging-port=0", fmt.tprintf("--user-data-dir=%s", profile), fmt.tprintf("--window-size=%d,%d", SITE_DESKTOP.width, SITE_DESKTOP.height), "--no-first-run", "about:blank"}
	p, err := os.process_start({command = cmd})
	if err != nil { fmt.eprintfln("site check: %s: %v", program, err); return false }
	s.browser, s.started = p, true
	begun := time.now()
	for time.since(begun) < SITE_START_LIMIT {
		if site_gone(s) { fmt.eprintfln("site check: the browser ended: %s", program); return false }
		if port, path, written := site_port_file(read_text(fmt.tprintf("%s/%s", profile, SITE_PORT_FILE))); written {
			if d, connected := dt_open(port, path); connected {
				s.dt, s.connected = d, true
				return true
			}
		}
		time.sleep(POLL)
	}
	fmt.eprintfln("site check: no devtools from %s", program)
	return false
}

// What the command lines of this run's processes hold, and no one else's: the name of a folder made for it. "" if `profile` is
// not such a folder: every command line holds "", and what is found here is killed.
site_run_mark :: proc(profile: string) -> string {
	name := profile[strings.last_index_any(profile, "/\\") + 1:]
	return strings.has_prefix(name, SITE_PROFILE_NAME) && len(name) > len(SITE_PROFILE_NAME) ? name : ""
}

// The processes of this run: no one else's browser is ever among them.
site_processes :: proc(profile: string) -> []int {
	name := site_run_mark(profile)
	if name == "" { return nil }
	out := make([dynamic]int, context.temp_allocator)
	pids, err := os.process_list(context.temp_allocator)
	if err != nil { return nil }
	for pid in pids {
		// (what may not be read is not ours: this user started ours)
		info, info_err := os.process_info_by_pid(pid, {.Command_Line}, context.temp_allocator)
		if info_err == nil && strings.contains(info.command_line, name) { append(&out, pid) }
	}
	return out[:]
}

// (by its number: on Windows os.process_open does not ask for the right to end what it opens)
@(private = "file")
site_kill :: proc(pid: int) {
	id := fmt.tprintf("%d", pid)
	when ODIN_OS == .Windows {
		_, _ = capture("taskkill", "/F", "/PID", id)
	} else {
		_, _ = capture("kill", "-9", id)
	}
}

// Asked to leave, then made to, its helpers with it: what ends the browser does not end them, and they hold its profile.
// (The call has a limit of its own: a browser that does not answer must not hold the rest up.)
@(private = "file")
site_browser_end :: proc(s: ^Site_Run, profile: string) {
	if !s.started { return }
	if s.connected {
		if !site_gone(s) {
			s.dt.session = ""
			_ = net.set_option(s.dt.sock, .Receive_Timeout, SITE_CLOSE_LIMIT)
			dt_call(&s.dt, "Browser.close")
		}
		dt_close(&s.dt)
	}
	if !s.ended {
		state, err := os.process_wait(s.browser, SITE_CLOSE_LIMIT)
		s.ended = state.exited || (err != nil && err != os.General_Error.Timeout)
	}
	if !s.ended {
		fmt.eprintln("site check: the browser did not leave: it is killed")
		_ = os.process_kill(s.browser)
		_, _ = os.process_wait(s.browser, SITE_CLOSE_LIMIT)
		s.ended = true
	}
	for pid in site_processes(profile) { site_kill(pid) }
	// (killed is not gone: a process in the middle of a read of the disk ends when that read does)
	begun := time.now()
	for {
		left := site_processes(profile)
		if len(left) == 0 { return }
		if time.since(begun) > SITE_GONE_LIMIT { fmt.eprintfln("left behind: the processes %v", left); s.left_behind = true; return }
		time.sleep(POLL)
	}
}

@(private = "file")
site_remove :: proc(s: ^Site_Run, folder: string) {
	begun := time.now()
	for {
		if os.remove_all(folder) == nil && !os.exists(folder) { return }
		if time.since(begun) > SITE_REMOVE_LIMIT { fmt.eprintfln("left behind: %s", folder); s.left_behind = true; return }
		time.sleep(POLL)
	}
}

@(private = "file")
expect :: proc(s: ^Site_Run, ok: bool, what: string) {
	fmt.printfln("%s %s", ok ? "ok  " : "FAIL", what)
	if ok { s.passed += 1 } else { s.failed += 1 }
	if !ok && s.threw != "" { fmt.eprintfln("     %s", s.threw) }
}

// !ok: the expression threw, or the browser is gone. Either fails what asked.
@(private = "file")
site_js :: proc(s: ^Site_Run, expression: string) -> (value: json.Value, ok: bool) {
	s.threw = ""
	if site_gone(s) { s.threw = "the browser is gone"; return nil, false }
	r, called := dt_call(&s.dt, "Runtime.evaluate", fmt.tprintf(`{{"expression":%s,"awaitPromise":true,"returnByValue":true}}`, json_text(expression)))
	if !called { return nil, false }
	o, _ := r.(json.Object)
	if details, threw := o["exceptionDetails"].(json.Object); threw {
		exception, _ := details["exception"].(json.Object)
		text, _ := exception["description"].(json.String)
		s.threw = text != "" ? text : expression
		return nil, false
	}
	result, _ := o["result"].(json.Object)
	return result["value"], true
}

@(private = "file")
site_true :: proc(s: ^Site_Run, expression: string) -> bool {
	v, ok := site_js(s, expression)
	yes, is_bool := v.(json.Boolean)
	return ok && is_bool && yes
}

@(private = "file")
site_text :: proc(s: ^Site_Run, expression: string) -> string {
	v, _ := site_js(s, expression)
	text, _ := v.(json.String)
	return text
}

@(private = "file")
site_number :: proc(s: ^Site_Run, expression: string) -> f64 {
	v, _ := site_js(s, expression)
	return json_num(v)
}

// Until the expression holds: it does at once when it can, the limit is for what never comes.
@(private = "file")
site_wait :: proc(s: ^Site_Run, expression: string, limit: time.Duration) -> bool {
	begun := time.now()
	for {
		if site_true(s, expression) { return true }
		if s.ended || time.since(begun) > limit { return false }
		time.sleep(POLL)
	}
}

// A call that does not go through is a failure of the run, not a step skipped: what follows would look at the wrong thing, or at
// nothing, and could pass.
@(private = "file")
site_call :: proc(s: ^Site_Run, method, params: string) -> (result: json.Value, ok: bool) {
	result, ok = dt_call(&s.dt, method, params)
	if !ok { expect(s, false, fmt.tprintf("%s goes through", method)) }
	return
}

@(private = "file")
site_key :: proc(s: ^Site_Run, key: string) {
	code: int
	switch key {
	case "ArrowRight": code = 39
	case "ArrowLeft":  code = 37
	case "End":        code = 35
	case "Escape":     code = 27
	case "Tab":        code = 9
	}
	name := json_text(key)
	site_call(s, "Input.dispatchKeyEvent", fmt.tprintf(`{{"type":"rawKeyDown","key":%s,"code":%s,"windowsVirtualKeyCode":%d}}`, name, name, code))
	site_call(s, "Input.dispatchKeyEvent", fmt.tprintf(`{{"type":"keyUp","key":%s,"code":%s}}`, name, name))
}

@(private = "file")
site_view :: proc(s: ^Site_Run, view: Site_View) {
	site_call(s, "Emulation.setDeviceMetricsOverride", fmt.tprintf(`{{"width":%d,"height":%d,"deviceScaleFactor":1,"mobile":%v}}`, view.width, view.height, view.mobile))
}

@(private = "file")
site_scheme :: proc(s: ^Site_Run, value: string) {
	site_call(s, "Emulation.setEmulatedMedia", fmt.tprintf(`{{"features":[{{"name":"prefers-color-scheme","value":%s}}]}}`, json_text(value)))
}

@(private = "file")
site_go :: proc(s: ^Site_Run, path: string) -> bool {
	url := fmt.tprintf("%s/%s", s.origin, path)
	r, ok := site_call(s, "Page.navigate", fmt.tprintf(`{{"url":%s}}`, json_text(url)))
	o, _ := r.(json.Object)
	failure, _ := o["errorText"].(json.String)
	if failure != "" { fmt.eprintfln("%s: %s", url, failure) }
	loaded := ok && failure == "" && site_wait(s, fmt.tprintf(`location.href === %s && document.readyState === 'complete'`, json_text(url)), SITE_PAGE_LIMIT)
	if !loaded { expect(s, false, fmt.tprintf("%s: the page loads", path)) }
	return loaded
}

@(private = "file")
site_count_is :: proc(n, of: int) -> string {
	return fmt.tprintf(`%s === '%d / %d'`, SITE_COUNT, n, of)
}

@(private = "file")
site_click :: proc(s: ^Site_Run, x, y: f64) {
	moves := [?]string{"mouseMoved", "mousePressed", "mouseReleased"}
	for type in moves {
		moved := type == "mouseMoved"
		site_call(s, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"%s","x":%f,"y":%f,"button":"%s","clickCount":%d}}`, type, x, y, moved ? "none" : "left", moved ? 0 : 1))
	}
}

@(private = "file")
site_viewer :: proc(s: ^Site_Run, path: string) {
	if !site_go(s, path) { return }
	count := int(site_number(s, `document.querySelectorAll('.shot a.frame').length`))
	pictures := int(site_number(s, `document.querySelectorAll('.shot img').length`))
	expect(s, count > 0 && count == pictures, fmt.tprintf("%s: every capture is a link (%d of %d)", path, count, pictures))

	// a real click, on the third capture
	at, rested := site_js(s, SITE_REST)
	spot, _ := at.(json.Array)
	if !rested || len(spot) != 2 { expect(s, false, fmt.tprintf("%s: the third capture comes to rest", path)); return }
	site_js(s, SITE_CLICK_KEPT)
	site_click(s, json_num(spot[0]), json_num(spot[1]))
	expect(s, site_wait(s, SITE_OPEN, SITE_INPUT_LIMIT), fmt.tprintf("%s: a click opens the viewer", path))
	// (that nothing follows cannot be awaited: what says so is the link's click, prevented, on a page that is still this one)
	expect(s, site_true(s, fmt.tprintf(`location.pathname === %s && !!window.occClick && window.occClick.defaultPrevented`, json_text(fmt.tprintf("/%s", path)))), fmt.tprintf("%s: the page stays where it is", path))
	expect(s, site_wait(s, SITE_LOADED, SITE_PICTURE_LIMIT), fmt.tprintf("%s: the picture loads", path))
	expect(s, site_true(s, site_count_is(3, count)), fmt.tprintf("%s: it is the capture clicked", path))
	expect(s, site_number(s, `document.querySelector('.lightbox-caption').textContent.length`) > 0, fmt.tprintf("%s: its caption is shown", path))
	expect(s, site_true(s, SITE_FILLS), fmt.tprintf("%s: the picture is large and within the window", path))
	expect(s, site_true(s, SITE_NO_SIDEWAYS), fmt.tprintf("%s: no sideways scrolling", path))
	if s.shot != "" && path == "index.html" {
		if dt_shot(&s.dt, s.shot) { fmt.printfln("saved %s", s.shot) } else { expect(s, false, fmt.tprintf("%s is written", s.shot)) }
	}

	site_key(s, "ArrowRight")
	next := site_wait(s, site_count_is(4, count), SITE_INPUT_LIMIT)
	site_wait(s, SITE_LOADED, SITE_PICTURE_LIMIT)
	expect(s, next, fmt.tprintf("%s: Right: the next one", path))
	site_key(s, "ArrowLeft")
	site_wait(s, site_count_is(3, count), SITE_INPUT_LIMIT)
	site_key(s, "ArrowLeft")
	expect(s, site_wait(s, site_count_is(2, count), SITE_INPUT_LIMIT), fmt.tprintf("%s: Left: the previous one", path))
	site_key(s, "End")
	expect(s, site_wait(s, site_count_is(count, count), SITE_INPUT_LIMIT), fmt.tprintf("%s: End: the last one", path))
	site_key(s, "ArrowRight")
	expect(s, site_wait(s, site_count_is(1, count), SITE_INPUT_LIMIT), fmt.tprintf("%s: Right from the last: the first one", path))
	site_key(s, "Escape")
	expect(s, site_wait(s, "!" + SITE_OPEN, SITE_INPUT_LIMIT), fmt.tprintf("%s: Esc closes", path))
	expect(s, site_true(s, SITE_FOCUS_BACK), fmt.tprintf("%s: the keyboard is back on the link last shown", path))
	expect(s, site_true(s, SITE_SCROLLS), fmt.tprintf("%s: the page scrolls again", path))
}

// A browser of each system: what it says it runs on (navigator.userAgent, navigator.platform, navigator.userAgentData), the
// download the home page offers it (the button: where, what it says, the file it says under that, the logo it shows; the small link
// to the other system's).
@(private = "file")
Site_System :: struct { name, agent, platform, data, button, label, sub, icon, other: string }

@(private = "file")
SITE_SYSTEMS := [?]Site_System{
	{"Windows", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36", "Win32", "Windows", "-windows-x64.exe", "Download for Windows", " · Windows 10 / 11 · x64 · .exe", "windows", "-linux-x64.tar.gz"},
	{"Linux", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36", "Linux x86_64", "Linux", "-linux-x64.tar.gz", "Download for Linux", " · x64 · .tar.gz · Vulkan", "linux", "-windows-x64.exe"},
	{"macOS", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36", "MacIntel", "macOS", "#download", "Get opencode native", "for Windows or Linux · x64", "any", "/releases/latest"},
}

@(private = "file")
site_downloads :: proc(s: ^Site_Run) {
	for sys in SITE_SYSTEMS {
		site_call(s, "Emulation.setUserAgentOverride", fmt.tprintf(`{{"userAgent":%s,"platform":%s,"userAgentMetadata":{{"platform":%s,"platformVersion":"","architecture":"x86","model":"","mobile":false}}}}`,
			json_text(sys.agent), json_text(sys.platform), json_text(sys.data)))
		if !site_go(s, "index.html") { continue }
		button :: `document.querySelector('.hero .actions .btn.accent')`
		other :: `document.querySelector('.hero p.small a')`
		main :: `document.querySelector('.hero .get-main').textContent`
		sub :: `document.querySelector('.hero .get-sub').textContent`
		// (the logos shown: those with a box)
		icons :: `[...document.querySelectorAll('.hero [data-os-icon]')].filter((e) => e.getClientRects().length > 0).map((e) => e.dataset.osIcon).join(',')`
		expect(s, site_true(s, fmt.tprintf(`%s.href.endsWith(%s) && %s === %s`, button, json_text(sys.button), main, json_text(sys.label))),
			fmt.tprintf("index.html, %s: the button is %s, %q (%s, %s)", sys.name, sys.button, sys.label, site_text(s, button + ".href"), site_text(s, main)))
		expect(s, site_true(s, fmt.tprintf(`%s.endsWith(%s) && /\d+\.\d+\.\d+|Windows or Linux/.test(%s)`, sub, json_text(sys.sub), sub)),
			fmt.tprintf("index.html, %s: under it %q (%s)", sys.name, sys.sub, site_text(s, sub)))
		expect(s, site_true(s, fmt.tprintf(`%s === %s`, icons, json_text(sys.icon))),
			fmt.tprintf("index.html, %s: the logo %q (%s)", sys.name, sys.icon, site_text(s, icons)))
		expect(s, site_true(s, fmt.tprintf(`%s.href.endsWith(%s)`, other, json_text(sys.other))),
			fmt.tprintf("index.html, %s: the small link is %s (%s)", sys.name, sys.other, site_text(s, other + ".href")))
	}
	site_call(s, "Emulation.setUserAgentOverride", `{"userAgent":""}`)   // (the browser's own again)
}

@(private = "file")
site_classic :: proc(s: ^Site_Run, path: string) {
	expect(s, site_true(s, SITE_LANDMARKS), fmt.tprintf("%s: a main, a header, a nav and a footer", path))
	expect(s, site_true(s, SITE_ALT_TEXTS), fmt.tprintf("%s: every picture shown has a text", path))
	site_key(s, "Tab")
	expect(s, site_wait(s, SITE_SKIP_LINK, SITE_INPUT_LIMIT), fmt.tprintf("%s: Tab reaches the skip link first, shown with its focus ring", path))
	for view in ([2]Site_View{SITE_PHONE, SITE_DESKTOP}) {
		site_view(s, view)
		expect(s, site_true(s, SITE_NO_SIDEWAYS), fmt.tprintf("%s: no sideways scrolling at %d px", path, view.width))
	}
	if path == SITE_CLASSIC + "index.html" {
		high := site_number(s, SITE_HIGH)
		expect(s, high > 0 && high <= SITE_HOME_SCREENS, fmt.tprintf("%s: %.2f screens high (%v at most)", path, high, SITE_HOME_SCREENS))
	}
	site_scheme(s, "light")
	light := site_text(s, SITE_COLORS)
	site_scheme(s, "dark")
	dark := site_text(s, SITE_COLORS)
	site_scheme(s, "")
	expect(s, light != "" && dark != "" && light != dark, fmt.tprintf("%s: light and dark (%s / %s)", path, light, dark))
}

@(private = "file")
site_page :: proc(s: ^Site_Run, path: string, pages: []string) {
	if !site_go(s, path) { return }
	// what the page loads or links on this site, as paths with their anchor
	v, read := site_js(s, SITE_LINKS)
	links := site_links(v)
	broken := make([dynamic]string, context.temp_allocator)
	for link in links {
		if !site_link_resolves(s.root, link) { append(&broken, site_link_text(link)) }
	}
	said := len(broken) > 0 ? fmt.tprintf(": not %s", strings.join(broken[:], ", ", context.temp_allocator)) : ""
	expect(s, read && len(broken) == 0, fmt.tprintf("%s: its %d links resolve%s", path, len(links), said))

	classic := strings.has_prefix(path, SITE_CLASSIC)
	other := classic ? "Modern version" : "Classic version"
	found, _ := site_js(s, fmt.tprintf(`[...document.querySelectorAll('footer a')].filter((a) => a.textContent === %s).map((a) => new URL(a.href).pathname)`, json_text(other)))
	list, _ := found.(json.Array)
	to := make([]string, len(list), context.temp_allocator)
	for item, i in list { to[i], _ = item.(json.String) }
	same := classic ? path[len(SITE_CLASSIC):] : strings.concatenate({SITE_CLASSIC, path}, context.temp_allocator)
	want := fmt.tprintf("/%s", classic && !slice.contains(pages, same) ? "index.html" : same)
	wanted, _ := site_file(s.root, want)
	there := ""
	if len(to) == 1 { there, _ = site_file(s.root, to[0]) }
	expect(s, there != "" && there == wanted, fmt.tprintf(`%s: "%s" is %s (%s)`, path, other, want, strings.join(to, ", ", context.temp_allocator)))
	if classic { site_classic(s, path) }
}

@(private = "file")
site_checks :: proc(s: ^Site_Run, pages: []string) -> bool {
	r, made := dt_call(&s.dt, "Target.createTarget", `{"url":"about:blank"}`)
	if !made { return false }
	o, _ := r.(json.Object)
	target, _ := o["targetId"].(json.String)
	r, made = dt_call(&s.dt, "Target.attachToTarget", fmt.tprintf(`{{"targetId":%s,"flatten":true}}`, json_text(target)))
	if !made { return false }
	o, _ = r.(json.Object)
	s.dt.session, _ = o["sessionId"].(json.String)
	if _, enabled := dt_call(&s.dt, "Page.enable"); !enabled { return false }
	site_view(s, SITE_DESKTOP)
	viewers := [?]string{"index.html", SITE_CLASSIC + "screenshots.html"}
	for path in viewers { site_viewer(s, path) }
	for path in pages { site_page(s, path, pages) }
	site_downloads(s)
	return true
}

// Everything it opens is closed on the way out of here, whatever happened: what could not be is in `s` after it.
@(private = "file")
site_check_all :: proc(s: ^Site_Run, site, program: string) -> int {
	made, made_err := os.make_directory_temp("", SITE_MADE_TEMP, context.allocator)
	if made_err != nil { fmt.eprintfln("site check: %v", made_err); return 1 }
	defer site_remove(s, made)
	s.root = fmt.aprintf("%s/site", made)
	if !site_generate(site, s.root) { return 1 }
	pages, listed := site_pages(s.root)
	if !listed { fmt.eprintfln("site check: no pages in %s", s.root); return 1 }

	server, served := site_serve(s.root)
	if !served { fmt.eprintln("site check: nothing can listen on this machine"); return 1 }
	defer site_serve_end(server)
	s.origin = fmt.aprintf("http://127.0.0.1:%d", server.port)
	profile, profile_err := os.make_directory_temp("", SITE_PROFILE_TEMP, context.allocator)
	if profile_err != nil { fmt.eprintfln("site check: %v", profile_err); return 1 }
	defer site_remove(s, profile)
	defer site_browser_end(s, profile)
	if !site_browser_start(s, program, profile) { return 1 }

	whole := site_checks(s, pages)
	gone := site_gone(s)
	if gone { fmt.eprintln("site check: the browser ended during the run") }
	fmt.printfln("site check: %d of %d passed", s.passed, s.passed + s.failed)
	return whole && s.failed == 0 && !gone ? 0 : 1
}

run_site_check :: proc(args: []string) -> int {
	site, shot, program := SITE_DIR, "", ""
	for i := 0; i < len(args); i += 1 {
		switch {
		case args[i] == "--site" && i + 1 < len(args):
			i += 1
			site = args[i]
		case args[i] == "--shot" && i + 1 < len(args):
			i += 1
			shot = args[i]
		case args[i] == "--browser" && i + 1 < len(args):
			i += 1
			program = args[i]
		case:
			fmt.eprintfln("site check: what is %s?", args[i])
			return EXIT_USAGE
		}
	}
	if program == "" { program = site_find_browser() }
	if program == "" { fmt.eprintln("no Chrome or Edge found: give --browser"); return EXIT_USAGE }
	s := Site_Run{shot = shot}
	code := site_check_all(&s, site, program)
	return s.left_behind ? 1 : code
}

