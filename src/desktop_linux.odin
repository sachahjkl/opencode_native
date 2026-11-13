// Linux: the words of this system, the icons of the menu entry, and the copy of the menu entry on the Desktop that Setup up
// to 0.30 wrote ($XDG_DESKTOP_DIR/opencode-native.desktop, else ~/Desktop): the toolkit's setup has no such part, so an
// uninstall removes it here. It is ours when it carries the identity's marker or runs the installed copy (as Setup before
// 0.21 wrote it), and only then is it removed.
package ocn

import "core:os"
import desktop "gt:desktop"
import setup "gt:setup"
import i18n "gt:i18n"

@(private = "file")
ICON_SET := [?]desktop.Icon{{256, #load("../assets/logo_256.png")}}

// The icons of the theme (Windows uses the executable's own).
desktop_icons :: proc() -> []desktop.Icon { return ICON_SET[:] }

// What the settings call the pieces of an install, on this system.
LBL_PIECES :: "the applications menu entry, the icon"
// (the settings' line about Setup, whole: a language orders its words its own way)
SETUP_HINT := i18n.later("Installation and the applications menu entry, the icon are in Setup… (title bar menu).")

// After an uninstall: the copy of the menu entry on the Desktop, when it is ours.
desktop_copy_remove :: proc() {
	path: string
	if d := os.get_env("XDG_DESKTOP_DIR", context.temp_allocator); d != "" { path = pjoin({d, APP_SLUG + ".desktop"}) } else { path = pjoin({os.get_env("HOME", context.temp_allocator), "Desktop", APP_SLUG + ".desktop"}) }
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return }
	o, _ := setup.options(setup_config())
	mark, _ := desktop.entry_value(string(data), o.identity.entry_marker)
	exec, _ := desktop.entry_value(string(data), "Exec")
	installed := pjoin({o.install_dir, desktop.exe_name_of(o.identity)})
	if mark == o.identity.slug || desktop.same_path(desktop.exec_program(exec), installed) { _ = os.remove(path) }
}
