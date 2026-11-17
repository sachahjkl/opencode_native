package ocntools

// The program of live, shots, film and measure on Linux: on a desktop nobody sees (toolbox.Program_Session, its own
// sway), so no window opens on the user's, its DevTools server on a port the system has free.

import "core:fmt"
import toolbox "gt:toolbox"

app_start :: proc(app: ^App, command: []string) -> bool {
	s := &app.session
	// (HOME stays the user's: the program finds the local server by what it wrote there, service.json)
	o := toolbox.Program_Options{
		command = command,
		env     = {fmt.tprintf("XDG_CONFIG_HOME=%s/config", app.settings), "OPENCODE_NATIVE_NO_SETUP=1"},
		log     = app.log,
	}
	if why := toolbox.program_session_start(s, app.settings, o); why != "" {
		fmt.eprintfln("live: %s", why)
		toolbox.program_session_stop(s)
		return false
	}
	app.started, app.process = s.started, s.program
	dt, why := toolbox.program_session_connect(s)
	if why == "" { app.dt = dt; return true }
	if !s.running && s.ended >= 0 {
		fmt.eprintfln("live: the program ended at the start, code %d: see %s", s.ended, app.log)
	} else {
		fmt.eprintfln("live: %s", why)
	}
	toolbox.program_session_stop(s)
	return false
}

app_stop :: proc(app: ^App) {
	toolbox.program_session_stop(&app.session)
}
