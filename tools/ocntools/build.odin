package ocntools

// The program's build, test and check are the toolkit's (toolbox.build_commands, src/md/infrastructure/build-commands.md
// of the toolkit); this file gives what is opencode native's own: the Rust library and Ghostty's emulation, built before
// any odin command of the program (prepare), and the checks of that Rust and of the emulation's headers. What is pinned
// is here: Ghostty by the commit of its tag vt-1.0.0, libghostty-vt's first stable version, Zig by version and SHA-256,
// the crates by native/Cargo.lock (--locked). Ghostty's source and Zig are fetched into build/vt, and nowhere else.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import cli "gt:cli"
import tk_changelog "gt:changelog"
import toolbox "gt:toolbox"

EXE         :: toolbox.EXE_SUFFIX
GT_DEFAULT  :: toolbox.TOOLKIT_DEFAULT
OUT_DEFAULT :: "build/opencode-native" + EXE

NATIVE_DIR :: "native"
GT_NATIVE_DIR :: GT_DEFAULT + "/native"   // the toolkit's crates ocn_native takes by path (gt_mermaid)
NATIVE_OUT :: "build/native"
VT_OUT     :: "build/vt"
VT_SOURCE  :: VT_OUT + "/ghostty"
SETUP_FILE :: "src/setup.odin"
// (not native/target: that one is cargo's own default, and a stale copy of the library has no place beside the crates)
RUST_TEST_DIR :: "../../build/native/test"

GHOSTTY_COMMIT :: "0fa3d577a5614150ff8e2c152de5fb9d5c6d2dec"
GHOSTTY_REMOTE :: "https://github.com/ghostty-org/ghostty.git"
ZIG_VERSION    :: "0.17.0"

when ODIN_OS == .Windows {
	NATIVE_LIB      :: NATIVE_OUT + "/ocn_native.lib"
	NATIVE_TARGET   :: "x86_64-pc-windows-msvc"
	NATIVE_BUILT    :: NATIVE_OUT + "/target/" + NATIVE_TARGET + "/release/ocn_native.lib"
	VT_LIB          :: VT_OUT + "/ghostty-vt-static.lib"
	VT_BUILT_SUFFIX :: "ghostty-vt-static.lib"
	VT_TARGET       :: "x86_64-windows-msvc"
	ZIG_SYSTEM      :: "windows"
	ZIG_ARCHIVE     :: ".zip"
	ZIG_SHA256      :: "b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428"
} else {
	NATIVE_LIB      :: NATIVE_OUT + "/libocn_native.a"
	NATIVE_TARGET   :: ""
	NATIVE_BUILT    :: NATIVE_OUT + "/target/release/libocn_native.a"
	VT_LIB          :: VT_OUT + "/libghostty-vt.a"
	VT_BUILT_SUFFIX :: ".a"
	VT_TARGET       :: "x86_64-linux-gnu"
	ZIG_SYSTEM      :: "linux"
	ZIG_ARCHIVE     :: ".tar.xz"
	ZIG_SHA256      :: "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026"
}
ZIG_NAME :: "zig-x86_64-" + ZIG_SYSTEM + "-" + ZIG_VERSION

// The tests: the program's take the toolkit's one test session (one at a time); the tool's link nothing of the program.
@(rodata) OCN_TESTS := [?]toolbox.Test_Package{{path = "src", one_thread = true}, {path = "src/update"}, {path = OCN_TOOL}}
@(rodata) OCN_CHECKS := [?]toolbox.Build_Check{check_vt_headers, check_rust}
OCN_TOOL :: "tools/ocntools"
// (a variable, as OCN_PROJECT is: a constant's slice would live on the stack of build_options)
OCN_I18N := toolbox.I18n_Catalogues{dirs = {"src"}, folder = "i18n"}

// What the toolkit's build, test and check get: GT=<folder> another toolkit (the toolkit reads it), OUT=<file> the
// program elsewhere. Dev is the build with no word: every check, every try and every picture runs one, in a second.
// Fresh: a build never writes the program that runs (Windows refuses it); the check's release build takes its place.
build_options :: proc() -> toolbox.Build_Options {
	p := OCN_PROJECT
	if out := os.get_env("OUT", context.temp_allocator); out != "" { p.program = out }
	return {
		project = p, changelog_command = tk_changelog.command(p), tests = OCN_TESTS[:], tool = OCN_TOOL,
		catalogues = OCN_I18N, notices = true, prepare = prepare_native, checks = OCN_CHECKS[:],
		iterate = .Dev, fresh = true, pinned_odin = true,
	}
}

