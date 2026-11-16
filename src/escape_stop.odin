// Escape stops a run in two presses (src/md/features/escape-stop.md): the first arms the stop and the composer says so,
// the second within ESCAPE_STOP_MS stops it.
package ocn

import "core:math"
import "core:strings"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

// How long the first Escape keeps the stop armed.
ESCAPE_STOP_MS :: 2000
// The banner's red behind its text.
ESCAPE_STOP_TINT :: 0.16

// The session the first Escape armed the stop of ("": none; owned), and until when (ui.now_ms).
Escape_Stop :: struct {
	session: string,
	until:   f64,
}

// An Escape that nothing else took, while a run works.
escape_stop :: proc(app: ^App, pane: ^Chat_Pane) {
	if escape_stop_armed(app, pane) {
		escape_stop_clear(app)
		interrupt_session(app, pane.chat.id)
		return
	}
	e := &app.escape_stop
	delete(e.session)
	e.session = strings.clone(pane.chat.id)
	e.until = ui.now_ms() + ESCAPE_STOP_MS
}

// Armed for the session shown, its run still working, the time not over.
escape_stop_armed :: proc(app: ^App, pane: ^Chat_Pane) -> bool {
	e := &app.escape_stop
	return e.session != "" && e.session == pane.chat.id && pane.chat.busy && ui.now_ms() < e.until
}

escape_stop_clear :: proc(app: ^App) {
	delete(app.escape_stop.session)
	app.escape_stop = {}
}

// The banner at the top of the composer while the stop is armed. It asks for a wake at the end of the arming: it goes
// without other input.
escape_stop_banner :: proc(app: ^App, pane: ^Chat_Pane, em: f32) {
	if !escape_stop_armed(app, pane) {
		// (only what this pane armed, or what no pane shows: another pane's stop is armed in its own composer)
		if s := app.escape_stop.session; s != "" && (s == pane.chat.id || !pane_shows(app, s)) { escape_stop_clear(app) }
		return
	}
	ui.wake_within(built_state(app), max(1, int(math.ceil(app.escape_stop.until - ui.now_ms()))))
	red := ui.hue(.Red)
	h := math.round(em * QUEUE_ROW_H_EM)
	ui.next({width = ui.fill(), height = ui.px(h), axis = .X})
	if ui.row(id = "###stop_armed") {
		ui.space(ui.SPACE_2)
		// (tinted: it must catch the eye of one who pressed Escape by habit)
		ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center, bg = ui.with_alpha(red, ESCAPE_STOP_TINT), radius = math.round(em * 0.4 * corners())})
		if ui.row(.Center, flags = {.Draw_Background}, id = "###tint") {
			ui.space(ui.SPACE_2)
			glyph(lucide.OCTAGON_X, red, math.round(em * ICON_SMALL), em * 1.1)
			ui.space(ui.SPACE_1)
			text("t", i18n.tr("Press Esc again to stop the run"), red, ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_NOTE)})
			ui.spacer(ui.fill())
			if hint_action("###stop_now", i18n.tr("Stop now"), em, app.mono, intent = .Danger) {
				escape_stop_clear(app)
				interrupt_session(app, pane.chat.id)
			}
			ui.space(ui.SPACE_2)
		}
		ui.space(ui.SPACE_2)
	}
}
