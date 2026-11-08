// Linux: what the toolkit's integration does not have. A copy of the menu entry on the Desktop (the package has no
// desktop shortcut part on Linux): $XDG_DESKTOP_DIR/opencode-native.desktop, else ~/Desktop. It is ours when it carries
// the identity's marker or runs the installed copy (as Setup before 0.21 wrote it), and only then is it replaced or removed.
// The system's record of the install is the icon in the icon theme.
package occ

import "core:os"
import "core:path/filepath"
import desktop "gt:desktop"

@(private = "file")
ICON_SET := [?]desktop.Icon{{256, #load("../assets/logo_256.png")}}

// The icons of the theme (Windows uses the executable's own).
desktop_icons :: proc() -> []desktop.Icon { return ICON_SET[:] }

// What the Setup dialog calls the pieces of an install, on this system.
LBL_MENU      :: "menu entry"
LBL_MENU_ITEM :: APP_SLUG + ".desktop"
LBL_RECORD    :: "icon"
LBL_RECORD_IT :: "hicolor/256x256/apps/" + APP_SLUG + ".png"
LBL_PIECES    :: "the applications menu entry, the icon"
LBL_START     :: "the applications menu"
LBL_PIECES_MISSING :: "the menu entry, the icon or a file"

@(private = "file")
desktop_file :: proc() -> string {
	if d := os.get_env("XDG_DESKTOP_DIR", context.temp_allocator); d != "" { return pjoin({d, APP_SLUG + ".desktop"}) }
	return pjoin({os.get_env("HOME", context.temp_allocator), "Desktop", APP_SLUG + ".desktop"})
}

desktop_shortcut_there :: proc(o: ^desktop.Options, _: ^desktop.Status) -> bool {
	data, err := os.read_entire_file(desktop_file(), context.temp_allocator)
	if err != nil { return false }
	mark, _ := desktop.entry_value(string(data), o.identity.entry_marker)
	exec, _ := desktop.entry_value(string(data), "Exec")
	return mark == o.identity.slug || desktop.same_path(desktop.exec_program(exec), o.exe)
}

// Writes the copy of the menu entry on the Desktop for `o.exe`, or removes ours.
desktop_shortcut_set :: proc(o: ^desktop.Options, on: bool) -> bool {
	path := desktop_file()
	if !on {
		if desktop_shortcut_there(o, nil) { _ = os.remove(path) }
		return true
	}
	if os.exists(path) && !desktop_shortcut_there(o, nil) { return false }   // (another program's file of that name stays)
	_ = os.make_directory_all(filepath.dir(path))
	if os.write_entire_file(path, desktop.desktop_entry_text(o)) != nil { return false }
	_ = os.chmod(path, os.Permissions_Default_File | {.Execute_User})   // (a desktop starts only an executable entry)
	return true
}

system_record_there :: proc(s: ^desktop.Status, _: bool) -> bool {
	return s.parts[.Icons].present && !s.parts[.Icons].partial
}
