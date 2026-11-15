// The session's goal (`/goal <objective>`, the server's opencode.goal plugin): an objective the session works on round after
// round until it is met, paused or cleared. While the session has one, a line over the composer says it: its objective, how
// it stands (active, paused, met), the rounds, and what can be done to it (pause or resume, change, clear), each one the
// `/goal` command. It is read when the session is shown (POST /api/rpc/opencode.goal/get) and follows the stream's
// rpc.opencode.goal.changed.
package ocn

import tk_json "gt:json"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

Goal_Status :: enum u8 { Active, Paused, Complete }

Goal :: struct {
	objective, reason: string,   // (in the chat's arena)
	status:            Goal_Status,
	rounds, max_rounds: int,
}

GOAL_EVENT :: "rpc.opencode.goal.changed"

// The session shown's goal, asked again.
goal_read :: proc(app: ^App, pane: ^Chat_Pane) {
	id := pane.chat.id
	if id == "" || flying(app, .Goal, id) { return }
	q := location_query(pane_dir(app, pane))
	path := q != "" ? fmt.tprintf("/api/rpc/opencode.goal/get?%s", q) : "/api/rpc/opencode.goal/get"
	request(app, .Goal, "POST", path, fmt.tprintf(`{{"input":{{"sessionID":%s}}}}`, tk_json.quote(id)), tag = id, pane = pane)
}

// What the server said of a session's goal (null: none), in each pane that shows that session.
goal_set :: proc(app: ^App, session: string, v: json.Value) {
	for &pane, i in app.panes {
		if pane_is_shown(app, i) && pane.chat.id == session { chat_goal_set(&pane.chat, v) }
	}
}

@(private = "file")
chat_goal_set :: proc(c: ^Chat, v: json.Value) {
	if _, none := v.(json.Null); none || v == nil {
		c.goal, c.has_goal = {}, false
		return
	}
	g := Goal{objective = strings.clone(tk_json.text(v, "objective"), c.alloc), reason = strings.clone(tk_json.text(v, "reason"), c.alloc)}
	switch tk_json.text(v, "status") {
	case "paused":   g.status = .Paused
	case "complete": g.status = .Complete
	case:            g.status = .Active
	}
	g.rounds, g.max_rounds = int(tk_json.number(v, "rounds")), int(tk_json.number(v, "maxRounds"))
	c.goal, c.has_goal = g, g.objective != ""
}

// `/goal <what>` for the session shown.
@(private = "file")
goal_command :: proc(app: ^App, pane: ^Chat_Pane, what: string) {
	outgoing_command(app, pane, fmt.tprintf("/goal %s", what), "goal", what)
	goal_read(app, pane)
}

// Over the composer: the goal and what can be done to it.
goal_strip :: proc(app: ^App, pane: ^Chat_Pane, em: f32) {
	c := &pane.chat
	if !c.has_goal || c.id == "" { return }
	g := &c.goal
	ui.next({width = ui.fill(), height = ui.px(math.round(em * BUTTON_COMPACT_H_EM)), axis = .X, cross = .Center})
	ui.a11y({role = .Group, name = i18n.tr("Goal")})
	if ui.row(.Center, id = "###goal_strip") {
		note := ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}
		ui.spacer(ui.px(em * 0.5))
		switch g.status {
		case .Active:   lamp("###gl", ui.hue(.Yellow), 1, pulse = true, size = em * CARD_MARK_EM)
		case .Paused:   lamp("###gl", themed("faint text"), 1, size = em * CARD_MARK_EM)
		case .Complete: glyph(lucide.CHECK, ui.hue(.Green), math.round(em * ICON_SMALL))
		}
		ui.spacer(ui.px(em * 0.35))
		word := g.status == .Active ? i18n.tr("goal") : g.status == .Paused ? i18n.tr("goal paused") : i18n.tr("goal met")
		text("w", word, themed("weak text"), note)
		ui.spacer(ui.px(em * 0.5))
		text("o", g.objective, themed("soft text"), ui.Style_Mod{font_size = math.round(em * FS_NOTE)}, ui.fill())
		if g.max_rounds > 0 {
			ui.spacer(ui.px(em * 0.6))
			text("r", fmt.tprintf(i18n.tr("round %d/%d"), g.rounds, g.max_rounds), themed("faint text"), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
		}
		ui.spacer(ui.px(em * 1.0))
		switch g.status {
		case .Active:   if hint_action("###g_pause", "pause", em, app.mono, lucide.SQUARE) { goal_command(app, pane, "pause") }
		case .Paused:   if hint_action("###g_resume", "resume", em, app.mono, lucide.SEND_HORIZONAL) { goal_command(app, pane, "resume") }
		case .Complete:
		}
		ui.spacer(ui.px(em * 0.9))
		if hint_action("###g_change", "change", em, app.mono, lucide.PENCIL) {
			ui.text_edit_set(&pane.composer.area, fmt.tprintf("/goal %s", g.objective))
			pane.composer.focus_next = true
		}
		ui.spacer(ui.px(em * 0.9))
		if hint_action("###g_clear", "clear", em, app.mono, lucide.X, .Danger) { goal_command(app, pane, "clear") }
		ui.spacer(ui.px(em * 0.5))
	}
}

