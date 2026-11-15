// What the client asks of Linux itself: a question on the terminal.
package ocn

import "core:fmt"
import "core:os"
import "core:strings"
import "gt:platform"

// The opencode server's own folder of `kind` (its configuration, its state): the toolkit's standard folder, as the
// server follows the XDG folders on Linux (temp memory; "": no home).
opencode_dir :: proc(kind: platform.User_Dir) -> string { return platform.user_dir(kind, "opencode", context.temp_allocator) }

// (no taskbar button to flash: the toast tells)
flash_taskbar :: proc(app: ^App) {}

ANSWER_BUF_BYTES :: 16

// The command line's answer (no window yet): 6 = yes, as on Windows.
message_box :: proc(text: string, question: bool) -> int {
	fmt.println(text)
	if !question { return 1 }
	fmt.print("[y/N] ")
	buf: [ANSWER_BUF_BYTES]u8
	n, _ := os.read(os.stdin, buf[:])
	a := strings.to_lower(strings.trim_space(string(buf[:max(n, 0)])), context.temp_allocator)
	return a == "y" || a == "yes" ? 6 : 7
}
