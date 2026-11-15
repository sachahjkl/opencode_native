#+build linux
package ocn

import "core:fmt"
import "core:os"
import "core:testing"
import setup "gt:setup"

// The person's files of the earlier layout (~/.config/opencode-native, the logs in ~/.local/state/opencode-native) move
// once into the vendor's folder, and the program reads them there; an install goes to ~/.local/opt/FromentSoftware/
// OpencodeNative. Every folder is the test's own: none of the machine's is read or written.
@(test)
the_folders_are_the_vendors :: proc(t: ^testing.T) {
	tmp, _ := os.temp_dir(context.temp_allocator)
	root := pjoin({tmp, fmt.tprintf("ocn-folders-%d", os.get_pid())})
	defer os.remove_all(root)
	NAMES :: [?]string{"HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"}
	saved: [len(NAMES)]struct { value: string, had: bool }
	for name, i in NAMES {
		saved[i].value, saved[i].had = os.lookup_env(name, context.temp_allocator)
		dir := pjoin({root, name})
		testing.expect(t, os.make_directory_all(dir) == nil, dir)
		_ = os.set_env(name, dir)
	}
	defer for name, i in NAMES {
		if saved[i].had { _ = os.set_env(name, saved[i].value) } else { _ = os.unset_env(name) }
	}

	old_config := pjoin({root, "XDG_CONFIG_HOME", APP_FOLDER_BEFORE})
	old_logs := pjoin({root, "XDG_STATE_HOME", APP_FOLDER_BEFORE, "logs"})
	testing.expect(t, os.make_directory_all(old_config) == nil && os.make_directory_all(old_logs) == nil)
	testing.expect(t, os.write_entire_file(pjoin({old_config, "servers.txt"}), "s = 1\n") == nil)
	// (an install of the earlier Setup, in the earlier data folder: its menu entry names it, so it stays)
	old_install := pjoin({root, "XDG_DATA_HOME", APP_FOLDER_BEFORE})
	testing.expect(t, os.make_directory_all(old_install) == nil)
	testing.expect(t, os.write_entire_file(pjoin({old_install, "opencode-native"}), "#!/bin/sh\n") == nil)

	folders_move()
	testing.expect(t, os.exists(pjoin({old_install, "opencode-native"})), "the earlier install stayed where its menu entry names it")
	testing.expect_value(t, config_dir(), pjoin({root, "XDG_CONFIG_HOME", "FromentSoftware", "OpencodeNative"}))
	data, err := os.read_entire_file(servers_path(), context.temp_allocator)
	testing.expect(t, err == nil && string(data) == "s = 1\n", "the servers came along")
	testing.expect(t, os.is_dir(pjoin({root, "XDG_STATE_HOME", "FromentSoftware", "OpencodeNative", "logs"})), "the logs came along")
	testing.expect(t, !os.exists(old_config), "the old folder is gone")

	f := setup.facts(setup_options())
	testing.expect_value(t, f.dir, pjoin({root, "HOME", ".local", "opt", "FromentSoftware", "OpencodeNative"}))
	testing.expect_value(t, f.state, setup.State.Not_Installed)
}
