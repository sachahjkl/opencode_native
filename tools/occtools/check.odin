package occtools

import "core:fmt"
import "core:os"
import "core:time"

EXE :: ".exe" when ODIN_OS == .Windows else ""
CHECK_OUT :: "build/occ-new" + EXE
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
	if !run("odin", "test", "src", "-collection:gt=ext/gui_toolkit", "-out:build/test" + EXE) { return 1 }
	if !run("odin", "test", "tools/occtools", "-out:build/occtools_test" + EXE) { return 1 }
	if !run_in({dir = "native/occ_native"}, "cargo", "test", "--release", "--locked", "--target-dir", RUST_TEST_DIR) { return 1 }

	before, had := os.modification_time_by_path(out)
	how := Run{env = env_with("GT", fmt.tprintf("OUT=%s", out))}
	built := run_in(how, "cmd", "/c", "build.bat") when ODIN_OS == .Windows else run_in(how, "bash", "build.sh")
	if !built { return 1 }
	after, err := os.modification_time_by_path(out)
	if err != nil { fmt.eprintfln("check: no %s after the build", out); return 1 }
	if had == nil && time.diff(before, after) <= 0 { fmt.eprintfln("check: %s is not new: the build wrote nothing", out); return 1 }
	fmt.printfln("check: all passed, %s is new", out)
	return 0
}
