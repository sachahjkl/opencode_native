// The themes: the colours of the whole interface, from a few of each theme's own, in a dark and a light version (gui_toolkit's
// themes: docs/themes.md). The views draw with the theme shown, by role and by hue (themed, ui.hue): opencode's own colours are
// the theme OpenCode, the only place that holds them (src/md/features/colours.md). The themes: OpenCode, then the toolkit's;
// themes of the user's own come from themes.txt, beside the preferences (themes_poll).
package ocn


import "core:path/filepath"
import "core:strings"
import "gt:draw"
import "gt:platform"
import prefs_page "gt:prefs_page"
import "gt:ui"

@(private = "file") BLACK_STEPS :: [6]u32{0x070707ff, 0x0a0a0aff, 0x101010ff, 0x161616ff, 0x1e1e1eff, 0x2a2a2aff}
@(private = "file") BLACK_TEXTS :: [4]u32{0x5a5a5aff, 0x8f8f8fff, 0xedededff, 0xffffffff}
// peach (opencode's primary), blue, purple, green, yellow, red, cyan, rose
@(private = "file") BLACK_HUES  :: [8]u32{0xfab283ff, 0x5c9cf5ff, 0x9d7cd8ff, 0x7fd88fff, 0xf5a742ff, 0xe06c75ff, 0x56b6c2ff, 0xf28ba8ff}
@(private = "file") WHITE_STEPS :: [6]u32{0xe8e8e8ff, 0xf9f9f9ff, 0xf1f1f1ff, 0xffffffff, 0xffffffff, 0xdadadaff}
@(private = "file") WHITE_TEXTS :: [4]u32{0xa3a3a3ff, 0x6b6b6bff, 0x1c1c1cff, 0x000000ff}
@(private = "file") WHITE_HUES  :: [8]u32{0xc8622aff, 0x2f6fdbff, 0x7c4dd8ff, 0x2f8a3aff, 0xb57d07ff, 0xc9303eff, 0x12838fff, 0xc83e6aff}

// opencode's black with its peach; in the light version white and a deeper orange.
THEME_OPENCODE :: ui.Theme_Def{"OpenCode", {BLACK_STEPS, BLACK_TEXTS, BLACK_HUES}, {WHITE_STEPS, WHITE_TEXTS, WHITE_HUES}, .Both, nil, false, 0}

// The colours of the version shown; OpenCode's dark before one is (a test, the first frame). For what the interface does not
// draw: the window's clear colour, the terminal's palette, the logo's tint.
theme_colors :: proc() -> ui.Theme_Colors {
	if app := the_app; app != nil && app.cx.theme.colors != {} { return app.cx.theme.colors }
	return THEME_OPENCODE.dark
}

// An entry of the toolkit's theme by its name ("weak text", "bar background"), whatever tags are pushed where it is asked:
// while a view is built and in a custom draw (no build: the main window's state; every window shares the one theme).
themed :: proc(name: string) -> Color { return ui.color_from_tags(built_state(the_app), 0, name) }

// A shade `t` of the way from one entry of the theme to another, in sRGB steps: between two of its steps, it keeps its place
// in every theme, dark or light (a share toward white or black is a large step on a light page).
between :: proc(from, to: string, t: f32) -> Color { return ui.srgb_step(themed(from), themed(to), t) }

// The program's themes: OpenCode, then the toolkit's.
@(private = "file")
themes_builtin :: proc() -> []ui.Theme_Def {
	@(static) made: [len(ui.THEMES) + 1]ui.Theme_Def
	if made[0].name == "" {
		made[0] = THEME_OPENCODE
		copy(made[1:], ui.THEMES[:])
	}
	return made[:]
}

// The themes there are, the one shown and in which version.
Theme_State :: struct {
	file:     prefs_page.Themes_File,   // the program's themes, then the user's (themes.txt)
	at:       int,
	light:    bool,                 // the light version shown
	colors:   ui.Theme_Colors,
	scheme:   u32,                  // the system's light / dark, as platform.color_scheme_serial last said
}

// The themes there are: the program's, then the user's.
themes :: proc(app: ^App) -> []ui.Theme_Def { return len(app.cx.theme.file.all) > 0 ? app.cx.theme.file.all[:] : themes_builtin() }

// The theme of this name ("" or an unknown one: opencode's).
theme_index :: proc(app: ^App, name: string) -> int {
	for t, i in themes(app) { if strings.equal_fold(t.name, name) { return i } }
	return 0
}

// Whether the light version is meant: the mode asked for (appearance.mode), the system's for "system".
theme_wants_light :: proc(mode: string) -> bool { return ui.theme_wants_light(ui.theme_mode_of(mode)) }

// Shows theme `at`, light or dark (a theme with no light version: dark).
theme_set :: proc(app: ^App, asked: int, light_asked: bool) {
	all := themes(app)
	ts := &app.cx.theme
	at := asked < len(all) ? asked : 0
	colors, light := ui.theme_version(all[at], light_asked)
	if at == ts.at && light == ts.light && ts.colors != {} { return }
	ts.at, ts.light = at, light
	ts.colors = colors
}

// The windows as the version shown: the title bars the system draws dark or light, and the ground each frame is cleared to.
theme_windows :: proc(app: ^App) {
	dark := !app.cx.theme.light
	if app.win != nil { platform.set_dark_title(app.win, dark) }
	// what each frame is cleared to: the theme's ground, which shows where nothing is drawn (it stayed the first theme's: a light line
	// under the title bar once the theme went dark)
	app.window.background = draw.hex(theme_colors().steps[1])   // (the windows of the views take both from it: host.view_windows)
}

// Whether what is shown is a light version (its surfaces are flat: the machined reliefs are made for the dark).
theme_light :: proc() -> bool { return the_app != nil && the_app.cx.theme.light }

// The system went light or dark: what follows it follows (once a frame: an integer compared).
theme_follow_system :: proc(app: ^App) {
	n := platform.color_scheme_serial()
	if n == app.cx.theme.scheme { return }
	app.cx.theme.scheme = n
	if app.prefs.mode == "system" { prefs_refresh(app) }
}

////////////////////////////////
// Themes of the user's own: themes.txt (prefs_page.Themes_File: made, opened and read again by tasks)

// Where they are: beside the preferences.
themes_file :: proc(app: ^App) -> string {
	if app.prefs_file == "" { return "" }
	p, _ := filepath.join({filepath.dir(app.prefs_file), THEMES_FILE}, context.temp_allocator)
	return p
}

// Keeps the user's themes (at the start, with the preferences' file: a test has none).
themes_init :: proc(app: ^App) {
	if path := themes_file(app); path != "" { prefs_page.themes_file_init(&app.cx.theme.file, path, themes_builtin()) }
}

// At each build: the user's themes, read again when the file changed (a task looks at it now and then); the theme shown
// again as it now says.
themes_poll :: proc(app: ^App) {
	if app.cx.theme.file.path == "" { return }
	if prefs_page.themes_file_poll(&app.cx.theme.file, &app.state) {
		app.cx.theme.colors = {}
		prefs_refresh(app)
	}
}
