// Windows: the words of this system. The toolkit's desktop and setup packages do the rest: the shortcuts with the
// AppUserModelID, the Settings > Apps record (which also says where the copy is), the deferred deletion of the running
// copy's file.
package ocn

import desktop "gt:desktop"
import i18n "gt:i18n"

// What the settings call the pieces of an install, on this system.
LBL_PIECES :: "the shortcuts, the Settings > Apps entry"
// (the settings' line about Setup, whole: a language orders its words its own way)
SETUP_HINT := i18n.later("Installation and the shortcuts, the Settings > Apps entry are in Setup… (title bar menu).")

// (Windows uses the executable's own icon)
desktop_icons :: proc() -> []desktop.Icon { return nil }

// (the Desktop's shortcut is the toolkit's part: its uninstall removes it)
desktop_copy_remove :: proc() {}
