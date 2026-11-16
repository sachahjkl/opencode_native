// Pairing a device (a phone, another computer) with the server, as OpenCode does: the server makes a short-lived code that works
// once (POST /api/pair), and its link `<server address>/auth/connect/<code>` signs a browser in to the web app (or gives a client
// a token). The dialog shows the link of each address the server is reached at (GET /api/info `urls`), large as a QR code for the
// first one another device can reach (not a loopback address: a tunnel, a network address), and how long the code lasts.
package ocn

import tk_json "gt:json"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

PAIR_QR_EM      :: 15     // the QR code's side
PAIR_TICK_MS    :: 1000   // the time left is said to the second
PAIR_CONNECT    :: "/auth/connect/"
PAIR_HOSTNAME_HINT :: "opencode service set hostname 0.0.0.0"

Pair :: struct {
	code:       string,   // (owned) "": none yet
	expires_ms: f64,      // ui.now_ms() when the code stops working
	failed:     string,   // (owned) why no code came
}

// Opens the dialog with a new code (a code works once: each opening makes one).
pair_open :: proc(app: ^App) {
	ui.view_open(&app.program_views, PAIR_VIEW, app)
	pair_new_code(app)
	request(app, .Info, "GET", "/api/info")   // (the addresses: a tunnel may have come or gone)
}

@(private = "file")
pair_new_code :: proc(app: ^App) {
	p := &app.pair
	delete(p.code); p.code = ""
	delete(p.failed); p.failed = ""
	request(app, .Pair, "POST", "/api/pair")
}

// The server's answer: the code and how many seconds it lasts.
pair_load :: proc(app: ^App, code: string, expires_in: f64) {
	p := &app.pair
	delete(p.code)
	p.code = strings.clone(code)
	p.expires_ms = ui.now_ms() + expires_in * 1000
}

pair_failed :: proc(app: ^App, why: string) {
	p := &app.pair
	delete(p.failed)
	p.failed = strings.clone(why != "" ? why : i18n.tr("The server made no pairing code"))
}

server_urls_clear :: proc(app: ^App) {
	for u in app.server_urls { delete(u) }
	clear(&app.server_urls)
}

pair_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { pair_load(app, tk_json.text(v, "code"), tk_json.number(v, "expires_in")) }

pair_on_fail :: proc(app: ^App, r: ^Request, f: Failure, message: string) -> (told: bool) {
	pair_failed(app, message)
	return true   // (the dialog says it, with its Try again)
}

// The server's version and the addresses it is reached at.
info_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) {
	delete(app.server_version); app.server_version = strings.clone(tk_json.text(v, "version"))
	server_urls_clear(app)
	for u in tk_json.array(v, "urls") { if s, ok := u.(json.String); ok && s != "" { append(&app.server_urls, strings.clone(string(s))) } }
}

// The link that redeems `code` at the server's address `url` (temp memory).
pair_link :: proc(url, code: string) -> string {
	return fmt.tprintf("%s%s%s", strings.trim_right(url, "/"), PAIR_CONNECT, code)
}

// The address of the QR code: the first one another device can reach ("": none, the server listens on this machine only).
pair_reachable :: proc(urls: []string) -> string {
	for u in urls { if !url_is_here(u) { return u } }
	return ""
}

// (its title is the view's header)
pair_view :: proc(v: ^ui.View, app: ^App) {
	em := ui.font_size()
	ui.space(ui.SPACE_4)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###pair") {
		ui.space(ui.SPACE_6)
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column() { pair_body(app, v, em) }
		ui.space(ui.SPACE_6)
	}
	ui.space(ui.SPACE_4)
}

// Closed, whichever way: the code goes (it works once, and only for the server it came from).
pair_closed :: proc(app: ^App) {
	p := &app.pair
	delete(p.code)
	p.code = ""
}

// The server left: its code with it.
pair_forget :: proc(app: ^App) {
	ui.view_close(&app.program_views, PAIR_VIEW)
	pair_closed(app)
}

