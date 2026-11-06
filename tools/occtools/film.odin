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

// `how_long` of the film, keeping the window at work while its frames are read: an answer to wait for lets the events in.
film_pump :: proc(dt: ^Dt, how_long: time.Duration) {
	begun := time.now()
	for time.since(begun) < how_long * FILM_SLOW {
		dt_call(dt, "Toolkit.state")
		time.sleep(5 * time.Millisecond)
	}
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

@(private = "file")
scene_probe :: proc(l: ^Live) -> bool {
	app, ok := launch(l, "film_probe", FILM_SIZE, FILM_SCALE, fmt.tprintf("--slow-motion=%d", FILM_SLOW), fmt.tprintf("--session=%s", l.session), "--search=Python clock")
	if !ok { return false }
	defer app_end(&app)
	dt := &app.dt
	if !dt_wait_for(dt, "Clock.py created", STEP_LIMIT) { return false }
	if !film_start(dt, "probe") { return false }
	x, y := film_at(dt, 0.65, 0.4)
	fmt.printfln("film: the wheel at %d,%d", x, y)
	for _ in 0 ..< 24 {
		film_wheel(dt, x, y, -1)
		film_pump(dt, 120 * time.Millisecond)
	}
	return film_end(dt, "probe")
}

run_film :: proc(args: []string) -> int {
	l: Live
	if !live_setup(&l, args) { return 1 }
	if os.make_directory_all(FILM_DIR) != nil || os.make_directory_all(LIVE_DIR) != nil { return 1 }
	if len(args) == 0 || args[0] == "probe" { return scene_probe(&l) ? 0 : 1 }
	fmt.eprintfln("film: no scene %s", args[0])
	return EXIT_USAGE
}
