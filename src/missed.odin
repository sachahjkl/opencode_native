// What the person missed while away: a log (gt:notices) of what happened in the sessions of a server, kept across restarts in
// notices.txt beside the preferences. The log is a projection of what this program already knows, never a second truth:
//   - a run that ended and was not seen is the server's own mark (session_end_unseen: time.idle after time.viewed). missed_sync
//     puts an entry for each such session and acknowledges it when the mark goes (POST /view here, session.viewed from another
//     client, the session shown). A run that ends while the entry is open puts it again: it counts one more.
//   - what waits for the person is app.permissions and app.cx.forms. missed_sync puts an entry for each, and acknowledges it once
//     it is gone from them: only an answer acknowledges a wait.
//   - a command in the background that ended, a run that a schedule started, a sub-agent that ended: nothing else keeps them.
//     Their entries come from the event, and a visit of their session (opening it, the window coming in front of it) acknowledges them.
// The system's notifications are effects of the same entries: an entry keeps the id of its notification, and acknowledging it
// closes the notification (close_system).
//
// Keys and groups start with the server's name and MISSED_SCOPE: two servers never mix. A group is the root session (a
// sub-agent's wait or end goes under the session at the top of its tree).
package ocn

import "core:encoding/json"
import "core:strings"
import "core:unicode/utf8"
import "gt:platform"
import "gt:ui"
import notices "gt:notices"
import i18n "gt:i18n"

Missed_Kind :: enum u16 { End, Permission, Question, Shell, Scheduled, Sub }

@(rodata) MISSED_PREFIX := [Missed_Kind]string{
	.End = "end", .Permission = "perm", .Question = "form", .Shell = "shell", .Scheduled = "sched", .Sub = "sub",
}

MISSED_SCOPE      :: "\x1f"   // after the server's name, in a key and a group
MISSED_ASKER      :: "\x1e"   // after a wait's id in its key: the session that asks
MISSED_EXCERPT    :: 200      // bytes of an entry's excerpt, at most
MISSED_ROOT_DEPTH :: 8        // parents climbed to find a session's root
MISSED_FILE       :: "notices.txt"

// The run a schedule started in a session, until it ends (a scheduled prompt's id is msg_<schedule id>_<run>).
MISSED_SCHEDULED_ID :: "msg_sch_"

Missed_Scheduled :: struct { id, text: string }   // (owned)

// A row of the view: a session's header, or one of its entries.
Missed_Row :: struct {
	entry: ^notices.Entry,   // nil: the header of `root`
	root:  string,           // the session (in the log's memory: valid as the rows are)
	group: string,
	open:  int,              // a header: the entries of its group that are open and not waits (what "Acknowledge" acts on)
}

Missed :: struct {
	log:          notices.Log,
	opened:       bool,
	// what missed_sync last saw: it runs again when one of these moves
	synced:       bool,
	due:          bool,                          // a list of waits came back: a wait that is gone may be acknowledged now
	sessions_ver: u64,
	marks_ver:    u64,
	shown:        string,                        // app.chat.id (owned)
	server:       int,
	front:        bool,                          // the window was in front
	scheduled:    map[string]Missed_Scheduled,   // by session (keys owned)
	// the view (missed_view.odin), made again when the log, the server or the history toggle changes
	history:      bool,                          // the acknowledged entries are shown too
	rows:         [dynamic]Missed_Row,
	ids:          [dynamic]u64,
	selectable:   [dynamic]bool,
	rows_made:    bool,
	rows_log:     u64,
	rows_server:  int,
	rows_history: bool,
	rows_stamp:   u64,                           // bumped at each making: the list's ids_version
	new_here:     int,                           // New entries of this server: the bell's count
	vl:           ui.Virtual_List,
	fresh:        bool,                          // just opened: the list takes the keyboard
}

////////////////////////////////
// The log

// At the start, before the window (stores_open): the file is read on this thread. A test opens none: missed_log makes one in memory.
missed_open :: proc(app: ^App, path: string) {
	m := &app.missed
	notices.open(&m.log, path, NOTICES_KEEP_MAX)   // (the preference lowers it once read: an entry past the default is not dropped before)
	missed_adopt(app)
}

