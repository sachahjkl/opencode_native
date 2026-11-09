package ocntools

// What the release workflow does, as commands of this tool (.github/workflows/release.yml):
//   release dist <tag>             (after build release, on each system) the tag must be APP_VERSION's (vX.Y.Z, or vX.Y.Z-beta.N for
//                                  a beta); the release files of this system in build/dist (package), and the signed update
//                                  manifests of its channels: a beta goes to the beta channel, a release to both ($UPDATE_SIGNING_KEY)
//   release publish <tag> <folder> (with gh, GH_TOKEN and GH_REPO) the files of every system in <folder>: their SHA256SUMS.txt, the
//                                  GitHub release (made from the CHANGELOG's section, NOTES.md, when it does not exist yet; its
//                                  files replaced when it does), and the beta channel's fixed address (the release channel-beta)

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import update "gt:update"
import ocn_update "../../src/update"
import toolbox "gt:toolbox"

run_release :: proc(args: []string) -> int {
	switch {
	case len(args) == 2 && args[0] == "dist":    return release_dist(args[1])
	case len(args) == 3 && args[0] == "publish": return release_publish(args[1], args[2])
	}
	fmt.eprintln("release dist <tag> | publish <tag> <folder>")
	return EXIT_USAGE
}

// The version of a tag (v0.20.0, v0.20.0-beta.1: 0.20.0), and whether it is a beta.
tag_version :: proc(tag: string) -> (version: string, beta: bool) {
	v := strings.trim_prefix(tag, "v")
	if i := strings.index(v, "-beta"); i >= 0 { return v[:i], true }
	return v, false
}

@(private = "file")
release_dist :: proc(tag: string) -> int {
	version, beta := tag_version(tag)
	source, found := app_version(read_text(SETUP_FILE))
	if !found || source != version { fmt.eprintfln("release: tag %s does not match APP_VERSION %s (%s)", tag, source, SETUP_FILE); return 1 }
	if run_package({version}) != 0 { return 1 }
	file := fmt.tprintf("%s/%s", DIST_DIR, update.expected_file_name(ocn_update.PRODUCT, version, update.PLATFORM, context.temp_allocator))
	channels := beta ? []string{"beta"} : []string{"stable", "beta"}
	for c in channels {
		out := fmt.tprintf("%s/%s", DIST_DIR, update.manifest_name(update.PLATFORM, c, context.temp_allocator))
		if manifest(file, version, c, out) != 0 { fmt.eprintfln("release: the %s manifest could not be signed", c); return 1 }
	}
	return 0
}

NOT_THEIRS_NOTE :: "\n---\n\nAn independent project: not built by the OpenCode team, and not affiliated with them.\n"
BETA_RELEASE    :: "channel-beta"

@(private = "file")
release_publish :: proc(tag, folder: string) -> int {
	version, beta := tag_version(tag)
	entries, err := os.read_all_directory_by_path(folder, context.temp_allocator)
	if err != nil { fmt.eprintfln("release: cannot read %s", folder); return 1 }
	programs := make([dynamic]string, context.temp_allocator)   // opencode-native-*: the files of the release
	manifests := make([dynamic]string, context.temp_allocator)  // update-*: their signed manifests
	for e in entries {
		if strings.has_prefix(e.name, "opencode-native-") { append(&programs, e.name) }
		if strings.has_prefix(e.name, "update-") { append(&manifests, e.name) }
	}
	slice.sort(programs[:])
	slice.sort(manifests[:])

	sums := strings.builder_make(context.temp_allocator)
	for name in programs {
		data, rerr := os.read_entire_file(fmt.tprintf("%s/%s", folder, name), context.temp_allocator)
		if rerr != nil { fmt.eprintfln("release: cannot read %s", name); return 1 }
		ctx: sha2.Context_256
		sha2.init_256(&ctx)
		sha2.update(&ctx, data)
		digest: [sha2.DIGEST_SIZE_256]byte
		sha2.final(&ctx, digest[:])
		fmt.sbprintf(&sums, "%s  %s\n", string(hex.encode(digest[:], context.temp_allocator)), name)
	}
	if os.write_entire_file(fmt.tprintf("%s/SHA256SUMS.txt", folder), strings.to_string(sums)) != nil { return 1 }
	fmt.print(strings.to_string(sums))

	files := make([dynamic]string, context.temp_allocator)
	append(&files, ..programs[:])
	append(&files, "SHA256SUMS.txt")
	append(&files, ..manifests[:])
	in_folder := toolbox.Run{dir = folder, echo = true}
	if _, code := toolbox.capture({"gh", "release", "view", tag}); code == 0 {
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, "gh", "release", "upload", tag)
		append(&cmd, ..files[:])
		append(&cmd, "--clobber")
		if !toolbox.run(cmd[:], in_folder) { return 1 }
	} else {
		notes := fmt.tprintf("%s/NOTES.md", folder)
		text := read_text(notes)
		if os.write_entire_file(notes, strings.concatenate({text, NOT_THEIRS_NOTE}, context.temp_allocator)) != nil { return 1 }
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, "gh", "release", "create", tag)
		append(&cmd, ..files[:])
		if beta { append(&cmd, "--prerelease") }
		append(&cmd, "--title", fmt.tprintf("opencode native %s", version), "--notes-file", "NOTES.md")
		if !toolbox.run(cmd[:], in_folder) { return 1 }
	}

	// the beta channel's fixed address: the programs and their beta manifests
	beta_files := make([dynamic]string, context.temp_allocator)
	for name in programs { if !strings.has_suffix(name, ".tar.gz") { append(&beta_files, name) } }
	for name in manifests { if strings.contains(name, "-beta.json") { append(&beta_files, name) } }
	if _, code := toolbox.capture({"gh", "release", "view", BETA_RELEASE}); code != 0 {
		if !run("gh", "release", "create", BETA_RELEASE, "--prerelease", "--title", "Beta channel", "--notes", "What the beta channel of the updater reads.") { return 1 }
	}
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "gh", "release", "upload", BETA_RELEASE)
	append(&cmd, ..beta_files[:])
	append(&cmd, "--clobber")
	return toolbox.run(cmd[:], in_folder) ? 0 : 1
}
