// The themes: the colours of the whole interface, from a few of each theme's own, in a dark and a light version. Every colour this
// program draws is one of opencode's (the HEX_ constants, in style.odin and beside what uses them); a theme moves each to its own:
// a grey to the same place on the theme's steps (its backgrounds, its lines, its texts), a colour to the theme's colour of the
// nearest hue, mixed as much with the theme's grey as it was with opencode's. OpenCode dark is opencode's: it moves nothing.
// Themes of the user's own come from themes.txt, beside the preferences (theme_load).
package occ

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import "gt:platform"
import "gt:ui"

// A theme's colours (0xRRGGBBAA, sRGB). Its steps: what is sunk (wells, code), the conversation, the bars and the sidebar, the
// cards, what is raised, the lines; its texts, from the faintest; its colours, in the order of THEME_HUES.
Theme_Colors :: struct {
	steps: [6]u32,   // well, bg0, bg1, bg2, bg3, line
	texts: [4]u32,   // faint, weak, text, bright
	hues:  [8]u32,   // accent (opencode's peach), blue, purple, green, yellow, red, cyan, rose
}

Theme_Def :: struct {
	name:      string,
	dark:      Theme_Colors,
	light:     Theme_Colors,
	has_light: bool,   // (a theme of the user's with no light colours stays dark)
}

// opencode's own colours, that the others take the place of (the order of Theme_Colors.hues)
THEME_HUES := [8]u32{HEX_PEACH, HEX_BLUE, HEX_PURPLE, HEX_GREEN, HEX_YELLOW, HEX_RED, HEX_CYAN, HEX_ROSE}

// Where opencode's greys stand (their level, 0..255), and what of a theme each is: what is under the well, the well, the
// backgrounds, the line, the texts. A grey between two of them goes between the theme's two.
@(private = "file")
GREY_LEVELS := [?]f32{0, 6, 10, 16, 22, 30, 42, 90, 143, 200, 237, 255}

@(private = "file") BLACK_STEPS :: [6]u32{0x070707ff, 0x0a0a0aff, 0x101010ff, 0x161616ff, 0x1e1e1eff, 0x2a2a2aff}
@(private = "file") BLACK_TEXTS :: [4]u32{0x5a5a5aff, 0x8f8f8fff, 0xedededff, 0xffffffff}
@(private = "file") WHITE_STEPS :: [6]u32{0xe8e8e8ff, 0xf9f9f9ff, 0xf1f1f1ff, 0xffffffff, 0xffffffff, 0xdadadaff}
@(private = "file") WHITE_TEXTS :: [4]u32{0xa3a3a3ff, 0x6b6b6bff, 0x1c1c1cff, 0x000000ff}
@(private = "file") LIGHT_HUES  :: [7]u32{0x2f6fdbff, 0x7c4dd8ff, 0x2f8a3aff, 0xb57d07ff, 0xc9303eff, 0x12838fff, 0xc83e6aff}   // blue to rose, for white

// opencode's black (or white) with one accent of its own
@(private = "file")
black_theme :: proc(name: string, dark, light: u32) -> Theme_Def {
	l := LIGHT_HUES
	return {name, {BLACK_STEPS, BLACK_TEXTS, {dark, HEX_BLUE, HEX_PURPLE, HEX_GREEN, HEX_YELLOW, HEX_RED, HEX_CYAN, HEX_ROSE}},
		{WHITE_STEPS, WHITE_TEXTS, {light, l[0], l[1], l[2], l[3], l[4], l[5], l[6]}}, true}
}

