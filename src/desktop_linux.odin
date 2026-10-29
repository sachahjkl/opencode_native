// Desktop integration on Linux, for the user only (the XDG folders of the home, never root):
//   ~/.local/share/opencode-native/opencode-native          the installed copy (and `version`, its record)
//   ~/.local/share/applications/opencode-native.desktop     its entry in the applications menu (and optionally a copy on
//                                                           the Desktop)
//   ~/.local/share/icons/hicolor/256x256/apps/opencode-native.png   its icon
// `--install [--desktop]`, `--uninstall`, `--status` do it without a window; the Setup dialog (setup.odin) does it with one.
// A running program's file can be replaced or deleted on Linux: no renaming, no deferred removal.
package occ

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

EXE_NAME :: "opencode-native"
APP_ID   :: "opencode-native"   // the .desktop file's name, the icon's, the windows' class

@(private = "file")
LOGO_256 :: #load("../assets/logo_256.png")

@(private = "file")
data_home :: proc() -> string {
	if d := os.get_env("XDG_DATA_HOME", context.temp_allocator); d != "" { return d }
	return pjoin({os.get_env("HOME", context.temp_allocator), ".local", "share"})
}

@(private = "file")
desktop_dir :: proc() -> string {
	if d := os.get_env("XDG_DESKTOP_DIR", context.temp_allocator); d != "" { return d }
	return pjoin({os.get_env("HOME", context.temp_allocator), "Desktop"})
}

install_dir :: proc() -> string { return pjoin({data_home(), "opencode-native"}) }

@(private = "file")
entry_path :: proc() -> string { return pjoin({data_home(), "applications", APP_ID + ".desktop"}) }

@(private = "file")
desk_entry_path :: proc() -> string { return pjoin({desktop_dir(), APP_ID + ".desktop"}) }

@(private = "file")
icon_path :: proc() -> string { return pjoin({data_home(), "icons", "hicolor", "256x256", "apps", APP_ID + ".png"}) }

running_exe :: proc() -> string {
	p, err := os.read_link("/proc/self/exe", context.temp_allocator)
	return err == nil ? p : (len(os.args) > 0 ? os.args[0] : "")
}

same_path :: proc(a, b: string) -> bool {
	ca, _ := filepath.clean(a, context.temp_allocator)
	cb, _ := filepath.clean(b, context.temp_allocator)
	return strings.trim_right(ca, "/") == strings.trim_right(cb, "/")
}

// (the windows' class is set by the platform layer)
set_app_id :: proc() {}

desktop_clean_old :: proc() {}

install_facts :: proc() -> (f: Install_Facts) {
	f.dir = install_dir()
	f.exe = pjoin({f.dir, EXE_NAME})
	f.running = running_exe()
	f.start_lnk = os.exists(entry_path())
	f.desk_lnk = os.exists(desk_entry_path())
	f.record = os.exists(icon_path())
	if data, err := os.read_entire_file(pjoin({f.dir, "version"}), context.temp_allocator); err == nil {
		f.version = strings.trim_space(string(data))
	}
	switch {
	case !os.exists(f.exe):                           f.state = .Not_Installed
	case !same_path(f.exe, f.running):                f.state = .Other_Copy
	case f.start_lnk && f.record && f.version != "":  f.state = .This_Copy
	case:                                             f.state = .Repair
	}
	return
}

@(private = "file")
entry_text :: proc(exe: string) -> string {
	return fmt.tprintf(
		"[Desktop Entry]\nType=Application\nName=%s\nGenericName=opencode client\nComment=A native desktop client for the opencode server\n" +
		"Exec=\"%s\" %%U\nIcon=%s\nTerminal=false\nCategories=Development;\nStartupWMClass=%s\n",
		APP_NAME, exe, APP_ID, APP_ID)
}

@(private = "file")
write_file :: proc(path, text: string, mode: os.Permissions = os.Permissions_Default_File) -> bool {
	_ = os.make_directory_all(filepath.dir(path))
	if os.write_entire_file(path, transmute([]u8)text) != nil { return false }
	_ = os.chmod(path, mode)
	return true
}

desktop_install :: proc(desktop_shortcut: bool) -> (ok: bool, msg: string) {
	f := install_facts()
	if !same_path(f.exe, f.running) {
		_ = os.make_directory_all(f.dir)
		_ = os.remove(f.exe)   // (a copy that runs keeps its own file: the new one is a new file)
		if err := os.copy_file(f.exe, f.running); err != nil { return false, fmt.tprintf("copying the program: %v", err) }
		_ = os.chmod(f.exe, os.Permissions_Default_File | {.Execute_User, .Execute_Group, .Execute_Other})
	}
	if !write_file(icon_path(), string(LOGO_256)) { return false, "writing the icon" }
	if !write_file(entry_path(), entry_text(f.exe)) { return false, "writing the applications menu entry" }
	if desktop_shortcut {
		_ = write_file(desk_entry_path(), entry_text(f.exe), os.Permissions_Default_File | {.Execute_User})
	} else {
		_ = os.remove(desk_entry_path())
	}
	_ = write_file(pjoin({f.dir, "version"}), APP_VERSION + "\n")
	return true, f.exe
}

desktop_uninstall :: proc() -> (ok: bool, deferred: bool, msg: string) {
	f := install_facts()
	_ = os.remove(entry_path())
	_ = os.remove(desk_entry_path())
	_ = os.remove(icon_path())
	_ = os.remove(pjoin({f.dir, "version"}))
	if os.exists(f.exe) {
		if err := os.remove(f.exe); err != nil { return false, false, fmt.tprintf("removing the program: %v", err) }
	}
	_ = os.remove(f.dir)
	return true, false, ""
}

// Starts the installed copy (after an install from a downloaded copy).
launch :: proc(exe: string) -> bool {
	_, err := os.process_start({command = {exe}, working_dir = filepath.dir(exe)})
	return err == nil
}
