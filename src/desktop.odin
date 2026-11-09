// What opencode native is to the toolkit's desktop package (gt:desktop, ext/gui_toolkit/docs/desktop.md), and what Setup
// reads and does with it: the state of the install (setup.odin shows it), install, uninstall. The package writes and
// removes every file and key; the per-system files (desktop_windows.odin, desktop_linux.odin) keep the words of each system,
// and on Linux the copy of the menu entry on the Desktop, which the package has no part for.
//
// The installed copy:
//   Windows  %LOCALAPPDATA%\Programs\opencode-native\opencode-native.exe (or the folder the Settings > Apps record names),
//            Start menu\Programs\opencode native.lnk (and one on the Desktop) with the AppUserModelID,
//            HKCU\...\CurrentVersion\Uninstall\OpencodeNative, the Settings > Apps entry
//   Linux    ~/.local/share/opencode-native/opencode-native, ~/.local/share/applications/opencode-native.desktop (and a
//            copy on the Desktop), ~/.local/share/icons/hicolor/256x256/apps/opencode-native.png
// and in the install folder the manifest (MANIFEST_NAME): the version and the files placed, which the uninstall removes.
//
// The identity's names and marks are those Setup used before the package (0.20.0 and earlier): an install it made is found
// and removed. Its record was a `version` file in the install folder (Linux) or the registry key alone (Windows), not the
// manifest: such an install reads as Repair, which rewrites it in today's form (LEGACY_RECORD).
package occ

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import desktop "gt:desktop"
import "gt:platform"
import process "gt:process"

APP_NAME      :: "opencode native"
// (said wherever this program presents itself: their README asks it of a project with "opencode" in its name, and it is the truth)
APP_NOT_THEIRS :: "An independent project: not built by the OpenCode team, and not affiliated with them."
APP_PUBLISHER :: "Froment Software"

APP_SLUG       :: "opencode-native"   // the .desktop file, the icon, the windows' class, the executable
INSTALL_FOLDER :: "opencode-native"   // the install folder's name (Windows: not the toolkit's default, which is APP_NAME)
MANIFEST_NAME  :: "opencode-native-install.txt"
// What Setup before the package wrote as the record of an install on Linux: the version, in the install folder.
LEGACY_RECORD  :: "version"

// What opencode native needs from the system on NixOS, by nixpkgs attribute: what it links (glibc; libgcc_s is in
// stdenv.cc.cc) and what it opens with dlopen, which is `runtime` in flake.nix without mesa (the Vulkan driver is the
// system's). The test nixos_libraries_follow_the_flake keeps the two in step.
NIXOS_LIBRARIES := [?]string{
	"glibc", "stdenv.cc.cc",
	"vulkan-loader", "libxkbcommon", "wayland", "libx11", "libxcb", "libxcursor", "libxrandr", "libxi", "libxext", "libxcb-cursor",
	"fontconfig", "freetype", "dbus",
}

// The names and marks of opencode native on the desktop. They are what an install already carries on users' machines:
// changing one leaves those files and keys behind, unrecognised.
identity :: proc() -> desktop.Identity {
	return desktop.Identity{
		name = APP_NAME, key = "OpencodeNative", slug = APP_SLUG, aumid = "FromentSoftware.OpencodeNative",
		description = "A native desktop client for the opencode server. Not affiliated with the OpenCode team.",
		vendor = APP_PUBLISHER,
		entry_marker = "X-OpencodeNative-Integration", registry_mark = "OpencodeNativeIntegration", vendor_key = "FromentSoftware",
		manifest_name = MANIFEST_NAME,
		manifest_header = "Written by opencode native's Setup: the files it placed in this folder. Uninstalling removes exactly these.",
		uninstall_arguments = "--uninstall",   // (Settings > Apps: it asks, then removes)
		generic_name = "opencode client", categories = "Development;",
		nix_runtime_name = "opencode-native-runtime", nixos_libraries = NIXOS_LIBRARIES[:],
		cleanup_name = "opencode-native-uninstall",
	}
}

Install_State :: enum u8 {
	Not_Installed,
	This_Copy,        // the running program is the installed copy, everything in place
	Repair,           // a launcher, the system's record or the manifest is missing (or the install is of Setup before 0.21)
	Other_Copy,       // a copy is installed elsewhere: this one runs standalone (Install replaces that one)
	Removal_Scheduled,   // uninstalled while it ran: the file goes when this process ends, and nothing else is to be done (Setup says it, nothing on disk does)
	Nix_Package,      // this copy is a Nix package (it runs from /nix/store): the Nix configuration installs it, its menu entry and its icon
}

