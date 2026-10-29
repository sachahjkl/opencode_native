// What the client asks of Linux itself: the local time's offset (libc), a question on the terminal.
package occ

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

foreign import libc "system:c"

@(private = "file")
Tm :: struct {   // glibc's struct tm
	sec, min, hour, mday, mon, year, wday, yday, isdst: c.int,
	gmtoff: c.long,
	zone:   cstring,
}

@(default_calling_convention = "c", private = "file")
foreign libc {
	time :: proc(t: ^c.long) -> c.long ---
	localtime_r :: proc(t: ^c.long, out: ^Tm) -> ^Tm ---
}

// Minutes to add to UTC for the machine's local time (daylight saving included).
local_offset_minutes :: proc() -> int {
	@(static) cached: int
	@(static) known: bool
	if !known {
		now := time(nil)
		tm: Tm
		if localtime_r(&now, &tm) != nil { cached = int(tm.gmtoff) / 60 }
		known = true
	}
	return cached
}

// (no taskbar button to flash: the toast tells)
flash_taskbar :: proc(app: ^App) {}

// The command line's answer (no window yet): 6 = yes, as on Windows.
message_box :: proc(text: string, question: bool) -> int {
	fmt.println(text)
	if !question { return 1 }
	fmt.print("[y/N] ")
	buf: [16]u8
	n, _ := os.read(os.stdin, buf[:])
	a := strings.to_lower(strings.trim_space(string(buf[:max(n, 0)])), context.temp_allocator)
	return a == "y" || a == "yes" ? 6 : 7
}
