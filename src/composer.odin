// The dock under the conversation (permission requests, then the composer) and the composer: its text, its toolbar, the agent,
// the model and how hard it thinks, sending.
package ocn

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"


HEX_PERM_TOP          :: 0x2a2116ff
HEX_PERM_BOTTOM       :: 0x1d170fff
HEX_PERM_DETAIL       :: 0xd8c8b0ff

// The composer: its text and focus, what goes with the prompt, and what each session's composer keeps while another is shown.
Composer :: struct {
	area:        ui.Text_Edit,
	paste:       Composer_Paste,          // a paste whose answers are on their way (attachments.odin)
	focused:     bool,
	focus_next:  bool,                    // the composer takes the focus at its next build
	edit_key:    ui.Key,                  // the editor's box: what a paste of its menu (ui.edit_menu) answers to
	fit:         struct { level: int, at: [3]f32 },   // what the toolbar leaves out, and at which widths (composer_fit)
	history:     History,                 // Up and Down: the session's prompts (history.odin)
	mentions:    Mentions,                // @ (files.odin)
	slash_pick:  Slash_Pick,              // / (slash.odin)
	attachments: [dynamic]Attachment,     // what goes with the prompt (attachments.odin)
	attaching:   [dynamic]^Attach_Job,    // files being read and encoded for a composer, on threads (attach_done takes them out)
	fork_prompt: string,                  // the prompt a fork left out, for the composer of the new session (owned)
	drafts:      map[string]Draft,        // each session's composer while another is shown (drafts.odin; keys owned)
	drafts_seen: string,                  // the composer's text when drafts_track last looked (owned)
}

////////////////////////////////
// The dock: permission requests and the composer

dock :: proc(app: ^App, em: f32, side, col: f32) {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###dock") {
		ui.spacer(ui.px(side))
		ui.next({width = ui.px(col), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###dockcol") {
			goal_strip(app, em)
			activity_strip(app, em)
			for &p in app.permissions {
				if p.session == app.chat.id { permission_card(app, &p, em) }
			}
			forms_dock(app, em)
			queue_list(app, em)
			composer(app, em)
			activity_tray(app, em)
			ui.spacer(ui.px(em * 1.1))
		}
	}
}

permission_card :: proc(app: ^App, p: ^Permission, em: f32) {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if plate(fmt.tprintf("###perm_%s", p.id), top = HEX_PERM_TOP, bottom = HEX_PERM_BOTTOM, radius = CARD_RADIUS, shadow = 8, rim = 0.1, border = with_alpha(hex(HEX_YELLOW), 0.55)) {
		ui.spacer(ui.px(em * 0.7))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###r") {
			ui.spacer(ui.px(em))
			glyph(lucide.SHIELD, hex(HEX_YELLOW), math.round(em * ICON_LARGE), em * 1.6)
			ui.spacer(ui.px(em * 0.5))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column() {
				text("a", fmt.tprintf(i18n.tr("Permission requested: %s"), p.action), hex(HEX_YELLOW), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_LABEL), height = ui.px(em * 1.5)}, ui.fill())
				detail := p.message != "" ? p.message : strings.join(p.resources, ", ", context.temp_allocator)
				text("d", detail, hex(HEX_PERM_DETAIL), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.4)}, ui.fill())
			}
			ui.spacer(ui.px(em * 0.5))
			if ui.button("once", i18n.tr("Allow once"), lucide.CHECK, {intent = .Success, disabled = p.replying}).clicked { reply_permission(app, p, "once") }
			ui.spacer(ui.px(em * 0.4))
			if ui.button("always", i18n.tr("Always"), o = {intent = .Success, disabled = p.replying}).clicked { reply_permission(app, p, "always") }
			ui.spacer(ui.px(em * 0.4))
			if ui.button("reject", i18n.tr("Reject"), lucide.X, {intent = .Danger, disabled = p.replying}).clicked { reply_permission(app, p, "reject") }
			ui.spacer(ui.px(em))
		}
		ui.spacer(ui.px(em * 0.7))
	}
	ui.spacer(ui.px(em * 0.7))
}

COMPOSER_MAX_LINES   :: 12
COMPOSER_HINT_MIN_EM :: 44
COMPOSER_BUTTON_W_EM :: 2.6