// The program's themes, made once (black_theme is no constant).
@(private = "file")
themes_builtin :: proc() -> []Theme_Def {
	@(static) made: [dynamic]Theme_Def
	if len(made) > 0 { return made[:] }
	append(&made,
		black_theme("OpenCode", HEX_PEACH, 0xc8622aff),
		black_theme("Ink", 0x6aa8ffff, 0x2f6fdbff),
		black_theme("Orchid", 0xb294f0ff, 0x7c4dd8ff),
		black_theme("Moss", 0x8fd694ff, 0x2f8a3aff),
		black_theme("Lagoon", 0x5ccbd6ff, 0x12838fff),
		black_theme("Rose", 0xf28ba8ff, 0xc83e6aff),
		Theme_Def{"Monokai",
			{{0x161713ff, 0x1c1d19ff, 0x22231eff, 0x272822ff, 0x30312aff, 0x3e3d32ff}, {0x75715eff, 0x9d9a8aff, 0xf8f8f2ff, 0xffffffff},
				{0xfd971fff, 0x66d9efff, 0xae81ffff, 0xa6e22eff, 0xe6db74ff, 0xf92672ff, 0x78dce8ff, 0xff6188ff}},
			{{0xe8e6dfff, 0xfafaf8ff, 0xf2f1ecff, 0xffffffff, 0xffffffff, 0xd9d7cfff}, {0xa59f85ff, 0x75715eff, 0x272822ff, 0x000000ff},
				{0xd96a00ff, 0x0f8fa8ff, 0x7c4dffff, 0x5c8a00ff, 0x9e8600ff, 0xd01b5fff, 0x0f8fa8ff, 0xe0457bff}}, true},
		Theme_Def{"Gruvbox",
			{{0x141617ff, 0x1a1c1dff, 0x1d2021ff, 0x282828ff, 0x32302fff, 0x45403dff}, {0x7c6f64ff, 0xa89984ff, 0xebdbb2ff, 0xfbf1c7ff},
				{0xfe8019ff, 0x83a598ff, 0xd3869bff, 0xb8bb26ff, 0xfabd2fff, 0xfb4934ff, 0x8ec07cff, 0xd3869bff}},
			{{0xebdbb2ff, 0xfbf1c7ff, 0xf2e5bcff, 0xfdf6d8ff, 0xfffbe8ff, 0xd5c4a1ff}, {0xa89984ff, 0x7c6f64ff, 0x3c3836ff, 0x282828ff},
				{0xaf3a03ff, 0x076678ff, 0x8f3f71ff, 0x79740eff, 0xb57614ff, 0x9d0006ff, 0x427b58ff, 0x8f3f71ff}}, true},
		Theme_Def{"Dracula",
			{{0x15161cff, 0x1b1c24ff, 0x21222cff, 0x282a36ff, 0x303241ff, 0x44475aff}, {0x6272a4ff, 0x9ea6c9ff, 0xf8f8f2ff, 0xffffffff},
				{0xbd93f9ff, 0x8be9fdff, 0xbd93f9ff, 0x50fa7bff, 0xf1fa8cff, 0xff5555ff, 0x8be9fdff, 0xff79c6ff}},
			{{0xeee9d4ff, 0xfffbebff, 0xf4efdaff, 0xfffdf4ff, 0xffffffff, 0xdcd6bfff}, {0x9a948aff, 0x6c664bff, 0x1f1f1fff, 0x000000ff},
				{0x644ac9ff, 0x036a96ff, 0x644ac9ff, 0x14710aff, 0x846e15ff, 0xcb3a2aff, 0x036a96ff, 0xa3144dff}}, true},
		Theme_Def{"Nord",
			{{0x1f232bff, 0x252a33ff, 0x2a2f3aff, 0x2e3440ff, 0x3b4252ff, 0x434c5eff}, {0x616e88ff, 0x8a96acff, 0xe5e9f0ff, 0xeceff4ff},
				{0x88c0d0ff, 0x81a1c1ff, 0xb48eadff, 0xa3be8cff, 0xebcb8bff, 0xbf616aff, 0x8fbcbbff, 0xd08770ff}},
			{{0xd8dee9ff, 0xeceff4ff, 0xe5e9f0ff, 0xf6f8fbff, 0xffffffff, 0xcdd3deff}, {0x8a93a6ff, 0x5c6a83ff, 0x2e3440ff, 0x1d222bff},
				{0x5e81acff, 0x5e81acff, 0x8f6c8dff, 0x6e8a55ff, 0xb08a3aff, 0xbf616aff, 0x4f8f8fff, 0xc0704fff}}, true},
		Theme_Def{"Tokyo Night",
			{{0x101118ff, 0x14151eff, 0x16161eff, 0x1a1b26ff, 0x24283bff, 0x2f344dff}, {0x565f89ff, 0x787fa8ff, 0xc0caf5ff, 0xe4e9ffff},
				{0x7aa2f7ff, 0x7aa2f7ff, 0xbb9af7ff, 0x9ece6aff, 0xe0af68ff, 0xf7768eff, 0x7dcfffff, 0xff9e64ff}},
			{{0xd5d6dbff, 0xe9e9edff, 0xe1e2e7ff, 0xf2f2f5ff, 0xfafafcff, 0xc4c8daff}, {0x8990b3ff, 0x6172b0ff, 0x3760bfff, 0x1e2a5aff},
				{0x2e7de9ff, 0x2e7de9ff, 0x9854f1ff, 0x587539ff, 0x8c6c3eff, 0xf52a65ff, 0x007197ff, 0xb15c00ff}}, true},
		Theme_Def{"Catppuccin",
			{{0x0b0b12ff, 0x11111bff, 0x181825ff, 0x1e1e2eff, 0x282839ff, 0x313244ff}, {0x6c7086ff, 0x9399b2ff, 0xcdd6f4ff, 0xf2f5ffff},
				{0xcba6f7ff, 0x89b4faff, 0xcba6f7ff, 0xa6e3a1ff, 0xf9e2afff, 0xf38ba8ff, 0x94e2d5ff, 0xf5c2e7ff}},
			{{0xdce0e8ff, 0xeff1f5ff, 0xe6e9efff, 0xf7f8faff, 0xffffffff, 0xccd0daff}, {0x9ca0b0ff, 0x6c6f85ff, 0x4c4f69ff, 0x1e2030ff},
				{0x8839efff, 0x1e66f5ff, 0x8839efff, 0x40a02bff, 0xdf8e1dff, 0xd20f39ff, 0x179299ff, 0xea76cbff}}, true},
		Theme_Def{"One Dark",
			{{0x14161aff, 0x1b1d23ff, 0x21252bff, 0x282c34ff, 0x2c313aff, 0x3e4451ff}, {0x5c6370ff, 0x8a919eff, 0xd7dae0ff, 0xffffffff},
				{0x61afefff, 0x61afefff, 0xc678ddff, 0x98c379ff, 0xe5c07bff, 0xe06c75ff, 0x56b6c2ff, 0xd19a66ff}},
			{{0xe5e5e6ff, 0xfafafaff, 0xf0f0f1ff, 0xffffffff, 0xffffffff, 0xdbdbdcff}, {0xa0a1a7ff, 0x696c77ff, 0x383a42ff, 0x000000ff},
				{0x4078f2ff, 0x4078f2ff, 0xa626a4ff, 0x50a14fff, 0xc18401ff, 0xe45649ff, 0x0184bcff, 0x986801ff}}, true},
		Theme_Def{"Campbell",
			{{0x050505ff, 0x0c0c0cff, 0x121212ff, 0x181818ff, 0x202020ff, 0x303030ff}, {0x767676ff, 0x9e9e9eff, 0xccccccff, 0xf2f2f2ff},
				{0x3b78ffff, 0x3b78ffff, 0xb4009eff, 0x16c60cff, 0xc19c00ff, 0xe74856ff, 0x61d6d6ff, 0xb4009eff}},
			{{0xdededeff, 0xf7f7f7ff, 0xeeeeeeff, 0xffffffff, 0xffffffff, 0xd0d0d0ff}, {0x8a8a8aff, 0x5e5e5eff, 0x0c0c0cff, 0x000000ff},
				{0x0037daff, 0x0037daff, 0x881798ff, 0x13a10eff, 0xc19c00ff, 0xc50f1fff, 0x3a96ddff, 0x881798ff}}, true},
		Theme_Def{"Retro",
			{{0x000000ff, 0x050505ff, 0x0b0b0bff, 0x121212ff, 0x1a1a1aff, 0x2b2b2bff}, {0x626262ff, 0x9c9c94ff, 0xe8e6dcff, 0xffffffff},
				{0xffaf00ff, 0x5f87ffff, 0xaf87ffff, 0x87d75fff, 0xffd75fff, 0xff5f5fff, 0x5fd7d7ff, 0xff87afff}},
			{{0xe4dfd0ff, 0xf5f2e8ff, 0xece8dbff, 0xfbf9f2ff, 0xffffffff, 0xd2ccb9ff}, {0x9a9484ff, 0x6a655aff, 0x1a1a1aff, 0x000000ff},
				{0xd75f00ff, 0x005fd7ff, 0x8700afff, 0x008700ff, 0xaf8700ff, 0xd70000ff, 0x008787ff, 0xd7005fff}}, true},
		Theme_Def{"Naysayer",
			{{0x03161bff, 0x041c22ff, 0x052026ff, 0x062329ff, 0x0b2d34ff, 0x154049ff}, {0x4e7a6eff, 0x8f9f88ff, 0xd1b897ff, 0xffffffff},
				{0x8cde94ff, 0x7ad0c6ff, 0xc39ad8ff, 0x44b340ff, 0xe0c46cff, 0xf0605cff, 0x2ec09cff, 0xd68fa3ff}},
			{{0xe6dcc4ff, 0xf4ecd8ff, 0xece2caff, 0xfaf5e8ff, 0xfffcf2ff, 0xd6c9a8ff}, {0x9a8f74ff, 0x5f6b5cff, 0x062329ff, 0x021014ff},
				{0x2e8a4fff, 0x1f7f86ff, 0x8a4fa0ff, 0x2f7f2bff, 0x9c7a12ff, 0xc0392bff, 0x16806aff, 0xb05072ff}}, true},
		Theme_Def{"Solarized",
			{{0x001d24ff, 0x00232bff, 0x002731ff, 0x002b36ff, 0x073642ff, 0x0f4552ff}, {0x586e75ff, 0x839496ff, 0xe4dfcdff, 0xfdf6e3ff},
				{0x268bd2ff, 0x268bd2ff, 0x6c71c4ff, 0x859900ff, 0xb58900ff, 0xdc322fff, 0x2aa198ff, 0xd33682ff}},
			{{0xeee8d5ff, 0xfdf6e3ff, 0xf5efdcff, 0xfffbeeff, 0xffffffff, 0xddd6c1ff}, {0x93a1a1ff, 0x657b83ff, 0x073642ff, 0x002b36ff},
				{0x268bd2ff, 0x268bd2ff, 0x6c71c4ff, 0x859900ff, 0xb58900ff, 0xdc322fff, 0x2aa198ff, 0xd33682ff}}, true},
	)
	return made[:]
}

