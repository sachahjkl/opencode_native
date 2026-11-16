// The dock under the conversation (permission requests, then the composer) and the composer: its text, its toolbar, the agent,
// the model and how hard it thinks, sending.
package ocn

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "gt:platform"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

// The composer: its text and focus, what goes with the prompt, and what each session's composer keeps while another is shown.
Composer :: struct {
	area:        ui.Text_Edit,
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
	drafts_seen: string,                  // the composer's text when drafts_track last looked (owned)
}

////////////////////////////////
// The dock: permission requests and the composer

dock :: proc(app: ^App, pane: ^Chat_Pane, em: f32, side, col: f32) {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###dock") {
		ui.spacer(ui.px(side))
		ui.next({width = ui.px(col), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###dockcol") {
			is_main := pane == main_pane(app)   // (the activity is the main view's: chat-panes.md, Layer 2)
			goal_strip(app, pane, em)
			if is_main { activity_strip(app, em) }
			for &p in app.permissions {
				if p.session == pane.chat.id { permission_card(app, &p, em) }
			}
			forms_dock(app, pane, em)
			queue_list(app, pane, em)
			// (the free usage used up and nothing paid: nothing the composer sends could run)
			if free_limit_active(app) { free_limit_panel(app, em) } else { composer(app, pane, em) }
			if is_main { activity_tray(app, em) }
			ui.spacer(ui.px(em * 1.1))
		}
	}
}

permission_card :: proc(app: ^App, p: ^Permission, em: f32) {
	if ui.card("", id = fmt.tprintf("###perm_%s", p.id), o = warm_card(ui.hue(.Yellow))) {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###r") {
			glyph(lucide.SHIELD, ui.hue(.Yellow), math.round(em * ICON_LARGE), em * 1.6)
			ui.space(ui.ICON_GAP)
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column() {
				text("a", fmt.tprintf(i18n.tr("Permission requested: %s"), p.action), ui.hue(.Yellow), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_LABEL), height = ui.px(em * 1.5)}, ui.fill())
				detail := p.message != "" ? p.message : strings.join(p.resources, ", ", context.temp_allocator)
				text("d", detail, between("soft text", "hue_accent", 0.3), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.4)}, ui.fill())
			}
			ui.space(ui.CONTROL_GAP)
			if ui.button("once", i18n.tr("Allow once"), lucide.CHECK, {intent = .Success, disabled = p.replying}).clicked { reply_permission(app, p, "once") }
			ui.space(ui.CONTROL_GAP)
			if ui.button("always", i18n.tr("Always"), o = {intent = .Success, disabled = p.replying}).clicked { reply_permission(app, p, "always") }
			ui.space(ui.CONTROL_GAP)
			if ui.button("reject", i18n.tr("Reject"), lucide.X, {intent = .Danger, disabled = p.replying}).clicked { reply_permission(app, p, "reject") }
		}
	}
	ui.space(ui.ITEM_GAP)
}

COMPOSER_MAX_LINES   :: 12
COMPOSER_HINT_MIN_EM :: 44
COMPOSER_BUTTON_W_EM :: 2.6

