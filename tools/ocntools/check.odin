package ocntools

import cli "gt:cli"
import toolbox "gt:toolbox"

// The built program starts on Windows: a broken manifest once shipped a program that Windows refused to start, unseen
// by a build that only compiles. The CI's Windows job runs it after its build (check runs it after its release build);
// elsewhere it says nothing.
run_launcher :: proc(args: []string) -> cli.Exit {
	return toolbox.ended(toolbox.check_launcher(OCN_PROJECT))
}
