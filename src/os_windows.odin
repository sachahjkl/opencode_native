// What the client asks of Windows itself: the server's folders, the taskbar button flashing.
package ocn

import "core:os"
import win "core:sys/windows"
import "gt:platform"

// The opencode server's own folder of `kind` (temp memory; "": no home). Not the toolkit's standard folder (%APPDATA%,
// %LOCALAPPDATA%): the server keeps the XDG layout on Windows too, $XDG_<kind>_HOME when it is set, else under the
// user's home (%USERPROFILE%\.config\opencode, %USERPROFILE%\.local\state\opencode), as its global-roots.ts does.
opencode_dir :: proc(kind: platform.User_Dir) -> string {
	variable, under: string
	#partial switch kind {
	case .Config: variable, under = "XDG_CONFIG_HOME", ".config"
	case .Data:   variable, under = "XDG_DATA_HOME", ".local/share"
	case .State:  variable, under = "XDG_STATE_HOME", ".local/state"
	case .Cache:  variable, under = "XDG_CACHE_HOME", ".cache"
	case:         return ""
	}
	// (any value, as opencode takes it: the service wrote its service.json there)
	if base := os.get_env(variable, context.temp_allocator); base != "" { return pjoin({base, "opencode"}) }
	home := os.get_env("USERPROFILE", context.temp_allocator)
	if home == "" { home = os.get_env("HOME", context.temp_allocator) }
	if home == "" { return "" }
	return pjoin({home, under, "opencode"})
}

foreign import user32_flash "system:User32.lib"

FLASHWINFO :: struct { cbSize: u32, hwnd: win.HWND, dwFlags: u32, uCount: u32, dwTimeout: u32 }

@(default_calling_convention = "system", private = "file")
foreign user32_flash {
	FlashWindowEx :: proc(fi: ^FLASHWINFO) -> win.BOOL ---
}

FLASH_COUNT :: 3   // of the taskbar button

flash_taskbar :: proc(app: ^App) {
	fi := FLASHWINFO{cbSize = size_of(FLASHWINFO), hwnd = win.HWND(app.win.hwnd), dwFlags = 0x3 | 0xC, uCount = FLASH_COUNT}   // FLASHW_ALL | FLASHW_TIMERNOFG
	FlashWindowEx(&fi)
}
