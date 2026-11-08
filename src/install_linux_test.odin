#+build linux
package occ

import "core:fmt"
import "core:os"
import "core:testing"

// Setup up to 0.20.0 wrote these files itself (desktop_linux.odin of that version): the toolkit's integration finds them,
// Setup shows the install as one to repair, and its uninstall removes all of it.
@(test)
an_install_of_the_earlier_setup_is_seen_and_removed :: proc(t: ^testing.T) {
	tmp, _ := os.temp_dir(context.temp_allocator)
	root := pjoin({tmp, fmt.tprintf("ocn-legacy-install-%d", os.get_pid())})
	data := pjoin({root, "data"})
	desk := pjoin({root, "Desktop"})
	defer os.remove_all(root)
	old_data, had_data := os.lookup_env("XDG_DATA_HOME", context.temp_allocator)
	old_desk, had_desk := os.lookup_env("XDG_DESKTOP_DIR", context.temp_allocator)
	_ = os.set_env("XDG_DATA_HOME", data)
	_ = os.set_env("XDG_DESKTOP_DIR", desk)
	defer {
		if had_data { _ = os.set_env("XDG_DATA_HOME", old_data) } else { _ = os.unset_env("XDG_DATA_HOME") }
		if had_desk { _ = os.set_env("XDG_DESKTOP_DIR", old_desk) } else { _ = os.unset_env("XDG_DESKTOP_DIR") }
	}

	dir := pjoin({data, "opencode-native"})
	exe := pjoin({dir, "opencode-native"})
	entry := fmt.tprintf(
		"[Desktop Entry]\nType=Application\nName=%s\nGenericName=opencode client\nComment=A native desktop client for the opencode server. Not affiliated with the OpenCode team.\n" +
		"Exec=\"%s\" %%U\nIcon=%s\nTerminal=false\nCategories=Development;\nStartupWMClass=%s\n",
		APP_NAME, exe, "opencode-native", "opencode-native")
	files := [?][2]string{
		{exe, "#!/bin/sh\n"},
		{pjoin({dir, "version"}), "0.20.0\n"},
		{pjoin({data, "applications", "opencode-native.desktop"}), entry},
		{pjoin({desk, "opencode-native.desktop"}), entry},
		{pjoin({data, "icons", "hicolor", "256x256", "apps", "opencode-native.png"}), string(#load("../assets/logo_256.png"))},
	}
	for f in files {
		testing.expect(t, os.make_directory_all(pjoin({f[0], ".."})) == nil || os.exists(pjoin({f[0], ".."})))
		testing.expect(t, os.write_entire_file(f[0], f[1]) == nil, f[0])
	}
	_ = os.chmod(exe, os.Permissions_Default_File | {.Execute_User})

	f := install_facts()
	testing.expect_value(t, f.dir, dir)
	testing.expect(t, f.exe_there, "the program")
	testing.expect(t, !f.running_it)
	testing.expect(t, f.start_lnk, "the menu entry runs it")
	testing.expect(t, f.desk_lnk, "the copy on the Desktop runs it")
	testing.expect(t, f.record, "the icon")
	testing.expect(t, !f.manifest, "the earlier Setup kept a version file")
	testing.expect_value(t, f.state, Install_State.Repair)

	ok, leftovers, msg := desktop_uninstall()
	testing.expect(t, ok, msg)
	testing.expect_value(t, len(leftovers), 0)
	delete(leftovers)
	for f in files { testing.expectf(t, !os.exists(f[0]), "%s is gone", f[0]) }
	testing.expect(t, !os.exists(dir), "the install folder is gone")
	testing.expect_value(t, install_facts().state, Install_State.Not_Installed)
}
