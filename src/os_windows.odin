// What the client asks of Windows itself: the local time's offset, the taskbar button flashing, a message box.
package occ

import "core:encoding/base64"
import "core:strings"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"
foreign import user32_flash "system:User32.lib"
foreign import crypt32 "system:Crypt32.lib"

@(private = "file")
Data_Blob :: struct { size: u32, data: [^]u8 }

@(default_calling_convention = "system", private = "file")
foreign crypt32 {
	CryptProtectData :: proc(data_in: ^Data_Blob, description: cstring16, entropy: ^Data_Blob, reserved, prompt: rawptr, flags: u32, data_out: ^Data_Blob) -> win.BOOL ---
	CryptUnprotectData :: proc(data_in: ^Data_Blob, description: ^cstring16, entropy: ^Data_Blob, reserved, prompt: rawptr, flags: u32, data_out: ^Data_Blob) -> win.BOOL ---
}

@(private = "file") CRYPTPROTECT_UI_FORBIDDEN :: u32(1)
@(private = "file") SEALED_MARK :: "dpapi:"

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

// A password as the servers' file keeps it: encrypted for this Windows account (DPAPI), in text.
password_seal :: proc(name, password: string) -> (field: string, ok: bool) {
	plain := Data_Blob{u32(len(password)), raw_data(transmute([]u8)password)}
	out: Data_Blob
	if !CryptProtectData(&plain, nil, nil, nil, nil, CRYPTPROTECT_UI_FORBIDDEN, &out) { return "", false }
	defer win.LocalFree(out.data)
	text, err := base64.encode(out.data[:out.size], allocator = context.temp_allocator)
	if err != nil { return "", false }
	return strings.concatenate({SEALED_MARK, text}, context.temp_allocator), true
}

// What password_seal wrote. `sealed` false: it is not its work (a password in clear from an older version); `ok` false:
// it is, but this account cannot open it.
password_open :: proc(name, field: string) -> (password: string, sealed, ok: bool) {
	if !strings.has_prefix(field, SEALED_MARK) { return "", false, false }
	data, err := base64.decode(field[len(SEALED_MARK):], allocator = context.temp_allocator)
	if err != nil || len(data) == 0 { return "", false, false }
	blob := Data_Blob{u32(len(data)), raw_data(data)}
	out: Data_Blob
	if !CryptUnprotectData(&blob, nil, nil, nil, nil, CRYPTPROTECT_UI_FORBIDDEN, &out) { return "", true, false }
	defer win.LocalFree(out.data)
	return strings.clone(string(out.data[:out.size]), context.temp_allocator), true, true
}

password_forget :: proc(name: string) {}   // (it lives in the file)

// What the server dialog says of where the password goes (nothing to warn of here).
password_note :: proc() -> string { return "" }
