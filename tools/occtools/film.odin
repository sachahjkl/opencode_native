package occtools

// The program filmed from inside: its own frames (Page.startScreencast), nothing of the desktop and no focus taken. A frame
// comes when the window changes and carries its time, so a clip is rebuilt at a fixed rate from what really happened.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

FILM_DIR        :: "build/film"
FILM_FPS        :: "30"
FILM_SIZE       :: "--size=1440x900"
FILM_SCALE      :: "--scale=1.5"
FILM_SLOW       :: 4     // the program's time, this much slower: a frame takes longer to read than it lasts (src/film.odin)
FILM_LAST_FRAME :: 1.0   // seconds: the last frame's own length (no later frame says it)

// The lines of an ffmpeg concat list: each frame held until the next one's time.
concat_list :: proc(names: []string, times: []f64) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "ffconcat version 1.0\n")
	for name, i in names {
		held := i + 1 < len(times) ? times[i + 1] - times[i] : FILM_LAST_FRAME
		fmt.sbprintf(&b, "file %s\nduration %.4f\n", name, held)
	}
	// (ffmpeg drops the duration of the last entry: the file again gives it one)
	if len(names) > 0 { fmt.sbprintf(&b, "file %s\n", names[len(names) - 1]) }
	return strings.to_string(b)
}

// A point of the window as parts of its size (its units are not the pixels of --size: --scale divides them).
film_at :: proc(dt: ^Dt, x, y: f64) -> (px, py: int) {
	r, _ := dt_call(dt, "Toolkit.state")
	o, _ := r.(json.Object)
	return int(json_num(o["width"]) * x), int(json_num(o["height"]) * y)
}

