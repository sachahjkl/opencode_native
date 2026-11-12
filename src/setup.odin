// The version, the command line of the desktop integration, and the Setup dialog: the toolkit's (gt:setup), with opencode
// native's Config (desktop.odin setup_config), its logo, and the user's answer kept in settings.txt (stores.odin).
package ocn

import "core:fmt"
import "core:image/png"
import "core:os"
import desktop "gt:desktop"
import "gt:draw"
import "gt:render"
import setup "gt:setup"
import "gt:ui"

APP_VERSION :: "0.47.9"

LOGO_PNG :: #load("../assets/logo_256.png")

////////////////////////////////
// Command line: --install [--desktop], --uninstall, --status (no window; exit code 0 = done / installed)

desktop_cli :: proc(o: Cli_Options) -> (handled: bool, code: int) {
	switch {
	case o.install:
		ok, msg := setup.install(setup_config(), o.desktop)
		say(ok ? "installed: %s\n" : "install failed: %s\n", msg)
		if desktop.is_nixos() { say("%s\n", NIXOS_ADVICE) }
		return true, ok ? 0 : 1
	case o.uninstall:
		quiet := o.quiet
		if !quiet && message_box("Remove opencode native from this computer?\n\n" + LBL_PIECES + " and the program are removed. Nothing on the opencode server changes.", true) != 6 { return true, 1 }
		ok, leftovers, msg := setup.uninstall(setup_config())
		if ok { desktop_copy_remove() }
		// (this process ends now: what it holds goes after it)
		if len(leftovers) > 0 && !setup.remove_later(setup_config(), leftovers[:]) { ok, msg = false, "cannot schedule the removal of the program" }
		if !quiet { message_box(ok ? "opencode native was removed." : fmt.tprintf("The removal failed: %s", msg), false) }
		return true, ok ? 0 : 1
	case o.status:
		f := setup.facts(setup_config())
		say("%v %s\n", f.state, f.exe)
		#partial switch f.state {
		case .This_Copy, .Other_Copy, .Nix_Package: return true, 0   // (a Nix package is installed: by Nix)
		case .Repair:                               return true, 2
		}
		return true, 1
	}
	return false, 0
}


////////////////////////////////
// The logo, as a texture (the Setup dialog, the empty conversation)

Logo :: struct {
	tex:  render.Texture,
	size: [2]f32,   // of the picture, in pixels
	tint: u32,      // the accent it was painted in
}

// The edge of the bolt takes the accent. All the rest of the picture is grey, so what has a colour is that edge, its soft pixels included:
// how much of the peach of the file a pixel holds is how much of the accent it gets. (0xRRGGBBAA)
logo_tint_pixels :: proc(pixels: []u8, accent: u32) {
	to := [3]f32{f32(u8(accent >> 24)), f32(u8(accent >> 16)), f32(u8(accent >> 8))}
	for i := 0; i + 3 < len(pixels); i += 4 {
		r, g, b := pixels[i], pixels[i + 1], pixels[i + 2]
		if r <= b { continue }
		amount := min(f32(r - b) / LOGO_EDGE_CHROMA, 1)
		grey := f32(min(r, g, b))
		for c in 0 ..< 3 { pixels[i + c] = u8(grey + (to[c] - grey) * amount) }
	}
}

logo_load :: proc(app: ^App) {
	img, err := png.load_from_bytes(LOGO_PNG, {.alpha_add_if_missing}, context.temp_allocator)
	if err != nil || img == nil || img.channels != 4 || img.depth != 8 { return }
	if app.logo.tex == 0 { app.logo.tex = render.create_texture_rgba(&app.r, img.width, img.height) }
	app.logo.size = {f32(img.width), f32(img.height)}
	logo_tint_pixels(img.pixels[:], app.prefs.accent_hex)
	app.logo.tint = app.prefs.accent_hex
	render.update_texture_rgba(&app.r, app.logo.tex, 0, 0, img.width, img.height, img.pixels[:])
}

@(private = "file")
logo_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	app := (^App)(user)
	if app.logo.tex == 0 { return }
	draw.image(dc, app.logo.tex, b.rect)
}

// Paints the logo again when another accent was chosen.
@(private = "file")
logo_follow_accent :: proc(app: ^App) {
	if app.logo.tex != 0 && app.logo.tint != app.prefs.accent_hex { logo_load(app) }
}

// The logo in a square of `size` (frame pixels).
logo_box :: proc(app: ^App, id: string, size: f32) {
	logo_follow_accent(app)
	ui.next({width = ui.px(size), height = ui.px(size)})
	b := ui.build_box({}, id)
	b.custom = logo_draw
	b.custom_user = app
}

////////////////////////////////
// The Setup dialog (gt:setup). The user's answer is kept in settings.txt under "setup".

setup_open :: proc(app: ^App) {
	setup.open(&app.setup, setup_config())
}

// At a start: the dialog when there is something to do, unless the user answered already.
setup_offer_at_start :: proc(app: ^App) {
	if os.get_env("OPENCODE_NATIVE_NO_SETUP", context.temp_allocator) != "" { return }
	cfg := setup_config()
	if setup.wanted(setup.facts(cfg), APP_VERSION, settings_get(app, "setup")) { setup.open(&app.setup, cfg) }
}

setup_dialog :: proc(app: ^App, em: f32) {
	logo_follow_accent(app)
	logo: Maybe(setup.Logo)
	if app.logo.tex != 0 { logo = setup.Logo{app.logo.tex, app.logo.size} }
	ev := setup.dialog(&app.setup, setup_config(), em, logo)
	if choice, changed := setup_choice(ev, app.setup.facts, settings_get(app, "setup")); changed { settings_set(app, "setup", choice) }
	#partial switch ev {
	case .Uninstalled: desktop_copy_remove()
	case .Launched:    app.quit = true   // (the installed copy runs)
	}
}

// What an event of the dialog leaves as the user's answer. Closed without one, the dialog is not offered again for this
// version; an earlier "standalone" or "installed" stays then, unless what was declined is an upgrade.
setup_choice :: proc(ev: setup.Event, f: setup.Facts, saved: string) -> (choice: string, changed: bool) {
	#partial switch ev {
	case .Installed:       return setup.CHOICE_INSTALLED, true
	case .Kept_Standalone: return setup.CHOICE_STANDALONE, true
	case .Dismissed:
		if !setup.is_upgrade(f, APP_VERSION) && (saved == setup.CHOICE_STANDALONE || saved == setup.CHOICE_INSTALLED) { return saved, false }
		return setup.choice_dismissed(APP_VERSION), true
	}
	return saved, false
}

// At the end of the process: what an uninstall left because this process held it goes then.
setup_finish :: proc(app: ^App) {
	setup.finish(&app.setup, setup_config())
	setup.destroy(&app.setup)
}
