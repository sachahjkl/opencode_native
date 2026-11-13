// The themes: the colours of the whole interface, from a few of each theme's own, in a dark and a light version (gui_toolkit's
// themes: docs/themes.md). Every colour this program draws is one of opencode's (the HEX_ constants, in style.odin and beside what
// uses them); ui.theme_recolor moves each to the theme shown: a grey to the same place on the theme's steps (its backgrounds, its
// lines, its texts), a colour to the theme's colour of the nearest hue, mixed as much with the theme's grey as it was with opencode's.
// OpenCode dark is opencode's: it moves nothing. The themes: OpenCode, then the toolkit's; themes of the user's own come from
// themes.txt, beside the preferences (themes_poll).
package ocn


import "core:path/filepath"
import "core:strings"
import "gt:platform"
import prefs_page "gt:prefs_page"
import "gt:ui"

@(private = "file") BLACK_STEPS :: [6]u32{0x070707ff, 0x0a0a0aff, 0x101010ff, 0x161616ff, 0x1e1e1eff, 0x2a2a2aff}
@(private = "file") BLACK_TEXTS :: [4]u32{0x5a5a5aff, 0x8f8f8fff, 0xedededff, 0xffffffff}
@(private = "file") WHITE_STEPS :: [6]u32{0xe8e8e8ff, 0xf9f9f9ff, 0xf1f1f1ff, 0xffffffff, 0xffffffff, 0xdadadaff}
@(private = "file") WHITE_TEXTS :: [4]u32{0xa3a3a3ff, 0x6b6b6bff, 0x1c1c1cff, 0x000000ff}

// opencode's black with its peach; in the light version white and a deeper orange.
THEME_OPENCODE :: ui.Theme_Def{"OpenCode",
	{BLACK_STEPS, BLACK_TEXTS, {HEX_PEACH, HEX_BLUE, HEX_PURPLE, HEX_GREEN, HEX_YELLOW, HEX_RED, HEX_CYAN, HEX_ROSE}},
	{WHITE_STEPS, WHITE_TEXTS, {0xc8622aff, 0x2f6fdbff, 0x7c4dd8ff, 0x2f8a3aff, 0xb57d07ff, 0xc9303eff, 0x12838fff, 0xc83e6aff}},
	.Both, nil, false, 0}

// opencode's colours as what theme_recolor moves from: its dark version, and where its greys stand (their level, 0..255): what
// is under the well, the well, the backgrounds, the line, the texts.
@(private = "file")
opencode_reference := ui.Theme_Reference{colors = THEME_OPENCODE.dark, levels = {0, 6, 10, 16, 22, 30, 42, 90, 143, 200, 237, 255}}

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

// The themes there are, the one shown and in which version, and opencode's colours as it has them (made as they are asked for:
// the same few hundred each frame).
Theme_State :: struct {
	file:     prefs_page.Themes_File,   // the program's themes, then the user's (themes.txt)
	at:       int,
	light:    bool,                 // the light version shown
	identity: bool,                 // OpenCode dark: nothing moves
	colors:   ui.Theme_Colors,
	cache:    map[u32]u32,
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
	ts.identity = at == 0 && !light
	clear(&ts.cache)
}

// The windows as the version shown: the title bars the system draws dark or light, and the ground each frame is cleared to.
theme_windows :: proc(app: ^App) {
	dark := !app.cx.theme.light
	if app.win != nil { platform.set_dark_title(app.win, dark) }
	for d in app.cx.detached { if d.win != nil { platform.set_dark_title(d.win, dark) } }
	// what each frame is cleared to: the theme's ground, which shows where nothing is drawn (it stayed the first theme's: a light line
	// under the title bar once the theme went dark)
	app.window.background = hex(HEX_BG0)
	for d in app.cx.detached { d.window.background = hex(HEX_BG0) }
}

// Whether what is shown is a light version (its surfaces are flat: the machined reliefs are made for the dark).
theme_light :: proc() -> bool { return the_app != nil && the_app.cx.theme.light }

// One of opencode's colours, as the theme shown has it.
themed :: proc(c: u32) -> u32 {
	app := the_app
	if app == nil || app.cx.theme.identity || app.cx.theme.colors == {} { return c }
	if v, ok := app.cx.theme.cache[c]; ok { return v }
	v := c == HEX_ON_ACCENT ? ui.theme_on_accent(app.cx.theme.colors) : ui.theme_recolor(&opencode_reference, app.cx.theme.colors, c)
	app.cx.theme.cache[c] = v
	return v
}

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
