package occtools

// What the program costs, as published figures must be made: real runs of the real program on the real server, the first
// one apart (it compiles its shaders), the median of the others.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"

MEASURE_RUNS :: 7
MB           :: 1024.0 * 1024.0

Sample :: struct {
	first_ms, session_ms: f64,
	working, private:     f64,   // MB
}

median :: proc(values: []f64) -> f64 {
	if len(values) == 0 { return 0 }
	sorted := slice.clone(values, context.temp_allocator)
	slice.sort(sorted)
	mid := len(sorted) / 2
	return len(sorted) % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

@(private = "file")
report :: proc(name: string, values: []f64, unit: string) {
	sorted := slice.clone(values, context.temp_allocator)
	slice.sort(sorted)
	fmt.printfln("  %-30s median %7.1f %s   (%.1f to %.1f)", name, median(values), unit, sorted[0], sorted[len(sorted) - 1])
}

@(private = "file")
one_run :: proc(l: ^Live, s: ^Sample) -> bool {
	app, ok := launch(l, "measure", fmt.tprintf("--session=%s", l.session), "--search=Python clock")
	if !ok { return false }
	defer app_end(&app)
	dt := &app.dt
	if !dt_wait_for(dt, "New session", STEP_LIMIT) { return false }
	s.first_ms = time.duration_milliseconds(time.since(app.started))
	if !dt_wait_for(dt, "Clock.py created", STEP_LIMIT) { return false }
	s.session_ms = time.duration_milliseconds(time.since(app.started))
	if _, idle := dt_call(dt, "Toolkit.waitIdle", `{"timeout":10000}`); !idle { return false }
	working, private := memory_of(app.process)
	s.working, s.private = f64(working) / MB, f64(private) / MB
	return true
}

// From a key to the file found, on the screen: the whole way, through the server and back.
@(private = "file")
measure_find :: proc(l: ^Live, runs: int) -> int {
	app, ok := launch(l, "measure_find", "--session=ses_e7633e562ffeJfyNPycNzsVrb1", "--search=Tour")
	if !ok { return 1 }
	defer app_end(&app)
	dt := &app.dt
	if !dt_wait_for(dt, "connected", STEP_LIMIT) { return 1 }
	dt_call(dt, "Toolkit.waitIdle", `{"timeout":5000}`)
	dt_key(dt, "ctrl+p")
	if !dt_wait_name(dt, "flr0", STEP_LIMIT) { return 1 }
	dt_call(dt, "Toolkit.waitIdle", `{"timeout":5000}`)
	found := make([]f64, runs, context.temp_allocator)
	for i in 0 ..< runs {
		begun := time.now()
		dt_type(dt, "make_logo.p")   // (not the whole name: the field must not be what is found)
		if !dt_wait_for(dt, "make_logo.ps1", STEP_LIMIT) { return 1 }
		found[i] = time.duration_milliseconds(time.since(begun))
		dt_key(dt, "ctrl+a")
		dt_key(dt, "Backspace")
		if !dt_wait_for(dt, "make_logo.ps1", STEP_LIMIT, gone = true) { return 1 }
		dt_call(dt, "Toolkit.waitIdle", `{"timeout":3000}`)
	}
	report("a key to the file found", found, "ms")
	return 0
}

run_measure :: proc(args: []string) -> int {
	l: Live
	if !live_setup(&l, args) { return 1 }
	runs := MEASURE_RUNS
	if len(args) > 0 && args[0] == "find" { return measure_find(&l, runs) }
	for i := 0; i < len(args); i += 1 {
		switch {
		case args[i] == "--exe" && i + 1 < len(args):
			i += 1
			l.exe = args[i]
		case args[i] == "--runs" && i + 1 < len(args):
			i += 1
			n, ok := strconv.parse_int(args[i])
			if !ok || n < 1 { fmt.eprintfln("measure: %s runs?", args[i]); return EXIT_USAGE }
			runs = n
		case:
			fmt.eprintfln("measure: what is %s?", args[i])
			return EXIT_USAGE
		}
	}
	info, err := os.stat(l.exe, context.temp_allocator)
	if err != nil { fmt.eprintfln("measure: no %s: occtools check builds it", l.exe); return 1 }
	if !make_folder(LIVE_DIR) { return 1 }

	warm: Sample
	if !one_run(&l, &warm) { fmt.eprintln("measure: the first run failed"); return 1 }
	fmt.printfln("first run, apart: content at %.0f ms, session at %.0f ms", warm.first_ms, warm.session_ms)

	first := make([]f64, runs, context.temp_allocator)
	session := make([]f64, runs, context.temp_allocator)
	working := make([]f64, runs, context.temp_allocator)
	private := make([]f64, runs, context.temp_allocator)
	for i in 0 ..< runs {
		s: Sample
		if !one_run(&l, &s) { fmt.eprintfln("measure: run %d failed", i + 1); return 1 }
		first[i], session[i], working[i], private[i] = s.first_ms, s.session_ms, s.working, s.private
	}
	fmt.printfln("%d runs of %s (%.1f MB):", runs, l.exe, f64(info.size) / MB)
	report("start to the interface", first, "ms")
	report("start to a session shown", session, "ms")
	report("memory at rest, working set", working, "MB")
	report("memory at rest, private", private, "MB")
	return 0
}
