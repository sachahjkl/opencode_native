// A session's approval mode: its own permission rules on the server (Session.Info.permissions). They come after the
// configuration's and the last rule that matches wins, so a preset here says what the session asks for; a policy's deny stays.
// The server decides and every client sees the same (session.permissions): nothing is answered here in its place.
package ocn

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "gt:ui"
import lucide "gt:lucide"

Approval :: enum u8 { Configured, Allow_Edits, Allow_All, Ask_All, Custom }

// The rules each preset puts on the session (Configured: none; Custom: rules set elsewhere, left as they are).
APPROVAL_RULES := [Approval]string{
	.Configured  = "null",
	.Allow_Edits = `[{"action":"edit","resource":"*","effect":"allow"}]`,
	.Allow_All   = `[{"action":"*","resource":"*","effect":"allow"}]`,
	.Ask_All     = `[{"action":"*","resource":"*","effect":"ask"}]`,
	.Custom      = "",
}

APPROVAL_WORDS := [Approval]string{
	.Configured  = "As configured",
	.Allow_Edits = "Allow edits",
	.Allow_All   = "Allow everything",
	.Ask_All     = "Ask for everything",
	.Custom      = "Custom rules",
}

// What each says in the menu.
APPROVAL_DETAIL := [Approval]string{
	.Configured  = "the server's rules decide",
	.Allow_Edits = "file edits go without asking",
	.Allow_All   = "nothing is asked; a policy's deny stays",
	.Ask_All     = "every action waits for you",
	.Custom      = "rules set elsewhere",
}

// The word beside the shield in the toolbar ("": the shield alone).
@(private = "file")
APPROVAL_SHORT := [Approval]string{.Configured = "", .Allow_Edits = "edits", .Allow_All = "all", .Ask_All = "ask", .Custom = "custom"}

// The preset a session's rules are (none or empty: Configured; any other: Custom).
approval_of :: proc(rules: json.Value) -> Approval {
	list, is_list := rules.(json.Array)
	if rules == nil || (is_list && len(list) == 0) { return .Configured }
	if !is_list || len(list) != 1 { return .Custom }
	action, resource, effect := jstr(list[0], "action"), jstr(list[0], "resource"), jstr(list[0], "effect")
	switch {
	case action == "edit" && resource == "*" && effect == "allow": return .Allow_Edits
	case action == "*" && resource == "*" && effect == "allow":    return .Allow_All
	case action == "*" && resource == "*" && effect == "ask":      return .Ask_All
	}
	return .Custom
}

// The mode of the session shown.
approval_shown :: proc(app: ^App) -> Approval {
	c := &app.chat
	if c.have_self { return c.self.approval }
	if s := find_session(app, c.id); s != nil { return s.approval }
	return .Configured
}

// What the server says a session's rules are now (session.permissions, or a session read again).
approval_seen :: proc(app: ^App, sid: string, mode: Approval) {
	if s := find_session(app, sid); s != nil { s.approval = mode }
	if app.chat.have_self && app.chat.self.id == sid { app.chat.self.approval = mode }
}

// Puts a preset's rules on the session. Shown at once; the server's session.permissions confirms it to every client.
approval_set :: proc(app: ^App, sid: string, mode: Approval) {
	if sid == "" || mode == .Custom { return }
	request(app, .Action, "PATCH", fmt.tprintf("/api/session/%s", sid), fmt.tprintf(`{{"permissions":%s}}`, APPROVAL_RULES[mode]), sid)
	approval_seen(app, sid, mode)
}

// The shield in the composer's toolbar: the session's mode in its colour, a menu of the presets.
approval_button :: proc(app: ^App, em: f32) {
	mode := approval_shown(app)
	color: Color
	switch mode {
	case .Configured:  color = hex(HEX_WEAK)
	case .Allow_Edits: color = hex(HEX_BLUE)
	case .Allow_All:   color = hex(HEX_YELLOW)   // (nothing is asked: it says so)
	case .Ask_All:     color = hex(HEX_GREEN)
	case .Custom:      color = hex(HEX_PURPLE)
	}
	ui.a11y({role = .Button, name = fmt.tprintf("Approvals: %s", APPROVAL_WORDS[mode])})
	key := ui.key_from_string(0, "approval_menu")
	sig := bevel_button("###approval", APPROVAL_SHORT[mode], lucide.SHIELD, height = math.round(em * BUTTON_COMPACT_H_EM), quiet = true, lit = ui.ctx_menu_is_open(key), icon_color = color, face = .Ghost)
	if sig.clicked { ui.ctx_menu_open_rect(key, sig.box.rect, sig.box.key) }
	if ui.hovered_for(sig, TOOLTIP_DELAY_S) { if ui.tooltip() { ui.tooltip_text(fmt.tprintf("Approvals: %s (%s)", APPROVAL_WORDS[mode], APPROVAL_DETAIL[mode])) } }
	if ui.ctx_menu(key) {
		ui.menu_heading("Approvals in this session")
		for m in Approval {
			if m == .Custom && mode != .Custom { continue }   // (shown only when the session has such rules)
			// (what it does in the shortcut's column: faint, at the right)
			if ui.menu_item(APPROVAL_WORDS[m], APPROVAL_DETAIL[m], m == mode, enabled = m != .Custom).clicked {
				approval_set(app, app.chat.id, m)
			}
		}
	}
}

// The preset a new session is made with (permission.new_sessions): its rules go in the request that makes it, so the server
// applies them from its first step, as the shield would.
approval_of_pref :: proc(name: string) -> Approval {
	switch name {
	case "allow_edits": return .Allow_Edits
	case "allow_all":   return .Allow_All
	case "ask_all":     return .Ask_All
	}
	return .Configured
}

// What makes a session in `directory` ("": the server's): its place, and the rules of the preset new sessions take.
new_session_body :: proc(app: ^App, directory: string) -> string {
	fields := make([dynamic]string, context.temp_allocator)
	if directory != "" { append(&fields, fmt.tprintf(`"location":{{"directory":%s}}`, jquote(directory))) }
	if mode := app.prefs.new_sessions; mode != .Configured { append(&fields, fmt.tprintf(`"permissions":%s`, APPROVAL_RULES[mode])) }
	return fmt.tprintf("{{%s}}", strings.join(fields[:], ",", context.temp_allocator))
}