// build --force: the Rust library and Ghostty's emulation built again, whatever their stamps say.
@(private = "file")
force_native: bool

// The toolkit's build with --force, which is this program's alone.
run_build :: proc(args: []string) -> cli.Exit {
	release, debug := false, false
	for a in args {
		switch a {
		case "dev":     // (the build with no word, Build_Options.iterate)
		case "release": release = true
		case "debug":   debug = true
		case "--force": force_native = true
		case:
			fmt.eprintfln("build: what is %s?", a)
			return .Usage
		}
	}
	if release && debug { fmt.eprintln("build: release or debug, not both"); return .Usage }
	return toolbox.ended(toolbox.program_build(build_options(), release, debug))
}

// Every file under `dir`.
files_under :: proc(dir: string, out: ^[dynamic]string) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	for e in entries {
		if e.type == .Directory { files_under(e.fullpath, out); continue }
		append(out, e.fullpath)
	}
}

// What every odin command of the program links of its own: the Rust library, then Ghostty's emulation.
@(private = "file")
prepare_native :: proc(p: toolbox.Project) -> bool { return build_native(force_native) && build_vt(force_native) }

// (where the headers are: a build of the emulation is what brings them, and the CI keeps only its library)
@(private = "file")
check_vt_headers :: proc(p: toolbox.Project) -> bool { return !os.exists(VT_HEADERS) || vt_run(VT_HEADERS, true) == .Done }

@(private = "file")
check_rust :: proc(p: toolbox.Project) -> bool {
	return toolbox.run({"cargo", "test", "--release", "--locked", "--target-dir", RUST_TEST_DIR}, {dir = "native/ocn_native", echo = true})
}

// What the Rust library is made of. (Not native/target, which cargo test may leave there: only the crates' own folders.)
@(private = "file")
native_stamp :: proc() -> string {
	files := make([dynamic]string, context.temp_allocator)
	append(&files, NATIVE_DIR + "/Cargo.toml", NATIVE_DIR + "/Cargo.lock")
	// (its crates, and the toolkit's it takes by path: a new toolkit's gt_mermaid is a new library)
	for dir in ([]string{NATIVE_DIR, GT_NATIVE_DIR}) {
		entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		for e in entries {
			manifest := fmt.tprintf("%s/Cargo.toml", e.fullpath)
			if e.type != .Directory || !os.exists(manifest) { continue }
			append(&files, manifest)
			files_under(fmt.tprintf("%s/src", e.fullpath), &files)
		}
	}
	slice.sort(files[:])
	all := strings.builder_make(context.temp_allocator)
	for f in files { strings.write_string(&all, read_text(f)) }
	return toolbox.sha256_hex(transmute([]byte)strings.to_string(all), context.temp_allocator)
}

@(private = "file")
stamped :: proc(lib, stamp_file, stamp: string) -> bool {
	return os.exists(lib) && strings.trim_space(read_text(stamp_file)) == stamp
}

@(private = "file")
write_text :: proc(path, text: string) -> bool {
	if os.write_entire_file(path, transmute([]byte)text) == nil { return true }
	fmt.eprintfln("build: cannot write %s", path)
	return false
}

@(private = "file")
build_native :: proc(force: bool) -> bool {
	stamp_file := NATIVE_OUT + "/STAMP"
	stamp := native_stamp()
	if !force && stamped(NATIVE_LIB, stamp_file, stamp) { fmt.printfln("ocn_native up to date in %s", NATIVE_OUT); return true }
	if !make_folder(NATIVE_OUT) { return false }
	target_dir := "../" + NATIVE_OUT + "/target"
	built := false
	when ODIN_OS == .Windows {
		// (the static C runtime, as Odin's programs link it: libwebp's C, compiled by the cc crate, otherwise asks for the
		// DLL's __imp_malloc and the like, which no Odin program links; the toolkit's tk build_native does the same)
		crt := "target." + NATIVE_TARGET + ".rustflags=['-C','target-feature=+crt-static']"
		built = toolbox.run({"cargo", "build", "--release", "--locked", "--target", NATIVE_TARGET, "--target-dir", target_dir, "--config", crt}, {dir = NATIVE_DIR, echo = true})
	} else {
		built = toolbox.run({"cargo", "build", "--release", "--locked", "--target-dir", target_dir}, {dir = NATIVE_DIR, echo = true})
	}
	if !built { return false }
	if os.copy_file(NATIVE_LIB, NATIVE_BUILT) != nil { fmt.eprintfln("build: no %s", NATIVE_BUILT); return false }
	if !write_text(stamp_file, stamp) { return false }
	fmt.printfln("built %s", NATIVE_LIB)
	return true
}

