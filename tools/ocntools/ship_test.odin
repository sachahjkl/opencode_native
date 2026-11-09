package ocntools

import "core:testing"

SETUP :: `APP_VERSION :: "1.2.3"`
CHANGELOG :: "## [1.2.3] - 2026-11-06\n\n[1.2.3]: https://example.org\n"
README :: `<img src="https://img.shields.io/badge/version-1.2.3-fab283">`

@(test)
a_version_is_ready_when_everything_says_it :: proc(t: ^testing.T) {
	testing.expect_value(t, not_ready("1.2.3", "release/1.2.3", SETUP, CHANGELOG, README), "")
}

@(test)
what_disagrees_stops_it :: proc(t: ^testing.T) {
	testing.expect(t, not_ready("1.2.3", "master", SETUP, CHANGELOG, README) != "", "another branch")
	testing.expect(t, not_ready("1.2.3", "release/1.2.3", `APP_VERSION :: "1.2.2"`, CHANGELOG, README) != "", "another version in the program")
	testing.expect(t, not_ready("1.2.3", "release/1.2.3", SETUP, "## [1.2.2] - 2026-11-06\n", README) != "", "no section")
	testing.expect(t, not_ready("1.2.3", "release/1.2.3", SETUP, "## [1.2.3] - 2026-11-06\n", README) != "", "no link")
	testing.expect(t, not_ready("1.2.3", "release/1.2.3", SETUP, CHANGELOG, "version-1.2.2-") != "", "the badge")
}

@(test)
what_is_a_version :: proc(t: ^testing.T) {
	testing.expect(t, version_is_valid("0.15.1"))
	testing.expect(t, version_is_valid("10.0.22"))
	for bad in ([]string{"", "1", "1.2", "1.2.3.4", "1..3", ".1.2", "1.2.", "v1.2.3", "1.2.x"}) {
		testing.expect(t, !version_is_valid(bad), bad)
	}
}

@(test)
a_run_is_the_one_of_this_commit :: proc(t: ^testing.T) {
	list := `[{"databaseId":7,"headSha":"aaa"},{"databaseId":8,"headSha":"bbb"}]`
	testing.expect_value(t, run_of_sha(list, "bbb"), i64(8))
	testing.expect_value(t, run_of_sha(list, "ccc"), i64(0))
	testing.expect_value(t, run_of_sha("not json", "bbb"), i64(0))
}

@(test)
a_manifest_says_its_version :: proc(t: ^testing.T) {
	testing.expect_value(t, manifest_version(`{"channel":"stable","version":"0.15.1","size":3}`), "0.15.1")
	testing.expect_value(t, manifest_version("<html>"), "")
}

@(test)
a_tag_says_its_version_and_whether_it_is_a_beta :: proc(t: ^testing.T) {
	v, beta := tag_version("v0.20.0")
	testing.expect(t, v == "0.20.0" && !beta)
	v, beta = tag_version("v0.21.0-beta.2")
	testing.expect(t, v == "0.21.0" && beta)
}
