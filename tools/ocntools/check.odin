package ocntools

import "core:fmt"
import "core:os"
import "core:time"
import cli "gt:cli"
import toolbox "gt:toolbox"

EXE :: ".exe" when ODIN_OS == .Windows else ""
CHECK_OUT :: "build/ocn-new" + EXE
// (not native/target: that one is cargo's own default, and a stale copy of the library has no place beside the crates)
RUST_TEST_DIR :: "../../build/native/test"

// Stops at the first step that fails: what comes after would say nothing.
run_check :: proc(args: []string) -> cli.Exit {
	out := CHECK_OUT
	for i := 0; i < len(args); i += 1 {
		if args[i] == "--out" && i + 1 < len(args) { i += 1; out = args[i]; continue }
		fmt.eprintfln("check: what is %s?", args[i])
		return .Usage
	}
	if !changelog_check() { return .Failed }   // (ROADMAP.md too: the toolkit's changelog check reads it)
	// (a text of the code with no French, or a French text the code no longer has)
	if why := toolbox.i18n_catalogue({"src"}, "i18n/fr.txt", "fr", true); why != "" { fmt.eprintfln("check: %s", why); return .Failed }
	// (a scope opened under a negation ends at once: `if !ui.row(...)`)
	if !toolbox.check_scopes("src") { return .Failed }
	// (the other system's code compiles too: Windows' from Linux, Linux's from Windows is the CI's)
	when ODIN_OS != .Windows { if !toolbox.check_windows(OCN_PROJECT) { return .Failed } }
	// (where the headers are: a build of the emulation is what brings them, and the CI keeps only its library)
	if os.exists(VT_HEADERS) && vt_run(VT_HEADERS, true) != .Done { return .Failed }
	// (the tests link the program's Rust library: built first, as the program is, so that they never link an old one)
	if !build_native(false) { return .Failed }
	// (one test with a window at a time: testkit/session says so; on Linux the program's own flags)
	tests := make([dynamic]string, context.temp_allocator)
	append(&tests, "odin", "test", "src", gt_collection(GT_DEFAULT), "-out:build/test" + EXE, "-define:ODIN_TEST_THREADS=1")
	native_flags := NATIVE_FLAGS
	append(&tests, ..native_flags[:])
	when ODIN_OS != .Windows { flags := LINUX_FLAGS; append(&tests, ..flags[:]) }
	if !run(..tests[:]) { return .Failed }
	if !run("odin", "test", "src/update", gt_collection(GT_DEFAULT), "-out:build/update_test" + EXE) { return .Failed }
	if !run("odin", "test", "tools/ocntools", gt_collection(GT_DEFAULT), "-out:build/ocntools_test" + EXE) { return .Failed }
	if !toolbox.run({"cargo", "test", "--release", "--locked", "--target-dir", RUST_TEST_DIR}, {dir = "native/ocn_native", echo = true}) { return .Failed }

	before, had := os.modification_time_by_path(out)
	if !build_program({gt = GT_DEFAULT, out = out}) { return .Failed }
	after, err := os.modification_time_by_path(out)
	if err != nil { fmt.eprintfln("check: no %s after the build", out); return .Failed }
	if had == nil && time.diff(before, after) <= 0 { fmt.eprintfln("check: %s is not new: the build wrote nothing", out); return .Failed }
	fmt.printfln("check: all passed, %s is new", out)
	return .Done
}

// The built program starts on Windows: a broken manifest once shipped a program that Windows refused to start, unseen
// by a build that only compiles. The CI's Windows job runs it after its build; elsewhere it says nothing.
run_launcher :: proc(args: []string) -> cli.Exit {
	return toolbox.ended(toolbox.check_launcher(OCN_PROJECT))
}
