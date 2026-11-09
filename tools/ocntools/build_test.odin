package ocntools

import "core:strings"
import "core:testing"

@(test)
the_version_is_read_from_the_source :: proc(t: ^testing.T) {
	v, ok := app_version("package x\nAPP_VERSION :: \"0.17.0\"\nOTHER :: \"1\"\n")
	testing.expect(t, ok)
	testing.expect_value(t, v, "0.17.0")
	_, none := app_version("package x\n")
	testing.expect(t, !none, "no version, none invented")
}

@(test)
the_header_wants_three_numbers :: proc(t: ^testing.T) {
	h := version_header("1.22.3")
	testing.expect(t, strings.contains(h, "#define OCN_VER_MINOR 22\r\n"))
	testing.expect(t, strings.contains(h, `#define OCN_VER_STRING "1.22.3"`))
	testing.expect_value(t, version_header("1.2"), "")
	testing.expect_value(t, version_header("1.2.3-beta"), "")
	testing.expect_value(t, version_header("1..3"), "")
}

CHANGELOG_SAMPLE :: "# Changelog\r\n\r\n## [0.2.0] - 2026-01-02\r\n\r\n### Added\r\n- **Two**\r\n\r\n## [0.1.0] - 2026-01-01\r\n\r\n### Added\r\n- **One**\r\n\r\n[0.2.0]: https://x\r\n"

@(test)
a_section_ends_at_the_next_version :: proc(t: ^testing.T) {
	two, ok := changelog_section(CHANGELOG_SAMPLE, "0.2.0")
	testing.expect(t, ok)
	testing.expect_value(t, two, "### Added\n- **Two**")
	one, _ := changelog_section(CHANGELOG_SAMPLE, "0.1.0")
	testing.expect(t, strings.has_prefix(one, "### Added\n- **One**"))
	_, none := changelog_section(CHANGELOG_SAMPLE, "0.3.0")
	testing.expect(t, !none, "a version with no section is said")
	_, partial := changelog_section(CHANGELOG_SAMPLE, "0.2")
	testing.expect(t, !partial, "0.2 is not 0.2.0")
}

@(test)
the_notes_say_where_it_runs :: proc(t: ^testing.T) {
	notes, ok := release_notes(CHANGELOG_SAMPLE, "0.2.0")
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
