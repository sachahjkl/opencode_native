// What the client asks of Windows itself: the local time's offset, the taskbar button flashing, a message box.
package occ

import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"
foreign import user32_flash "system:User32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32 {
	GetTimeZoneInformation :: proc(tzi: ^win.TIME_ZONE_INFORMATION) -> u32 ---
}

FLASHWINFO :: struct { cbSize: u32, hwnd: win.HWND, dwFlags: u32, uCount: u32, dwTimeout: u32 }

@(default_calling_convention = "system", private = "file")
foreign user32_flash {
	FlashWindowEx :: proc(fi: ^FLASHWINFO) -> win.BOOL ---
}

// Minutes to add to UTC for the machine's local time (daylight saving included).
local_offset_minutes :: proc() -> int {
	@(static) cached: int
	@(static) known: bool
	if !known {
		tzi: win.TIME_ZONE_INFORMATION
		r := GetTimeZoneInformation(&tzi)
		bias := int(tzi.Bias) + (r == 2 ? int(tzi.DaylightBias) : int(tzi.StandardBias))
		cached, known = -bias, true
	}
	return cached
}

FLASH_COUNT :: 3   // of the taskbar button

flash_taskbar :: proc(app: ^App) {
	fi := FLASHWINFO{cbSize = size_of(FLASHWINFO), hwnd = win.HWND(app.win.hwnd), dwFlags = 0x3 | 0xC, uCount = FLASH_COUNT}   // FLASHW_ALL | FLASHW_TIMERNOFG
	FlashWindowEx(&fi)
}

// A system message box (before any window of ours): 6 = Yes.
message_box :: proc(text: string, question: bool) -> int {
	flags := u32(question ? 0x4 | 0x20 : 0x40)   // MB_YESNO | MB_ICONQUESTION, else MB_ICONINFORMATION
	return int(win.MessageBoxW(nil, win.utf8_to_wstring(text, context.temp_allocator), win.L("opencode native"), flags))
}
