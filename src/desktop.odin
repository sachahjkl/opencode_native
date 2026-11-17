// What opencode native is to the toolkit's desktop and setup packages (gt:desktop, gt:setup; ext/gui_toolkit/docs/desktop.md
// and setup.md): its identity, and the Config of the Setup dialog (setup.odin shows it). The packages write and remove every
// file and key; the per-system files (desktop_windows.odin, desktop_linux.odin) keep the words of each system, and on Linux
// the removal of the copy of the menu entry on the Desktop that Setup up to 0.30 wrote.
//
// The installed copy:
//   Windows  %LOCALAPPDATA%\Programs\FromentSoftware\OpencodeNative\opencode-native.exe (or the folder the Settings > Apps
//            record names), Start menu\Programs\Opencode Native.lnk (and one on the Desktop) with the AppUserModelID,
//            HKCU\...\CurrentVersion\Uninstall\OpencodeNative, the Settings > Apps entry
//   Linux    ~/.local/opt/FromentSoftware/OpencodeNative/opencode-native, ~/.local/share/applications/opencode-native.desktop,
//            ~/.local/share/icons/hicolor/256x256/apps/opencode-native.png
// and in the install folder the manifest (MANIFEST_NAME): the version and the files placed, which the uninstall removes.
package ocn

import "base:runtime"
import "core:fmt"
import "core:path/filepath"
import desktop "gt:desktop"
import "gt:platform"
import process "gt:process"
import setup "gt:setup"
import i18n "gt:i18n"

// The name a person reads: the window, the menu entry, the shortcuts, the about page, the setup. APP_SLUG stays the
// technical name.
APP_TITLE     :: "Opencode Native"
// (said wherever this program presents itself: their README asks it of a project with "opencode" in its name, and it is the truth)
APP_NOT_THEIRS := i18n.later("An independent project: not built by the OpenCode team, and not affiliated with them.")
APP_PUBLISHER :: "Froment Software"
APP_PUBLISHER_URL :: "https://froment.software"   // (the setup's "By" line opens it)
APP_PUBLISHER_MARK :: #load("../site/img/froment-software-64.png")
// (the vendor's key as a constant: APP_FOLDER is one, and desktop.identity_of makes the identity's at run time)
APP_VENDOR_KEY :: "FromentSoftware"
// The program's folder in its vendor's: its settings, its state and its cache (APP_FOLDER), and its install folder. The
// title without its space: a path a person types in a terminal.
APP_FOLDER_NAME :: "OpencodeNative"
// Its folders (gui_toolkit's src/md/features/folders.md): %APPDATA%\FromentSoftware\OpencodeNative,
// ~/.config/FromentSoftware/OpencodeNative, and the same under the data, state and cache folders.
APP_FOLDER :: APP_VENDOR_KEY + platform.USER_DIR_SEPARATOR + APP_FOLDER_NAME
// The folder name of the earlier layout: user_dirs_move takes its folders into APP_FOLDER once.
APP_FOLDER_BEFORE :: "opencode-native"

APP_SLUG       :: "opencode-native"   // the .desktop file, the icon, the windows' class, the executable
MANIFEST_NAME  :: "opencode-native-install.txt"

// What opencode native needs from the system on NixOS, by nixpkgs attribute: what it links (glibc; libgcc_s is in
// stdenv.cc.cc) and what it opens with dlopen, which is `runtime` in flake.nix without mesa (the Vulkan driver is the
// system's). The test nixos_libraries_follow_the_flake keeps the two in step.
NIXOS_LIBRARIES := [?]string{
	"glibc", "stdenv.cc.cc",
	"vulkan-loader", "libxkbcommon", "wayland", "libx11", "libxcb", "libxcursor", "libxrandr", "libxi", "libxext", "libxcb-cursor",
	"fontconfig", "freetype", "dbus", "curl",
}

// The names and marks of opencode native on the desktop. They are what an install already carries on users' machines:
// changing one leaves those files and keys behind, unrecognised. The toolkit derives the key (OpencodeNative, the
// AppUserModelID's part), the vendor's key and the marks from the vendor, the title and the slug; the manifest keeps its
// earlier name, which installed copies carry.
identity :: proc() -> desktop.Identity { return the_identity }