// On NixOS the Nix package is the better install: Nix updates it. A classic install makes its copy run by itself: nix-build
// makes a profile of its libraries, and patchelf points the copy at it (the toolkit's NixOS adaptation).
NIXOS_ADVICE :: "On NixOS, the Nix package is the better install: nix profile add git+https://github.com/sachahjkl/opencode_native, or add it to your configuration. A classic install builds the libraries it needs with nix-build."

// This copy is a Nix package: it runs from the store, and Nix installs and updates it.
nix_package :: proc() -> bool { return desktop.in_nix_store(process.executable_path()) }

Install_Facts :: struct {
	state:      Install_State,
	dir:        string,   // where the installed copy is (or would go)
	exe:        string,
	exe_there:  bool,     // ... and it is there
	running:    string,   // this program
	running_it: bool,     // this program is the installed copy
	start_lnk:  bool,     // the launcher of the applications menu (Start menu shortcut, .desktop entry), running the installed copy
	desk_lnk:   bool,     // the one on the Desktop
	record:     bool,     // the system's record (Settings > Apps entry; the icon in the icon theme)
	manifest:   bool,     // the install folder has the manifest: the install is of this Setup
	missing:    int,      // files the manifest names that are not there
	version:    string,   // of the installed copy, from its manifest
	nixos:      bool,     // the system is NixOS: Setup advises the Nix package (NIXOS_ADVICE)
	from_nix:   bool,     // this copy runs from the Nix store: never offered an install or an update (a classic one can be removed)
}

// What the facts make of an install. No program but something of it left: to repair, or to remove. A program without the
// manifest was installed by Setup before 0.21: Repair (from this copy or the installed one) rewrites it in today's form.
install_state_of :: proc(f: Install_Facts) -> Install_State {
	switch {
	case !f.exe_there:  return f.start_lnk || f.desk_lnk || f.record || f.manifest ? .Repair : .Not_Installed
	case !f.manifest:   return .Repair
	case !f.running_it: return .Other_Copy
	case f.start_lnk && f.record && f.missing == 0: return .This_Copy
	}
	return .Repair
}

// The options of opencode native's integration, its install folder set: the one the system recorded (Windows), else
// INSTALL_FOLDER beside the toolkit's default. `recorded`: the system has a record of it.
desktop_options :: proc() -> (o: desktop.Options, recorded: bool) {
	o = desktop.options_make(identity())
	o.icons = desktop_icons()
	default := desktop.default_install_dir(&o)
	if found := desktop.install_target(&o); found != "" && !desktop.same_path(found, default) { o.install_dir = found; return o, true }
	if default != "" { o.install_dir = pjoin({process.parent_dir(default), INSTALL_FOLDER}) }
	return o, false
}

install_facts :: proc() -> (f: Install_Facts) {
	o, recorded := desktop_options()
	f.running = process.executable_path()
	f.dir = o.install_dir
	info := desktop.installed_info(&o, f.dir, context.temp_allocator)
	f.exe = info.exe != "" ? info.exe : pjoin({f.dir, desktop.exe_name_of(o.identity)})
	f.exe_there = info.exe_present
	f.manifest = info.manifest
	f.missing = info.missing
	f.version = info.version
	f.running_it = desktop.same_path(f.exe, f.running)
	o.exe = f.exe   // (the integration is measured against the installed copy)
	s := desktop.status(&o, context.temp_allocator)
	launcher := s.parts[.Launcher]
	f.start_lnk = launcher.present && !launcher.stale && !launcher.partial
	f.desk_lnk = desktop_shortcut_there(&o, &s)
	f.record = system_record_there(&s, recorded)
	f.state = install_state_of(f)
	f.nixos = desktop.is_nixos()
	// (a copy installed in the data directory keeps its state: Setup can remove it)
	f.from_nix = desktop.in_nix_store(f.running)
	if f.from_nix && f.state == .Not_Installed { f.state = .Nix_Package }
	return
}

// What a failure of the package says, for the dialog and the command line.
@(private = "file")
failure :: proc(r: desktop.Result) -> string {
	return r.detail != "" ? r.detail : desktop.error_text(r.error)
}

// Copies this program into the install folder (unless it runs from there), on NixOS makes it run by itself, writes its
// launchers and the system's record. Returns the installed program.
desktop_install :: proc(desktop_shortcut: bool) -> (ok: bool, msg: string) {
	o, _ := desktop_options()
	if o.install_dir == "" { return false, "the install folder is unknown" }
	exe_name := desktop.exe_name_of(o.identity)
	plan := desktop.Install_Plan{
		identity = o.identity, src_exe = process.executable_path(), dir = o.install_dir, exe_name = exe_name,
		version = APP_VERSION, channel = "release", adapt = true,
	}
	if r := desktop.files_install(plan); r.error != .None { return false, failure(r) }
	_ = os.remove(pjoin({o.install_dir, LEGACY_RECORD}))
	o.exe = pjoin({o.install_dir, exe_name})
	o.desktop_shortcut = desktop_shortcut
	if r := desktop.install(&o); r.error != .None { return false, failure(r) }
	if !desktop_shortcut_set(&o, desktop_shortcut) { return false, "cannot write the Desktop shortcut" }
	if r := desktop.record_install(&o, o.install_dir, APP_VERSION); r.error != .None { return false, failure(r) }
	return true, o.exe
}

