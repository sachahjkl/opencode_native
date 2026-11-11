package ocntools

import "core:strings"
import "core:testing"
import tk_changelog "gt:changelog"

SETUP_SAMPLE :: "package ocn\n\n// The version.\nAPP_VERSION :: \"0.45.0\"\nAPP_NAME :: \"opencode native\"\n"
README_SAMPLE :: `<a href="CHANGELOG.md"><img src="https://img.shields.io/badge/version-0.45.0-fab283" alt="version 0.45.0"></a>`

@(test)
prepare_writes_the_version_in_the_source :: proc(t: ^testing.T) {
	text, ok := with_app_version(SETUP_SAMPLE, "0.46.0")
	testing.expect(t, ok)
	testing.expect_value(t, text, "package ocn\n\n// The version.\nAPP_VERSION :: \"0.46.0\"\nAPP_NAME :: \"opencode native\"\n")
	v, _ := app_version(text)
	testing.expect_value(t, v, "0.46.0")
}

@(test)
prepare_keeps_a_crlf_source :: proc(t: ^testing.T) {
	crlf, _ := strings.replace_all(SETUP_SAMPLE, "\n", "\r\n", context.temp_allocator)
	text, ok := with_app_version(crlf, "1.0.0")
	testing.expect(t, ok)
	testing.expect(t, strings.contains(text, "APP_VERSION :: \"1.0.0\"\r\nAPP_NAME"), "the line keeps its end")
	testing.expect_value(t, strings.count(text, "\r\n"), strings.count(crlf, "\r\n"))
}

@(test)
prepare_without_a_version_says_so :: proc(t: ^testing.T) {
	text, ok := with_app_version("package ocn\n// APP_VERSION is elsewhere\n", "1.0.0")
	testing.expect(t, !ok, "no APP_VERSION line, none written")
	testing.expect_value(t, text, "package ocn\n// APP_VERSION is elsewhere\n")
}

// What prepare writes is what ship's not_ready asks.
@(test)
a_prepared_version_is_ready :: proc(t: ^testing.T) {
	setup, _ := with_app_version(SETUP_SAMPLE, "0.46.0")
	readme := tk_changelog.with_badge(README_SAMPLE, "0.46.0")
	testing.expect_value(t, readme, `<a href="CHANGELOG.md"><img src="https://img.shields.io/badge/version-0.46.0-fab283" alt="version 0.46.0"></a>`)
	changes := "## [0.46.0] - 2026-11-12\n\n### Added\n- **One**\n\n[0.46.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.46.0\n"
	testing.expect_value(t, not_ready("0.46.0", "release/0.46.0", setup, changes, readme), "")
}
