// What the desktop integration of every system shares: the state of the install and its facts, which the Setup dialog
// shows (desktop_windows.odin, desktop_linux.odin do the work).
package occ

import "core:os"
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

// What the Setup dialog calls the pieces of an install, on this system.
when ODIN_OS == .Windows {
	LBL_MENU      :: "start menu"
	LBL_MENU_ITEM :: APP_NAME + ".lnk"
	LBL_RECORD    :: "settings"
	LBL_RECORD_IT :: "Settings > Apps > opencode native"
	LBL_PIECES    :: "the shortcuts, the Settings > Apps entry"
	LBL_START     :: "the Start menu"
} else {
	LBL_MENU      :: "menu entry"
	LBL_MENU_ITEM :: "opencode-native.desktop"
	LBL_RECORD    :: "icon"
	LBL_RECORD_IT :: "hicolor/256x256/apps/opencode-native.png"
	LBL_PIECES    :: "the applications menu entry, the icon"
	LBL_START     :: "the applications menu"
}

// The client's own files (preferences, servers): %APPDATA%\opencode-native on Windows, $XDG_CONFIG_HOME/opencode-native
// (~/.config/opencode-native) elsewhere.
config_dir :: proc() -> string {
	when ODIN_OS == .Windows {
		return pjoin({os.get_env("APPDATA", context.temp_allocator), "opencode-native"})
	} else {
		if d := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); d != "" { return pjoin({d, "opencode-native"}) }
		return pjoin({os.get_env("HOME", context.temp_allocator), ".config", "opencode-native"})
	}
}
