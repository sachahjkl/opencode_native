// What opencode native is to the toolkit's desktop and setup packages (gt:desktop, gt:setup; ext/gui_toolkit/docs/desktop.md
// and setup.md): its identity, and the Config of the Setup dialog (setup.odin shows it). The packages write and remove every
// file and key; the per-system files (desktop_windows.odin, desktop_linux.odin) keep the words of each system, and on Linux
// the removal of the copy of the menu entry on the Desktop that Setup up to 0.30 wrote.
//
// The installed copy:
//   Windows  %LOCALAPPDATA%\Programs\opencode-native\opencode-native.exe (or the folder the Settings > Apps record names),
//            Start menu\Programs\opencode native.lnk (and one on the Desktop) with the AppUserModelID,
//            HKCU\...\CurrentVersion\Uninstall\OpencodeNative, the Settings > Apps entry
//   Linux    ~/.local/share/opencode-native/opencode-native, ~/.local/share/applications/opencode-native.desktop,
//            ~/.local/share/icons/hicolor/256x256/apps/opencode-native.png
// and in the install folder the manifest (MANIFEST_NAME): the version and the files placed, which the uninstall removes.
//
// The identity's names and marks are those Setup used before the package (0.20.0 and earlier): an install it made is found
// and removed. Its record was a `version` file in the install folder (Linux) or the registry key alone (Windows), not the
// manifest: such an install reads as Repair, which rewrites it in today's form (LEGACY_RECORD).
package ocn

import "core:fmt"
import "core:os"
import "core:path/filepath"
import desktop "gt:desktop"
import "gt:platform"
import process "gt:process"
import setup "gt:setup"
import i18n "gt:i18n"

APP_NAME      :: "opencode native"
// (said wherever this program presents itself: their README asks it of a project with "opencode" in its name, and it is the truth)
APP_NOT_THEIRS := i18n.later("An independent project: not built by the OpenCode team, and not affiliated with them.")
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
		name = APP_NAME, key = "OpencodeNative", slug = APP_SLUG,   // (the AppUserModelID: the vendor's and the name's, desktop.identity_aumid)
		description = "A native desktop client for opencode. Not affiliated with the OpenCode team.",
		vendor = APP_PUBLISHER,
		entry_marker = "X-OpencodeNative-Integration", registry_mark = "OpencodeNativeIntegration", vendor_key = "FromentSoftware",
		manifest_name = MANIFEST_NAME,
		manifest_header = "Written by opencode native's Setup: the files it placed in this folder. Uninstalling removes exactly these.",
		uninstall_arguments = "--setup",   // (Settings > Apps: the install's dialog, its Uninstall)
		generic_name = "opencode client", categories = "Development;",
		nix_runtime_name = "opencode-native-runtime", nixos_libraries = NIXOS_LIBRARIES[:],
		cleanup_name = "opencode-native-uninstall",
	}
}

// This copy is a Nix package: it runs from the store, and Nix installs and updates it.
nix_package :: proc() -> bool { return desktop.in_nix_store(process.executable_path()) }

// What the install is given: the identity, this version, the install folder, the icons, the line under the version, and
// what an install and an uninstall do besides the packages' parts. On NixOS a classic install makes its copy run by
// itself: nix-build makes a profile of NIXOS_LIBRARIES, and patchelf points the copy at it (the toolkit's NixOS adaptation).
setup_options :: proc() -> setup.Setup_Options {
	return setup.Setup_Options{
		identity = identity(), version = APP_VERSION, install_folder = INSTALL_FOLDER, icons = desktop_icons(),
		note = i18n.tr(APP_NOT_THEIRS), prepare = setup_prepare,
		// (the dialog in opencode's look: its blurred backdrop)
		backdrop = proc(_: rawptr) { dialog_backdrop() },
	}
}

// Called by both Install and Uninstall before the packages write or remove: the record of Setup up to 0.20.0 goes, so that
// an install is in today's form and an uninstall leaves an empty folder (which the package then removes).
@(private = "file")
setup_prepare :: proc(o: ^desktop.Integration_Options, _: []bool, _: rawptr) {
	if o.install_dir != "" { _ = os.remove(pjoin({o.install_dir, LEGACY_RECORD})) }
}

// The updater replaced `exe`: when it is the installed copy, its manifest takes the new version, its system's record too,
// and on NixOS the new program is made to run by itself again (the update is the release, made for a usual Linux).
desktop_updated :: proc(exe, version: string) -> (ok: bool, msg: string) {
	failure :: proc(r: desktop.Result) -> string { return r.detail != "" ? r.detail : desktop.error_text(r.error) }
	o, _ := setup.options(setup_options())
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
	platform.notify_set_app({name = APP_NAME, aumid = desktop.identity_aumid(id)})   // (notifications of the system: under this name, grouped with its windows)
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