// The themes there are, the one shown and in which version, and opencode's colours as it has them (made as they are asked for:
// the same few hundred each frame).
Theme_State :: struct {
	all:      [dynamic]Theme_Def,   // the program's, then the user's (their names owned)
	own:      int,                  // where the user's begin in all
	file_at:  time.Time,            // themes.txt as it was read (its time: read again when it changes)
	at:       int,
	light:    bool,                 // the light version shown
	identity: bool,                 // OpenCode dark: nothing moves
	colors:   Theme_Colors,
	cache:    map[u32]u32,
	scheme:   u32,                  // the system's light / dark, as platform.color_scheme_serial last said
}

// The themes there are: the program's, then the user's.
themes :: proc(app: ^App) -> []Theme_Def { return len(app.cx.theme.all) > 0 ? app.cx.theme.all[:] : themes_builtin() }

// The theme of this name ("" or an unknown one: opencode's).
theme_index :: proc(app: ^App, name: string) -> int {
	for t, i in themes(app) { if strings.equal_fold(t.name, name) { return i } }
	return 0
}

// Whether the light version is meant: the mode asked for (appearance.mode), the system's for "system".
theme_wants_light :: proc(mode: string) -> bool {
	switch mode {
	case "light": return true
	case "dark":  return false
	}
	return !platform.dark_mode_preferred()
}

