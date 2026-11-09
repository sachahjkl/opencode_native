package ocntools

// The release files of a finished build, in build/dist. On Windows the program, one file, its SHA-256 and the notes of the release;
// on Linux an archive with the program, the licences and a README, and the program alone (for the updater).

import "core:fmt"
import "core:os"
import "core:strings"
import update "gt:update"
import ocn_update "../../src/update"
import toolbox "gt:toolbox"

DIST_DIR  :: "build/dist"
STAGE_DIR :: "build/stage"

NOTES_TAIL :: `

**Windows 10 and 11 (x64)**: one executable; run it, or install it for your user from its Setup (title bar menu > Setup...).
**Linux (x64)**: the archive holds one program; run it, or ./opencode-native --install (an entry in the applications menu). Needs Vulkan, libxkbcommon, fontconfig, Wayland or X11.

It finds the opencode server of the computer by itself (another one: --url, or the status bar's server menu).`

LINUX_README :: `opencode native %s for Linux (x64): a native desktop client for the opencode server.
An independent project: not built by the OpenCode team, and not affiliated with them.

  ./opencode-native              run it (it finds the opencode server of this computer by itself)
  ./opencode-native --install    install it for your user: ~/.local/share/opencode-native, an entry in the applications
                                 menu, its icon (or from its Setup: title bar menu > Setup...)
  ./opencode-native --url=https://host:port --password=...    another server

Needs: Vulkan (mesa-vulkan-drivers or your GPU's driver, libvulkan1), libxkbcommon, fontconfig, and Wayland or X11.
On NixOS: nix profile add git+https://github.com/sachahjkl/opencode_native (or start it once with nix-ld or steam-run and --install:
the installed copy gets its libraries from nix-build and runs by itself).
https://github.com/sachahjkl/opencode_native
`

// The CHANGELOG's section of a version: from its heading to the next one.
changelog_section :: proc(changelog, version: string) -> (section: string, ok: bool) {
	heading := fmt.tprintf("## [%s]", version)
	lines := strings.split_lines(changelog, context.temp_allocator)
	start := -1
	end := len(lines)
	for line, i in lines {
		if start < 0 {
			if strings.has_prefix(line, heading) { start = i + 1 }
			continue
		}
		if strings.has_prefix(line, "## [") { end = i; break }
	}
	if start < 0 { return "", false }
	joined := strings.join(lines[start:end], "\n", context.temp_allocator)
	return strings.trim_space(joined), true
}

release_notes :: proc(changelog, version: string) -> (notes: string, ok: bool) {
	section, found := changelog_section(changelog, version)
	if !found { return "", false }
	return strings.concatenate({section, NOTES_TAIL}, context.temp_allocator), true
}

// What is published is optimized: a program built otherwise (build.bat with no word, debug) is no release.
@(private = "file")
package_is_release :: proc(program: string) -> bool {
	if mode := build_mode_of(program); mode != "release" {
		fmt.eprintfln("package: %s was built %s, not for release: build release (build.bat release, ./build.sh release)", program, mode != "" ? mode : "in a way not known")
		return false
	}
	return true
}

@(private = "file")
package_windows :: proc(version: string) -> bool {
	program := "build/opencode-native.exe"
	if !os.exists(program) { fmt.eprintfln("package: %s is missing: build it first", program); return false }
	if !package_is_release(program) { return false }
	_ = os.remove_all(DIST_DIR)
	if !make_folder(DIST_DIR) { return false }
	name := fmt.tprintf("opencode-native-%s-windows-x64.exe", version)
	path := fmt.tprintf("%s/%s", DIST_DIR, name)
	if os.copy_file(path, program) != nil { return false }
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return false }
	sum := toolbox.sha256_hex(data, context.temp_allocator)
	sums := fmt.tprintf("%s  %s", sum, name)
	if os.write_entire_file(DIST_DIR + "/SHA256SUMS.txt", transmute([]byte)sums) != nil { return false }
	notes, found := release_notes(read_text("CHANGELOG.md"), version)
	if !found { fmt.eprintfln("package: CHANGELOG.md has no section for %s", version); return false }
	if os.write_entire_file(DIST_DIR + "/NOTES.md", transmute([]byte)notes) != nil { return false }
	fmt.printfln("packaged %s (%s)", path, sum)
	return true
}

@(private = "file")
package_linux :: proc(version: string) -> bool {
	program := "build/opencode-native"
	if !os.exists(program) { fmt.eprintfln("package: %s is missing: build it first", program); return false }
	if !package_is_release(program) { return false }
	name := fmt.tprintf("opencode-native-%s", version)
	stage := fmt.tprintf("%s/%s", STAGE_DIR, name)
	_ = os.remove_all(STAGE_DIR)
	if !make_folder(stage) || !make_folder(DIST_DIR) { return false }
	inside := fmt.tprintf("%s/opencode-native", stage)
	if os.copy_file(inside, program) != nil { return false }
	if !run("chmod", "+x", inside) { return false }   // (what is copied here is bytes: it must stay a program in the archive)

	licences := make([dynamic]string, context.temp_allocator)
	files_under("assets/fonts", &licences)
	append(&licences, "assets/GHOSTTY-LICENSE.txt", "LICENSE")
	for f in licences {
		if !strings.has_suffix(f, "LICENSE.txt") && f != "LICENSE" { continue }
		base := f[strings.last_index_any(f, "/\\") + 1:]
		if os.copy_file(fmt.tprintf("%s/%s", stage, base), f) != nil { fmt.eprintfln("package: no %s", f); return false }
	}
	readme := fmt.tprintf(LINUX_README, version)
	if os.write_entire_file(fmt.tprintf("%s/README.txt", stage), transmute([]byte)readme) != nil { return false }
	archive := fmt.tprintf("%s/%s-linux-x64.tar.gz", DIST_DIR, name)
	if !run("tar", "-C", STAGE_DIR, "-czf", archive, name) { return false }
	// the program alone too: what the updater downloads (update.expected_file_name)
	alone := fmt.tprintf("%s/%s", DIST_DIR, update.expected_file_name(ocn_update.PRODUCT, version, update.PLATFORM_LINUX_X64, context.temp_allocator))
	if os.copy_file(alone, program) != nil || !run("chmod", "+x", alone) { return false }
	fmt.printfln("packaged %s, %s", archive, alone)
	return true
}

run_package :: proc(args: []string) -> int {
	version := ""
	if len(args) > 1 { fmt.eprintln("package: [version]"); return EXIT_USAGE }
	if len(args) == 1 {
		version = args[0]
	} else {
		found: bool
		version, found = app_version(read_text(SETUP_FILE))
		if !found { fmt.eprintfln("package: no version in %s", SETUP_FILE); return 1 }
	}
	done := package_windows(version) when ODIN_OS == .Windows else package_linux(version)
	return done ? 0 : 1
}