// Why the goal is paused (the server's reason: "The session failed: You've hit your 5-hour limit…"), at the end of the conversation,
// across it as a change of the session is: all of it, on as many lines as it takes. It goes when the goal goes on.
goal_reason_line :: proc(app: ^App, pane: ^Chat_Pane, em: f32) {
	c := &pane.chat
	if !c.has_goal || c.goal.status != .Paused || c.goal.reason == "" { return }
	small := ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}
	why, resets := reason_and_reset(c.goal.reason, app.prefs.clock24)
	// (past the reset, what stopped it is over: the goal waits only for a word, which the line offers; the reason is history)
	over := resets > 0 && resets <= now_epoch_ms()
	ui.next({width = ui.fill(), height = ui.px(em * 2), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###goal_why") {
		groove(across = true)
		ui.spacer(ui.px(em * 0.6))
		lamp("###gwl", themed("faint text"), 1, size = em * CARD_MARK_EM)
		ui.spacer(ui.px(em * 0.35))
		text("w", i18n.tr("goal paused"), themed("weak text"), small)
		if resets > 0 {
			text("when", reset_text(resets, now_epoch_ms(), app.prefs.clock24), themed("faint text"), small)
			if !over { ui.wake_within(&app.state, GOAL_RESET_TICK_MS) }   // (the time left, minute after minute)
		}
		if over {
			ui.spacer(ui.px(em * 0.8))
			if hint_action("###gw_resume", "resume", em, app.mono, lucide.SEND_HORIZONAL) { goal_command(app, pane, "resume") }
		}
		ui.spacer(ui.px(em * 0.6))
		groove(across = true)
	}
	ui.next({width = ui.fill(), font_size = math.round(em * FS_NOTE), flags = {.Text_Wrap}, fg = over ? themed("faint text") : themed("weak text"), text_pad = 0, text_align = .Center})
	ui.paragraph(fmt.tprintf("%s###goal_reason", label_safe(why)))
	ui.spacer(ui.px(em * 1.2))
}

GOAL_RESET_TICK_MS :: 30_000

// The server's reason, said for a person: its "Resets at 2026-11-10T11:20:00.000Z." (a time in UTC, after the same time in words)
// goes, and when that is, in ms since 1970 (0: it says none). A time in the middle of a sentence is the local clock's instead.
reason_and_reset :: proc(reason: string, clock24: bool) -> (text: string, resets_ms: f64) {
	text = reason
	for i := 0; i + ISO_DATE_LEN <= len(text); i += 1 {
		if !looks_iso(text[i:]) { continue }
		t, used := time.rfc3339_to_time_utc(text[i:])
		if used == 0 { continue }
		ms := f64(time.to_unix_nanoseconds(t)) / NS_PER_MS
		// (the parser stops inside a fraction of milliseconds: ".000Z" leaves "0Z")
		for i + used < len(text) && (text[i + used] >= '0' && text[i + used] <= '9' || text[i + used] == 'Z') { used += 1 }
		before := strings.trim_right_space(text[:i])
		after := text[i + used:]
		// "Resets at <time>." as a sentence of its own: the sentence goes, the line over the reason says the time
		if lower := strings.to_lower(before, context.temp_allocator); strings.has_suffix(lower, "resets at") {
			start := len(before) - len("resets at")
			after = strings.trim_prefix(after, ".")
			text = strings.trim_space(strings.concatenate({strings.trim_right_space(text[:start]), after}, context.temp_allocator))
			return text, ms
		}
		text = strings.concatenate({text[:i], clock_text(ms, clock24), after}, context.temp_allocator)
		resets_ms = ms
		i += 1
	}
	return
}

ISO_DATE_LEN :: len("2026-11-10T11:20:00Z")

// "2026-11-10T..." at the start of s: four digits, a dash, two, a dash, two, a T.
@(private = "file")
looks_iso :: proc(s: string) -> bool {
	digit :: proc(c: u8) -> bool { return c >= '0' && c <= '9' }
	return len(s) >= 11 && digit(s[0]) && digit(s[1]) && digit(s[2]) && digit(s[3]) && s[4] == '-' && digit(s[5]) && digit(s[6]) && s[7] == '-' && digit(s[8]) && digit(s[9]) && (s[10] == 'T' || s[10] == 't')
}

////////////////////////////////
// What the answers to its requests do (net.odin REQ_FACTS)

goal_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { goal_set(app, r.tag, tk_json.get(v, "output")) }
