// ocntools: the project's machinery, one program: the same steps on Windows and Linux, whatever the shell.
//   odin run tools/ocntools -collection:gt=ext/gui_toolkit/src -out:build/ocntools -- <command>   (build.sh and build.bat: its shortcuts)
//   odin run tools/ocntools -collection:gt=ext/gui_toolkit/src -out:build/ocntools -- help
// What it needs is on the path: git, odin, cargo, curl, tar; gh for what is published.
package ocntools

import tk_changelog "gt:changelog"
import toolbox "gt:toolbox"
import product "../../src/product"

EXIT_USAGE :: 2

// What opencode native is to the toolkit's tools: its name, its repository, where it keeps its version, and what it takes of
// the toolkit (Mermaid; the CDP endpoint in a release build too, which shots, live and measure drive; only the Lucide icons
// it names, in a release build).
OCN_PROJECT :: toolbox.Project{
	name = "opencode-native", repository = "https://github.com/sachahjkl/opencode_native",
	version_file = SETUP_FILE, version_line = "APP_VERSION :: ",
	program = OUT_DEFAULT,
	features = {.Mermaid, .Devtools, .Lucide_Subset},
}

// The licence's commands (licence, paddle): its development pair is the toolkit's, public on purpose.
OCN_LICENCE_TOOL :: toolbox.Licence_Tool{
	dev_seed = "Z3QtbGljZW5jZS1zYW1wbGUtZGV2LXNlZWQtMDAwMSE",
	hint     = "Open this file with opencode native, or paste the key in Settings > Advanced.",
	paddle   = {name = "opencode native licence", description = "A personal, perpetual licence that supports opencode native.", amounts = "supporter=1500", currency = "EUR"},
}

COMMANDS :: [?]toolbox.Command{
	{name = "build", usage = "[debug] [--force]: the Rust library, Ghostty's emulation, the program (GT=<folder>, OUT=<file>)", run = run_build},
	{name = "package", usage = "[version]: the release files of a finished build, in build/dist", run = run_package},
	{name = "update", usage = "keygen | pubkey | manifest | verify: the signed manifests of a release", run = run_update},
	{name = "shots", usage = "[--only name,name] [--out folder] [--build] ...: the pictures of the documentation and the site, the program's own frames", run = run_shots},
	{name = "logo", usage = "[--out folder] [--hint 0|1|2]: the logo (assets/logo*.png) and the icon (opencode-native.ico), drawn by the toolkit's paint package", run = run_logo},
	{name = "vt", usage = "[--check] [--headers folder]: src/vt_gen.odin, the numbers and calls of libghostty-vt, from its headers", run = run_vt},
	{name = "check", usage = "[--out file]: the tests of the program, of its Rust code and of this tool, then a build that must be new", run = run_check},
	{name = "live", usage = "[link|password|prompt|diff|browser|folders] [--exe file]: the real program on the real server, failures made to happen; what it made is removed", run = run_live},
	{name = "clean", usage = "what a live run that did not end left in the demo folder, and only that", run = run_clean},
	{name = "measure", usage = "[find] [--runs n] [--exe file]: the start and the memory of the real program, or a file search; the figures that may be published", run = run_measure},
	{name = "film", usage = "prepare | all | <scene>: the program filmed from inside, its own frames, into build/film", run = run_film},
	{name = "prepare", usage = "<version>: the fragments into CHANGELOG.md with today's date, the version in src/setup.odin and the README", run = run_prepare},
	{name = "ship", usage = "<version> [--dry-run]: from branch release/<version>: CI, tag, release, master, the site, each after the last one's success", run = run_ship},
	{name = "release", usage = "dist <tag> | publish <tag> <folder>: what the release workflow does: this system's files and signed manifests; the GitHub release and the beta channel", run = run_release},
	{name = "fonts_check", usage = "<program>: every font of assets/fonts is in the program, byte for byte", run = run_fonts_check},
	{name = "font_proposals", usage = "[--only id,id] [--toolkit folder] [--exe file]: typefaces tried in the real client, their pictures (shots --font-dir)", run = run_font_proposals},
	{name = "wsl_build", usage = "[folder]: (Linux) this tree copied to a Linux folder and built there, for shots --linux-build", run = run_wsl_build},
	{name = "wsl_client", usage = "<relay> <program> [arguments]: (Linux) the program on Windows' opencode server, for shots --linux", run = run_wsl_client},
	{name = "relay", usage = "<host> <port>: a TCP connection on stdin and stdout (Windows' 127.0.0.1 for a program in WSL)", run = run_relay},
	{name = "site", usage = "build|changelog|meta <site> <out> | card | check [--site folder] [--shot file.png] [--browser program]: the site's pages from site/ and CHANGELOG.md, what is published; the sharing card; the pages in a real browser, served on this machine", run = run_site},
}

main :: proc() {
	tool := OCN_LICENCE_TOOL
	tool.product = product.LICENCE
	lic := toolbox.licence_commands(tool)
	commands := make([dynamic]toolbox.Command)
	own := COMMANDS
	append(&commands, ..own[:])
	append(&commands, tk_changelog.command(OCN_PROJECT), lic[0], lic[1], toolbox.i18n_command({dirs = {"src"}, folder = "i18n"}))
	// (a copy of the tree with no .git, which wsl_build builds from, has the mark too: the root is found by it)
	toolbox.tool_main("ocntools", commands[:], toolbox.ROOT_MARK_DEFAULT)
}
