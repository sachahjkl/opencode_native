// occtools: the project's machinery, one program: the same steps on Windows and Linux, whatever the shell.
//   odin build tools/occtools -out:build/occtools.exe
//   build\occtools help
// What it needs is on the path: git, odin, cargo; gh for what is published.
package occtools

import "core:fmt"
import "core:os"
import "core:strings"

EXIT_USAGE :: 2

Command :: struct {
	name, about: string,
	run:         proc(args: []string) -> int,
}

COMMANDS := []Command{
	{name = "check", about = "[--out file]: the tests of the program, of its Rust code and of this tool, then a build that must be new", run = run_check},
	{name = "live", about = "[link|password|prompt] [--exe file]: the real program on the real server, failures made to happen; what it made is removed", run = run_live},
	{name = "clean", about = "what a live run that did not end left in the demo folder, and only that", run = run_clean},
	{name = "measure", about = "[find] [--runs n] [--exe file]: the start and the memory of the real program, or a file search; the figures that may be published", run = run_measure},
	{name = "film", about = "prepare | all | <scene>: the program filmed from inside, its own frames, into build/film", run = run_film},
	{name = "ship", about = "<version> [--dry-run]: from branch release/<version>: CI, tag, release, master, the site, each after the last one's success", run = run_ship},
}

main :: proc() {
	if len(os.args) < 2 || os.args[1] == "help" || os.args[1] == "-h" || os.args[1] == "--help" { usage(); return }
	root, ok := capture("git", "rev-parse", "--show-toplevel")
	if !ok { fmt.eprintln("occtools: not in the repository"); os.exit(EXIT_USAGE) }
	if os.set_working_directory(strings.trim_space(root)) != nil { fmt.eprintfln("occtools: cannot work in %s", root); os.exit(EXIT_USAGE) }
	for c in COMMANDS {
		if c.name == os.args[1] { os.exit(c.run(os.args[2:])) }
	}
	fmt.eprintfln("occtools: no command %s", os.args[1])
	usage()
	os.exit(EXIT_USAGE)
}

usage :: proc() {
	fmt.println("occtools <command> [arguments]")
	for c in COMMANDS { fmt.printfln("  %-8s %s", c.name, c.about) }
}