// At the end: what changed is written, then everything is freed.
missed_close :: proc(app: ^App) {
	m := &app.missed
	if !m.opened { return }
	notices.close(&m.log)
	m.opened = false
	for k, v in m.scheduled { delete(k); delete(v.id); delete(v.text) }
	delete(m.scheduled)
	m.scheduled = nil
	delete(m.shown)
	m.shown = ""
	m.synced = false
	missed_rows_free(app)
}

// The log, opened in memory when nothing opened it (a test).
missed_log :: proc(app: ^App) -> ^notices.Log {
	m := &app.missed
	if !m.opened {
		notices.open(&m.log, "", NOTICES_KEEP_MAX)
		missed_adopt(app)
	}
	return &m.log
}

@(private = "file")
missed_adopt :: proc(app: ^App) {
	m := &app.missed
	m.opened = true
	if app.prefs.notices_keep > 0 { m.log.cap = app.prefs.notices_keep }
	m.log.close_user = app
	m.log.close_system = proc(user: rawptr, id: platform.Notification_Id) {
		app := (^App)(user)
		if app.win != nil { platform.notify_close(app.win, id) }
	}
}

// The server's name: what keeps two servers' entries apart.
missed_scope :: proc(app: ^App) -> string {
	if app.server >= 0 && app.server < len(app.servers) { return app.servers[app.server].name }
	return ""
}

// The key of an entry (temp memory). `asker`: a wait's session.
missed_key :: proc(app: ^App, kind: Missed_Kind, id: string, asker := "") -> string {
	if asker != "" { return strings.concatenate({missed_scope(app), MISSED_SCOPE, MISSED_PREFIX[kind], ":", id, MISSED_ASKER, asker}, context.temp_allocator) }
	return strings.concatenate({missed_scope(app), MISSED_SCOPE, MISSED_PREFIX[kind], ":", id}, context.temp_allocator)
}

// The group of a root session (temp memory).
missed_group :: proc(app: ^App, root: string) -> string {
	return strings.concatenate({missed_scope(app), MISSED_SCOPE, root}, context.temp_allocator)
}

// What follows the server's name in a key or a group; ok false: another server's.
missed_unscoped :: proc(app: ^App, s: string) -> (rest: string, ok: bool) {
	scope := missed_scope(app)
	if len(s) <= len(scope) || !strings.has_prefix(s, scope) || !strings.has_prefix(s[len(scope):], MISSED_SCOPE) { return "", false }
	return s[len(scope) + len(MISSED_SCOPE):], true
}

// A key of this server as its parts: what it is about (`id`) and, for a wait, the session that asks.
missed_key_parts :: proc(app: ^App, key: string) -> (id, asker: string, ok: bool) {
	rest := missed_unscoped(app, key) or_return
	colon := strings.index_byte(rest, ':')
	if colon < 0 { return }
	id = rest[colon + 1:]
	if i := strings.index(id, MISSED_ASKER); i >= 0 { id, asker = id[:i], id[i + len(MISSED_ASKER):] }
	return id, asker, true
}

missed_is_wait :: proc(e: ^notices.Entry) -> bool {
	k := Missed_Kind(e.kind)
	return k == .Permission || k == .Question
}

// The session at the top of `id`'s tree, as far as it is known (`id` itself: a root, or one whose parent is not known).
session_root :: proc(app: ^App, id: string) -> string {
	cur := id
	for _ in 0 ..< MISSED_ROOT_DEPTH {
		parent := ""
		if s := find_session(app, cur); s != nil {
			parent = s.parent
		} else if cur == app.chat.id && app.chat.have_self {
			parent = app.chat.self.parent
		} else if c := find_child(&app.chat, cur); c != nil {
			parent = c.parent != "" ? c.parent : app.chat.id
		} else if is_child(&app.chat, cur) {
			parent = app.chat.id
		}
		if parent == "" || parent == cur { return cur }
		cur = parent
	}
	return cur
}

// The run of a root session ended and nobody has seen that end: the server's mark, without what runs now (a run that goes on
// keeps the entry of the last end until its own end puts it again). session_unseen is this, at rest.
session_end_unseen :: proc(app: ^App, s: ^Session_Info) -> bool {
	return s.parent == "" && s.idle > s.viewed && s.id != app.chat.id
}

