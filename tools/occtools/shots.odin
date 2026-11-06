package occtools

// docs/screenshots/*.png, and the copies of them in site/img: the frames the program rendered, so the mouse, the keyboard and the
// windows in front are left alone. It runs with an empty settings folder and reads the demo sessions of the local server; nothing is
// sent to it but the shell of the terminal's picture, closed right after.
//   occtools shots [--build] [--only name,name] [--exe file] [--session id] [--work-session id] [--toolkit folder] [--out folder]
//                  [--font-dir folder] [--linux program | --linux-build]
//     --build        builds build/screenshots first
//     --out          writes there instead, the site untouched
//     --session      the session to show (only ever one made for pictures: they are published)
//     --work-session the one that edits a file and keeps a todo list (made for pictures too)
//     --font-dir     tries these faces (src/main.odin: fonts_from_dir)
//     --linux        just linux.png: this Linux build of the program, run in WSL (tools/wsl_client.sh), Windows only
//     --linux-build  the same from this tree, built in WSL with the flake (tools/wsl_build.sh): no release needed

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"

SHOTS_EXE   :: "build/screenshots" + EXE
SHOTS_DOCS  :: "docs/screenshots"
SHOTS_SITE  :: "site/img"
WSL_PORT    :: 9391
WSL_LIMIT   :: 60 * time.Second   // (WSL may fetch its libraries first)
SHOT_LIMIT  :: 15 * time.Second
SCROLL_TRIES :: 40
SCROLL_NEAR :: 0.06   // near enough, as a part of the window's height
SCROLL_STEP :: 120.0  // pixels a notch moves, about
SCROLL_MOST :: 10     // notches at a time
TOUR_TITLE  :: "Tour of picker.odin"
WORK_TITLE  :: "Python clock"   // what the sidebar's search leaves of the sessions, and shows once they are read
// (grey text: the colours of the stripes belong to a screen, and a picture is seen on others, scaled)
SHOT_ARGS   :: [?]string{"--pref", "appearance.accent=peach", "--pref", "appearance.text_smoothing=grey", "--pref", "appearance.zoom=1", "--scale=1.25"}
// (these are published: a model that is not public never goes out in one)
SHOT_SECRETS :: [?]string{"iceman", "Contributor"}

Shots :: struct {
	live:              Live,
	docs:              string,
	only:              []string,
	work_session:      string,
	font_dir:          string,
	linux:             string,
	to_site:           bool,
}

// A picture in the making: the first step that fails is what is said, the steps after it do nothing.
Snap :: struct {
	dt:   ^Dt,
	ok:   bool,
}

@(private = "file")
step :: proc(s: ^Snap, done: bool) { s.ok = s.ok && done }

@(private = "file")
idle :: proc(s: ^Snap) {
	if !s.ok { return }
	_, done := dt_call(s.dt, "Toolkit.waitIdle")
	step(s, done)
}

@(private = "file")
key :: proc(s: ^Snap, name: string) { if s.ok { step(s, dt_key(s.dt, name)) } }

@(private = "file")
typed :: proc(s: ^Snap, text: string) { if s.ok { step(s, dt_type(s.dt, text)) } }

@(private = "file")
click :: proc(s: ^Snap, name: string) { if s.ok { step(s, dt_click_name(s.dt, name)) } }

// What ends by itself with nothing to read: an animation, a shell that answers. What a window can say is awaited, not this.
@(private = "file")
settle :: proc(s: ^Snap, how_long: time.Duration) { if s.ok { time.sleep(how_long) } }

