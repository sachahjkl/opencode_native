// Windows: the toolkit's desktop and setup packages do it all: the shortcuts with the AppUserModelID, the Settings > Apps
// record (which also says where the copy is), the deferred deletion of the running copy's file.
package ocn

import desktop "gt:desktop"

// (Windows uses the executable's own icon)
desktop_icons :: proc() -> []desktop.Icon { return nil }