// One line of `s`, at most MISSED_EXCERPT bytes and whole characters (temp memory).
missed_excerpt :: proc(s: string) -> string {
	line := strings.trim_space(first_line(s))   // (a line's own margins say nothing in one line)
	if len(line) <= MISSED_EXCERPT { return line }
	cut := MISSED_EXCERPT
	for cut > 0 && !utf8.rune_start(line[cut]) { cut -= 1 }
	return line[:cut]
}

// The window is in front of the person (no window: a test, nobody looks).
missed_front :: proc(app: ^App) -> bool { return app.win != nil && app.win.active }

// What happens under `root` is on the person's screen now: no entry for it.
@(private = "file")
missed_on_screen :: proc(app: ^App, root: string) -> bool {
	return app.chat.id != "" && missed_front(app) && session_root(app, app.chat.id) == root
}

@(private = "file")
missed_put :: proc(app: ^App, kind: Missed_Kind, key, root, title, text: string, outcome: Sub_State, at: f64) -> ^notices.Entry {
	e, _ := notices.put(missed_log(app), {key = key, group = missed_group(app, root), title = title, text = missed_excerpt(text), kind = u16(kind), outcome = u8(outcome), at = i64(at)})
	return e
}

@(private = "file")
missed_is_open :: proc(log: ^notices.Log, key: string) -> bool { return log.live[key] != nil }

////////////////////////////////
// What happens

// A run ended (the stream: it ran here). Its entry, or a sub-agent's; the run a schedule started has one more. Returns the key
// that a notification of it goes with ("": none).
missed_run_ended :: proc(app: ^App, sid, word: string) -> (key: string) {
	if sid == "" { return "" }
	st: Sub_State = word == "failed" ? .Failed : word == "interrupted" ? .Cancelled : .Done
	root := session_root(app, sid)
	screen := missed_on_screen(app, root)
	now := now_epoch_ms()
	if root == sid {
		// (a root the list does not know: the server's mark cannot be read, the entry would never go)
		if s := find_session(app, sid); s != nil && sid != app.chat.id {
			key = missed_key(app, .End, sid)
			missed_put(app, .End, key, root, missed_end_title(st), "", st, now)
		}
	} else if !screen {
		key = missed_key(app, .Sub, sid)
		missed_put(app, .Sub, key, root, "Sub-agent", missed_sub_text(app, sid), st, now)
	}
	m := &app.missed
	if sid in m.scheduled {
		k, run := delete_key(&m.scheduled, sid)
		if !screen { missed_put(app, .Scheduled, missed_key(app, .Scheduled, run.id), root, "Scheduled run", run.text, st, now) }
		delete(k); delete(run.id); delete(run.text)
	}
	return
}

@(private = "file")
missed_end_title :: proc(st: Sub_State) -> string {
	#partial switch st {
	case .Failed:    return i18n.later("Failed")
	case .Cancelled: return i18n.later("Stopped")
	}
	return i18n.later("Done")
}

// What a sub-agent handed back, when the conversation shown has it (its card's result, the end of its work read for the tray).
@(private = "file")
missed_sub_text :: proc(app: ^App, sid: string) -> string {
	if p, ok := app.activity.peeks[sid]; ok && p.text != "" { return p.text }
	if is_child(&app.chat, sid) { return sub_view(app, sid).result }
	return ""
}

// A message came into a session's inbox: a schedule's prompt starts a run that is that schedule's.
missed_inbox :: proc(app: ^App, sid: string, d: json.Value) {
	id := jstr(d, "inboxID")
	if sid == "" || !strings.has_prefix(id, MISSED_SCHEDULED_ID) { return }
	text := jstr(d, "item", "payload", "metadata", "schedule", "name")
	if text == "" { text = jstr(d, "item", "metadata", "schedule", "name") }
	if text == "" { text = jstr(d, "item", "payload", "text") }
	m := &app.missed
	if old, ok := m.scheduled[sid]; ok {
		delete(old.id); delete(old.text)
		m.scheduled[sid] = {strings.clone(id), strings.clone(missed_excerpt(text))}
		return
	}
	m.scheduled[strings.clone(sid)] = {strings.clone(id), strings.clone(missed_excerpt(text))}
}

