package ocn

import "core:os"
import "core:strings"
import "core:testing"
import "gt:draw"
import prefs_page "gt:prefs_page"
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
	prefs_page.themes_file_destroy(&app.cx.theme.file)
	the_app = prev
}

// The magenta of an entry the theme does not have (ui.theme_lookup).
@(private = "file")
MISSING :: Color{1, 0, 1, 1}

// Every name a view asks the theme for (themed, between: read in the program's own files) is an entry of every theme, dark
// and light: a name the theme lacks draws magenta. And the entries are the version shown: its texts, its steps, its hues
// (the palette's blue was 0, and a view's blue the accent).
@(test)
every_name_a_view_asks_for_is_the_themes :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	prev := theme_app(app)
	defer theme_app_end(app, prev)
	names := theme_names_asked()
	testing.expectf(t, len(names) > 20, "the names asked for, read in the sources: %d", len(names))
	for def, i in themes(app) {
		for light in ([]bool{false, true}) {
			theme_set(app, i, light)
			th: ui.Theme
			theme_setup(&th)
			defer ui.theme_destroy(&th)
			for name in names {
				testing.expectf(t, ui.theme_lookup(&th, nil, name) != MISSING, "%s (light %v): no entry %q", def.name, light, name)
			}
			c := theme_colors()
			testing.expect_value(t, ui.theme_lookup(&th, nil, "faint text"), draw.hex(c.texts[0]))
			testing.expect_value(t, ui.theme_lookup(&th, nil, "weak text"), draw.hex(c.texts[1]))
			testing.expect_value(t, ui.theme_lookup(&th, nil, "text"), draw.hex(c.texts[2]))
			testing.expect_value(t, ui.theme_lookup(&th, nil, "bright text"), draw.hex(c.texts[3]))
			// (the toolkit's soft text is the one ocn made: 70 % of the way from weak to text, in sRGB steps)
			testing.expect_value(t, ui.theme_lookup(&th, nil, "soft text"), ui.srgb_step(draw.hex(c.texts[1]), draw.hex(c.texts[2]), 0.7))
			testing.expect_value(t, ui.theme_lookup(&th, nil, "well"), draw.hex(c.steps[0]))
			testing.expect_value(t, ui.theme_lookup(&th, nil, "background"), draw.hex(c.steps[1]))
			testing.expect_value(t, ui.theme_lookup(&th, nil, "bar background"), draw.hex(c.steps[2]))
			testing.expect_value(t, ui.theme_lookup(&th, nil, "card background"), draw.hex(c.steps[3]))
			testing.expect_value(t, ui.theme_lookup(&th, nil, "button background"), draw.hex(c.steps[4]))
			testing.expect_value(t, ui.theme_lookup(&th, nil, "border"), draw.hex(c.steps[5]))
			hue_names := [8]string{"hue_accent", "hue_blue", "hue_purple", "hue_green", "hue_yellow", "hue_red", "hue_cyan", "hue_rose"}
			for name, h in hue_names { testing.expect_value(t, ui.theme_lookup(&th, nil, name), draw.hex(c.hues[h])) }
		}
	}
}

// The names in `ui.theme_color("…")` and `between("…", "…", t)` in the program's files.
@(private = "file")
theme_names_asked :: proc() -> []string {
	names := make([dynamic]string, context.temp_allocator)
	entries, err := os.read_all_directory_by_path(#directory, context.temp_allocator)
	if err != nil { return nil }
	for e in entries {
		if !strings.has_suffix(e.name, ".odin") || strings.has_suffix(e.name, "_test.odin") { continue }
		data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
		if rerr != nil { continue }
		rest := string(data)
		for {
			at := min_index(strings.index(rest, "ui.theme_color("), strings.index(rest, "between("))
			if at < 0 { break }
			// (another package's procedure of that name, diff.between, or a longer name: not ours)
			if at > 0 {
				b := rest[at - 1]
				if b == '.' || b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') { rest = rest[at + 1:]; continue }
			}
			rest = rest[at:]
			end := strings.index_byte(rest, ')')
			if end < 0 { break }
			call := rest[:end]
			rest = rest[end:]
			// (each quoted name in the call)
			for {
				q := strings.index_byte(call, '"')
				if q < 0 { break }
				call = call[q + 1:]
				close := strings.index_byte(call, '"')
				if close < 0 { break }
				append(&names, call[:close])
				call = call[close + 1:]
			}
		}
	}
	return names[:]
}

@(private = "file")
min_index :: proc(a, b: int) -> int {
	if a < 0 { return b }
	if b < 0 { return a }
	return min(a, b)
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
			c := theme_colors()
			text, page, bright, weak, accent := draw.hex(c.texts[2]), draw.hex(c.steps[1]), draw.hex(c.texts[3]), draw.hex(c.texts[1]), draw.hex(c.hues[0])
			testing.expectf(t, ui.contrast(text, page) >= READABLE_TEXT, "%s (light %v): the text on the conversation, %.2f", def.name, light, ui.contrast(text, page))
			g := chosen_ground()
			title := ui.readable(bright, g, READABLE_TEXT)
			quiet := ui.readable(weak, g, READABLE_QUIET)
			testing.expectf(t, ui.contrast(title, g) >= READABLE_TEXT, "%s (light %v): the title of the session shown, %.2f", def.name, light, ui.contrast(title, g))
			testing.expectf(t, ui.contrast(quiet, g) >= READABLE_QUIET, "%s (light %v): its folder and its age, %.2f", def.name, light, ui.contrast(quiet, g))
			// an accent button's label (Send, New session) on the accent
			on_accent := draw.hex(themed_palette().accent_text)
			testing.expectf(t, ui.contrast(on_accent, accent) >= READABLE_QUIET, "%s (light %v): a label on the accent, %.2f", def.name, light, ui.contrast(on_accent, accent))
		}
	}
}


// An intent's button (accent, danger, success...) in a dialog keeps its own background (and its label stays readable on
// it): an entry of ours for what floats, ahead of the palette's, won over the button's (the setup dialog's Uninstall:
// white on white).
@(test)
a_button_in_a_dialog_keeps_its_background :: proc(t: ^testing.T) {
	th: ui.Theme
	defer ui.theme_destroy(&th)
	theme_setup(&th)
	floating := ui.theme_lookup(&th, {"floating"}, "background")
	for intent in ui.Intent {
		kind := ui.intent_tag(intent)
		if kind == "" { continue }
		bg := ui.theme_lookup(&th, {"floating", kind}, "background")
		testing.expectf(t, bg != floating, "%s in a dialog: its own background, not the dialog's", kind)
		testing.expect_value(t, bg, ui.theme_lookup(&th, {kind}, "background"))
	}
}
