// The version, the logo, and the install: the toolkit's (prefs_page.Install over gt:setup: the offer at a start, the
// install's dialog, the settings' Installation page, --install / --uninstall / --setup), with opencode native's options
// (desktop.odin setup_options) and its logo in the dialog.
package ocn

import "core:image/png"
import "gt:draw"
import prefs_page "gt:prefs_page"
import "gt:render"
import setup "gt:setup"
import "gt:ui"

APP_VERSION :: "0.53.2"

LOGO_PNG :: #load("../assets/logo_256.png")

////////////////////////////////
// The logo, as a texture (the install's dialog, the empty conversation)

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
// The install's dialog, each frame (the work that ended, the user's answer kept in the settings: install.choice)

setup_frame :: proc(app: ^App, em: f32) {
	logo_follow_accent(app)
	app.install.logo = nil
	if app.logo.tex != 0 { app.install.logo = setup.Logo{app.logo.tex, app.logo.size} }
	if prefs_page.install_frame(&app.install, em) == .Launched { app.quit = true }   // (the installed copy starts at the end: main)
}
