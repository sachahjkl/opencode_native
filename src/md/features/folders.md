# Folders, install place and title

opencode native follows the toolkit's per-publisher layout (gui_toolkit's `src/md/features/folders.md`). This file says
what it chose on top of it.

## Decisions

- **`APP_FOLDER` is `FromentSoftware` + `platform.USER_DIR_SEPARATOR` + `OpencodeNative`.** Every folder of the program
  is in it: the configuration (`config_dir`: settings, servers, drafts, views, licence, the palette's memory), the
  state (the log and the crash reports: `log_start` gives their folders, their files keep the name `opencode-native`).
  The folder name is the title without its space: a path a person types in a terminal.
- **The earlier folders move once** (`folders_move`, `platform.user_dirs_move("opencode-native", APP_FOLDER)`), first
  in `main`, before `--status`, the single instance and the log read anything. It is the toolkit's move, not a migration
  of ocn's: a rename, nothing read or rewritten. A failure is said on the standard error.
- **The single instance follows.** Its name is a hash of `config_dir()` (single-instance.md), so a copy before the move
  and a copy after it do not meet. One person runs one version at a time; refused: a second name kept for the old one.
- **The install is the toolkit's default place**, in the vendor's folder: `%LOCALAPPDATA%\Programs\FromentSoftware\
  OpencodeNative`, `~/.local/opt/FromentSoftware/OpencodeNative`. `Setup_Options.install_folder` is `OpencodeNative`:
  the default names the folder after the title, with its space. An install Windows recorded stays where it is (the
  toolkit reads the record).
- **No code for the earlier installs.** Setup up to 0.20.0 kept a `version` file in the install folder; its cleanup and
  its test went. Such an install shows as left over, and the person installs again.
- **The title a person reads is `APP_TITLE`, "Opencode Native"**: the window, the menu entry and the shortcuts
  (`Identity.name`), the about page, the setup, the licence file, the executable's description. The command, the
  package, the `.desktop` file, the icon and the window class keep `opencode-native` (`APP_SLUG`). The Windows shortcut
  keeps its file: Windows compares names without case, and the AppUserModelID (`FromentSoftware.OpencodeNative`) is the
  same.

## Subtle points

- On Linux, before toolkit 0.282.0, the install folder was `~/.local/share/opencode-native`, the data folder of the
  earlier layout. The move leaves the data folder out (`FOLDERS_MOVED`, `user_dirs_move`'s `kinds`): moved, the install
  would leave its menu entry and its updater on a path that is gone. This program keeps nothing else there.
