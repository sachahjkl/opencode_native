// What the client asks of Linux itself: the server's folders.
package ocn

import "gt:platform"

// The opencode server's own folder of `kind` (its configuration, its state): the toolkit's standard folder, as the
// server follows the XDG folders on Linux (temp memory; "": no home).
opencode_dir :: proc(kind: platform.User_Dir) -> string { return platform.user_dir(kind, "opencode", context.temp_allocator) }

// (no taskbar button to flash: the toast tells)
flash_taskbar :: proc(app: ^App) {}
