// Windows: the words of this system. The toolkit's integration does the rest: the shortcuts with the AppUserModelID, the
// Settings > Apps record (which also says where the copy is), the deferred deletion of the running copy's file.
package occ

import desktop "gt:desktop"

// What the Setup dialog calls the pieces of an install, on this system.
LBL_MENU      :: "start menu"
LBL_MENU_ITEM :: APP_NAME + ".lnk"
LBL_RECORD    :: "settings"
LBL_RECORD_IT :: "Settings > Apps > opencode native"
LBL_PIECES    :: "the shortcuts, the Settings > Apps entry"
LBL_START     :: "the Start menu"
LBL_PIECES_MISSING :: "a shortcut, the Settings entry or a file"

// (Windows uses the executable's own icon)
desktop_icons :: proc() -> []desktop.Icon { return nil }

desktop_shortcut_there :: proc(_: ^desktop.Options, s: ^desktop.Status) -> bool {
	p := s.parts[.Desktop_Shortcut]
	return p.present && !p.stale
}

// The toolkit's install wrote it, or took it away (Options.desktop_shortcut).
desktop_shortcut_set :: proc(_: ^desktop.Options, _: bool) -> bool { return true }

// The Settings > Apps record: the toolkit finds the install folder through it (desktop_options).
system_record_there :: proc(_: ^desktop.Status, recorded: bool) -> bool { return recorded }
