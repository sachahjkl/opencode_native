// Windows: the words of this system. The toolkit's desktop and setup packages do the rest: the shortcuts with the
// AppUserModelID, the Settings > Apps record (which also says where the copy is), the deferred deletion of the running
// copy's file.
package occ

import desktop "gt:desktop"

// What the settings call the pieces of an install, on this system.
LBL_PIECES :: "the shortcuts, the Settings > Apps entry"

// (Windows uses the executable's own icon)
desktop_icons :: proc() -> []desktop.Icon { return nil }

// (the Desktop's shortcut is the toolkit's part: its uninstall removes it)
desktop_copy_remove :: proc() {}
