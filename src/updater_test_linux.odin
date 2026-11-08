package occ

import "core:os"
import "core:testing"
import update "update"

// Linux: the new program is renamed over the old one, executable, and nothing is left beside it.
@(test)
an_update_takes_the_place_of_the_program :: proc(t: ^testing.T) {
	dir :: "build/test_update_place"
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)
	exe :: dir + "/opencode-native"
	_ = os.write_entire_file(exe, "\x7fELF old")

	data := make([]byte, update.MIN_BINARY, context.temp_allocator)
	copy(data, "\x7fELF")
	m := update.Manifest{platform = update.PLATFORM_LINUX_X64, size = i64(len(data)), sha256 = update.sha256_hex(data, context.temp_allocator)}
	testing.expect_value(t, update_place(exe, data, m), "")
	back, _ := os.read_entire_file_from_path(exe, context.temp_allocator)
	testing.expect_value(t, len(back), len(data))
	info, _ := os.stat(exe, context.temp_allocator)
	testing.expect(t, .Execute_User in info.mode, "executable")
	testing.expect(t, !os.exists(exe + ".update"), "nothing left beside it")

	testing.expect(t, update_place(exe, transmute([]byte)string("MZ not this platform"), m) != "", "a PE is refused")
}