composer :: proc(app: ^App, em: f32) {
	// Enter sends, Shift+Enter breaks the line (the editor itself breaks on Enter and commits on Ctrl+Enter). While a turn runs
	// one way queues and the other sends now: Enter and Ctrl+Enter, or in Ctrl+Enter mode Ctrl+Enter and Ctrl+Shift+Enter.
	submit, other := false, false
	keys := app.composer.focused && !app.cx.open[.Picker]
	// (the tray's keys with the focus nowhere too: a click on one of its rows leaves it there)
	if app.activity.open && !app.cx.open[.Picker] && (app.composer.focused || ui.focus_key() == 0) { activity_keys(app) }
	if keys { mention_keys(app) }
	if keys { slash_keys(app) }
	if keys { history_track(app) }
	// (wherever the focus is: this Escape must not stop the run)
	if queue_editing(app) && !overlay_open(app) && !history_browsing(app) && !mention_takes_escape(app) && ui.key_press(.Escape) { queue_edit_end(app, .Cancel) }
	if app.composer.focused && !app.prefs.ctrl_enter {   // (Ctrl+Enter mode: Enter breaks the line, the editor commits on Ctrl+Enter)
		if ui.key_press(.Return) { submit = true }
		if ui.key_press(.Return, {.Shift}) { area_insert(&app.composer.area, "\n") }
	}
	if app.composer.focused && app.prefs.ctrl_enter && ui.key_press(.Return, {.Ctrl, .Shift}) { submit, other = true, true }
	ui.next({width = ui.fill(), height = ui.children_sum(), radius = 11 * ui.scale()})
	if ui.well("###composer_well", .Y, flags = {.Focus_Within, .Draw_Focus_Ring}) {
		// (its menu on all of it, the bar of its buttons and around the text too, after what is in it: an image keeps its own)
		card := ui.parent_box()
		defer ctx_check(app, card, .Composer)
		ui.spacer(ui.px(em * 0.45))
		queue_edit_banner(app, em)
		mention_list(app, em)
		slash_list(app, em)
		attachments_row(app, em)
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###edrow") {
			ui.spacer(ui.px(em * 0.35))
			if ui.tags("bare") {
				// Up and Down go through the history where they have nothing to move (the caret on the first line; going
				// through it, always); Down on the last line opens the tray of what runs. (Down moves the caret to the end
				// of the last line first: what tells is that it did not move.)
				down := false
				caret0 := app.composer.area.cursor
				// (the composer's own paste, not the editor's: what the clipboard holds may be files or an image)
				if keys && (ui.key_press(.V, {.Ctrl}) || ui.key_press(.Insert, {.Shift})) { composer_paste(app) }
				if keys && !app.activity.open {
					browsing := history_browsing(app)
					if ui.key_pressed_peek(.Up) && (browsing || composer_on_first_line(app)) {
						_ = ui.key_press(.Up)
						history_step(app, 1)
					}
					if browsing {
						if ui.key_press(.Down) { history_step(app, -1) }
						if ui.key_press(.Escape) { history_leave(app, true) }
					} else {
						down = ui.key_pressed_peek(.Down)
					}
				}
				// Escape while a turn runs stops it, and the composer keeps the keyboard (one goes on writing what made one stop it);
				// the editor would have let go of it. With nothing running, Escape lets go of it, as everywhere.
				if app.composer.focused && app.chat.busy && !overlay_open(app) && !mention_takes_escape(app) && !history_browsing(app) && !queue_editing(app) && ui.key_press(.Escape) {
					interrupt_session(app, app.chat.id)
				}
				// typed with nothing focused (a click in the conversation took the keyboard away): the composer takes it. Not a
				// space (a focused button's), nor while a dialog is over the window or a box (the terminal) has the keyboard.
				if !overlay_open(app) && ui.focus_key() == 0 && typed_word(app) { ui.type_to_field(ui.key_from_string(ui.parent_box().key, "###composer")) }
				ui.next({width = ui.fill(), font_size = math.round(em * FS_BODY), text_pad = em * 0.5})
				// (own_menu: the menu is the whole card's, ctx_check below; it is ui.edit_menu on this area)
				res := ui.text_edit("###composer", &app.composer.area, {placeholder = i18n.tr("Ask anything…"), wrap = true, auto_height = true, min_lines = 2, max_lines = COMPOSER_MAX_LINES, own_menu = true})
				app.composer.focused = res.focused
				app.composer.edit_key = res.box.key
				mention_track(app)
				slash_track(app)
				if app.composer.focus_next { ui.set_focus(res.box.key); app.composer.focus_next = false }
				ctx_check(app, res.box, .Composer)
				if res.committed { submit, other = true, !app.prefs.ctrl_enter }
				if down && app.composer.area.cursor == caret0 { activity_open(app) }
				if res.changed { activity_close(app) }   // (typing: what is written is what matters now)
				drafts_track(app)   // (kept on disk a moment after it changes, however: typed, sent, put back)
			}
			ui.spacer(ui.px(em * 0.35))
		}
		// toolbar
		fit := composer_fit(app, em)
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.8)), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###tools") {
			ui.spacer(ui.px(em * 0.6))
			// what goes with the prompt, then who answers it and with what
			ui.a11y({role = .Button, name = i18n.tr("Attach files")})
			att := ui.button("attach", icon = lucide.PAPERCLIP, o = {face = .Ghost, height = math.round(em * BUTTON_COMPACT_H_EM), quiet = true})
			if att.clicked { attach_pick(app) }
			if ui.hovered_for(att) { if ui.tooltip() { ui.tooltip_text(i18n.tr("Attach files: images, PDF, text  (or paste, or drop them here)")) } }
			ui.spacer(ui.px(em * 0.1))
			agent := shown_agent(app)
			if agent == "" { agent = "build" }
			// (the narrowest toolbar: the agent and the variant by their glyphs, their names in the tips)
			asig := ui.button("agent", ui.text_shown(fit >= 3 ? "" : agent), lucide.BOT, {face = .Ghost, height = math.round(em * BUTTON_COMPACT_H_EM), quiet = true, lit = app.cx.open[.Picker] && app.picker.id == "agent", tip = fit >= 3 ? agent : ""})
			if asig.clicked { if app.cx.open[.Picker] && app.picker.id == "agent" { app.cx.open[.Picker] = false } else { picker_open(app, "agent", asig.box.rect) } }
			ui.spacer(ui.px(em * 0.4))
			model, _ := shown_model(app)
			if model == "" { model = i18n.tr("default model") }
			msig := ui.button("model", ui.text_shown(model), lucide.CPU, {face = .Ghost, height = math.round(em * BUTTON_COMPACT_H_EM), quiet = true, lit = app.cx.open[.Picker] && app.picker.id == "model"})
			if msig.clicked { if app.cx.open[.Picker] && app.picker.id == "model" { app.cx.open[.Picker] = false } else { picker_open(app, "model", msig.box.rect) } }
			variant_button(app, em, fit >= 3)
			ui.spacer(ui.px(em * 0.4))
			if app.chat.id != "" { approval_button(app, em) }   // (a session's: a new one has none yet)
			ui.spacer(ui.fill())
			held := composer_held(app)
			if app.conversation.column_w > em * COMPOSER_HINT_MIN_EM && fit < 1 {   // (room for it beside the agent and model buttons)
				if held {
					text("hint", attaching(app) ? i18n.tr("reading the attachment…") : i18n.tr("starting the session…"), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
				} else if history_browsing(app) {
					text("hint", fmt.tprintf(i18n.tr("history %d/%d   ·   "), app.composer.history.at, len(app.composer.history.view)), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
					if hint_action("###hist_back", i18n.tr("Esc  back to your text"), em, app.mono) { history_leave(app, true) }
				} else if queue_editing(app) {
					if hint_action("###h_save", app.prefs.ctrl_enter ? i18n.tr("Ctrl+Enter  save") : i18n.tr("Enter  save"), em, app.mono, intent = .Success) { submit = true }
				} else if as := composer_send_as(app); as != .Idle {
					// (each says what it does, and does it)
					first, second := as == .Queue ? i18n.tr("queue") : i18n.tr("steer"), as == .Queue ? i18n.tr("steer") : i18n.tr("queue")
					if hint_action("###h_first", fmt.tprintf("%s  %s", app.prefs.ctrl_enter ? "Ctrl+Enter" : "Enter", first), em, app.mono) { submit = true }
					text("h_dot", "   ·   ", hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
					if hint_action("###h_second", fmt.tprintf("%s  %s", app.prefs.ctrl_enter ? "Ctrl+Shift+Enter" : "Ctrl+Enter", second), em, app.mono) { submit, other = true, true }
				} else {
					text("hint", app.prefs.ctrl_enter ? i18n.tr("Ctrl+Enter  send   ·   Enter  new line") : i18n.tr("Enter  send   ·   Shift+Enter  new line"), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
				}
			}
			ui.spacer(ui.px(em * 0.8))
			composer_panels(app, em)
			if app.chat.busy {
				if ui.button("stop2", icon = lucide.SQUARE, o = {intent = .Danger, face = .Raised, width = ui.px(math.round(em * COMPOSER_BUTTON_W_EM)), height = math.round(em * BUTTON_H_EM)}).clicked { interrupt_session(app, app.chat.id) }
				ui.spacer(ui.px(em * 0.4))
			}
			empty := len(strings.trim_space(ui.text_edit_string(&app.composer.area))) == 0 && len(app.composer.attachments) == 0
			// (what it does, while that is not what it usually does)
			send_label, send_icon, send_intent := "", lucide.SEND_HORIZONAL, ui.Intent.Primary
			if queue_editing(app) {
				send_label, send_icon, send_intent = i18n.tr("Save"), lucide.CHECK, .Success
			} else {
				switch composer_send_as(app) {
				case .Idle:
				case .Queue: send_label, send_icon = i18n.tr("Queue"), lucide.LIST
				case .Steer: send_label = i18n.tr("Steer")
				}
			}
			if app.conversation.column_w <= em * QUEUE_WORDS_MIN_EM || fit >= 2 { send_label = "" }   // (narrow, its glyph says it: the toolbar has no room)
			send_w: ui.Size = send_label == "" ? ui.px(math.round(em * COMPOSER_BUTTON_W_EM)) : {}
			if ui.button("send", ui.text_shown(send_label), send_icon, {intent = send_intent, width = send_w, height = math.round(em * BUTTON_H_EM), disabled = empty || !online(app) || held}).clicked { submit = true }
			ui.spacer(ui.px(em * 0.55))

			composer_pickers(app, agent, em)
		}
	}
	if submit { submit_prompt(app, other) }
}

// What the composer's toolbar leaves out to stay within itself: 1, the keys' hint; 2, the send button's word too. A step is taken
// when what it held went past its end in the last layout (a long model's name, Stop beside "Steer"), and given back once the row
// is wider than where it went past (by a margin: what came back would not go past at once).
@(private = "file")
composer_fit :: proc(app: ^App, em: f32) -> int {
	f := &app.composer.fit
	tools := ui.prev_box("###tools")
	if tools == nil { return f.level }
	w := tools.rect.max.x - tools.rect.min.x
	end: f32
	for c := tools.first; c != nil; c = c.next {
		if .Floating_X not_in c.flags { end = max(end, c.rect.max.x) }
	}
	if end > tools.rect.max.x + 0.5 && f.level < len(f.at) {
		f.at[f.level] = w
		f.level += 1
	}
	for f.level > 0 && w > f.at[f.level - 1] + em * COMPOSER_FIT_SLACK_EM { f.level -= 1 }
	return f.level
}

// The browser and the shells, lit while they are open.
@(private = "file")
composer_panels :: proc(app: ^App, em: f32) {
	size := math.round(em * BUTTON_H_EM)
	panel :: proc(app: ^App, id, icon, name, tip, command: string, lit: bool, size, em: f32) {
		ui.a11y({role = .Button, name = name})
		ui.next({width = ui.px(size), height = ui.px(size)})
		if lit { ui.next({width = ui.px(size), height = ui.px(size), fg = accent()}) }
		sig := ui.button(id, icon = icon)
		if sig.clicked { command_run(app, command_find(command)) }
		if ui.hovered_for(sig) { if ui.tooltip() { ui.tooltip_text(tip) } }
		ui.spacer(ui.px(em * 0.4))
	}
	if preview_available() { panel(app, "preview_btn", lucide.GLOBE, i18n.tr("Preview panel"), i18n.tr("Preview panel  (Ctrl+Shift+B)"), "view.preview", app.preview.open, size, em) }
	panel(app, "terminal_btn", lucide.SQUARE_TERMINAL, i18n.tr("Terminal"), i18n.tr("Terminal  (Ctrl+Shift+T)"), "view.terminal", app.cx.terms.open, size, em)
}

composer_pickers :: proc(app: ^App, agent: string, em: f32) {
	p := &app.picker
	if !app.cx.open[.Picker] || (p.id != "agent" && p.id != "model") { return }
	// the items of the one open, made when it opens or the server's list changed (catalog_version), not at each frame
	if p.fresh || p.items_version != app.cx.catalog_version {
		p.items_version = app.cx.catalog_version
		for it in p.items { delete(it.detail) }   // (the only text of an item it owns: the others are the agents' and the models')
		clear(&p.items)
		clear(&p.item_ids)
		if p.id == "agent" {
			for a in app.agents {
				if a.mode == "subagent" { continue }
				append(&p.items, Pick_Item{label = a.name != "" ? a.name : a.id, detail = a.mode == "primary" ? "" : strings.clone(a.mode), current = a.id == agent, color = agent_color(a.id)})
				append(&p.item_ids, a.id)
			}
		} else {
			shown, shown_provider := shown_model(app)
			for m, i in app.models {
				append(&p.items, Pick_Item{label = m.name != "" ? m.name : m.id, group = m.provider, detail = m.ctx_len > 0 ? strings.clone(kfmt(m.ctx_len)) : "", model = &app.models[i], current = m.id == shown && m.provider == shown_provider})
			}
		}
	}
	// (a version of each list of its own, never 0: 0 keeps nothing)
	if k := picker(app, p, "agent", i18n.tr("Search agents"), p.items[:], em, version = app.cx.catalog_version * 2 + 1); k >= 0 { choose_agent(app, p.item_ids[k]) }
	if k := picker(app, p, "model", i18n.tr("Search models"), p.items[:], em, version = app.cx.catalog_version * 2 + 2); k >= 0 { choose_model(app, app.models[k]) }
}

// The reader picks one, in the picker or the palette: the session shown takes it, and it stands until that session's end.
choose_agent :: proc(app: ^App, agent: string) {
	c := &app.chat
	if c.id != "" { switch_agent(app, c.id, agent) }
	c.chose_agent = strings.clone(agent, c.alloc)
	choice_remember(app)
}

// (the variant stays when the new model has it too: "high" on one model is "high" on the next)
choose_model :: proc(app: ^App, m: Model_Info) {
	c := &app.chat
	variant := shown_variant(app)
	if !slice.contains(model_variants(app, m.id, m.provider), variant) { variant = "" }
	variant = strings.clone(variant, c.alloc)
	if c.id != "" { switch_model(app, c.id, m.id, m.provider, variant) }
	c.chose_model, c.chose_provider, c.chose_variant = strings.clone(m.id, c.alloc), strings.clone(m.provider, c.alloc), variant
	choice_remember(app)
}

// How hard the model shown thinks, picked in the composer's menu ("": the model's default). It goes with the model.
choose_variant :: proc(app: ^App, variant: string) {
	c := &app.chat
	model, provider := shown_model(app)
	if model == "" { return }   // (the server's default model: its variants are not known)
	model, provider = strings.clone(model, c.alloc), strings.clone(provider, c.alloc)
	if c.id != "" { switch_model(app, c.id, model, provider, variant) }
	c.chose_model, c.chose_provider, c.chose_variant = model, provider, strings.clone(variant, c.alloc)
	choice_remember(app)
}

// The agent and the model chosen last: what a new session starts with, from one run of the program to the next.
@(private = "file")
choice_remember :: proc(app: ^App) {
	model, provider := shown_model(app)
	agent := strings.clone(shown_agent(app), context.temp_allocator)
	model, provider = strings.clone(model, context.temp_allocator), strings.clone(provider, context.temp_allocator)
	pref_set(app, "session.agent", agent)
	pref_set(app, "session.model", model)
	pref_set(app, "session.provider", provider)
	pref_set(app, "session.variant", strings.clone(shown_variant(app), context.temp_allocator))
}

// The caret is on the first line the composer shows, wrapped or not (as last drawn).
composer_on_first_line :: proc(app: ^App) -> bool {
	a := &app.composer.area
	if len(a.buf) == 0 { return true }
	caret, _, ok := ui.text_edit_caret_rect(a)
	b := ui.prev_box("###composer")
	if !ok || b == nil { return false }
	return a.scroll.y < 1 && caret.min.y - b.rect.min.y < b.text_pad + (caret.max.y - caret.min.y) * 0.75
}

area_insert :: proc(a: ^ui.Text_Edit, s: string) {
	lo, hi := min(a.cursor, a.mark), max(a.cursor, a.mark)
	remove_range(&a.buf, lo, hi)
	inject_at(&a.buf, lo, ..transmute([]u8)s)
	a.cursor = lo + len(s)
	a.mark = a.cursor
}

// A prompt that did not reach the server comes back to the composer, ahead of what was typed since.
prompt_restore :: proc(app: ^App, text: string) {
	if text == "" { return }   // (an image alone)
	typed := ui.text_edit_string(&app.composer.area)
	ui.text_edit_set(&app.composer.area, strings.trim_space(typed) == "" ? text : fmt.tprintf("%s\n%s", text, typed))
}

// Enter, or Send. While the session it would go to is starting it stays in the composer: nothing is lost, the button says it. While a
// turn runs `other` is the way that is not Enter's (composer_send_as); what is being edited goes back where it was, whichever.
submit_prompt :: proc(app: ^App, other := false) {
	t := strings.clone(strings.trim_space(ui.text_edit_string(&app.composer.area)), context.temp_allocator)
	if (t == "" && len(app.composer.attachments) == 0) || !online(app) || composer_held(app) { return }
	history_leave(app, false)
	if queue_editing(app) { queue_edit_commit(app, t); return }
	as := composer_send_as(app, other)
	fields := send_as_fields(as)
	if app.chat.id == "" || !slash_send(app, t, fields) { outgoing_composer(app, t, app.chat.new_dir, fields) }
	ui.text_edit_set(&app.composer.area, "")
	if as == .Idle { chat_scroll_event(app, Scroll_Signal.Go_Bottom) }   // (what waits shows over the composer: the conversation stays where it is)
}

// How hard the model thinks: a button beside the model's that opens the menu of its variants. None when the model has none.
@(private = "file")
// `glyph`: its glyph alone (a narrow toolbar).
variant_button :: proc(app: ^App, em: f32, glyph := false) {
	model, provider := shown_model(app)
	variants := model_variants(app, model, provider)
	if len(variants) == 0 { return }
	current := shown_variant(app)
	ui.spacer(ui.px(em * 0.2))
	ui.a11y({role = .Button, name = i18n.tr("Thinking")})
	name := current != "" ? current : i18n.tr("default")
	sig := ui.button("variant", ui.text_shown(glyph ? "" : name), lucide.GAUGE, {face = .Ghost, height = math.round(em * BUTTON_COMPACT_H_EM), quiet = true})
	key := "variant_menu"
	if sig.clicked { ui.menu_open(key, sig.box.rect, sig.box.key, search = false) }
	if ui.hovered_for(sig) { if ui.tooltip() { ui.tooltip_text(glyph ? fmt.tprintf(i18n.tr("How hard the model thinks: %s"), name) : i18n.tr("How hard the model thinks")) } }
	if ui.menu(key, em * 12) {
		if ui.menu_item(fmt.tprintf("%s###v_default", i18n.tr("default")), "", current == "").clicked { choose_variant(app, "") }
		for v, i in variants {
			if ui.menu_item(fmt.tprintf("%s###v%d", label_safe(v), i), "", v == current).clicked { choose_variant(app, v) }
		}
	}
}

// A character typed this build that is not a space.
@(private = "file")
typed_word :: proc(app: ^App) -> bool {
	for r in app.state.typed { if r > ' ' && r != 0x7f { return true } }
	return false
}