// Shows theme `at`, light or dark (a theme with no light version: dark).
theme_set :: proc(app: ^App, asked: int, light_asked: bool) {
	all := themes(app)
	ts := &app.cx.theme
	at := asked < len(all) ? asked : 0
	light := light_asked && all[at].has_light
	if at == ts.at && light == ts.light && ts.colors != {} { return }
	ts.at, ts.light = at, light
	ts.colors = light ? all[at].light : all[at].dark
	ts.identity = at == 0 && !light
	clear(&ts.cache)
}

// The windows' title bars, as the version shown: the system draws them dark or light.
theme_titles :: proc(app: ^App) {
	dark := !app.cx.theme.light
	if app.win != nil { platform.set_dark_title(app.win, dark) }
	for d in app.cx.detached { if d.win != nil { platform.set_dark_title(d.win, dark) } }
}

// Whether what is shown is a light version (its surfaces are flat: the machined reliefs are made for the dark).
theme_light :: proc() -> bool { return the_app != nil && the_app.cx.theme.light }

// One of opencode's colours, as the theme shown has it.
themed :: proc(c: u32) -> u32 {
	app := the_app
	if app == nil || app.cx.theme.identity || app.cx.theme.colors == {} { return c }
	if v, ok := app.cx.theme.cache[c]; ok { return v }
	v := theme_color(&app.cx.theme.colors, c)
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

// opencode's colour `c` in colours `t`.
theme_color :: proc(t: ^Theme_Colors, c: u32) -> u32 {
	col := rgb3(c)
	a := c & 0xff
	lo, hi := min(col.r, col.g, col.b), max(col.r, col.g, col.b)
	if hi - lo <= THEME_GREY_SPREAD { return pack3(theme_grey(t, (col.r + col.g + col.b) / 3), a) }
	// a colour: the hue of opencode's it is nearest to, and how much of it, over a grey (c = (1 - k) grey + k hue)
	best, best_k, best_grey, best_err := 0, f32(1), f32(0), max(f32)
	for h, i in THEME_HUES {
		base := rgb3(h)
		for step in 0 ..= THEME_MIX_STEPS {
			k := f32(step) / THEME_MIX_STEPS
			grey, err: f32
			if k >= 1 {
				d := col - base
				err = d.r * d.r + d.g * d.g + d.b * d.b
			} else {
				g := (col - base * k) / (1 - k)
				grey = (g.r + g.g + g.b) / 3
				if grey < 0 || grey > 255 { continue }
				d := (g - grey) * (1 - k)
				err = d.r * d.r + d.g * d.g + d.b * d.b
			}
			if err < best_err { best, best_k, best_grey, best_err = i, k, grey, err }
		}
	}
	out := rgb3(t.hues[best]) * best_k
	if best_k < 1 { out += theme_grey(t, best_grey) * (1 - best_k) }
	return pack3(out, a)
}

THEME_GREY_SPREAD :: 3     // channels this close: a grey
THEME_MIX_STEPS   :: 64    // how finely a colour's share of its hue is looked for

// opencode's grey of this level, on the theme's steps.
@(private = "file")
theme_grey :: proc(t: ^Theme_Colors, level: f32) -> [3]f32 {
	well := rgb3(t.steps[0])
	under := rgb3(t.steps[1]) + (well - rgb3(t.steps[1])) * 2   // (past the well, as far again)
	stops := [len(GREY_LEVELS)][3]f32{
		under, well, rgb3(t.steps[1]), rgb3(t.steps[2]), rgb3(t.steps[3]), rgb3(t.steps[4]), rgb3(t.steps[5]),
		rgb3(t.texts[0]), rgb3(t.texts[1]), rgb3(t.texts[1]) * 0.3 + rgb3(t.texts[2]) * 0.7, rgb3(t.texts[2]), rgb3(t.texts[3]),
	}
	if level <= GREY_LEVELS[0] { return stops[0] }
	for i in 1 ..< len(GREY_LEVELS) {
		if level <= GREY_LEVELS[i] {
			f := (level - GREY_LEVELS[i - 1]) / (GREY_LEVELS[i] - GREY_LEVELS[i - 1])
			return stops[i - 1] * (1 - f) + stops[i] * f
		}
	}
	return stops[len(stops) - 1]
}

@(private = "file")
rgb3 :: proc(c: u32) -> [3]f32 { return {f32(c >> 24 & 0xff), f32(c >> 16 & 0xff), f32(c >> 8 & 0xff)} }

@(private = "file")
pack3 :: proc(c: [3]f32, a: u32) -> u32 {
	ch :: proc(v: f32) -> u32 { return u32(clamp(math.round(v), 0, 255)) }
	return ch(c.r) << 24 | ch(c.g) << 16 | ch(c.b) << 8 | a
}

////////////////////////////////
// Themes of the user's own: themes.txt

// Where they are: beside the preferences.
themes_file :: proc(app: ^App) -> string {
	if app.prefs_file == "" { return "" }
	p, _ := filepath.join({filepath.dir(app.prefs_file), THEMES_FILE}, context.temp_allocator)
	return p
}

// What a new themes.txt says: how it is read, and a theme to start from (commented: nothing changes until it is written).
THEMES_TEMPLATE :: `# Themes of your own. Each [section] is one, by its name; it shows in Settings > Appearance after the program's.
# A colour is #rrggbb. What is not given is OpenCode's. The keys, for the dark version:
#   well bg0 bg1 bg2 bg3 line        the steps: wells and code, the conversation, the bars, the cards, what is raised, the lines
#   faint weak text bright           the texts, from the faintest
#   accent blue purple green yellow red cyan rose
# and the same with "light." before them for the light version (a theme with none stays dark in light mode).
# A theme can start from another: from = Gruvbox
#
# [My theme]
# from = OpenCode
# accent = #e5c07b
# bg0 = #050505
# light.accent = #b58900
`

// The user's themes, read again when themes.txt changed (or at the start). The program's are first; a theme of the user's of the
// same name as one of them is the user's.
theme_load :: proc(app: ^App) {
	path := themes_file(app)
	if path == "" { return }
	ts := &app.cx.theme
	info, err := os.stat(path, context.temp_allocator)
	stamp := err == nil ? info.modification_time : time.Time{}
	if len(ts.all) > 0 && stamp == ts.file_at { return }
	ts.file_at = stamp
	for t in ts.all[ts.own:] { delete(t.name) }
	clear(&ts.all)
	append(&ts.all, ..themes_builtin())
	ts.own = len(ts.all)
	if err != nil { return }
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil { return }
	cur := -1
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' || l[0] == ';' { continue }
		if l[0] == '[' && l[len(l) - 1] == ']' {
			name := strings.trim_space(l[1:len(l) - 1])
			if name == "" { cur = -1; continue }
			base := themes_builtin()[0]
			base.has_light = false
			base.name = strings.clone(name)
			append(&ts.all, base)
			cur = len(ts.all) - 1
			continue
		}
		eq := strings.index_byte(l, '=')
		if cur < 0 || eq < 0 { continue }
		theme_key(&ts.all[cur], strings.to_lower(strings.trim_space(l[:eq]), context.temp_allocator), strings.trim_space(l[eq + 1:]))
	}
	// (of the user's, the last of a name; a program's of that name gives way to it)
	for i := len(ts.all) - 1; i >= ts.own; i -= 1 {
		for j in 0 ..< i {
			if strings.equal_fold(ts.all[j].name, ts.all[i].name) {
				if j >= ts.own { delete(ts.all[j].name); ordered_remove(&ts.all, j); i -= 1 } else { ts.all[j].name = "" }
				break
			}
		}
	}
	for i := ts.own - 1; i >= 0; i -= 1 { if ts.all[i].name == "" { ordered_remove(&ts.all, i); ts.own -= 1 } }
	app.cx.theme.colors = {}   // (shown again, as the file has it now)
}