@(private = "file")
pair_body :: proc(app: ^App, v: ^ui.View, em: f32) {
	p := &app.pair
	soft := ui.Style_Mod{font_size = math.round(em * FS_LABEL)}
	note := ui.Style_Mod{font_size = math.round(em * FS_NOTE)}
	if p.failed != "" {
		pair_note("###f", p.failed, ui.hue(.Red), soft)
		ui.space(ui.SPACE_3)
		if ui.button("pair_retry", i18n.tr("Try again"), lucide.REFRESH_CW).clicked { pair_new_code(app) }
		return
	}
	if p.code == "" {
		// (as tall as what it holds: it opens at the QR code's size, not at this line's that the code then pushes down)
		ui.view_not_ready(v)
		pair_note("###w", i18n.tr("Asking the server for a code…"), ui.theme_color("weak text"), soft)
		animate(app)
		return
	}
	left := (p.expires_ms - ui.now_ms()) / 1000
	urls := app.server_urls[:]
	reach := pair_reachable(urls)
	if left > 0 && reach != "" {
		// large, centred: what a phone's camera reads
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###pair_qr_row") {
			ui.spacer(ui.fill())
			ui.qr_code("###pair_qr", pair_link(reach, p.code), math.round(em * PAIR_QR_EM))
			ui.spacer(ui.fill())
		}
		ui.space(ui.SPACE_3)
		pair_note("###s", i18n.tr("Scan it with the device's camera, or open one of these links on it. A link works once."), ui.theme_color("soft text"), note)
	} else if left > 0 {
		pair_note("###s", i18n.tr("Open one of these links on the device. A link works once."), ui.theme_color("soft text"), note)
	}
	ui.space(ui.SPACE_2)
	if left > 0 {
		for u, i in urls {
			pair_link_row(app, fmt.tprintf("###pl%d", i), url_is_here(u) ? i18n.tr("This computer") : i18n.tr("Link"), pair_link(u, p.code), em)
		}
		ui.space(ui.SPACE_2)
		mins, secs := int(left) / 60, int(left) % 60
		pair_note("###x", fmt.tprintf(i18n.tr("The code expires in %d:%02d."), mins, secs), ui.theme_color("weak text"), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
		ui.wake_within(built_state(app), PAIR_TICK_MS)
	} else {
		pair_note("###x", i18n.tr("This code expired."), ui.theme_color("weak text"), soft)
	}
	if reach == "" {
		ui.space(ui.SPACE_2)
		pair_note("###h", fmt.tprintf(i18n.tr("The server can be reached from this computer only. To pair another device, run `%s`."), PAIR_HOSTNAME_HINT), ui.theme_color("weak text"), note)
	}
	ui.space(ui.SPACE_3)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###pair_buttons") {
		ui.spacer(ui.fill())
		if ui.button("pair_new", i18n.tr("New code"), lucide.REFRESH_CW).clicked { pair_new_code(app) }
		ui.space(ui.CONTROL_GAP)
		if ui.button("pair_close", i18n.tr("Close"), lucide.X).clicked { ui.view_end(v, ui.VIEW_CANCELLED) }
	}
}

// A sentence of the dialog: as wide as the dialog, as tall as its lines.
@(private = "file")
pair_note :: proc(id, s: string, color: Color, m: ui.Style_Mod) {
	runs := [1]ui.Rich_Run{{text = s, style = {color = color}}}
	mod := m
	mod.width = ui.fill()
	ui.next(mod)
	ui.rich_paragraph(id, runs[:])
}

// One link: what it is for, the link itself (it opens in the browser), and a copy button.
@(private = "file")
pair_link_row :: proc(app: ^App, id, what, link: string, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), axis = .X, cross = .Center})
	if ui.row(.Center, id = id) {
		text("w", what, ui.theme_color("weak text"), ui.Style_Mod{font_size = math.round(em * FS_SMALL), width = ui.px(em * 7)})
		runs := make([dynamic]ui.Rich_Run, context.temp_allocator)
		ui.rich_links(link, {font = app.mono}, &runs)
		ui.next({width = ui.fill(), font_size = math.round(em * FS_SMALL), flags = {.Selectable}})
		link_clicked(ui.rich_paragraph("###l", runs[:], max_lines = 1))
		ui.space(ui.SPACE_2)
		if ui.button("c", i18n.tr("Copy"), o = {height = math.round(em * BUTTON_SMALL_H_EM)}).clicked {
			clip_set(link)
			ui.announce(&app.announcer, .Good, i18n.tr("Link copied"))
		}
	}
}
