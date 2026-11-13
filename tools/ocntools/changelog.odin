package ocntools

// CHANGELOG.md is made of fragments (changelog.d/README.md), never edited by hand: the toolkit's changelog package does the work,
// this file says what opencode native is to it and writes the version where the program keeps it.
//   ocntools changelog new|check|preview   the toolkit's command (changelog.command, OCN_PROJECT)
//   ocntools prepare <version>             the release's files: the section, its link, APP_VERSION, the README's badge; ship then publishes them

import "core:fmt"
import "core:os"
import toolbox "gt:toolbox"
import tk_changelog "gt:changelog"

CHANGELOG_LINK :: "https://github.com/sachahjkl/opencode_native/releases/tag/v%s"

// What opencode native is to the toolkit's changelog: this checkout, its releases' link, where it keeps its version.
changelog_options :: proc() -> tk_changelog.Project_Options {
	return {root = ".", link = CHANGELOG_LINK, version = changelog_version, set_version = changelog_set_version}
}

@(private = "file")
changelog_version :: proc(root: string, _: rawptr) -> string {
	return toolbox.project_version(OCN_PROJECT)
}

// APP_VERSION and the README's badge: what assemble writes after CHANGELOG.md.
@(private = "file")
changelog_set_version :: proc(root, version: string, _: rawptr) -> bool {
	setup, found := toolbox.version_set(read_text(SETUP_FILE), OCN_PROJECT.version_line, version)
	if !found { fmt.eprintfln("prepare: no APP_VERSION in %s", SETUP_FILE); return false }
	if os.write_entire_file(SETUP_FILE, transmute([]byte)setup) != nil { return false }
	readme := tk_changelog.with_badge(read_text("README.md"), version)
	return os.write_entire_file("README.md", transmute([]byte)readme) == nil
}

// The errors said; whether there were none.
@(private = "file")
say_errors :: proc(what: string, errors: []string) -> bool {
	for e in errors { fmt.eprintfln("%s: %s", what, e) }
	return len(errors) == 0
}

// What `check` and `changelog check` run.
changelog_check :: proc(release := "") -> bool {
	errors, n := tk_changelog.check(changelog_options(), release)
	if changelog_version(".", nil) == "" { append(&errors, fmt.tprintf("APP_VERSION not found in %s", SETUP_FILE)) }
	if !say_errors("changelog", errors[:]) { return false }
	fmt.printfln("changelog: %d fragments, well formed", n)
	return true
}

// The files of a release, on its branch release/<version>: what ship's not_ready then finds. Nothing is committed.
run_prepare :: proc(args: []string) -> int {
	if len(args) != 1 { fmt.eprintln("prepare <version>"); return EXIT_USAGE }
	version := args[0]
	if !version_is_valid(version) { fmt.eprintfln("prepare: %s is not a version", version); return EXIT_USAGE }
	if !changelog_check() { return 1 }
	n, errors := tk_changelog.assemble(changelog_options(), version)   // (and set_version: APP_VERSION, the badge)
	if !say_errors("prepare", errors[:]) { return 1 }
	if !changelog_check(version) { return 1 }
	fmt.printfln("prepare: %s, %d entries in CHANGELOG.md, APP_VERSION and the README's badge; commit them with the deletion of the fragments", version, n)
	return 0
}