film_wheel :: proc(dt: ^Dt, x, y, notches: int) {
	dt_call(dt, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"mouseWheel","x":%d,"y":%d,"deltaX":0,"deltaY":%d}}`, x, y, notches * 100))
}

film_start :: proc(dt: ^Dt, name: string) -> bool {
	dir := fmt.tprintf("%s/%s", FILM_DIR, name)
	_ = os.remove_all(dir)
	if os.make_directory_all(dir) != nil { return false }
	dt.cast_dir = strings.clone(dir)
	_, ok := dt_call(dt, "Page.startScreencast", `{"format":"png","minIntervalMs":0}`)
	return ok
}

// Stops, and makes the clip of what came.
film_end :: proc(dt: ^Dt, name: string) -> bool {
	dt_call(dt, "Page.stopScreencast")
	dir := dt.cast_dir
	dt.cast_dir = ""
	n := len(dt.cast_times)
	if n < 2 { fmt.eprintfln("film: %s: %d frames", name, n); return false }
	span := dt.cast_times[n - 1] - dt.cast_times[0]
	fmt.printfln("film: %s: %d frames in %.2f s, %.1f a second", name, n, span, f64(n - 1) / max(span, 0.001))
	list := fmt.tprintf("%s/frames.ffconcat", dir)
	if os.write_entire_file(list, transmute([]byte)concat_list(dt.cast_names[:], dt.cast_times[:])) != nil { return false }
	clear(&dt.cast_names)
	clear(&dt.cast_times)
	return run("ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", list, "-vf", "crop=trunc(iw/2)*2:trunc(ih/2)*2,fps=" + FILM_FPS, "-c:v", "libx264", "-crf", "14", "-preset", "slow", "-pix_fmt", "yuv420p", fmt.tprintf("%s/%s.mp4", FILM_DIR, name))
}

FILM_SESSION  :: FILM_DIR + "/session.txt"
TOUR_SESSION  :: "ses_e7633e562ffeJfyNPycNzsVrb1"   // (made for pictures, on a public model)
PREPARE_LIMIT :: 90 * time.Second
KEY_GAP       :: 55 * time.Millisecond
// What must never be read in a film. The sidebar is held to the demo by --search; the home page lists the real sessions and
// folders whatever the search says, so its own words refuse a take, as does what is only there when a run went wrong.
SECRETS :: [?]string{"iceman", "Contributor", "START IN", "Other folder", "The run failed", "Untitled"}

Scene :: struct {
	name, search, session: string,
	play:                  proc(s: ^Shot),
	before:                proc(dt: ^Dt),   // what is done off camera
	diff:                  string,          // a patch to open in the full view (--diff)
}

Shot :: struct {
	dt:   ^Dt,
	leak: string,
}

// The film's time passes; what is visible is read all along, for what must not be in it.
@(private = "file")
hold :: proc(s: ^Shot, how_long: time.Duration) {
	begun := time.now()
	for time.since(begun) < how_long * FILM_SLOW {
		r, _ := dt_call(s.dt, "Toolkit.state")
		o, _ := r.(json.Object)
		height := json_num(o["height"])
		secrets := SECRETS
		for secret in secrets {
			for b in dt_find(s.dt, secret) {
				if b.h > 0 && b.y + b.h > 0 && b.y < height { s.leak = secret }
			}
		}
	}
}

@(private = "file")
type :: proc(s: ^Shot, text: string) {
	for c in text {
		dt_type(s.dt, fmt.tprintf("%c", c))
		hold(s, KEY_GAP)
	}
}

@(private = "file")
press :: proc(s: ^Shot, key: string, after: time.Duration) {
	dt_key(s.dt, key)
	hold(s, after)
}

@(private = "file")
wheel :: proc(s: ^Shot, notches, steps: int, gap: time.Duration) {
	x, y := film_at(s.dt, 0.65, 0.4)
	for _ in 0 ..< steps {
		film_wheel(s.dt, x, y, notches)
		hold(s, gap)
	}
}

public_model :: proc(dt: ^Dt) {
	dt_click_name(dt, "model")
	dt_call(dt, "Toolkit.waitIdle", `{"timeout":3000}`)
	dt_type(dt, "sonnet 5")
	dt_call(dt, "Toolkit.waitIdle", `{"timeout":3000}`)
	dt_shot(dt, LIVE_DIR + "/model_pick.png")
	dt_key(dt, "Enter")
	dt_call(dt, "Toolkit.waitIdle", `{"timeout":3000}`)
	if !dt_has(dt, "claude-sonnet-5") { fmt.eprintln("film: the public model was not taken: see model_pick.png") }
}

@(private = "file")
play_read :: proc(s: ^Shot) {
	hold(s, 700 * time.Millisecond)
	wheel(s, -2, 16, 260 * time.Millisecond)
	hold(s, 900 * time.Millisecond)
}

@(private = "file")
play_palette :: proc(s: ^Shot) {
	hold(s, 500 * time.Millisecond)
	press(s, "ctrl+k", 700 * time.Millisecond)
	type(s, ">")
	hold(s, 500 * time.Millisecond)
	for _ in 0 ..< 3 { press(s, "ArrowDown", 260 * time.Millisecond) }
	type(s, " zoom")
	hold(s, 900 * time.Millisecond)
	press(s, "Escape", 600 * time.Millisecond)
}

@(private = "file")
play_model :: proc(s: ^Shot) {
	hold(s, 500 * time.Millisecond)
	dt_click_name(s.dt, "model")
	hold(s, 700 * time.Millisecond)
	type(s, "sonnet")
	hold(s, 1000 * time.Millisecond)
	press(s, "Escape", 500 * time.Millisecond)
}

@(private = "file")
play_find :: proc(s: ^Shot) {
	hold(s, 500 * time.Millisecond)
	press(s, "ctrl+f", 500 * time.Millisecond)
	type(s, "http")
	hold(s, 700 * time.Millisecond)
	for _ in 0 ..< 4 { press(s, "Enter", 450 * time.Millisecond) }
	press(s, "Escape", 500 * time.Millisecond)
}

@(private = "file")
play_stats :: proc(s: ^Shot) {
	hold(s, 500 * time.Millisecond)
	press(s, "ctrl+i", 2200 * time.Millisecond)
	press(s, "ctrl+i", 900 * time.Millisecond)
}

// (the shell's suggestions come from the history of whoever films: none, and a clean screen)
@(private = "file")
terminal_ready :: proc(dt: ^Dt) {
	dt_key(dt, "ctrl+shift+t")
	dt_wait_name(dt, "term_box", STEP_LIMIT)
	dt_call(dt, "Toolkit.waitIdle", `{"timeout":5000}`)
	dt_click_name(dt, "term_box")
	dt_type(dt, "Set-PSReadLineOption -PredictionSource None; Clear-Host")
	dt_key(dt, "Enter")
	dt_call(dt, "Toolkit.waitIdle", `{"timeout":5000}`)
}

@(private = "file")
play_terminal :: proc(s: ^Shot) {
	hold(s, 500 * time.Millisecond)
	type(s, "Get-ChildItem | Select-Object Name, Length")
	press(s, "Enter", 1200 * time.Millisecond)
	type(s, "Write-Host 'a real shell, in the dock' -ForegroundColor Green")
	press(s, "Enter", 1400 * time.Millisecond)
}

@(private = "file")
play_browser :: proc(s: ^Shot) {
	hold(s, 400 * time.Millisecond)
	press(s, "ctrl+shift+b", 900 * time.Millisecond)
	dt_click_name(s.dt, "pv_url")
	hold(s, 200 * time.Millisecond)
	type(s, "sachahjkl.github.io/opencode_native")
	press(s, "Enter", 6000 * time.Millisecond)
}

@(private = "file")
click_text :: proc(s: ^Shot, label: string, after: time.Duration) {
	dt_call(s.dt, "Toolkit.click", fmt.tprintf(`{{"text":%s,"index":0,"count":1,"button":"left"}}`, json_text(label)))
	hold(s, after)
}

@(private = "file")
play_diff :: proc(s: ^Shot) {
	hold(s, 1200 * time.Millisecond)
	click_text(s, "Split", 900 * time.Millisecond)
	wheel(s, 2, 8, 280 * time.Millisecond)
	hold(s, 700 * time.Millisecond)
}

@(private = "file")
play_queue :: proc(s: ^Shot) {
	dt_click_name(s.dt, "composer")
	hold(s, 300 * time.Millisecond)
	type(s, "Write a long story about a clock")
	press(s, "Enter", 1200 * time.Millisecond)
	type(s, "Then add a --json flag")
	press(s, "Enter", 700 * time.Millisecond)
	type(s, "And update the README")
	press(s, "Enter", 1800 * time.Millisecond)
	press(s, "ctrl+Escape", 800 * time.Millisecond)
}

SCENES :: [?]Scene{
	{"read", "Tour", TOUR_SESSION, play_read, nil, ""},
	{"palette", "Tour", TOUR_SESSION, play_palette, nil, ""},
	{"model", "Tour", TOUR_SESSION, play_model, nil, ""},
	{"find", "Tour", TOUR_SESSION, play_find, nil, ""},
	{"stats", "Tour", TOUR_SESSION, play_stats, nil, ""},
	{"terminal", "", "", play_terminal, terminal_ready, ""},
	{"browser", "", "", play_browser, nil, ""},
	{"queue", "", "", play_queue, nil, ""},
	{"diff", "", "", play_diff, nil, FILM_DIR + "/preview.odin"},
}

// A session of the demo's own, a real run of a public model: what the scenes that want a project show.
@(private = "file")
prepare :: proc(l: ^Live) -> bool {
	if old := strings.trim_space(read_text(FILM_SESSION)); old != "" { _ = api_delete(l, "session", old) }
	before, listed := api_list(l, "session")
	if !listed { return false }
	app, ok := launch(l, "film_prepare", fmt.tprintf("--session=%s", l.session))
	if !ok { return false }
	defer app_end(&app)
	dt := &app.dt
	if !dt_wait_for(dt, "connected", STEP_LIMIT) { return false }
	dt_key(dt, "ctrl+n")
	if !dt_wait_name(dt, "composer", STEP_LIMIT) { return false }
	public_model(dt)
	dt_click_name(dt, "composer")
	dt_type(dt, "Keep a todo list. Add a --iso flag to clock.py that prints the time in ISO 8601, try it, then document it in README.md.")
	dt_key(dt, "Enter")
	dt_call(dt, "Toolkit.waitIdle", `{"timeout":3000}`)
	dt_shot(dt, LIVE_DIR + "/prepare_sent.png")
	begun := time.now()
	id := ""
	for time.since(begun) < PREPARE_LIMIT {
		now, _ := api_list(l, "session")
		if fresh := new_ids(before, now); len(fresh) > 0 { id = fresh[0] }
		if id != "" && !dt_has(dt, "Untitled") && dt_has(dt, "README") && !dt_has(dt, "Stop") { break }
		if dt_has(dt, "The run failed") { fmt.eprintln("film: the run failed"); return false }
		time.sleep(time.Second)
	}
	if id == "" || dt_has(dt, "Untitled") { fmt.eprintln("film: no finished session came"); return false }
	fmt.printfln("film: session %s", id)
	return os.write_entire_file(FILM_SESSION, transmute([]byte)id) == nil
}

@(private = "file")
shoot :: proc(l: ^Live, scene: Scene) -> bool {
	session := scene.session != "" ? scene.session : strings.trim_space(read_text(FILM_SESSION))
	if session == "" { fmt.eprintln("film: no session: occtools film prepare"); return false }
	search := scene.search != "" ? scene.search : "clock"
	extra := scene.diff != "" ? fmt.tprintf("--diff=%s", scene.diff) : "--pref=notify.finished=off"
	app, ok := launch(l, fmt.tprintf("film_%s", scene.name), FILM_SIZE, FILM_SCALE, fmt.tprintf("--slow-motion=%d", FILM_SLOW), fmt.tprintf("--session=%s", session), fmt.tprintf("--search=%s", search), extra)
	if !ok { return false }
	defer app_end(&app)
	dt := &app.dt
	if !dt_wait_for(dt, "connected", STEP_LIMIT * FILM_SLOW) { return false }
	dt_call(dt, "Toolkit.waitIdle", `{"timeout":15000}`)
	if scene.before != nil { scene.before(dt) }
	if !film_start(dt, scene.name) { return false }
	shot := Shot{dt = dt}
	scene.play(&shot)
	done := film_end(dt, scene.name)
	if shot.leak != "" {
		fmt.eprintfln("film: %s REFUSED: \"%s\" was in the picture", scene.name, shot.leak)
		_ = os.remove(fmt.tprintf("%s/%s.mp4", FILM_DIR, scene.name))
		return false
	}
	return done
}

run_film :: proc(args: []string) -> int {
	l: Live
	if !live_setup(&l, args) { return 1 }
	if os.make_directory_all(FILM_DIR) != nil || os.make_directory_all(LIVE_DIR) != nil { return 1 }
	what := len(args) > 0 ? args[0] : "all"
	if what == "prepare" { return prepare(&l) ? 0 : 1 }
	if !snapshot_take(&l) { return 1 }
	failed, found := 0, false
	scenes := SCENES
	for scene in scenes {
		if what != "all" && what != scene.name { continue }
		found = true
		if !shoot(&l, scene) { failed += 1 }
	}
	if clean_now(&l) != 0 { failed += 1 }
	if !found { fmt.eprintfln("film: no scene %s", what); return EXIT_USAGE }
	fmt.printfln("film: %d failed", failed)
	return failed > 0 ? 1 : 0
}
