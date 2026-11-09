// ocntools: the project's machinery, one program: the same steps on Windows and Linux, whatever the shell.
//   odin run tools/ocntools -collection:gt=ext/gui_toolkit/src -out:build/ocntools -- <command>   (build.sh and build.bat: its shortcuts)
//   odin run tools/ocntools -collection:gt=ext/gui_toolkit/src -out:build/ocntools -- help
// What it needs is on the path: git, odin, cargo, curl, tar; gh for what is published.
package ocntools

import "core:fmt"
import "core:os"
import "core:strings"
import toolbox "gt:toolbox"

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
	{name = "logo", about = "[--out folder] [--hint 0|1|2]: the logo (assets/logo*.png) and the icon (opencode-native.ico), drawn by the toolkit's paint package", run = run_logo},
	{name = "vt", about = "[--check] [--headers folder]: src/vt_gen.odin, the numbers and calls of libghostty-vt, from its headers", run = run_vt},
	{name = "check", about = "[--out file]: the tests of the program, of its Rust code and of this tool, then a build that must be new", run = run_check},
	{name = "live", about = "[link|password|prompt|diff|browser|folders] [--exe file]: the real program on the real server, failures made to happen; what it made is removed", run = run_live},
	{name = "clean", about = "what a live run that did not end left in the demo folder, and only that", run = run_clean},
	{name = "measure", about = "[find] [--runs n] [--exe file]: the start and the memory of the real program, or a file search; the figures that may be published", run = run_measure},
	{name = "film", about = "prepare | all | <scene>: the program filmed from inside, its own frames, into build/film", run = run_film},
	{name = "ship", about = "<version> [--dry-run]: from branch release/<version>: CI, tag, release, master, the site, each after the last one's success", run = run_ship},
	{name = "release", about = "dist <tag> | publish <tag> <folder>: what the release workflow does: this system's files and signed manifests; the GitHub release and the beta channel", run = run_release},
	{name = "fonts_check", about = "<program>: every font of assets/fonts is in the program, byte for byte", run = run_fonts_check},
	{name = "font_proposals", about = "[--only id,id] [--toolkit folder] [--exe file]: typefaces tried in the real client, their pictures (shots --font-dir)", run = run_font_proposals},
	{name = "wsl_build", about = "[folder]: (Linux) this tree copied to a Linux folder and built there, for shots --linux-build", run = run_wsl_build},
	{name = "wsl_client", about = "<relay> <program> [arguments]: (Linux) the program on Windows' opencode server, for shots --linux", run = run_wsl_client},
	{name = "relay", about = "<host> <port>: a TCP connection on stdin and stdout (Windows' 127.0.0.1 for a program in WSL)", run = run_relay},
	{name = "site", about = "build|changelog|meta <site> <out> | card | check [--site folder] [--shot file.png] [--browser program]: the site's pages from site/ and CHANGELOG.md, what is published; the sharing card; the pages in a real browser, served on this machine", run = run_site},
}

main :: proc() {
	if len(os.args) < 2 || os.args[1] == "help" || os.args[1] == "-h" || os.args[1] == "--help" { usage(); return }
	// (a copy of the tree has no .git: ocntools wsl_build builds from one, in the folder it starts in)
	if !os.exists(ROOT_MARK) {
		root, code := toolbox.capture({"git", "rev-parse", "--show-toplevel"})
		if code != 0 { fmt.eprintln("ocntools: not in the repository"); os.exit(EXIT_USAGE) }
		if os.set_working_directory(strings.trim_space(root)) != nil { fmt.eprintfln("ocntools: cannot work in %s", root); os.exit(EXIT_USAGE) }
	}
	commands := COMMANDS
	for c in commands {
		if c.name == os.args[1] { os.exit(c.run(os.args[2:])) }
	}
	fmt.eprintfln("ocntools: no command %s", os.args[1])
	usage()
	os.exit(EXIT_USAGE)
}

usage :: proc() {
	fmt.println("ocntools <command> [arguments]")
	commands := COMMANDS
	for c in commands { fmt.printfln("  %-8s %s", c.name, c.about) }
}
