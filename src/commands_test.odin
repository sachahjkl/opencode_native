package ocn

import "core:testing"
import "gt:ui"

// The composer has the keyboard most of the time: a command's key that types text would go to it and never run the
// command (gui_toolkit's src/md/features/commands.md). No command has one.
@(test)
no_command_key_types_text :: proc(t: ^testing.T) {
	for c in COMMANDS {
		testing.expectf(t, !ui.command_key_types_text({c.key, c.mods}), "%s: %v %v types text", c.id, c.mods, c.key)
	}
}

// The palette, the keys, the settings and quit are the window's: their keys work over the settings and every view shown
// as a dialog (command_keyed).
@(test)
the_window_commands :: proc(t: ^testing.T) {
	for c in COMMANDS {
		want := c.id == "app.palette" || c.id == "app.help" || c.id == "app.settings" || c.id == "app.quit"
		testing.expectf(t, (c.scope == .Window) == want, "%s: the window's is %v", c.id, want)
		if c.scope == .Window { testing.expectf(t, c.over == nil, "%s: a window command works over a dialog already", c.id) }
	}
}
