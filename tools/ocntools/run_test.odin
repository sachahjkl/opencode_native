package ocntools

import "core:testing"
import toolbox "gt:toolbox"

// Everything `ship` does rests on this: a step that fails must say so.
@(test)
a_command_that_fails_is_a_failure :: proc(t: ^testing.T) {
	testing.expect(t, run("git", "--version"), "git answers")
	testing.expect(t, !run("git", "rev-parse", "--verify", "-q", "refs/heads/no-such-branch"), "exit code 1")
	testing.expect(t, !run("no-such-program-here"), "nothing to start")
	_, code := toolbox.capture({"git", "rev-parse", "--verify", "-q", "refs/heads/no-such-branch"})
	testing.expect_value(t, code, 1)
}

@(test)
a_batch_file_that_is_not_there_is_a_failure :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		testing.expect(t, !run("cmd", "/c", "no-such-file.bat"), "cmd says so by its exit code")
		testing.expect(t, !run("cmd", "/c", "exit 3"), "a code of its own")
	}
}