@(private = "file")
mouse :: proc(s: ^Snap, kind: string, x, y: f64, press := false) {
	if !s.ok { return }
	extra := press ? fmt.tprintf(`,"button":"left","buttons":%d,"clickCount":1`, kind == "mousePressed" ? 1 : 0) : ""
	_, done := dt_call(s.dt, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"%s","x":%f,"y":%f%s}}`, kind, x, y, extra))
	step(s, done)
}

@(private = "file")
window_height :: proc(dt: ^Dt) -> f64 {
	r, _ := dt_call(dt, "Toolkit.state")
	o, _ := r.(json.Object)
	return json_num(o["height"])
}

// A place in the window as parts of it, rounded: a wheel zooms around it, so a pixel off moves the whole of a picture.
@(private = "file")
shot_at :: proc(dt: ^Dt, x, y: f64) -> (px, py: int) {
	r, _ := dt_call(dt, "Toolkit.state")
	o, _ := r.(json.Object)
	return int(math.round(json_num(o["width"]) * x)), int(math.round(json_num(o["height"]) * y))
}

// How many notches bring something `distance` pixels away nearer: at least one, at most SCROLL_MOST.
scroll_notches :: proc(distance: f64) -> int {
	n := clamp(int(math.round(abs(distance) / SCROLL_STEP)), 1, SCROLL_MOST)
	return distance < 0 ? -n : n
}

// The conversation scrolled until `text` is near `at` (as a part of the window's height).
@(private = "file")
scroll_to :: proc(s: ^Snap, text: string, at: f64) {
	if !s.ok { return }
	height := window_height(s.dt)
	x, y := shot_at(s.dt, 0.65, 0.4)
	for _ in 0 ..< SCROLL_TRIES {
		boxes := dt_find(s.dt, text)
		if len(boxes) == 0 {   // (a lazy column: it is further up, what a conversation opened at its end has above)
			film_wheel(s.dt, x, y, -5)
			idle(s)
			continue
		}
		d := boxes[0].y - at * height
		if abs(d) < height * SCROLL_NEAR { return }
		film_wheel(s.dt, x, y, scroll_notches(d))
		idle(s)
	}
	fmt.eprintfln("shots: could not bring into view: %s", text)
	s.ok = false
}

// A press and a release on the n-th box whose text is exactly `text` (Toolkit.click takes any text holding it, in any case).
@(private = "file")
click_exact :: proc(s: ^Snap, text: string, n: int) {
	if !s.ok { return }
	seen := 0
	for b in dt_find(s.dt, text) {
		if b.text != text { continue }
		if seen == n {
			x, y := b.x + b.w / 2, b.y + b.h / 2
			mouse(s, "mouseMoved", x, y)
			mouse(s, "mousePressed", x, y, press = true)
			mouse(s, "mouseReleased", x, y, press = true)
			return
		}
		seen += 1
	}
	fmt.eprintfln("shots: no box %d reading %s", n, text)
	s.ok = false
}

// The composer on a model anybody has, whatever this server's default is (chosen here, nothing is sent: it goes with a prompt).
@(private = "file")
any_model :: proc(s: ^Snap) {
	click(s, "model")
	idle(s)
	typed(s, "deepseek")
	idle(s)
	key(s, "Enter")
	idle(s)
}

@(private = "file") ready_subagents :: proc(s: ^Snap) { scroll_to(s, "Yes, but first launch", 0.2) }

// (the last match, in view: the picture shows the current one)
@(private = "file") ready_find :: proc(s: ^Snap) { key(s, "shift+Enter"); idle(s) }

@(private = "file")
ready_picker :: proc(s: ^Snap) {
	click(s, "model")
	idle(s)
	typed(s, "sonnet")
	idle(s)
}

// (the panel, by its key: the session is loaded by then)
@(private = "file")
ready_statistics :: proc(s: ^Snap) {
	key(s, "ctrl+i")
	settle(s, 900 * time.Millisecond)
	idle(s)
}

// (commands only: `>` keeps the sessions of whoever takes the picture out of it)
@(private = "file")
ready_palette :: proc(s: ^Snap) {
	key(s, "ctrl+k")
	idle(s)
	typed(s, ">")
	idle(s)
}

@(private = "file") ready_diff :: proc(s: ^Snap) { any_model(s); scroll_to(s, "argparse", 0.25) }

@(private = "file")
ready_activity :: proc(s: ^Snap) {
	any_model(s)
	key(s, "ctrl+j")
	settle(s, 700 * time.Millisecond)
	idle(s)
}

// (in the demo's folder, the shell closed once taken: `after`)
@(private = "file")
ready_terminal :: proc(s: ^Snap) {
	key(s, "ctrl+shift+t")
	if s.ok { step(s, dt_wait_name(s.dt, "term_box", SHOT_LIMIT)) }
	settle(s, 3 * time.Second)
	any_model(s)
	click(s, "term_box")
	typed(s, `Get-ChildItem | Select-Object Name, Length; Write-Host "ready" -ForegroundColor Green`)
	key(s, "Enter")
	settle(s, 2 * time.Second)   // (what the shell writes is in its grid, not in the tree: nothing here can be awaited)
}

// (the shell's tab, the only one that closes here; its request is on its way when the program ends)
@(private = "file")
after_terminal :: proc(s: ^Snap) {
	click(s, "dock_close")
	settle(s, 800 * time.Millisecond)
}

@(private = "file")
ready_mention :: proc(s: ^Snap) {
	any_model(s)
	click(s, "composer")
	typed(s, "What does @cl")
	settle(s, 900 * time.Millisecond)
}

@(private = "file")
ready_files :: proc(s: ^Snap) {
	any_model(s)
	key(s, "ctrl+p")
	settle(s, time.Second)
	click(s, "flr0")
	settle(s, 900 * time.Millisecond)
}

@(private = "file")
ready_schedules :: proc(s: ^Snap) {
	any_model(s)
	key(s, "ctrl+k")
	idle(s)
	typed(s, "Schedules of this session")
	idle(s)
	key(s, "Enter")
	settle(s, 900 * time.Millisecond)
}

// (searched: what shows is what the server can connect, not who is connected to what)
@(private = "file")
ready_connections :: proc(s: ^Snap) {
	settle(s, 1500 * time.Millisecond)
	click(s, "int_find")
	typed(s, "open")
	settle(s, 600 * time.Millisecond)
}

// (it looks at start)
@(private = "file") ready_updates :: proc(s: ^Snap) { if s.ok { step(s, dt_wait_for(s.dt, "Up to date", SHOT_LIMIT)) } }

@(private = "file")
ready_subagent_session :: proc(s: ^Snap) {
	scroll_to(s, "Summarise src/stats.odin", 0.4)
	click_exact(s, "Open", 2)
	if s.ok { step(s, dt_wait_for(s.dt, "sub-agent", SHOT_LIMIT)) }
	idle(s)
}

// (about one pixel of the picture per pixel of the window: sharp)
@(private = "file")
ready_viewer :: proc(s: ^Snap) {
	if s.ok { step(s, dt_wait_for(s.dt, "conversation.png", SHOT_LIMIT)) }
	if !s.ok { return }
	x, y := shot_at(s.dt, 0.45, 0.45)
	film_wheel(s.dt, x, y, -1)
	idle(s)
}

Picture :: struct {
	name:  string,
	work:  bool,     // the session that edits a file, not the tour
	extra: string,   // one more argument
	ready: proc(s: ^Snap),
	after: proc(s: ^Snap),
	on_conversation: bool,   // the viewer: on the conversation's picture, taken first
	linux: bool,
}

PICTURES :: [?]Picture{
	{name = "conversation"},
	{name = "subagents", ready = ready_subagents},
	{name = "find", extra = "--find=http", ready = ready_find},
	{name = "picker", ready = ready_picker},
	{name = "statistics", ready = ready_statistics},
	{name = "palette", ready = ready_palette},
	{name = "diff", work = true, ready = ready_diff},
	{name = "activity", work = true, ready = ready_activity},
	{name = "terminal", work = true, ready = ready_terminal, after = after_terminal},
	{name = "mention", work = true, ready = ready_mention},
	{name = "files", work = true, ready = ready_files},
	{name = "schedules", work = true, ready = ready_schedules},
	{name = "connections", extra = "--settings=6", ready = ready_connections},
	{name = "updates", extra = "--settings=3", ready = ready_updates},
	{name = "settings", extra = "--settings=0"},
	{name = "subagent-session", ready = ready_subagent_session},
	{name = "viewer", on_conversation = true, ready = ready_viewer},
	// the Linux build, in WSL, on Windows's server: its port and password from what the service wrote (never printed)
	{name = "linux", linux = true},
}

// Is this picture among those of this run?
wanted :: proc(p: Picture, only: []string, linux: bool) -> bool {
	if linux { return p.linux }
	if p.linux { return false }
	if len(only) == 0 { return true }
	for name in only { if name == p.name { return true } }
	return false
}

@(private = "file")
wsl_path :: proc(path: string) -> string {
	absolute, err := os.get_absolute_path(path, context.temp_allocator)
	if err != nil { return "" }
	out, ok := capture("wsl.exe", "--exec", "wslpath", "-a", strings.concatenate({absolute}, context.temp_allocator))
	return ok ? strings.trim_space(out) : ""
}

// The program of this tree, built in Linux: the last line of what the build says is where it is.
@(private = "file")
wsl_build :: proc() -> (program: string, ok: bool) {
	out, built := capture("wsl.exe", "--exec", "bash", "-l", wsl_path("tools/wsl_build.sh"))
	if !built { fmt.eprintln(out[max(0, len(out) - 2000):]); return }
	lines := strings.split_lines(strings.trim_space(out), context.temp_allocator)
	last := lines[len(lines) - 1]
	return last, strings.has_prefix(last, "/")
}

@(private = "file")
start_linux :: proc(s: ^Shots, args: []string) -> (app: App, ok: bool) {
	app.log = "build/wsl_client.log"   // (what went wrong in WSL; the password is not in it)
	log, err := os.open(app.log, os.O_WRONLY | os.O_CREATE | os.O_TRUNC | os.O_INHERITABLE, os.Permissions_Read_Write_All)
	if err != nil { return }
	defer os.close(log)
	program := strings.has_prefix(s.linux, "/") ? s.linux : wsl_path(s.linux)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "wsl.exe", "--exec", "bash", "-l", wsl_path("tools/wsl_client.sh"), program)
	append(&cmd, ..args)
	env := env_with({"TOOLKIT_DEVTOOLS", "OC_PORT", "OC_PASSWORD", "WSLENV"}, fmt.tprintf("TOOLKIT_DEVTOOLS=%d", WSL_PORT), fmt.tprintf("OC_PORT=%d", s.live.server.port), fmt.tprintf("OC_PASSWORD=%s", s.live.password), "WSLENV=TOOLKIT_DEVTOOLS:OC_PORT:OC_PASSWORD")
	p, start_err := os.process_start({command = cmd[:], env = env, stdout = log, stderr = log})
	if start_err != nil { fmt.eprintfln("shots: WSL does not start: %v", start_err); return }
	app.process = p
	begun := time.now()
	for time.since(begun) < WSL_LIMIT {
		if d, connected := dt_connect(WSL_PORT); connected { app.dt = d; return app, true }
		if state, _ := os.process_wait(p, 0); state.exited { fmt.eprintfln("shots: the program ended: see %s", app.log); return }
		time.sleep(POLL)
	}
	fmt.eprintfln("shots: no answer on port %d", WSL_PORT)
	_ = os.process_kill(p)
	return
}

// Would a secret be in the picture? (What is scrolled out of the window is in the tree, not in the picture.)
@(private = "file")
leak_of :: proc(dt: ^Dt) -> string {
	height := window_height(dt)
	secrets := SHOT_SECRETS
	for secret in secrets {
		for b in dt_find(dt, secret) {
			if b.h > 0 && b.y + b.h > 0 && b.y < height { return secret }
		}
	}
	return ""
}

@(private = "file")
take :: proc(s: ^Shots, p: Picture) -> bool {
	args := make([dynamic]string, context.temp_allocator)
	common := SHOT_ARGS
	append(&args, ..common[:])
	if s.font_dir != "" { append(&args, fmt.tprintf("--font-dir=%s", s.font_dir)) }
	append(&args, fmt.tprintf("--session=%s", p.work ? s.work_session : s.live.session), fmt.tprintf("--search=%s", p.work ? WORK_TITLE : "Tour"))
	if p.extra != "" { append(&args, p.extra) }
	if p.on_conversation { append(&args, fmt.tprintf("--image=%s/conversation.png", s.docs)) }

	app: App
	started: bool
	if p.linux {
		app, started = start_linux(s, args[:])
	} else {
		app, started = launch(&s.live, fmt.tprintf("shot_%s", p.name), ..args[:])
	}
	if !started { return false }
	defer app_end(&app)
	dt := &app.dt
	defer if p.linux { dt_call(dt, "Browser.close") }
	if !dt_wait_for(dt, "connected", SHOT_LIMIT) { return false }
	if !dt_wait_for(dt, p.work ? WORK_TITLE : TOUR_TITLE, SHOT_LIMIT) { return false }
	if _, quiet := dt_call(dt, "Toolkit.waitIdle", fmt.tprintf(`{{"timeout":%d}}`, int(time.duration_milliseconds(SHOT_LIMIT)))); !quiet { return false }

	snap := Snap{dt = dt, ok = true}
	if p.ready != nil { p.ready(&snap) }
	if snap.ok {   // the pointer over the title bar: nothing hovered, no scroll bar called up
		x, y := shot_at(dt, 0.5, 0.02)
		mouse(&snap, "mouseMoved", f64(x), f64(y))
	}
	settle(&snap, 500 * time.Millisecond)   // (what hover lit goes out)
	if p.linux { settle(&snap, 3 * time.Second) }   // (through the relay, the last requests are slower)
	idle(&snap)
	if !snap.ok { fmt.eprintfln("shots: %s failed", p.name); return false }
	if secret := leak_of(dt); secret != "" { fmt.eprintfln("shots: %s: \"%s\" would be in the picture", p.name, secret); return false }

	out := fmt.tprintf("%s/%s.png", s.docs, p.name)
	if !dt_shot(dt, out) { return false }
	if s.to_site && p.name != "conversation" {   // (the README's alone)
		if os.copy_file(fmt.tprintf("%s/%s.png", SHOTS_SITE, p.name), out) != nil { return false }
	}
	fmt.printfln("saved %s", p.name)
	if p.after != nil { p.after(&snap) }
	return snap.ok
}

run_shots :: proc(args: []string) -> int {
	s := Shots{to_site = true, work_session = DEMO_SESSION}
	if !live_setup(&s.live, nil) { return 1 }
	s.live.session = TOUR_SESSION
	s.live.exe = SHOTS_EXE
	s.docs = SHOTS_DOCS
	gt := ""
	build, linux_build := false, false
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		value := ""
		if a != "--build" && a != "--linux-build" {
			if i + 1 >= len(args) { fmt.eprintfln("shots: what is %s?", a); return EXIT_USAGE }
			i += 1
			value = args[i]
		}
		switch a {
		case "--build":        build = true
		case "--linux-build":  linux_build = true
		case "--only":         s.only = strings.split(value, ",", context.temp_allocator)
		case "--exe":          s.live.exe = value
		case "--session":      s.live.session = value
		case "--work-session": s.work_session = value
		case "--toolkit":      gt = value
		case "--out":          s.docs = value; s.to_site = false
		case "--font-dir":     s.font_dir = value
		case "--linux":        s.linux = value
		case:
			fmt.eprintfln("shots: what is %s?", a)
			return EXIT_USAGE
		}
	}
	absolute, err := os.get_absolute_path(s.docs, context.temp_allocator)   // (the viewer opens one of them, from a folder of its own)
	if err != nil { return 1 }
	s.docs = absolute
	if !make_folder(s.docs) || !make_folder(LIVE_DIR) { return 1 }
	if linux_build {
		program, built := wsl_build()
		if !built { fmt.eprintln("shots: the build in WSL failed"); return 1 }
		s.linux = program
	}
	if build && !build_program({gt = gt, out = s.live.exe}) { return 1 }
	if s.linux == "" && !os.exists(s.live.exe) { fmt.eprintfln("shots: %s is missing: run with --build", s.live.exe); return 1 }
	pictures := PICTURES
	for p in pictures {
		if !wanted(p, s.only, s.linux != "") { continue }
		if !take(&s, p) { return 1 }
	}
	return 0
}
