package ocntools

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

CHANGELOG_SAMPLE :: "# Changelog\r\n\r\n## [0.2.0] - 2026-01-02\r\n\r\n### Added\r\n- **Two**\r\n\r\n## [0.1.0] - 2026-01-01\r\n\r\n### Added\r\n- **One**\r\n\r\n[0.2.0]: https://x\r\n"

@(test)
the_notes_say_where_it_runs :: proc(t: ^testing.T) {
	tmp, _ := os.temp_dir(context.temp_allocator)
	root, _ := filepath.join({tmp, fmt.tprintf("ocntools_notes_%d", os.get_pid())}, context.temp_allocator)
	_ = os.make_directory(root)
	defer os.remove_all(root)
	changelog, _ := filepath.join({root, "CHANGELOG.md"}, context.temp_allocator)
	_ = os.write_entire_file(changelog, transmute([]byte)string(CHANGELOG_SAMPLE))
	notes, ok := release_notes(root, "0.2.0")
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(notes, "### Added\n- **Two**\n\n**Windows 10 and 11 (x64)**"))
}

@(test)
a_key_outside_a_work_tree_only :: proc(t: ^testing.T) {
	testing.expect(t, in_git_tree("tools/ocntools/some.key"), "this repository is one")
}

@(test)
the_scroll_goes_towards_the_text :: proc(t: ^testing.T) {
	testing.expect_value(t, scroll_notches(10), 1)
	testing.expect_value(t, scroll_notches(-10), -1)
	testing.expect_value(t, scroll_notches(360), 3)
	testing.expect_value(t, scroll_notches(100000), SCROLL_MOST)
}

@(test)
the_pictures_of_a_run :: proc(t: ^testing.T) {
	pictures := PICTURES
	all, on_linux := 0, 0
	for p in pictures {
		if wanted(p, nil, false) { all += 1 }
		if wanted(p, nil, true) { on_linux += 1 }
	}
	testing.expect_value(t, all, len(pictures) - 1)
	testing.expect_value(t, on_linux, 1)
	only := []string{"palette"}
	testing.expect(t, wanted({name = "palette"}, only, false))
	testing.expect(t, !wanted({name = "find"}, only, false))
	seen := make(map[string]bool, context.temp_allocator)
	for p in pictures {
		testing.expectf(t, !seen[p.name], "%s twice: the second would overwrite the first", p.name)
		seen[p.name] = true
	}
}