// Removes the launchers (ours only), the system's record and the installed files. The files of the copy that runs (Windows:
// they cannot be deleted while it runs) are in `leftovers` (heap, the caller's): desktop_remove_later deletes them after
// this process ends.
desktop_uninstall :: proc() -> (ok: bool, leftovers: [dynamic]string, msg: string) {
	o, _ := desktop_options()
	o.exe = pjoin({o.install_dir, desktop.exe_name_of(o.identity)})
	_ = desktop_shortcut_set(&o, false)
	if o.install_dir != "" { _ = os.remove(pjoin({o.install_dir, LEGACY_RECORD})) }
	ur := desktop.uninstall(&o, process.executable_path(), context.temp_allocator)
	if len(ur.leftovers) > 0 {
		leftovers = make([dynamic]string)
		for l in ur.leftovers { append(&leftovers, strings.clone(l)) }
		append(&leftovers, strings.clone(pjoin({ur.folder, MANIFEST_NAME})))   // (it stays while they are there)
	}
	if ur.result.error != .None { return false, leftovers, failure(ur.result) }
	return true, leftovers, ""
}

// Deletes `files`, then the install folder when empty, once this process has ended (a helper of the system's; false when
// there is none here).
desktop_remove_later :: proc(files: []string) -> bool {
	o, _ := desktop_options()
	return desktop.cleanup_later(&o, files, o.install_dir, desktop.current_process_id())
}

// The installed copy cleans what a replacement left beside it.
desktop_clean_old :: proc() {
	o := desktop.Options{identity = identity()}
	desktop.clean_old(&o, process.parent_dir(process.executable_path()))
}

// The updater replaced `exe`: when it is the installed copy, its manifest takes the new version, its system's record too,
// and on NixOS the new program is made to run by itself again (the update is the release, made for a usual Linux).
desktop_updated :: proc(exe, version: string) -> (ok: bool, msg: string) {
	o, _ := desktop_options()
	dir := process.parent_dir(exe)
	if !os.exists(pjoin({dir, MANIFEST_NAME})) || !desktop.same_path(dir, o.install_dir) { return true, "" }
	exe_name := desktop.exe_name_of(o.identity)
	plan := desktop.Install_Plan{identity = o.identity, src_exe = exe, dir = dir, exe_name = exe_name, version = version, channel = "release", adapt = true}
	if r := desktop.files_install(plan); r.error != .None { return false, failure(r) }
	o.exe = exe
	if r := desktop.record_install(&o, dir, version); r.error != .None { return false, failure(r) }
	return true, ""
}

// The windows of this process group under the shortcuts' AppUserModelID (Windows), and say they are opencode native: the
// Wayland app_id and X11 WM_CLASS, by which the desktop finds opencode-native.desktop, for the icon and the name in a task
// bar (Linux). Before the first window.
set_app_id :: proc() {
	id := identity()
	desktop.set_process_identity(id)
	platform.set_app_id(APP_SLUG)
	platform.notify_set_app({name = APP_NAME, aumid = id.aumid})   // (notifications of the system: under this name, grouped with its windows)
}

// Starts the installed copy (after an install from a downloaded copy).
launch :: proc(exe: string) -> bool {
	_, err := os.process_start({command = {exe}, working_dir = filepath.dir(exe)})
	return err == nil
}

// A path made of `parts` (temp memory).
pjoin :: proc(parts: []string) -> string {
	s, _ := filepath.join(parts, context.temp_allocator)
	return s
}

// The client's own files (preferences, servers): %APPDATA%\opencode-native on Windows, $XDG_CONFIG_HOME/opencode-native
// (~/.config/opencode-native) elsewhere.
config_dir :: proc() -> string {
	when ODIN_OS == .Windows {
		return pjoin({os.get_env("APPDATA", context.temp_allocator), "opencode-native"})
	} else {
		if d := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); d != "" { return pjoin({d, "opencode-native"}) }
		return pjoin({os.get_env("HOME", context.temp_allocator), ".config", "opencode-native"})
	}
}

// The command line's report: the standard output, or the console of the process that started a Windows program with a window.
say :: proc(format: string, args: ..any) {
	process.console_write(fmt.tprintf(format, ..args))
}
