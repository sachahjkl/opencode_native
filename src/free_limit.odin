// The free-limit panel (src/md/features/free-limit.md): opencode's free usage used up, with no paid provider, a panel
// takes the composer's place until it resets.
package ocn

import "core:encoding/json"
import "core:fmt"
import "core:math"
import tk_json "gt:json"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

// When a refusal does not say when the free usage resets.
FREE_LIMIT_FALLBACK_MS :: 3_600_000
// A reset said further than this is not believed (the desktop's bound).
FREE_LIMIT_MAX_RETRY_MS :: 45 * 86_400_000
FREE_LIMIT_GO_URL :: "https://opencode.ai/go"

Free_Limit :: struct {
	reset_ms:     f64,    // when the free usage resets (ms since 1970, the server's clock); 0: not refused
	paid:         bool,   // a paid provider is there (made when the catalogue changes)
	paid_version: u64,    // the catalog_version `paid` was made from (+1: 0 is "not made")
}

// A step refused for the free limit, in any session: when it resets.
free_limit_note :: proc(app: ^App, ev: json.Value) {
	d := tk_json.get(ev, "data")
	if tk_json.text(d, "error", "type") != "provider.free-limit" { return }
	created := tk_json.number(ev, "created")
	if created <= 0 { created = now_epoch_ms() }
	retry := tk_json.get(d, "error", "retryAfterMs")
	after := f64(FREE_LIMIT_FALLBACK_MS)
	if n, ok := retry.(json.Float); ok && n >= 0 && n <= FREE_LIMIT_MAX_RETRY_MS { after = f64(n) }
	if n, ok := retry.(json.Integer); ok && n >= 0 && n <= FREE_LIMIT_MAX_RETRY_MS { after = f64(n) }
	// (an older refusal, replayed, does not shorten it)
	app.free_limit.reset_ms = max(app.free_limit.reset_ms, created + after)
}

// Paid: a model of a provider other than opencode, or an opencode model with a price. Made again only when the
// catalogue changes.
@(private = "file")
free_limit_paid :: proc(app: ^App) -> bool {
	f := &app.free_limit
	if f.paid_version == app.cx.catalog_version + 1 { return f.paid }
	f.paid_version = app.cx.catalog_version + 1
	f.paid = false
	for m in app.models {
		if m.provider != "opencode" || (m.priced && m.price_in > 0) { f.paid = true; break }
	}
	return f.paid
}

// The panel stands in the composer's place now.
free_limit_active :: proc(app: ^App) -> bool {
	f := &app.free_limit
	return f.reset_ms > 0 && !free_limit_paid(app) && f.reset_ms > now_epoch_ms()
}

// In the composer's place: what happened, when it resets, and the two ways on.
free_limit_panel :: proc(app: ^App, em: f32) {
	left := app.free_limit.reset_ms - now_epoch_ms()
	ui.wake_within(built_state(app), max(1, int(math.ceil(min(left, f64(max(i32)))))))   // (it goes by itself)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y, radius = 11 * ui.scale()})
	if ui.well("###free_limit", .Y) {
		ui.spacer(ui.px(em * 0.7))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###fl_top") {
			ui.spacer(ui.px(em * 0.9))
			glyph(lucide.CIRCLE_GAUGE, hex(HEX_YELLOW), math.round(em * ICON_SMALL), em * 1.3)
			ui.spacer(ui.px(em * 0.4))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column(id = "###fl_words") {
				text("t", i18n.tr("Free limit reached"), hex(HEX_BRIGHT), ui.Style_Mod{font_size = math.round(em * FS_LABEL), height = ui.px(em * 1.5)}, ui.fill())
				// (its time, and its day when it is not today)
				at := app.free_limit.reset_ms
				when_ := clock_text(at, app.prefs.clock24)
				if !same_local_day(at, now_epoch_ms()) { when_ = fmt.tprintf("%s %s", date_text(at), when_) }
				said := fmt.tprintf(i18n.tr("Free usage resets at %s. Connect a provider or subscribe to Go to continue."), when_)
				ui.next({width = ui.fill(), font_size = math.round(em * FS_SMALL), fg = hex(HEX_WEAK), text_pad = 0})
				ui.paragraph(fmt.tprintf("%s###fl_reset", ui.text_shown(said)))
			}
			ui.spacer(ui.px(em * 0.9))
		}
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###fl_acts") {
			ui.spacer(ui.fill())
			if ui.button("fl_go", i18n.tr("Subscribe to Go · $10/mo"), o = {face = .Ghost}).clicked { ui.open(FREE_LIMIT_GO_URL, .Url) }
			ui.spacer(ui.px(em * 0.4))
			if ui.button("fl_connect", i18n.tr("Connect provider"), lucide.PLUG, {intent = .Primary}).clicked { settings_open_on(app, "connections") }
			ui.spacer(ui.px(em * 0.8))
		}
		ui.spacer(ui.px(em * 0.7))
	}
}
