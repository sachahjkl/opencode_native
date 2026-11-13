// Linux: the icons of the menu entry.
package ocn

import desktop "gt:desktop"

@(private = "file")
ICON_SET := [?]desktop.Icon{{256, #load("../assets/logo_256.png")}}

// The icons of the theme (Windows uses the executable's own).
desktop_icons :: proc() -> []desktop.Icon { return ICON_SET[:] }
