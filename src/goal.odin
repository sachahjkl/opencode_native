// The session's goal (`/goal <objective>`, the server's opencode.goal plugin): an objective the session works on round after
// round until it is met, paused or cleared. While the session has one, a line over the composer says it: its objective, how
// it stands (active, paused, met), the rounds, and what can be done to it (pause or resume, change, clear), each one the
// `/goal` command. It is read when the session is shown (POST /api/rpc/opencode.goal/get) and follows the stream's
// rpc.opencode.goal.changed.
package ocn

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "gt:ui"
import lucide "gt:lucide"

Goal_Status :: enum u8 { Active, Paused, Complete }

Goal :: struct {
	objective, reason: string,   // (in the chat's arena)
	status:            Goal_Status,
	rounds, max_rounds: int,
}

GOAL_EVENT :: "rpc.opencode.goal.changed"

// The session shown's goal, asked again.
goal_read :: proc(app: ^App) {
	id := app.chat.id
	if id == "" || flying(app, .Goal, id) { return }
	q := location_query(chat_dir(app))
	path := q != "" ? fmt.tprintf("/api/rpc/opencode.goal/get?%s", q) : "/api/rpc/opencode.goal/get"
	request(app, .Goal, "POST", path, fmt.tprintf(`{{"input":{{"sessionID":%s}}}}`, jquote(id)), tag = id)
}

// What the server said of a session's goal (null: none). Another session's is not this one's.
goal_set :: proc(app: ^App, session: string, v: json.Value) {
	c := &app.chat
	if session != c.id { return }
	if _, none := v.(json.Null); none || v == nil {
		c.goal, c.has_goal = {}, false
		return
	}
	g := Goal{objective = strings.clone(jstr(v, "objective"), c.alloc), reason = strings.clone(jstr(v, "reason"), c.alloc)}
	switch jstr(v, "status") {
	case "paused":   g.status = .Paused
	case "complete": g.status = .Complete
	case:            g.status = .Active
	}
	g.rounds, g.max_rounds = int(jnum(v, "rounds")), int(jnum(v, "maxRounds"))
	c.goal, c.has_goal = g, g.objective != ""
}

// `/goal <what>` for the session shown.
@(private = "file")
goal_command :: proc(app: ^App, what: string) {
	outgoing_command(app, fmt.tprintf("/goal %s", what), "goal", what)
	goal_read(app)
}

// Over the composer: the goal and what can be done to it.
goal_strip :: proc(app: ^App, em: f32) {
	c := &app.chat
	if !c.has_goal || c.id == "" { return }
	g := &c.goal
	ui.next({width = ui.fill(), height = ui.px(math.round(em * BUTTON_COMPACT_H_EM)), axis = .X, cross = .Center})
	ui.a11y({role = .Group, name = "Goal"})
	if ui.row(.Center, id = "###goal_strip") {
		note := ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}
		ui.spacer(ui.px(em * 0.5))
		switch g.status {
		case .Active:   lamp("###gl", hex(HEX_YELLOW), 1, pulse = true, size = em * CARD_MARK_EM)
		case .Paused:   lamp("###gl", hex(HEX_FAINT), 1, size = em * CARD_MARK_EM)
		case .Complete: glyph(lucide.CHECK, hex(HEX_GREEN), math.round(em * ICON_SMALL))
		}
		ui.spacer(ui.px(em * 0.35))
		word := g.status == .Active ? "goal" : g.status == .Paused ? "goal paused" : "goal met"
		text("w", word, hex(HEX_WEAK), note)
		ui.spacer(ui.px(em * 0.5))
		text("o", g.objective, hex(HEX_TEXT_SOFT), ui.Style_Mod{font_size = math.round(em * FS_NOTE)}, ui.fill())
		if g.max_rounds > 0 {
			ui.spacer(ui.px(em * 0.6))
			text("r", fmt.tprintf("round %d/%d", g.rounds, g.max_rounds), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
		}
		ui.spacer(ui.px(em * 1.0))
		switch g.status {
		case .Active:   if hint_action("###g_pause", "pause", em, app.mono, lucide.SQUARE) { goal_command(app, "pause") }
		case .Paused:   if hint_action("###g_resume", "resume", em, app.mono, lucide.SEND_HORIZONTAL) { goal_command(app, "resume") }
		case .Complete:
		}
		ui.spacer(ui.px(em * 0.9))
		if hint_action("###g_change", "change", em, app.mono, lucide.PENCIL) {
			ui.area_set(&app.composer, fmt.tprintf("/goal %s", g.objective))
			app.cx.focus_composer = true
		}
		ui.spacer(ui.px(em * 0.9))
		if hint_action("###g_clear", "clear", em, app.mono, lucide.X) { goal_command(app, "clear") }
		ui.spacer(ui.px(em * 0.5))
	}
}

// Why the goal is paused (the server's reason: "The session failed: You've hit your 5-hour limit…"), at the end of the conversation,
// across it as a change of the session is: all of it, on as many lines as it takes. It goes when the goal goes on.
goal_reason_line :: proc(app: ^App, em: f32) {
	c := &app.chat
	if !c.has_goal || c.goal.status != .Paused || c.goal.reason == "" { return }
	small := ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}
	ui.next({width = ui.fill(), height = ui.px(em * 2), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###goal_why") {
		groove(across = true)
		ui.spacer(ui.px(em * 0.6))
		lamp("###gwl", hex(HEX_FAINT), 1, size = em * CARD_MARK_EM)
		ui.spacer(ui.px(em * 0.35))
		text("w", "goal paused", hex(HEX_WEAK), small)
		ui.spacer(ui.px(em * 0.6))
		groove(across = true)
	}
	ui.next({width = ui.fill(), font_size = math.round(em * FS_NOTE), flags = {.Text_Wrap}, fg = hex(HEX_WEAK), text_pad = 0, text_align = .Center})
	ui.paragraph(fmt.tprintf("%s###goal_reason", label_safe(c.goal.reason)))
	ui.spacer(ui.px(em * 1.2))
}