// A command of the background ended (the tray's reading of the session shown). `session`: whose ("": the session shown).
missed_shell_ended :: proc(app: ^App, id, session, command: string, st: Sub_State) {
	sid := session != "" ? session : app.chat.id
	if sid == "" { return }
	root := session_root(app, sid)
	if missed_on_screen(app, root) { return }
	missed_put(app, .Shell, missed_key(app, .Shell, id), root, "Command ended", command, st, now_epoch_ms())
}

// The session is gone: what was about it goes, its history too.
missed_session_gone :: proc(app: ^App, sid: string) {
	if sid == "" { return }
	log := missed_log(app)
	notices.remove_group(log, missed_group(app, sid))
	notices.remove(log, missed_key(app, .Sub, sid))
}

// The person went to the session `id` (opened it, or the window came in front of it): what nothing else acknowledges, under its
// root, is seen. (Its end is the server's mark, missed_sync's; a wait waits for its answer.)
missed_visit :: proc(app: ^App, id: string) {
	if id == "" { return }
	log := missed_log(app)
	group := missed_group(app, session_root(app, id))
	keys := make([dynamic]string, context.temp_allocator)
	for e in log.entries {
		if e.state == .Acknowledged || e.group != group { continue }
		if k := Missed_Kind(e.kind); k == .Shell || k == .Scheduled || k == .Sub { append(&keys, e.key) }
	}
	for k in keys { notices.acknowledge(log, k) }
}

// A list of waits came back: what it no longer has is answered.
missed_due :: proc(app: ^App) { app.missed.due = true }

////////////////////////////////
// The projection

// The log as what is known says it. At each build, after the events and before their effects (a notification finds its entry);
// it does its work only when the sessions, their marks, the session shown or the server moved: O(sessions + waits + entries) then.
missed_sync :: proc(app: ^App) {
	m := &app.missed
	front := missed_front(app)
	if front && !m.front && app.chat.id != "" { missed_visit(app, app.chat.id) }
	m.front = front
	cx := &app.cx
	if m.synced && !m.due && m.sessions_ver == cx.sessions_ver && m.marks_ver == cx.marks_ver && m.shown == app.chat.id && m.server == app.server { return }
	m.synced, m.due = true, false
	m.sessions_ver, m.marks_ver, m.server = cx.sessions_ver, cx.marks_ver, app.server
	if m.shown != app.chat.id { delete(m.shown); m.shown = strings.clone(app.chat.id) }
	log := missed_log(app)

	// the ends: the server's mark, session by session
	if app.sessions_loaded {
		for &s in app.sessions {
			key := missed_key(app, .End, s.id)
			want := session_end_unseen(app, &s)
			open := missed_is_open(log, key)
			if want && !open {
				st, _ := state_of_word(s.outcome)
				if st == .Unknown { st = .Done }
				missed_put(app, .End, key, s.id, missed_end_title(st), "", st, s.idle)
			} else if !want && open {
				notices.acknowledge(log, key)
			}
		}
	}

	// the waits: what app.permissions and app.cx.forms hold
	now := now_epoch_ms()
	waiting := make(map[string]bool, len(app.permissions) + len(app.cx.forms), context.temp_allocator)
	for &p in app.permissions {
		if p.session == "" { continue }
		key := missed_key(app, .Permission, p.id, p.session)
		waiting[key] = true
		if !missed_is_open(log, key) { missed_put(app, .Permission, key, session_root(app, p.session), "Permission", permission_line(&p), .Unknown, now) }
	}
	for f in app.cx.forms {
		if f.session == "" { continue }   // (no session: the conversation shows it)
		key := missed_key(app, .Question, f.id, f.session)
		waiting[key] = true
		if !missed_is_open(log, key) { missed_put(app, .Question, key, session_root(app, f.session), "Question", form_line(f), .Unknown, now) }
	}
	// a wait gone from them was answered; one not read yet since the stream came up may still be on its way
	if app.sessions_loaded && online(app) && !cx.waits_unread {
		gone := make([dynamic]string, context.temp_allocator)
		for e in log.entries {
			if e.state == .Acknowledged || !missed_is_wait(e) || e.key in waiting { continue }
			id, asker, mine := missed_key_parts(app, e.key)
			if !mine { continue }
			if !waits_were_answered(app, id) && (flying(app, .Permissions, asker) || flying(app, .Forms, asker)) { continue }
			append(&gone, e.key)
		}
		for k in gone { notices.acknowledge(log, k) }
	}
}

