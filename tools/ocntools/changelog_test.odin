package ocntools

import "core:testing"
import tk_changelog "gt:changelog"
import toolbox "gt:toolbox"

SETUP_SAMPLE :: "package ocn\n\n// The version.\nAPP_VERSION :: \"0.45.0\"\nAPP_NAME :: \"opencode native\"\n"
README_SAMPLE :: `<a href="CHANGELOG.md"><img src="https://img.shields.io/badge/version-0.45.0-fab283" alt="version 0.45.0"></a>`

// What prepare writes is what ship's not_ready asks.
@(test)
a_prepared_version_is_ready :: proc(t: ^testing.T) {
	setup, _ := toolbox.version_set(SETUP_SAMPLE, OCN_PROJECT.version_line, "0.46.0")
	readme := tk_changelog.with_badge(README_SAMPLE, "0.46.0")
	testing.expect_value(t, readme, `<a href="CHANGELOG.md"><img src="https://img.shields.io/badge/version-0.46.0-fab283" alt="version 0.46.0"></a>`)
	changes := "## [0.46.0] - 2026-11-12\n\n### Added\n- **One**\n\n[0.46.0]: https://github.com/sachahjkl/opencode_native/releases/tag/v0.46.0\n"
	testing.expect_value(t, not_ready("0.46.0", "release/0.46.0", setup, changes, readme), "")
}
