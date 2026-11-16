// MCP events (opencode 2.3.0, experimental): what the stream's `experimental.mcp.event` says goes on the MCP servers page under its
// server; the synthetic message that wakes a session watching one shows in its conversation as a note with the event's data
// (src/md/features/mcp-events.md).
package ocn

import tk_json "gt:json"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

// An event of the stream, as the page shows it: read once, when it comes. (Its strings are owned.)
Mcp_Event :: struct {
	sub, server, name, event_id: string,   // its subscription, its server, its type, the MCP server's id of it
	data:      string,   // its data on one line, cut ("": none)
	at:        f64,      // when it came (epoch ms)
	truncated: bool,     // events before it were skipped
}

// The stream's event `d`, which came at `at`. Delivery is at least once: one already kept (same subscription, same id) is dropped.
mcp_event_add :: proc(app: ^App, d: json.Value, at: f64) {
	sub, id := tk_json.text(d, "id"), tk_json.text(d, "eventId")
	for e in app.mcp_events { if e.sub == sub && e.event_id == id { return } }
	if len(app.mcp_events) >= MCP_EVENTS_KEPT {
		mcp_event_free(app.mcp_events[0])
		ordered_remove(&app.mcp_events, 0)
	}
	data := ""
	if v := tk_json.get(d, "data"); v != nil { data = ellipsize(tk_json.to_text(v), MCP_EVENT_DATA_CHARS) }
	append(&app.mcp_events, Mcp_Event{
		sub = strings.clone(sub), server = strings.clone(tk_json.text(d, "server")), name = strings.clone(tk_json.text(d, "name")),
		event_id = strings.clone(id), data = strings.clone(data), at = at, truncated = tk_json.boolean(d, "truncated"),
	})
}

@(private = "file")
mcp_event_free :: proc(e: Mcp_Event) {
	delete(e.sub); delete(e.server); delete(e.name); delete(e.event_id); delete(e.data)
}

// They were the server's left.
mcp_events_forget :: proc(app: ^App) {
	for e in app.mcp_events { mcp_event_free(e) }
	clear(&app.mcp_events)
}

// Under a server's row of the MCP servers page: its last events, the newest first. (At most MCP_EVENTS_KEPT to look through.)
mcp_server_events :: proc(app: ^App, server: string, em: f32) {
	now := now_epoch_ms()
	shown := 0
	for k := len(app.mcp_events) - 1; k >= 0 && shown < MCP_EVENTS_SHOWN; k -= 1 {
		e := &app.mcp_events[k]
		if e.server != server { continue }
		if shown == 0 { ui.space(ui.LINE_GAP) }
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.4)), axis = .X, cross = .Center})
		if ui.row(.Center, id = fmt.tprintf("###ev%d", k)) {
			ui.spacer(ui.px(math.round(em * (0.9 + ui.ICON_GAP))))   // (under the name: the lamp and its gap)
			text("n", e.name, ui.theme_color("soft text"), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
			ui.space(ui.ICON_GAP)
			if e.truncated {
				text("k", i18n.tr("earlier events skipped"), ui.hue(.Yellow), ui.Style_Mod{font_size = math.round(em * FS_CAPTION)})
				ui.space(ui.ICON_GAP)
			}
			text("d", e.data, ui.theme_color("faint text"), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}, ui.fill())
			ui.space(ui.ICON_GAP)
			text("a", fmt.tprintf(i18n.tr("%s ago"), duration_text(e.at, now)), ui.theme_color("faint text"), ui.Style_Mod{font_size = math.round(em * FS_CAPTION)})
		}
		shown += 1
	}
}

// A synthetic message that woke its session for an MCP event (metadata.source "mcp.event", with an eventID): its server, its type,
// whether events were skipped, and its data, pretty, from the text's last fence. Read once, with the message. (A watch that stopped
// has no eventID: it keeps its plain line.)
mcp_wake_set :: proc(m: ^Message, it: json.Value, a := context.allocator) {
	if tk_json.text(it, "metadata", "eventID") == "" { return }
	m.mcp_server = strings.clone(tk_json.text(it, "metadata", "server"), a)
	m.mcp_event = strings.clone(tk_json.text(it, "metadata", "event"), a)
	m.mcp_skipped = strings.contains(m.text, "Some events before it were skipped")
	data := fenced_last(m.text)
	if v, err := json.parse_string(data, parse_integers = true, allocator = context.temp_allocator); err == nil {
		data = tk_json.to_text(v, "  ")
		if _, is_null := v.(json.Null); is_null { data = "" }
	}
	m.mcp_data = strings.clone(data, a)
}

// The body of the JSON fence that ends `s`: a run of backticks, "json", a line break, the body, a line break, the same run. The run is
// longer than any inside the body (the server makes it so), and the lines before it have no line break inside a field: its first
// opening is the fence's. ("": none.)
fenced_last :: proc(s: string) -> string {
	t := strings.trim_right_space(s)
	nl := strings.last_index_byte(t, '\n')
	if nl < 0 { return "" }
	close := t[nl + 1:]
	if len(close) < 3 || strings.trim_left(close, "`") != "" { return "" }
	open := strings.concatenate({close, "json\n"}, context.temp_allocator)
	head := strings.index(t[:nl + 1], open)
	if head < 0 || head + len(open) > nl { return "" }
	return t[head + len(open):nl]
}

// The note of a wake-up in the conversation: the server and the event, and its data under it.
mcp_wake_note :: proc(app: ^App, pane: ^Chat_Pane, m: ^Message, em: f32) {
	line := fmt.tprintf("%s · %s", m.mcp_server, m.mcp_event)
	if m.mcp_skipped { line = fmt.tprintf("%s · %s", line, i18n.tr("earlier events skipped")) }
	note_line(app, m, em, lucide.PLUG, line)
	if m.mcp_data == "" { return }
	mono_well(fmt.tprintf("###mcpd_%s", m.id), m.mcp_data, em, TOOL_INPUT_LINES_MAX, kept = &m.mcp_well, kept_in = pane.chat.alloc)
	ui.space(ui.SPACE_2)
}