composer :: proc(app: ^App, pane: ^Chat_Pane, em: f32) {
	// Enter sends, Shift+Enter breaks the line (the editor itself breaks on Enter and commits on Ctrl+Enter). While a turn runs
	// one way queues and the other sends now: Enter and Ctrl+Enter, or in Ctrl+Enter mode Ctrl+Enter and Ctrl+Shift+Enter.
	submit, other, first := false, false, false
	keys := pane.composer.focused
	is_main := pane == main_pane(app)   // (the activity, and the keys typed with nothing focused, are the main view's)
	// (the tray's keys with the focus nowhere too: a click on one of its rows leaves it there)
	if is_main && app.activity.open && (pane.composer.focused || ui.focus_key() == 0) { activity_keys(app) }
	if keys { mention_keys(app, pane) }
	if keys { slash_keys(app, pane) }
	if keys { history_track(app, pane) }
	// (wherever the focus is: this Escape must not stop the run)
	if queue_editing(app, pane) && !overlay_open(app) && !history_browsing(app, pane) && !mention_takes_escape(app, pane) && ui.key_press(.Escape) { queue_edit_end(app, pane, .Cancel) }
	if pane.composer.focused && !app.prefs.ctrl_enter {   // (Ctrl+Enter mode: Enter breaks the line, the editor commits on Ctrl+Enter)
		if ui.key_press(.Return) { submit = true }
		if ui.key_press(.Return, {.Shift}) { area_insert(&pane.composer.area, "\n") }
	}
	if pane.composer.focused && app.prefs.ctrl_enter && ui.key_press(.Return, {.Ctrl, .Shift}) { submit, other = true, true }
	// Alt+Enter: queued first while a turn runs (queue_first_start), in either mode. Not while @ or / proposes: their Enter
	// takes a choice, and Alt+Enter is not one.
	if keys && !mention_shown(app, pane) && !slash_shown(app, pane) && ui.key_press(.Return, {.Alt}) { submit, first = true, true }
	ui.next({width = ui.fill(), height = ui.children_sum(), radius = 11 * ui.scale()})
	if ui.well("###composer_well", .Y, flags = {.Focus_Within, .Draw_Focus_Ring}) {
		// (its menu on all of it, the bar of its buttons and around the text too, after what is in it: an image keeps its own)
		card := ui.parent_box()
		defer ctx_check(app, card, .Composer, pane = pane)
		ui.spacer(ui.px(em * 0.45))
		escape_stop_banner(app, pane, em)
		queue_edit_banner(app, pane, em)
		mention_list(app, pane, em)
		slash_list(app, pane, em)
		attachments_row(app, pane, em)
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###edrow") {
			ui.spacer(ui.px(em * 0.35))
			if ui.tags("bare") {
				// Up and Down go through the history where they have nothing to move (the caret on the first line; going
				// through it, always); Down on the last line opens the tray of what runs. (Down moves the caret to the end
				// of the last line first: what tells is that it did not move.)
				down := false
				caret0 := pane.composer.area.cursor
				if keys && !(is_main && app.activity.open) {
					browsing := history_browsing(app, pane)
					if ui.key_pressed_peek(.Up) && (browsing || composer_on_first_line(app, pane)) {
						_ = ui.key_press(.Up)
						history_step(app, pane, 1)
					}
					if browsing {
						if ui.key_press(.Down) { history_step(app, pane, -1) }
						if ui.key_press(.Escape) { history_leave(app, pane, true) }
					} else {
						down = ui.key_pressed_peek(.Down)
					}
				}
				// Escape while a turn runs arms its stop, a second one stops it (escape_stop), and the composer keeps the
				// keyboard (one goes on writing what made one stop it); the editor would have let go of it. With nothing
				// running, Escape lets go of it, as everywhere.
				if pane.composer.focused && pane.chat.busy && !overlay_open(app) && !mention_takes_escape(app, pane) && !history_browsing(app, pane) && !queue_editing(app, pane) && ui.key_press(.Escape) {
					escape_stop(app, pane)
				}
				// typed with nothing focused (a click in the conversation took the keyboard away): the composer takes it. Not a
				// space (a focused button's), nor while a dialog is over the window or a box (the terminal) has the keyboard.
				if is_main && !overlay_open(app) && ui.focus_key() == 0 && typed_word(app) { ui.type_to_field(ui.key_from_string(ui.parent_box().key, "###composer")) }
				ui.next({width = ui.fill(), font_size = math.round(em * FS_BODY), text_pad = em * 0.5})
				// (own_menu: the menu is the whole card's, ctx_check below; it is ui.edit_menu on this area)
				// (a paste may give files or an image: the editor takes text, the composer attaches the rest, the toolkit's one
				// answer; Ctrl+V, Shift+Insert and its menu's Paste alike)
				res := ui.text_edit("###composer", &pane.composer.area, {placeholder = i18n.tr("Ask anything…"), wrap = true, auto_height = true, min_lines = 2, max_lines = COMPOSER_MAX_LINES, own_menu = true, paste = COMPOSER_PASTE})
				pane.composer.focused = res.focused
				pane.composer.edit_key = res.box.key
				if a, ok := ui.paste_answer(res.box.key, {.Files, .Image}); ok { composer_paste_take(app, pane, a) }
				mention_track(app, pane)
				slash_track(app, pane)
				if pane.composer.focus_next { ui.set_focus(res.box.key); pane.composer.focus_next = false }
				ctx_check(app, res.box, .Composer, pane = pane)
				if res.committed { submit, other = true, !app.prefs.ctrl_enter }
				if is_main && down && pane.composer.area.cursor == caret0 { activity_open(app) }
				if is_main && res.changed { activity_close(app) }   // (typing: what is written is what matters now)
				drafts_track(app, pane)   // (kept on disk a moment after it changes, however: typed, sent, put back)
			}
			ui.spacer(ui.px(em * 0.35))
		}
		// toolbar
		fit := composer_fit(app, pane, em)
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.8)), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###tools") {
			ui.spacer(ui.px(em * 0.6))
			// what goes with the prompt, then who answers it and with what
			ui.a11y({role = .Button, name = i18n.tr("Attach files")})
			att := ui.button("attach", icon = lucide.PAPERCLIP, o = {face = .Ghost, height = math.round(em * BUTTON_COMPACT_H_EM), quiet = true})
			// (the palette's commands act on the main view: only its composer's buttons are theirs, and a name stated twice goes to
			// the last one built)
			named := pane == main_pane(app)
			if named { ui.act_name(att.box, "command:composer.attach") }
			if att.clicked { attach_pick(app, pane) }
			if ui.hovered_for(att) { if ui.tooltip() { ui.tooltip_text(i18n.tr("Attach files: images, PDF, text  (or paste, or drop them here)")) } }
			agent := shown_agent(app, pane)
			if agent == "" { agent = "build" }
			// (the narrowest toolbar: the agent and the variant by their glyphs, their names in the tips)
			composer_tool_pad(em)
			asig := ui.button("agent", ui.text_shown(fit >= 3 ? "" : agent), lucide.BOT, {face = .Ghost, height = math.round(em * BUTTON_COMPACT_H_EM), quiet = true, lit = chooser_shows(app, .Agents), tip = fit >= 3 ? agent : ""})
			if asig.clicked { chooser_toggle(app, pane, .Agents) }
			model, _ := shown_model(app, pane)
			if model == "" { model = i18n.tr("default model") }
			composer_tool_pad(em)
			msig := ui.button("model", ui.text_shown(model), lucide.CPU, {face = .Ghost, height = math.round(em * BUTTON_COMPACT_H_EM), quiet = true, lit = chooser_shows(app, .Models)})
			if msig.clicked { chooser_toggle(app, pane, .Models) }
			variant_button(app, pane, em, fit >= 3)
			if pane.chat.id != "" { approval_button(app, pane, em) }   // (a session's: a new one has none yet)
			ui.spacer(ui.fill())
			held := composer_held(app, pane)
			if pane.conversation.column_w > em * COMPOSER_HINT_MIN_EM && fit < 1 {   // (room for it beside the agent and model buttons)
				if held {
					text("hint", attaching(app, pane) ? i18n.tr("reading the attachment…") : i18n.tr("starting the session…"), ui.theme_color("faint text"), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
				} else if history_browsing(app, pane) {
					text("hint", fmt.tprintf(i18n.tr("history %d/%d   ·   "), pane.composer.history.at, len(pane.composer.history.view)), ui.theme_color("faint text"), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
					if hint_action("###hist_back", i18n.tr("Esc  back to your text"), em, app.mono) { history_leave(app, pane, true) }
				} else if queue_editing(app, pane) {
					if hint_action("###h_save", app.prefs.ctrl_enter ? i18n.tr("Ctrl+Enter  save") : i18n.tr("Enter  save"), em, app.mono, intent = .Success) { submit = true }
				} else if as := composer_send_as(app, pane); as != .Idle {
					// (each says what it does, and does it)
					first, second := as == .Queue ? i18n.tr("queue") : i18n.tr("steer"), as == .Queue ? i18n.tr("steer") : i18n.tr("queue")
					if hint_action("###h_first", fmt.tprintf("%s  %s", platform.key_text(app.prefs.ctrl_enter ? "Ctrl+Enter" : "Enter"), first), em, app.mono) { submit = true }
					text("h_dot", "   ·   ", ui.theme_color("faint text"), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
					if hint_action("###h_second", fmt.tprintf("%s  %s", platform.key_text(app.prefs.ctrl_enter ? "Ctrl+Shift+Enter" : "Ctrl+Enter"), second), em, app.mono) { submit, other = true, true }
				} else {
					text("hint", app.prefs.ctrl_enter ? i18n.tr("Ctrl+Enter  send   ·   Enter  new line") : i18n.tr("Enter  send   ·   Shift+Enter  new line"), ui.theme_color("faint text"), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
				}
			}
			ui.spacer(ui.px(em * 0.8))
			composer_panels(app, em, named)
			if pane.chat.busy {
				if ui.button("stop2", icon = lucide.SQUARE, o = {intent = .Danger, face = .Raised, width = ui.px(math.round(em * COMPOSER_BUTTON_W_EM)), height = math.round(em * BUTTON_H_EM)}).clicked { interrupt_session(app, pane.chat.id) }
				ui.spacer(ui.px(em * 0.4))
			}
			empty := len(strings.trim_space(ui.text_edit_string(&pane.composer.area))) == 0 && len(pane.composer.attachments) == 0
			// (what it does, while that is not what it usually does)
			send_label, send_icon, send_intent := "", lucide.SEND_HORIZONAL, ui.Intent.Primary
			if queue_editing(app, pane) {
				send_label, send_icon, send_intent = i18n.tr("Save"), lucide.CHECK, .Success
			} else {
				switch composer_send_as(app, pane) {
				case .Idle:
				case .Queue: send_label, send_icon = i18n.tr("Queue"), lucide.LIST
				case .Steer: send_label, send_icon = i18n.tr("Steer"), lucide.SHIP_WHEEL
				}
			}
			if pane.conversation.column_w <= em * QUEUE_WORDS_MIN_EM || fit >= 2 { send_label = "" }   // (narrow, its glyph says it: the toolbar has no room)
			send_w: ui.Size = send_label == "" ? ui.px(math.round(em * COMPOSER_BUTTON_W_EM)) : {}
			if ui.button("send", ui.text_shown(send_label), send_icon, {intent = send_intent, width = send_w, height = math.round(em * BUTTON_H_EM), disabled = empty || !online(app) || held}).clicked { submit = true }
			ui.spacer(ui.px(em * 0.55))
		}
	}
	if submit { submit_prompt(app, pane, other, first) }
}

// What the composer's toolbar leaves out to stay within itself: 1, the keys' hint; 2, the send button's word too. A step is taken
// when what it held went past its end in the last layout (a long model's name, Stop beside "Steer"), and given back once the row
// is wider than where it went past (by a margin: what came back would not go past at once).
@(private = "file")
composer_fit :: proc(app: ^App, pane: ^Chat_Pane, em: f32) -> int {
	f := &pane.composer.fit
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
composer_panels :: proc(app: ^App, em: f32, named: bool) {
	size := math.round(em * BUTTON_H_EM)
	panel :: proc(app: ^App, id, icon, name, tip, command, act: string, lit: bool, size, em: f32) {
		ui.a11y({role = .Button, name = name})
		ui.next({width = ui.px(size), height = ui.px(size)})
		if lit { ui.next({width = ui.px(size), height = ui.px(size), fg = ui.hue(.Accent)}) }
		sig := ui.button(id, icon = icon)
		ui.act_name(sig.box, act)
		if sig.clicked { command_run(app, command_find(command)) }
		if ui.hovered_for(sig) { if ui.tooltip() { ui.tooltip_text(tip) } }
		ui.spacer(ui.px(em * 0.4))
	}
	if preview_available() { panel(app, "preview_btn", lucide.GLOBE, i18n.tr("Preview panel"), i18n.tr("Preview panel  (Ctrl+Shift+B)"), "view.preview", named ? "command:view.preview" : "", app.preview.open, size, em) }
	panel(app, "terminal_btn", lucide.SQUARE_TERMINAL, i18n.tr("Terminal"), i18n.tr("Terminal  (Ctrl+Shift+T)"), "view.terminal", named ? "command:view.terminal" : "", app.cx.terms.open, size, em)
}

// The reader picks one, in the chooser of the composer's button or under `#` in the palette: the session shown takes it, and it stands until that session's end.
choose_agent :: proc(app: ^App, pane: ^Chat_Pane, agent: string) {
	c := &pane.chat
	if c.id != "" { switch_agent(app, c.id, agent) }
	c.chose_agent = strings.clone(agent, c.alloc)
	choice_remember(app, pane)
}

// (the variant stays when the new model has it too: "high" on one model is "high" on the next)
choose_model :: proc(app: ^App, pane: ^Chat_Pane, m: Model_Info) {
	c := &pane.chat
	variant := shown_variant(app, pane)
	if !slice.contains(model_variants(app, m.id, m.provider), variant) { variant = "" }
	variant = strings.clone(variant, c.alloc)
	if c.id != "" { switch_model(app, c.id, m.id, m.provider, variant) }
	c.chose_model, c.chose_provider, c.chose_variant = strings.clone(m.id, c.alloc), strings.clone(m.provider, c.alloc), variant
	choice_remember(app, pane)
}

// How hard the model shown thinks, picked in the composer's menu ("": the model's default). It goes with the model.
choose_variant :: proc(app: ^App, pane: ^Chat_Pane, variant: string) {
	c := &pane.chat
	model, provider := shown_model(app, pane)
	if model == "" { return }   // (the server's default model: its variants are not known)
	model, provider = strings.clone(model, c.alloc), strings.clone(provider, c.alloc)
	if c.id != "" { switch_model(app, c.id, model, provider, variant) }
	c.chose_model, c.chose_provider, c.chose_variant = model, provider, strings.clone(variant, c.alloc)
	choice_remember(app, pane)
}

// The agent and the model chosen last: what a new session starts with, from one run of the program to the next.
@(private = "file")
choice_remember :: proc(app: ^App, pane: ^Chat_Pane) {
	model, provider := shown_model(app, pane)
	agent := strings.clone(shown_agent(app, pane), context.temp_allocator)
	model, provider = strings.clone(model, context.temp_allocator), strings.clone(provider, context.temp_allocator)
	pref_set(app, "session.agent", agent)
	pref_set(app, "session.model", model)
	pref_set(app, "session.provider", provider)
	pref_set(app, "session.variant", strings.clone(shown_variant(app, pane), context.temp_allocator))
}

// The caret is on the first line the composer shows, wrapped or not (as last drawn).
composer_on_first_line :: proc(app: ^App, pane: ^Chat_Pane) -> bool {
	a := &pane.composer.area
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
prompt_restore :: proc(app: ^App, pane: ^Chat_Pane, text: string) {
	if text == "" { return }   // (an image alone)
	typed := ui.text_edit_string(&pane.composer.area)
	ui.text_edit_set(&pane.composer.area, strings.trim_space(typed) == "" ? text : fmt.tprintf("%s\n%s", text, typed))
}

// Enter, or Send. While the session it would go to is starting it stays in the composer: nothing is lost, the button says it. While a
// turn runs `other` is the way that is not Enter's (composer_send_as); what is being edited goes back where it was, whichever.
// `first` (Alt+Enter): while a turn runs it is queued first (queue_first_start); otherwise it is Enter.
submit_prompt :: proc(app: ^App, pane: ^Chat_Pane, other := false, first := false) {
	t := strings.clone(strings.trim_space(ui.text_edit_string(&pane.composer.area)), context.temp_allocator)
	empty := t == "" && len(pane.composer.attachments) == 0
	// (the other way, nothing written, while a run works: the first queued prompt is steered into it, as opencode 2.3.0's
	// desktop does)
	if empty && other && !first && pane.chat.busy && !queue_editing(app, pane) { queue_steer_first(app, pane); return }
	if empty || !online(app) || composer_held(app, pane) { return }
	history_leave(app, pane, false)
	if queue_editing(app, pane) { queue_edit_commit(app, pane, t); return }
	// (a command of this program, before the server's: slash.odin CLIENT_COMMANDS)
	if client_command_run(app, pane, t) { return }
	if first && composer_send_as(app, pane) != .Idle {
		fields := send_as_fields(.Queue)
		// (a command is not a prompt the inbox can admit again: it goes queued, where it falls)
		if !slash_send(app, pane, t, fields) {
			outgoing_composer(app, pane, t, pane.chat.new_dir, fields)
			queue_first_await(app, pane, app.cx.outgoing_last)
		}
		ui.text_edit_set(&pane.composer.area, "")
		return
	}
	as := composer_send_as(app, pane, other)
	fields := send_as_fields(as)
	if pane.chat.id == "" || !slash_send(app, pane, t, fields) { outgoing_composer(app, pane, t, pane.chat.new_dir, fields) }
	ui.text_edit_set(&pane.composer.area, "")
	if as == .Idle { chat_scroll_event(pane, Scroll_Signal.Go_Bottom) }   // (what waits shows over the composer: the conversation stays where it is)
}

// The room beside the words of a toolbar button (agent, model, variant, approvals), in ems. The toolkit's own (0.95)
// is a lone button's: four ghost buttons in a row read as far apart, their faces unseen until the pointer comes.
COMPOSER_TOOL_PAD_EM :: 0.4

// The next toolbar button's room beside its words.
composer_tool_pad :: proc(em: f32) { ui.next({text_pad = math.round(em * COMPOSER_TOOL_PAD_EM)}) }

// How hard the model thinks: a button beside the model's that opens the menu of its variants. None when the model has none.
@(private = "file")
// `glyph`: its glyph alone (a narrow toolbar).
variant_button :: proc(app: ^App, pane: ^Chat_Pane, em: f32, glyph := false) {
	model, provider := shown_model(app, pane)
	variants := model_variants(app, model, provider)
	if len(variants) == 0 { return }
	current := shown_variant(app, pane)
	ui.a11y({role = .Button, name = i18n.tr("Thinking")})
	name := current != "" ? current : i18n.tr("default")
	composer_tool_pad(em)
	sig := ui.button("variant", ui.text_shown(glyph ? "" : name), lucide.GAUGE, {face = .Ghost, height = math.round(em * BUTTON_COMPACT_H_EM), quiet = true})
	key := "variant_menu"
	if sig.clicked { ui.menu_open(key, sig.box.rect, sig.box.key, search = false) }
	if ui.hovered_for(sig) { if ui.tooltip() { ui.tooltip_text(glyph ? fmt.tprintf(i18n.tr("How hard the model thinks: %s"), name) : i18n.tr("How hard the model thinks")) } }
	if ui.menu(key, em * 12) {
		if ui.menu_item(fmt.tprintf("%s###v_default", i18n.tr("default")), "", current == "").clicked { choose_variant(app, pane, "") }
		for v, i in variants {
			if ui.menu_item(fmt.tprintf("%s###v%d", label_safe(v), i), "", v == current).clicked { choose_variant(app, pane, v) }
		}
	}
}

// A character typed this build that is not a space.
@(private = "file")
typed_word :: proc(app: ^App) -> bool {
	for r in app.state.typed { if r > ' ' && r != 0x7f { return true } }
	return false
}