// A permission in a line, from what is kept of it (permission_words reads the event's).
@(private = "file")
permission_line :: proc(p: ^Permission) -> string {
	if m := strings.trim_space(p.message); m != "" { return first_line(m) }
	if len(p.resources) > 0 { return strings.concatenate({p.action, " ", p.resources[0]}, context.temp_allocator) }
	return p.action
}

@(private = "file")
form_line :: proc(f: ^Form_Req) -> string {
	if t := strings.trim_space(f.title); t != "" { return first_line(t) }
	if len(f.fields) > 0 { return first_line(f.fields[0].title) }
	return ""
}

////////////////////////////////
// What the person does

// Acknowledges an entry of this server. A wait is not: its answer is. An end is the server's mark: POST /view says it was seen.
// False: nothing to acknowledge.
missed_acknowledge :: proc(app: ^App, key: string) -> bool {
	log := missed_log(app)
	e := log.live[key]
	if e == nil || missed_is_wait(e) { return false }
	if Missed_Kind(e.kind) == .End {
		if id, _, ok := missed_key_parts(app, key); ok {
			if s := find_session(app, id); s != nil { session_seen(app, s) }
		}
	}
	notices.acknowledge(log, key)
	return true
}

// Every open entry of the group, waits aside. Returns how many.
missed_acknowledge_group :: proc(app: ^App, group: string) -> int {
	return missed_acknowledge_where(app, group)
}

// Every open entry of this server, waits aside. Returns how many.
missed_acknowledge_all :: proc(app: ^App) -> int { return missed_acknowledge_where(app, "") }

@(private = "file")
missed_acknowledge_where :: proc(app: ^App, group: string) -> (n: int) {
	log := missed_log(app)
	keys := make([dynamic]string, context.temp_allocator)
	for e in log.entries {
		if e.state == .Acknowledged || missed_is_wait(e) { continue }
		if group != "" && e.group != group { continue }
		if _, mine := missed_unscoped(app, e.key); !mine { continue }
		append(&keys, strings.clone(e.key, context.temp_allocator))
	}
	for k in keys { if missed_acknowledge(app, k) { n += 1 } }
	return
}

// Opens the view, or closes it. Opened, what was New is Seen.
missed_toggle :: proc(app: ^App) {
	if app.cx.open[.Notices] { app.cx.open[.Notices] = false; return }
	missed_view_open(app)
}

missed_view_open :: proc(app: ^App) {
	app.cx.open[.Notices] = true
	app.missed.fresh = true
	notices.seen_all(missed_log(app))
}

// The oldest open entry of this server whose session is not the one shown: its session opens (the queue of what was missed).
missed_next :: proc(app: ^App) {
	log := missed_log(app)
	for e in log.entries {
		if e.state == .Acknowledged { continue }
		root, mine := missed_unscoped(app, e.group)
		if !mine || root == "" || root == app.chat.id { continue }
		open_root(app, root)
		return
	}
	ui.toast(.Info, i18n.tr("Nothing missed"))
}

// A notification of the system came back: a click opens the session of its entry (the visit acknowledges what it can), in front.
missed_notification_click :: proc(app: ^App, id: platform.Notification_Id) {
	if app.win != nil { platform.raise_window(app.win) }
	if !app.missed.opened || id == 0 { return }
	for e in app.missed.log.entries {
		if e.system != id { continue }
		if root, mine := missed_unscoped(app, e.group); mine && root != "" && root != app.chat.id { open_root(app, root) }
		return
	}
}

missed_notification_closed :: proc(app: ^App, id: platform.Notification_Id) {
	if app.missed.opened { notices.system_closed(&app.missed.log, id) }
}

// The notification of the system shown for `key` (0: none): a new one replaces it.
missed_system_of :: proc(app: ^App, key: string) -> platform.Notification_Id {
	if key == "" || !app.missed.opened { return 0 }
	if e := app.missed.log.live[key]; e != nil { return e.system }
	return 0
}

missed_system_set :: proc(app: ^App, key: string, id: platform.Notification_Id) {
	if key == "" { return }
	notices.set_system(missed_log(app), key, id)
}
