package ocntools

// The program of live, shots, film and measure on Windows: started on the user's desktop (no desktop of its own here),
// its DevTools server on a port the system has free.

import "core:fmt"
import "core:os"
import "core:time"
import cdp "gt:cdp"
import toolbox "gt:toolbox"

app_start :: proc(app: ^App, command: []string) -> bool {
	port, free := toolbox.free_port()
	if !free { fmt.eprintln("live: no free port for the DevTools server"); return false }
	if !make_folder(app.settings) { return false }
	log, err := os.open(app.log, os.O_WRONLY | os.O_CREATE | os.O_TRUNC | os.O_INHERITABLE, os.Permissions_Read_Write_All)   // (a child only writes to what it may inherit)
	if err != nil { fmt.eprintfln("live: %s: %v", app.log, err); return false }
	defer os.close(log)
	env := toolbox.env_with({"APPDATA", "TOOLKIT_DEVTOOLS", "OPENCODE_NATIVE_NO_SETUP"},
		fmt.tprintf("APPDATA=%s", app.settings), fmt.tprintf("TOOLKIT_DEVTOOLS=%d", port), "OPENCODE_NATIVE_NO_SETUP=1")
	app.started = time.now()
	p, start_err := os.process_start({command = command, env = env, stdout = log, stderr = log})
	if start_err != nil { fmt.eprintfln("live: %s does not start: %v", command[0], start_err); return false }
	app.process = p
	dt, connected, ended := cdp.connect_wait(port, START_LIMIT, p)
	if connected { app.dt = dt; return true }
	if ended.exited {
		fmt.eprintfln("live: the program ended at the start, code %d: see %s", ended.exit_code, app.log)
	} else {
		fmt.eprintfln("live: no devtools on port %d, the program alive: see %s", port, app.log)
		_ = os.process_kill(p)
	}
	return false
}

app_stop :: proc(app: ^App) {
	_ = os.process_kill(app.process)
	_, _ = os.process_wait(app.process, 5 * time.Second)
}
