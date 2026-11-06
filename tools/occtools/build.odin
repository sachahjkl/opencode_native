package occtools

// The program built, the same steps on Windows and Linux: the Rust library, Ghostty's emulation, the numbers of the version, then
// the program. What is pinned is here: Ghostty by commit (the one Ghostling, its reference client, builds against), Zig by version
// and SHA-256, the crates by native/Cargo.lock (--locked). Ghostty's source and Zig are fetched into build/vt, and nowhere else.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import update "../../src/update"

GT_DEFAULT  :: "ext/gui_toolkit"
GT_BESIDE   :: "../gui_toolkit"
OUT_DEFAULT :: "build/opencode-native" + EXE

NATIVE_DIR :: "native"
NATIVE_OUT :: "build/native"
VT_OUT     :: "build/vt"
VT_SOURCE  :: VT_OUT + "/ghostty"
VERSION_H  :: "build/version.h"
SETUP_FILE :: "src/setup.odin"

GHOSTTY_COMMIT :: "f64f4aca2c29b554d111b36c3d946a9bddd159ff"
GHOSTTY_REMOTE :: "https://github.com/ghostty-org/ghostty.git"
ZIG_VERSION    :: "0.16.0"

when ODIN_OS == .Windows {
	NATIVE_LIB      :: NATIVE_OUT + "/occ_native.lib"
	NATIVE_TARGET   :: "x86_64-pc-windows-msvc"
	NATIVE_BUILT    :: NATIVE_OUT + "/target/" + NATIVE_TARGET + "/release/occ_native.lib"
	VT_LIB          :: VT_OUT + "/ghostty-vt-static.lib"
	VT_BUILT_SUFFIX :: "ghostty-vt-static.lib"
	VT_TARGET       :: "x86_64-windows-msvc"
	ZIG_SYSTEM      :: "windows"
	ZIG_ARCHIVE     :: ".zip"
	ZIG_SHA256      :: "68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e"
} else {
	NATIVE_LIB      :: NATIVE_OUT + "/libocc_native.a"
	NATIVE_TARGET   :: ""
	NATIVE_BUILT    :: NATIVE_OUT + "/target/release/libocc_native.a"
	VT_LIB          :: VT_OUT + "/libghostty-vt.a"
	VT_BUILT_SUFFIX :: ".a"
	VT_TARGET       :: "x86_64-linux-gnu"
	ZIG_SYSTEM      :: "linux"
	ZIG_ARCHIVE     :: ".tar.xz"
	ZIG_SHA256      :: "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00"
}
ZIG_NAME :: "zig-x86_64-" + ZIG_SYSTEM + "-" + ZIG_VERSION

Build :: struct {
	gt, out:      string,
	debug, force: bool,
}

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

// What the VERSIONINFO resource reads. "": not three numbers.
version_header :: proc(version: string) -> string {
	parts := strings.split(version, ".", context.temp_allocator)
	if len(parts) != 3 { return "" }
	for p in parts {
		if p == "" { return "" }
		for c in p { if c < '0' || c > '9' { return "" } }
	}
	return fmt.tprintf("#define OCC_VER_MAJOR %s\r\n#define OCC_VER_MINOR %s\r\n#define OCC_VER_PATCH %s\r\n#define OCC_VER_STRING \"%s\"\r\n", parts[0], parts[1], parts[2], version)
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
	return update.sha256_hex(transmute([]byte)strings.to_string(all), context.temp_allocator)
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
	if !force && stamped(NATIVE_LIB, stamp_file, stamp) { fmt.printfln("occ_native up to date in %s", NATIVE_OUT); return true }
	if !make_folder(NATIVE_OUT) { return false }
	target_dir := "../" + NATIVE_OUT + "/target"
	built := false
	when ODIN_OS == .Windows {
		built = run_in({dir = NATIVE_DIR}, "cargo", "build", "--release", "--locked", "--target", NATIVE_TARGET, "--target-dir", target_dir)
	} else {
		built = run_in({dir = NATIVE_DIR}, "cargo", "build", "--release", "--locked", "--target-dir", target_dir)
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
	if !run("curl", "-fsSL", "-o", archive, url) { return }
	data, read_err := os.read_entire_file(archive, context.temp_allocator)
	if read_err != nil { return }
	if update.sha256_hex(data, context.temp_allocator) != ZIG_SHA256 {
		fmt.eprintln("build: Zig: the SHA-256 does not match")
		_ = os.remove(archive)
		return
	}
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
	if !run_in({dir = VT_SOURCE}, zig, "build", "-Demit-lib-vt=true", "-Doptimize=ReleaseFast", "-Dtarget=" + VT_TARGET) { return false }
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
	header := found ? version_header(version) : ""
	if header == "" { fmt.eprintfln("build: no version of three numbers in %s", SETUP_FILE); return false }
	if read_text(VERSION_H) == header { return true }
	return write_text(VERSION_H, header)
}

@(private = "file")
odin_is_pinned :: proc(odin: string) -> bool {
	if os.get_env("OCC_ANY_ODIN", context.temp_allocator) != "" { return true }
	want := strings.trim_space(read_text("odin.version"))
	got, ok := capture(odin, "version")
	if ok && strings.contains(got, want) { return true }
	fmt.eprintfln("This tree needs Odin %s (odin.version); found: %s", want, strings.trim_space(got))
	fmt.eprintln("Install that release, or set OCC_ANY_ODIN=1 to build anyway.")
	return false
}

// The toolkit: the one asked for, else the submodule, else a copy beside this repository.
toolkit_folder :: proc(asked: string) -> (gt: string, ok: bool) {
	if asked != "" { return asked, os.exists(fmt.tprintf("%s/ui", asked)) }
	if os.exists(GT_DEFAULT + "/ui") { return GT_DEFAULT, true }
	if os.exists(GT_BESIDE + "/ui") { return GT_BESIDE, true }
	return "", false
}

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
	append(&cmd, odin, "build", "src", fmt.tprintf("-collection:gt=%s", gt), fmt.tprintf("-out:%s", out), "-vet")
	when ODIN_OS == .Windows {
		if !write_version_header() { return false }
		// (the C runtime linked in: no vcruntime140.dll to ship)
		append(&cmd, "-resource:res/opencode-native.rc", "-extra-linker-flags:/NODEFAULTLIB:vcruntime.lib /DEFAULTLIB:libvcruntime.lib")
		if !b.debug { append(&cmd, "-subsystem:windows") }
	} else {
		// the text backend is the toolkit's native one, inside the Rust library (no DirectWrite here); wgpu-native is a second Rust
		// library: both carry Rust's standard library, whose few unmangled symbols (rust_eh_personality) are the same code
		append(&cmd, "-define:FONT_BACKEND=native", "-define:FONT_NATIVE_LINK=false", "-extra-linker-flags:-Wl,--allow-multiple-definition")
	}
	append(&cmd, b.debug ? "-debug" : "-o:speed")
	if !run(..cmd[:]) { return false }
	fmt.printfln("built %s (toolkit: %s)", out, gt)
	return true
}

run_build :: proc(args: []string) -> int {
	b := Build {
		gt  = os.get_env("GT", context.temp_allocator),
		out = os.get_env("OUT", context.temp_allocator),
	}
	for a in args {
		switch a {
		case "debug":   b.debug = true
		case "--force": b.force = true
		case:
			fmt.eprintfln("build: what is %s?", a)
			return EXIT_USAGE
		}
	}
	return build_program(b) ? 0 : 1
}
