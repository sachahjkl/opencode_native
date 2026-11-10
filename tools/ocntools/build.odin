package ocntools

// The program built, the same steps on Windows and Linux: the Rust library, Ghostty's emulation, the numbers of the version, then
// the program. What is pinned is here: Ghostty by the commit of its tag vt-1.0.0, libghostty-vt's first stable version, Zig by version
// and SHA-256, the crates by native/Cargo.lock (--locked). Ghostty's source and Zig are fetched into build/vt, and nowhere else.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import toolbox "gt:toolbox"

// What the program needs on Linux, built or tested: the text backend is the toolkit's native one, inside the Rust library (no
// DirectWrite here); wgpu-native is a second Rust library: both carry Rust's standard library, whose few unmangled symbols
// (rust_eh_personality) are the same code.
LINUX_FLAGS :: [?]string{"-define:FONT_BACKEND=native", "-define:FONT_NATIVE_LINK=false", "-extra-linker-flags:-Wl,--allow-multiple-definition"}
// On every system: the toolkit's Mermaid diagrams are built into native/ocn_native (gt_mermaid), not linked on their own.
NATIVE_FLAGS :: [?]string{"-define:MERMAID_NATIVE_LINK=false"}

GT_DEFAULT  :: "ext/gui_toolkit"
GT_BESIDE   :: "../gui_toolkit"
OUT_DEFAULT :: "build/opencode-native" + EXE

NATIVE_DIR :: "native"
NATIVE_OUT :: "build/native"
VT_OUT     :: "build/vt"
VT_SOURCE  :: VT_OUT + "/ghostty"
VERSION_H  :: "build/version.h"
SETUP_FILE :: "src/setup.odin"

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

Build :: struct {
	gt, out: string,
	mode:    Build_Mode,
	force:   bool,
}

// How a program is compiled. Dev: at once (-o:minimal: modules apart, kept between builds; a second at most), what every check, every
// try and every picture runs. Release: optimized (-o:speed: a minute), what is published, and what alone is measured for speed (the
// diff's frames in live). Debug: debug information, the console.
Build_Mode :: enum u8 { Dev, Release, Debug }

BUILD_MODE_NAMES := [Build_Mode]string{.Dev = "dev", .Release = "release", .Debug = "debug"}

// The mode a program was built in, as the build wrote it beside it (<program>.mode); "": not known (built otherwise).
build_mode_of :: proc(program: string) -> string { return strings.trim_space(read_text(fmt.tprintf("%s.mode", program))) }

