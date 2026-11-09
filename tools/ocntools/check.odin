package ocntools

import "core:fmt"
import "core:os"
import "core:time"
import toolbox "gt:toolbox"

EXE :: ".exe" when ODIN_OS == .Windows else ""
CHECK_OUT :: "build/ocn-new" + EXE
// (not native/target: that one is cargo's own default, and a stale copy of the library has no place beside the crates)
RUST_TEST_DIR :: "../../build/native/test"

// Stops at the first step that fails: what comes after would say nothing.
run_check :: proc(args: []string) -> int {
	out := CHECK_OUT
	for i := 0; i < len(args); i += 1 {
		if args[i] == "--out" && i + 1 < len(args) { i += 1; out = args[i]; continue }
		fmt.eprintfln("check: what is %s?", args[i])
		return EXIT_USAGE
	}
	// (where the headers are: a build of the emulation is what brings them, and the CI keeps only its library)
	if os.exists(VT_HEADERS) && vt_run(VT_HEADERS, true) != 0 { return 1 }
	// (one test with a window at a time: testkit/session says so; on Linux the program's own flags)
	tests := make([dynamic]string, context.temp_allocator)
	append(&tests, "odin", "test", "src", gt_collection(GT_DEFAULT), "-out:build/test" + EXE, "-define:ODIN_TEST_THREADS=1")
	when ODIN_OS != .Windows { flags := LINUX_FLAGS; append(&tests, ..flags[:]) }
	if !run(..tests[:]) { return 1 }
	if !run("odin", "test", "src/update", gt_collection(GT_DEFAULT), "-out:build/update_test" + EXE) { return 1 }
	if !run("odin", "test", "tools/ocntools", gt_collection(GT_DEFAULT), "-out:build/ocntools_test" + EXE) { return 1 }
	if !toolbox.run({"cargo", "test", "--release", "--locked", "--target-dir", RUST_TEST_DIR}, {dir = "native/ocn_native", echo = true}) { return 1 }

	before, had := os.modification_time_by_path(out)
	if !build_program({gt = GT_DEFAULT, out = out}) { return 1 }
	after, err := os.modification_time_by_path(out)
	if err != nil { fmt.eprintfln("check: no %s after the build", out); return 1 }
	if had == nil && time.diff(before, after) <= 0 { fmt.eprintfln("check: %s is not new: the build wrote nothing", out); return 1 }
	fmt.printfln("check: all passed, %s is new", out)
	return 0
}
