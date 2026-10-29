// What the desktop integration of every system shares: the state of the install and its facts, which the Setup dialog
// shows (desktop_windows.odin, desktop_linux.odin do the work).
package occ

import "core:path/filepath"

APP_NAME      :: "opencode native"
APP_PUBLISHER :: "Froment Software"

Install_State :: enum u8 {
	Not_Installed,
	This_Copy,        // the running program is the installed copy, everything in place
	Repair,           // this is the installed copy, but a launcher or the system's record of it is missing
	Other_Copy,       // a copy is installed elsewhere: this one runs standalone (Install replaces that one)
}

Install_Facts :: struct {
	state:     Install_State,
	dir:       string,   // where the installed copy is (or would go)
	exe:       string,
	running:   string,   // this program
	start_lnk: bool,     // the launcher of the applications menu (Start menu shortcut, .desktop entry)
	desk_lnk:  bool,     // the one on the Desktop
	record:    bool,     // the system's record (Settings > Apps entry; the icon in the icon theme)
	version:   string,   // of the installed copy, from its record
}

// A path made of `parts` (temp memory).
pjoin :: proc(parts: []string) -> string {
	s, _ := filepath.join(parts, context.temp_allocator)
	return s
}
