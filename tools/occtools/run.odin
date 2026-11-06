package occtools

import "core:fmt"
import "core:os"
import "core:strings"

Run :: struct {
	dir: string,     // "": here
	env: []string,   // nil: this process's
}

// A command, its output going where ours goes. Did it succeed?
run_in :: proc(how: Run, cmd: ..string) -> bool {
	fmt.printfln("> %s", strings.join(cmd, " ", context.temp_allocator))
	p, err := os.process_start({command = cmd, working_dir = how.dir, env = how.env, stdin = os.stdin, stdout = os.stdout, stderr = os.stderr})
	if err != nil { fmt.eprintfln("%s: %v", cmd[0], err); return false }
	state, wait_err := os.process_wait(p)
	if wait_err != nil { fmt.eprintfln("%s: %v", cmd[0], wait_err) }
	return wait_err == nil && state.success
}

run :: proc(cmd: ..string) -> bool { return run_in({}, ..cmd) }

// What a command prints, for the answers of git and gh. In the frame's allocator.
capture :: proc(cmd: ..string) -> (out: string, ok: bool) {
	state, stdout, stderr, err := os.process_exec({command = cmd}, context.temp_allocator)
	if err != nil { return "", false }
	if !state.success && len(stderr) > 0 { fmt.eprint(string(stderr)) }
	return string(stdout), state.success
}

// This process's environment, without `name` and with `extra` ("NAME=value").
env_with :: proc(without: string, extra: ..string) -> []string {
	all, err := os.environ(context.temp_allocator)
	if err != nil { return nil }
	out := make([dynamic]string, context.temp_allocator)
	prefix := strings.concatenate({without, "="}, context.temp_allocator)
	for e in all {
		if !strings.has_prefix(e, prefix) { append(&out, e) }
	}
	append(&out, ..extra)
	return out[:]
}

read_text :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? string(data) : ""
}