// (made once for the process: identity_of allocates, and the setup's jobs share its strings for as long as they run)
@(private = "file") the_identity: desktop.Identity

@(init)
@(private = "file")
identity_init :: proc "contextless" () {
	context = runtime.default_context()
	id := desktop.identity_of(APP_PUBLISHER, APP_TITLE, APP_SLUG, runtime.heap_allocator())
	id.manifest_name = MANIFEST_NAME
	id.description = "A native desktop client for opencode. Not affiliated with the OpenCode team."
	id.manifest_header = "Written by Opencode Native's Setup: the files it placed in this folder. Uninstalling removes exactly these."
	id.uninstall_arguments = "--setup"   // (Settings > Apps: the install's dialog, its Uninstall)
	id.generic_name, id.categories = "opencode client", "Development;"
	id.nix_runtime_name, id.nixos_libraries = "opencode-native-runtime", NIXOS_LIBRARIES[:]
	id.cleanup_name = "opencode-native-uninstall"
	the_identity = id
}

// This copy is a Nix package: it runs from the store, and Nix installs and updates it.
nix_package :: proc() -> bool { return desktop.in_nix_store(process.executable_path()) }

// What the install is given: the identity, this version, the install folder, the icons, the line under the version. On
// NixOS a classic install makes its copy run by itself: nix-build makes a profile of NIXOS_LIBRARIES, and patchelf points
// the copy at it (the toolkit's NixOS adaptation).
setup_options :: proc() -> setup.Setup_Options {
	return setup.Setup_Options{
		// (the install folder is the toolkit's default place, in the vendor's folder, under APP_FOLDER_NAME: the default
		// names it after the title, whose space a person would have to quote in a terminal; no note: the identity's
		// description already says the project is not the OpenCode team's)
		identity = identity(), version = APP_VERSION, install_folder = APP_FOLDER_NAME, icons = desktop_icons(),
		vendor_url = APP_PUBLISHER_URL,
		running = instance_running, quit = instance_quit,   // (--status, --quit: the single instance, single_instance.odin)
		// (the dialog in opencode's look: its blurred backdrop, behind it as a dialog only)
		backdrop = view_backdrop,
	}
}

// The windows of this process group under the shortcuts' AppUserModelID (Windows), and say they are opencode native: the
// Wayland app_id and X11 WM_CLASS, by which the desktop finds opencode-native.desktop, for the icon and the name in a task
// bar (Linux). Before the first window.
set_app_id :: proc() {
	id := identity()
	desktop.set_process_identity(id)
	platform.set_app_id(APP_SLUG)
	platform.notify_set_app({name = APP_TITLE, aumid = desktop.identity_aumid(id)})   // (notifications of the system: under this name, grouped with its windows)
}

// At the start, before anything reads the folders and before the log: the folders of the earlier layout move once into
// APP_FOLDER (the toolkit's move), so the person's settings, servers, drafts, licence and logs come along. A failure is
// said on the standard error: the log is not open yet.
folders_move :: proc() {
	if _, why := platform.user_dirs_move(APP_FOLDER_BEFORE, APP_FOLDER, FOLDERS_MOVED); why != "" { say("opencode-native: %s\n", why) }
}

// A path made of `parts` (temp memory).
pjoin :: proc(parts: []string) -> string {
	s, _ := filepath.join(parts, context.temp_allocator)
	return s
}

// The client's own files (preferences, servers): the toolkit's configuration folder, %APPDATA%\FromentSoftware\OpencodeNative
// on Windows, $XDG_CONFIG_HOME/FromentSoftware/OpencodeNative (~/.config/...) on Linux (temp memory).
config_dir :: proc() -> string { return platform.user_dir(.Config, APP_FOLDER, context.temp_allocator) }

// The command line's report: the standard output, or the console of the process that started a Windows program with a window.
say :: proc(format: string, args: ..any) {
	process.console_write(fmt.tprintf(format, ..args))
}
