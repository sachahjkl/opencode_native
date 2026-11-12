package ocn

import "core:os"
import "core:path/filepath"
import "core:testing"
import "gt:ui"

// The theme of the App given, as the program would have it, for a test; what it made goes with it.
@(private = "file")
theme_app :: proc(app: ^App) -> (prev: ^App) {
	prev = the_app
	the_app = app
	return
}

@(private = "file")
theme_app_end :: proc(app: ^App, prev: ^App) {
	delete(app.cx.theme.cache)
	for t in app.cx.theme.all[app.cx.theme.own:] { delete(t.name) }
	delete(app.cx.theme.all)
	the_app = prev
}

@(test)
opencode_dark_moves_nothing :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	prev := theme_app(app)
	defer theme_app_end(app, prev)
	theme_set(app, 0, false)
	for c in ([]u32{HEX_BG0, HEX_TEXT, HEX_PEACH, HEX_DIFF_ADD_BG, HEX_ON_ACCENT, 0x12345678}) { testing.expect_value(t, themed(c), c) }
}

@(test)
a_theme_moves_greys_to_its_steps_and_colours_to_its_hues :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	prev := theme_app(app)
	defer theme_app_end(app, prev)
	gruvbox := theme_index(app, "gruvbox")
	testing.expect(t, gruvbox > 0, "Gruvbox, by its name in any case")
	def := themes(app)[gruvbox]
	theme_set(app, gruvbox, false)
	testing.expect_value(t, themed(HEX_BG0), def.dark.steps[1])
	testing.expect_value(t, themed(HEX_LINE), def.dark.steps[5])
	testing.expect_value(t, themed(HEX_TEXT), def.dark.texts[2])
	testing.expect_value(t, themed(HEX_GREEN), def.dark.hues[3])
	testing.expect_value(t, themed(HEX_PEACH), def.dark.hues[0])
	testing.expect_value(t, themed(HEX_PEACH & 0xffffff00 | 0x40), def.dark.hues[0] & 0xffffff00 | 0x40)   // (its alpha kept)
	theme_set(app, gruvbox, true)
	testing.expect_value(t, themed(HEX_BG0), def.light.steps[1])
	testing.expect_value(t, themed(HEX_TEXT), def.light.texts[2])
}

// In every theme, dark and light: the text reads on the conversation, and the session shown in the sidebar reads on its ground.
@(test)
every_theme_reads :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	prev := theme_app(app)
	defer theme_app_end(app, prev)
	for def, i in themes(app) {
		for light in ([]bool{false, true}) {
			theme_set(app, i, light)
			testing.expectf(t, ui.contrast(hex(HEX_TEXT), hex(HEX_BG0)) >= READABLE_TEXT, "%s (light %v): the text on the conversation, %.2f", def.name, light, ui.contrast(hex(HEX_TEXT), hex(HEX_BG0)))
			g := chosen_ground()
			title := ui.readable(hex(HEX_BRIGHT), g, READABLE_TEXT)
			quiet := ui.readable(hex(HEX_WEAK), g, READABLE_QUIET)
			testing.expectf(t, ui.contrast(title, g) >= READABLE_TEXT, "%s (light %v): the title of the session shown, %.2f", def.name, light, ui.contrast(title, g))
			testing.expectf(t, ui.contrast(quiet, g) >= READABLE_QUIET, "%s (light %v): its folder and its age, %.2f", def.name, light, ui.contrast(quiet, g))
			// an accent button's label (Send, New session) on the accent
			testing.expectf(t, ui.contrast(hex(HEX_ON_ACCENT), hex(HEX_PEACH)) >= READABLE_QUIET, "%s (light %v): a label on the accent, %.2f", def.name, light, ui.contrast(hex(HEX_ON_ACCENT), hex(HEX_PEACH)))
		}
	}
}


// themes.txt: a theme from another, a few colours of its own; a theme of the program's name is the user's; what is not a colour is left.
@(test)
themes_of_ones_own :: proc(t: ^testing.T) {
	dir := filepath.join({os.get_env("TEMP", context.temp_allocator), "ocn_theme_test"}, context.temp_allocator) or_else ""
	_ = os.make_directory(dir)
	defer os.remove_all(dir)
	app := new(App)
	defer free(app)
	app.prefs_file = filepath.join({dir, "prefs.txt"}, context.temp_allocator) or_else ""
	prev := theme_app(app)
	defer theme_app_end(app, prev)
	text := "# mine\n[Mine]\nfrom = Nord\naccent = #e5c07b\nbg0 = 050505\nlight.text = #101010\nred = nope\n\n[Monokai]\nbg0 = #000000\n"
	testing.expect(t, os.write_entire_file(themes_file(app), transmute([]u8)text) == nil)
	theme_load(app)
	all := themes(app)
	mine := theme_index(app, "Mine")
	testing.expect(t, mine > 0 && all[mine].name == "Mine", "the user's theme is there")
	nord := all[theme_index(app, "Nord")]
	testing.expect_value(t, all[mine].dark.hues[0], 0xe5c07bff)
	testing.expect_value(t, all[mine].dark.steps[1], 0x050505ff)
	testing.expect_value(t, all[mine].dark.steps[2], nord.dark.steps[2])   // (from Nord)
	testing.expect_value(t, all[mine].dark.hues[5], nord.dark.hues[5])     // ("nope": not a colour)
	testing.expect_value(t, all[mine].light.texts[2], 0x101010ff)
	testing.expect(t, all[mine].versions == .Both, "a light version")
	monokai := theme_index(app, "Monokai")
	testing.expect(t, monokai >= app.cx.theme.own && all[monokai].dark.steps[1] == 0x000000ff, "Monokai is the user's now")
	n := 0
	for th in all { if th.name == "Monokai" { n += 1 } }
	testing.expect_value(t, n, 1)
}

// An intent's button (accent, danger, success...) in a dialog keeps its own background (and its label stays readable on
// it): our colours of what floats were an entry ahead of the palette's and won over the button's (the setup dialog's
// Uninstall: white on white).
@(test)
a_button_in_a_dialog_keeps_its_background :: proc(t: ^testing.T) {
	th: ui.Theme
	defer ui.theme_destroy(&th)
	theme_setup(&th)
	floating := ui.theme_lookup(&th, {"floating"}, "background")
	testing.expect_value(t, floating, hex(HEX_FLOATING_BG))
	for intent in ui.Intent {
		kind := ui.intent_tag(intent)
		if kind == "" { continue }
		bg := ui.theme_lookup(&th, {"floating", kind}, "background")
		testing.expectf(t, bg != floating, "%s in a dialog: its own background, not the dialog's", kind)
		testing.expect_value(t, bg, ui.theme_lookup(&th, {kind}, "background"))
	}
}