// APP_VERSION in the text of src/setup.odin.
app_version :: proc(setup: string) -> (version: string, ok: bool) {
	at := strings.index(setup, "APP_VERSION")
	if at < 0 { return }
	rest := setup[at:]
	open := strings.index_byte(rest, '"')
	if open < 0 { return }
	rest = rest[open + 1:]
	close := strings.index_byte(rest, '"')
	if close <= 0 { return }
	return rest[:close], true
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

// What the Rust library is made of. (Not native/target, which cargo test may leave there: only the crates' own folders.)
@(private = "file")
native_stamp :: proc() -> string {
	files := make([dynamic]string, context.temp_allocator)
	append(&files, NATIVE_DIR + "/Cargo.toml", NATIVE_DIR + "/Cargo.lock")
	entries, _ := os.read_all_directory_by_path(NATIVE_DIR, context.temp_allocator)
	for e in entries {
		manifest := fmt.tprintf("%s/Cargo.toml", e.fullpath)
		if e.type != .Directory || !os.exists(manifest) { continue }
		append(&files, manifest)
		files_under(fmt.tprintf("%s/src", e.fullpath), &files)
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
		built = toolbox.run({"cargo", "build", "--release", "--locked", "--target", NATIVE_TARGET, "--target-dir", target_dir}, {dir = NATIVE_DIR, echo = true})
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
	// (ReleaseFast: a debug build of it is very slow. The target: the ABI of the linker Odin uses)
	if !toolbox.run({zig, "build", "-Demit-lib-vt=true", "-Doptimize=ReleaseFast", "-Dtarget=" + VT_TARGET}, {dir = VT_SOURCE, echo = true}) { return false }
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

// (the numbers of the VERSIONINFO resource: rewritten only when they change, the resource is built again otherwise)
@(private = "file")
write_version_header :: proc() -> bool {
	version, found := app_version(read_text(SETUP_FILE))
	if !found || toolbox.version_header(version) == "" { fmt.eprintfln("build: no version of three numbers in %s", SETUP_FILE); return false }
	if why := toolbox.write_version_header(VERSION_H, version); why != "" { fmt.eprintfln("build: %s", why); return false }
	return true
}

@(private = "file")
odin_is_pinned :: proc(odin: string) -> bool {
	if os.get_env("OCN_ANY_ODIN", context.temp_allocator) != "" { return true }
	want := strings.trim_space(read_text("odin.version"))
	got, code := toolbox.capture({odin, "version"})
	if code == 0 && strings.contains(got, want) { return true }
	fmt.eprintfln("This tree needs Odin %s (odin.version); found: %s", want, strings.trim_space(got))
	fmt.eprintln("Install that release, or set OCN_ANY_ODIN=1 to build anyway.")
	return false
}

// The toolkit: the one asked for, else the submodule, else a copy beside this repository.
toolkit_folder :: proc(asked: string) -> (gt: string, ok: bool) {
	if asked != "" { return asked, os.exists(fmt.tprintf("%s/src/ui", asked)) }
	if os.exists(GT_DEFAULT + "/src/ui") { return GT_DEFAULT, true }
	if os.exists(GT_BESIDE + "/src/ui") { return GT_BESIDE, true }
	return "", false
}

// The collection of the toolkit at `gt` (its packages are in its src folder).
gt_collection :: proc(gt: string) -> string { return fmt.tprintf("-collection:gt=%s/src", gt) }

build_program :: proc(b: Build) -> bool {
	gt, found := toolkit_folder(b.gt)
	if !found { fmt.eprintln("the toolkit is missing: git submodule update --init"); return false }
	out := b.out != "" ? b.out : OUT_DEFAULT
	odin := os.get_env("ODIN", context.temp_allocator)
	if odin == "" { odin = "odin" }
	if !odin_is_pinned(odin) { return false }
	if !build_native(b.force) || !build_vt(b.force) { return false }
	if !make_folder(filepath.dir(out)) { return false }

	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, odin, "build", "src", gt_collection(gt), fmt.tprintf("-out:%s", out), "-vet")
	native_flags := NATIVE_FLAGS
	append(&cmd, ..native_flags[:])
	when ODIN_OS == .Windows {
		if !write_version_header() { return false }
		// (the C runtime linked in: no vcruntime140.dll to ship)
		append(&cmd, "-resource:res/opencode-native.rc", "-extra-linker-flags:/NODEFAULTLIB:vcruntime.lib /DEFAULTLIB:libvcruntime.lib")
		if b.mode != .Debug { append(&cmd, "-subsystem:windows") }
	} else {
		flags := LINUX_FLAGS
		append(&cmd, ..flags[:])
	}
	switch b.mode {
	case .Dev:     append(&cmd, "-o:minimal")
	case .Release: append(&cmd, "-o:speed")
	case .Debug:   append(&cmd, "-debug")
	}
	if !run(..cmd[:]) { return false }
	if !write_text(fmt.tprintf("%s.mode", out), BUILD_MODE_NAMES[b.mode]) { return false }
	fmt.printfln("built %s, %s (toolkit: %s)", out, BUILD_MODE_NAMES[b.mode], gt)
	return true
}

run_build :: proc(args: []string) -> int {
	b := Build {
		gt  = os.get_env("GT", context.temp_allocator),
		out = os.get_env("OUT", context.temp_allocator),
	}
	for a in args {
		switch a {
		case "debug":   b.mode = .Debug
		case "release": b.mode = .Release
		case "--force": b.force = true
		case:
			fmt.eprintfln("build: what is %s?", a)
			return EXIT_USAGE
		}
	}
	return build_program(b) ? 0 : 1
}