// A line of a theme in themes.txt.
@(private = "file")
theme_key :: proc(t: ^Theme_Def, key, value: string) {
	if key == "from" {
		for b in themes_builtin() {
			if strings.equal_fold(b.name, value) { name := t.name; t^ = b; t.name = name; return }
		}
		return
	}
	c, ok := theme_hex(value)
	if !ok { return }
	cols := &t.dark
	k := key
	if strings.has_prefix(k, "light.") { cols, k = &t.light, k[len("light."):]; t.has_light = true }
	else if strings.has_prefix(k, "dark.") { k = k[len("dark."):] }
	NAMES :: [?]string{"well", "bg0", "bg1", "bg2", "bg3", "line", "faint", "weak", "text", "bright", "accent", "blue", "purple", "green", "yellow", "red", "cyan", "rose"}
	for n, i in NAMES {
		if n != k { continue }
		switch {
		case i < 6:  cols.steps[i] = c
		case i < 10: cols.texts[i - 6] = c
		case:        cols.hues[i - 10] = c
		}
	}
}

// #rrggbb (or rrggbb) as 0xRRGGBBFF.
@(private = "file")
theme_hex :: proc(s: string) -> (u32, bool) {
	h := strings.trim_prefix(s, "#")
	if len(h) != 6 { return 0, false }
	v, ok := strconv.parse_uint(h, 16)
	if !ok { return 0, false }
	return u32(v) << 8 | 0xff, true
}

// themes.txt, opened in the system's editor (made from the template first if there is none).
themes_file_open :: proc(app: ^App) {
	path := themes_file(app)
	if path == "" { return }
	if !os.exists(path) {
		if os.write_entire_file(path, transmute([]u8)string(THEMES_TEMPLATE)) != nil { ui.toast(.Bad, "%s could not be written", THEMES_FILE); return }
	}
	_ = platform.open_path(path)
}
