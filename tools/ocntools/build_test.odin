package ocntools

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import toolbox "gt:toolbox"

// What the toolkit's check and build must keep of what opencode native's own did: every step on each system, the Rust
// tests and the emulation's headers, every test package, the build that never overwrites the running program, the
// pinned Odin, and the linker flags of each system.
@(test)
the_build_keeps_what_ocn_needs :: proc(t: ^testing.T) {
	o := build_options()
	for system in ([]runtime.Odin_OS_Type{.Linux, .Windows}) {
		steps := toolbox.check_steps(o, system)
		want := toolbox.Check_Steps{.Changelog, .Scopes, .Checks, .Catalogues, .Notices, .Odin_Check, .Tool, .Tests, .Release_Build}
		testing.expectf(t, want <= steps, "%v: the check lost %v", system, want - steps)
	}
	testing.expect(t, .Check_Windows in toolbox.check_steps(o, .Linux))
	// (no macOS code; the Rust library carries the toolkit's crates, which the toolkit then does not build)
	testing.expect(t, .Check_Darwin not_in toolbox.check_steps(o, .Linux))
	testing.expect(t, o.native_carried)
	testing.expect(t, .Launcher in toolbox.check_steps(o, .Windows))
	testing.expect_value(t, len(o.checks), 2)
	testing.expect(t, o.prepare != nil)
	paths := make([dynamic]string, context.temp_allocator)
	for p in o.tests { append(&paths, p.path) }
	testing.expect_value(t, strings.join(paths[:], " ", context.temp_allocator), "src src/update tools/ocntools")
	testing.expect(t, o.tests[0].one_thread)
	testing.expect_value(t, o.iterate, toolbox.Build_Mode.Dev)
	testing.expect(t, o.fresh && o.pinned_odin && o.notices)
	testing.expect_value(t, toolbox.linker_flag(o.project, .Windows, "build", true), "-extra-linker-flags:" + toolbox.WINDOWS_STATIC_VCRUNTIME)
	testing.expect_value(t, toolbox.linker_flag(o.project, .Linux, "build", true), "-extra-linker-flags:" + toolbox.LINUX_LINK + " -s")
	testing.expect_value(t, toolbox.linker_flag(o.project, .Linux, "build", false), "-extra-linker-flags:" + toolbox.LINUX_LINK)
	for d in ([]string{"-define:MERMAID_NATIVE_LINK=false", "-define:IMAGE_WEBP=true", "-define:IMAGE_WEBP_NATIVE_LINK=false"}) {
		testing.expectf(t, slice.contains(o.defines, d), "%s on every system", d)
	}
	testing.expect(t, slice.contains(o.linux_defines, "-define:FONT_NATIVE_LINK=false"))
}

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