// Zig, checked against its SHA-256 before anything of it runs.
@(private = "file")
fetch_zig :: proc() -> (zig: string, ok: bool) {
	relative := fmt.tprintf("%s/%s/zig%s", VT_OUT, ZIG_NAME, EXE)
	// (not os.get_absolute_path: on Linux it fails for what is not there yet, and the first time Zig is not)
	here, err := os.get_working_directory(context.temp_allocator)
	if err != nil { fmt.eprintfln("build: no working directory: %v", err); return }
	absolute := fmt.tprintf("%s/%s", here, relative)
	if os.exists(relative) { return absolute, true }
	archive := VT_OUT + "/zig" + ZIG_ARCHIVE
	url := fmt.tprintf("https://ziglang.org/download/%s/%s%s", ZIG_VERSION, ZIG_NAME, ZIG_ARCHIVE)
	if why := toolbox.download_pinned(url, archive, ZIG_SHA256); why != "" { fmt.eprintfln("build: Zig: %s", why); return }
	if !run("tar", "-xf", archive, "-C", VT_OUT) { return }
	_ = os.remove(archive)
	return absolute, true
}

// The fetch of every package libghostty-vt's build may need, before the build. Zig 0.17.0's build runner crashes at random
// while it fetches lazy packages during a build on a cold cache (a general protection fault on Linux, a segmentation
// fault on Windows: 0.75.0's release failed on both, three times, -j1 too); with every package fetched first, the build
// fetches nothing and went through every time on a cold cache.
vt_fetch_command :: proc(zig: string) -> []string {
	args := make([]string, 3, context.temp_allocator)
	args[0], args[1], args[2] = zig, "build", "--fetch=all"
	return args
}

// The build of libghostty-vt. ReleaseFast: a debug build of it is very slow. The target: the ABI of the linker Odin uses.
vt_build_command :: proc(zig: string) -> []string {
	args := make([]string, 5, context.temp_allocator)
	args[0], args[1], args[2], args[3], args[4] = zig, "build", "-Demit-lib-vt=true", "-Doptimize=ReleaseFast", "-Dtarget=" + VT_TARGET
	return args
}

@(private = "file")
build_vt :: proc(force: bool) -> bool {
	stamp_file := VT_OUT + "/STAMP"
	stamp := GHOSTTY_COMMIT + " " + ZIG_VERSION + " " + ZIG_SYSTEM
	if !force && stamped(VT_LIB, stamp_file, stamp) { fmt.printfln("libghostty-vt up to date in %s", VT_OUT); return true }
	if !make_folder(VT_OUT) { return false }
	zig, has_zig := fetch_zig()
	if !has_zig { return false }
	if !os.exists(VT_SOURCE + "/.git") {
		if !make_folder(VT_SOURCE) { return false }
		if !run("git", "-C", VT_SOURCE, "init", "-q") { return false }
		if !run("git", "-C", VT_SOURCE, "remote", "add", "origin", GHOSTTY_REMOTE) { return false }
	}
	if !run("git", "-C", VT_SOURCE, "fetch", "-q", "--depth", "1", "origin", GHOSTTY_COMMIT) { return false }
	if !run("git", "-C", VT_SOURCE, "-c", "advice.detachedHead=false", "checkout", "-q", "--force", GHOSTTY_COMMIT) { return false }
	if !toolbox.run(vt_fetch_command(zig), {dir = VT_SOURCE, echo = true}) { return false }
	if !toolbox.run(vt_build_command(zig), {dir = VT_SOURCE, echo = true}) { return false }
	made := make([dynamic]string, context.temp_allocator)
	files_under(VT_SOURCE + "/zig-out/lib", &made)
	for f in made {
		if !strings.has_suffix(f, VT_BUILT_SUFFIX) { continue }
		if os.copy_file(VT_LIB, f) != nil { return false }
		if !write_text(stamp_file, stamp) { return false }
		fmt.printfln("built %s", VT_LIB)
		return true
	}
	fmt.eprintfln("build: Zig made no %s", VT_BUILT_SUFFIX)
	return false
}

// The collection of the toolkit at `gt` (its packages are in its src folder).
gt_collection :: proc(gt: string) -> string { return fmt.tprintf("-collection:gt=%s/src", gt) }
