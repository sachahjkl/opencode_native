package ocn

import "core:fmt"
import "core:os"
import "core:testing"

// This computer's server is where opencode registers it: $XDG_STATE_HOME/opencode/service.json when the variable is set, on
// Windows too (opencode 2.3.0's global-roots.ts). Its address and its password are the file's; the machine's own files are
// not read.
@(test)
the_local_server_follows_xdg_state_home :: proc(t: ^testing.T) {
	tmp, _ := os.temp_dir(context.temp_allocator)
	root := pjoin({tmp, fmt.tprintf("ocn-discover-%d", os.get_pid())})
	defer os.remove_all(root)
	state := pjoin({root, "opencode"})
	testing.expect(t, os.make_directory_all(state) == nil, state)
	registration := `{"id":"x","version":"2.3.0","url":"http://127.0.0.1:28894","pid":1,"password":"from-the-file"}`
	testing.expect(t, os.write_entire_file(pjoin({state, "service.json"}), registration) == nil)

	saved, had := os.lookup_env("XDG_STATE_HOME", context.temp_allocator)
	_ = os.set_env("XDG_STATE_HOME", root)
	defer if had { _ = os.set_env("XDG_STATE_HOME", saved) } else { _ = os.unset_env("XDG_STATE_HOME") }

	cfg := discover_server()
	defer { delete(cfg.host); delete(cfg.password) }
	testing.expect_value(t, cfg.host, "127.0.0.1")
	testing.expect_value(t, cfg.port, u16(28894))
	testing.expect_value(t, cfg.password, "from-the-file")
}
