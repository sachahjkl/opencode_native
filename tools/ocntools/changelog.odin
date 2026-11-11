package ocntools

// CHANGELOG.md is made of fragments (changelog.d/README.md), never edited by hand: the toolkit's changelog package does the work,
// this file says what opencode native is to it and writes the version where the program keeps it.
//   ocntools changelog new <type> <text>   one fragment, named from the text's bold summary
//   ocntools changelog check               every fragment well formed, no [Unreleased] in CHANGELOG.md, the version the last released
//   ocntools changelog preview             what the next version brings
//   ocntools prepare <version>             the release's files: the section, its link, APP_VERSION, the README's badge; ship then publishes them

import "core:fmt"
import "core:os"
import "core:strings"
import tk_changelog "gt:changelog"

CHANGELOG_LINK :: "https://github.com/sachahjkl/opencode_native/releases/tag/v%s"

// What opencode native is to the toolkit's changelog: this checkout, its releases' link, where it keeps its version.
changelog_options :: proc() -> tk_changelog.Options {
	return {root = ".", link = CHANGELOG_LINK, version = changelog_version, set_version = changelog_set_version}
}

@(private = "file")
changelog_version :: proc(root: string) -> string {
	v, _ := app_version(read_text(SETUP_FILE))
	return v
}

// APP_VERSION and the README's badge: what assemble writes after CHANGELOG.md.
@(private = "file")
changelog_set_version :: proc(root, version: string) -> bool {
	setup, found := with_app_version(read_text(SETUP_FILE), version)
	if !found { fmt.eprintfln("prepare: no APP_VERSION in %s", SETUP_FILE); return false }
	if os.write_entire_file(SETUP_FILE, transmute([]byte)setup) != nil { return false }
	readme := tk_changelog.with_badge(read_text("README.md"), version)
	return os.write_entire_file("README.md", transmute([]byte)readme) == nil
}

// The text of src/setup.odin with APP_VERSION set to `version`. ok = false: it has no APP_VERSION line.
with_app_version :: proc(setup, version: string) -> (text: string, ok: bool) {
	lines := strings.split(setup, "\n", context.temp_allocator)
	for l, i in lines {
		if !strings.has_prefix(l, "APP_VERSION ") { continue }
		// (the line's own end, "\r" on a checkout with CRLF, stays)
		cr := strings.has_suffix(l, "\r") ? "\r" : ""
		lines[i] = fmt.tprintf("APP_VERSION :: \"%s\"%s", version, cr)
		ok = true
	}
	if !ok { return setup, false }
	return strings.join(lines, "\n", context.temp_allocator), true
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
	if changelog_version(".") == "" { append(&errors, fmt.tprintf("APP_VERSION not found in %s", SETUP_FILE)) }
	if !say_errors("changelog", errors[:]) { return false }
	fmt.printfln("changelog: %d fragments, well formed", n)
	return true
}

run_changelog :: proc(args: []string) -> int {
	USAGE :: "changelog new <Added|Changed|Deprecated|Removed|Fixed|Security> <text> | check | preview"
	if len(args) == 0 { fmt.eprintln(USAGE); return EXIT_USAGE }
	switch args[0] {
	case "new":
		if len(args) < 3 { fmt.eprintln(USAGE); return EXIT_USAGE }
		path, why := tk_changelog.new_fragment(".", args[1], "", strings.join(args[2:], " ", context.temp_allocator))
		if why != "" { fmt.eprintfln("changelog: %s", why); return 1 }
		fmt.println(path)
		return 0
	case "check":
		return changelog_check() ? 0 : 1
	case "preview":
		text, errors := tk_changelog.preview(".")
		if !say_errors("changelog", errors[:]) { return 1 }
		fmt.print(text != "" ? text : "changelog: no fragment, nothing to publish\n")
		return 0
	}
	fmt.eprintln(USAGE)
	return EXIT_USAGE
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
