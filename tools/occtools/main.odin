// occtools: the project's machinery, one program: the same steps on Windows and Linux, whatever the shell.
//   odin build tools/occtools -out:build/occtools.exe
//   build\occtools help
// What it needs is on the path: git, odin, cargo, curl, tar; gh for what is published.
package occtools

import "core:fmt"
import "core:os"
import "core:strings"

EXIT_USAGE :: 2
ROOT_MARK  :: "odin.version"

Command :: struct {
	name, about: string,
	run:         proc(args: []string) -> int,
}

COMMANDS :: [?]Command{
	{name = "build", about = "[debug] [--force]: the Rust library, Ghostty's emulation, the program (GT=<folder>, OUT=<file>)", run = run_build},
	{name = "package", about = "[version]: the release files of a finished build, in build/dist", run = run_package},
	{name = "update", about = "keygen | pubkey | manifest | verify: the signed manifests of a release", run = run_update},
	{name = "shots", about = "[--only name,name] [--out folder] [--build] ...: the pictures of the documentation and the site, the program's own frames", run = run_shots},
	{name = "vt", about = "[--check] [--headers folder]: src/vt_gen.odin, the numbers and calls of libghostty-vt, from its headers", run = run_vt},
	{name = "check", about = "[--out file]: the tests of the program, of its Rust code and of this tool, then a build that must be new", run = run_check},
	{name = "live", about = "[link|password|prompt|diff|browser|folders] [--exe file]: the real program on the real server, failures made to happen; what it made is removed", run = run_live},
	{name = "clean", about = "what a live run that did not end left in the demo folder, and only that", run = run_clean},
	{name = "measure", about = "[find] [--runs n] [--exe file]: the start and the memory of the real program, or a file search; the figures that may be published", run = run_measure},
	{name = "film", about = "prepare | all | <scene>: the program filmed from inside, its own frames, into build/film", run = run_film},
	{name = "ship", about = "<version> [--dry-run]: from branch release/<version>: CI, tag, release, master, the site, each after the last one's success", run = run_ship},
	{name = "site", about = "build|changelog|meta <site> <out> | card | check [--site folder] [--shot file.png] [--browser program]: the site's pages from site/ and CHANGELOG.md, what is published; the sharing card; the pages in a real browser, served on this machine", run = run_site},
}

main :: proc() {
	if len(os.args) < 2 || os.args[1] == "help" || os.args[1] == "-h" || os.args[1] == "--help" { usage(); return }
	// (a copy of the tree has no .git: tools/wsl_build.sh builds from one, in the folder it starts in)
	if !os.exists(ROOT_MARK) {
		root, ok := capture("git", "rev-parse", "--show-toplevel")
		if !ok { fmt.eprintln("occtools: not in the repository"); os.exit(EXIT_USAGE) }
		if os.set_working_directory(strings.trim_space(root)) != nil { fmt.eprintfln("occtools: cannot work in %s", root); os.exit(EXIT_USAGE) }
	}
	commands := COMMANDS
	for c in commands {
		if c.name == os.args[1] { os.exit(c.run(os.args[2:])) }
	}
	fmt.eprintfln("occtools: no command %s", os.args[1])
	usage()
	os.exit(EXIT_USAGE)
}

usage :: proc() {
	fmt.println("occtools <command> [arguments]")
	commands := COMMANDS
	for c in commands { fmt.printfln("  %-8s %s", c.name, c.about) }
}
