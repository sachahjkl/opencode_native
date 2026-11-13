// What happens without anyone at the keyboard, and what the server keeps beside the sessions: a session's schedules (a prompt that wakes it
// later), the artifacts of a folder (pages an agent published) and the plugins. Schedules and artifacts are experimental on the server,
// off unless its configuration turns them on: the dialogs say what it answers then. A plugin's GUI bundle is CommonJS for the Electron
// app: there is nothing here to run it.
package ocn

import "base:runtime"

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "gt:platform"
import "gt:ui"
import lucide "gt:lucide"
import remote "gt:remote"
import i18n "gt:i18n"

////////////////////////////////
// Schedules

Schedule_Status :: enum u8 { Unknown, Active, Paused, Done }   // (Unknown: a word of a newer server: it is neither paused nor resumed from here)

@(private = "file")
schedule_status :: proc(word: string) -> Schedule_Status {
	switch word {
	case "active": return .Active
	case "paused": return .Paused
	case "done":   return .Done
	}
	return .Unknown
}

Schedule :: struct {
	id, name, prompt, when_text, outcome: string,
	status:    Schedule_Status,
	next:      f64,
	remaining: int,
	runs:      int,
}

When_Mode :: enum u8 { In, Every, At, Cron }

// (`unit`: stays in the field beside what is typed; `hint`: an example, until something is.)
WHEN_MODES := [When_Mode]struct { label, key, hint, unit: string }{
	.In    = {i18n.later("In"), "in", "2 hours", i18n.later("from now")},
	.Every = {i18n.later("Every"), "every", "1 day", i18n.later("repeats")},
	.At    = {i18n.later("At"), "at", "2026-12-31T09:00:00", i18n.later("once")},
	.Cron  = {"Cron", "cron", "0 9 * * 1", i18n.later("repeats")},
}

Schedules :: struct {
	session:  string,   // (owned)
	read:     remote.Remote,   // the list
	making:   remote.Remote,   // a new one on its way: the form sends nothing else until it is answered, and says why it failed
	problem:  string,   // what the form lacks (owned)
	removing: string,   // the one asked about (owned)
	list:     [dynamic]Schedule,
	arena:    virtual.Arena,
	mode:     When_Mode,
	prompt, value: ui.Text_Field,
	fresh:    bool,     // just opened: the prompt takes the focus
}

@(private = "file")
set_text :: proc(s: ^string, value: string) {
	delete(s^)
	s^ = strings.clone(value)
}

@(private = "file")
schedules_clear :: proc(s: ^Schedules) {
	virtual.arena_destroy(&s.arena)
	clear(&s.list)
}

@(private = "file")
schedule_form_clear :: proc(s: ^Schedules) {
	ui.field_set(&s.prompt, ""); ui.field_set(&s.value, "")
	set_text(&s.problem, "")
}

// What was typed was for one session: it stays for that one alone. What the list said is read again: nothing of it shows until then.
schedules_open :: proc(app: ^App, id: string) {
	s := &app.cx.schedules
	if id != s.session {
		schedule_form_clear(s)
		remote.reset(&s.making)
	} else if s.making.state != .Loading {
		remote.reset(&s.making)
	}
	set_text(&s.session, id)
	set_text(&s.problem, ""); set_text(&s.removing, "")
	schedules_clear(s)
	remote.reset(&s.read)
	app.cx.open[.Schedules], s.fresh = true, true
	schedules_ask(app)
}

schedules_ask :: proc(app: ^App) {
	s := &app.cx.schedules
	remote.begin(&s.read)
	request(app, .Schedules, "GET", fmt.tprintf("/api/experimental/schedule?sessionID=%s", url_escape(s.session)), reading = &s.read)
}

schedules_forget :: proc(app: ^App) {
	s := &app.cx.schedules
	app.cx.open[.Schedules] = false
	set_text(&s.session, ""); set_text(&s.removing, "")
	schedule_form_clear(s)
	schedules_clear(s)
	remote.reset(&s.read)
	remote.reset(&s.making)
	app.cx.no_schedules = false   // (what the next server offers is for it to say: experimental_check)
}

// How the server's description reads.
when_text :: proc(w: json.Value) -> string {
	switch jstr(w, "type") {
	case "in":    return fmt.tprintf("once, in %s", jstr(w, "in"))
	case "at":    return fmt.tprintf("once, at %s", jstr(w, "at"))
	case "every": return fmt.tprintf("every %s", jstr(w, "every"))
	case "cron":  return fmt.tprintf("cron %s", jstr(w, "cron"))
	}
	return ""
}

schedules_load :: proc(app: ^App, v: json.Value) {
	s := &app.cx.schedules
	schedules_clear(s)
	_ = virtual.arena_init_growing(&s.arena)
	a := virtual.arena_allocator(&s.arena)
	for it in jarr(v, "data") {
		append(&s.list, Schedule{
			id = strings.clone(jstr(it, "id"), a), name = strings.clone(jstr(it, "name"), a), prompt = strings.clone(jstr(it, "action", "prompt"), a),
			when_text = strings.clone(when_text(jget(it, "when")), a), status = schedule_status(jstr(it, "status")), outcome = strings.clone(jstr(it, "lastOutcome"), a),
			next = jnum(it, "nextDueAt"), remaining = int(jnum(it, "remainingRuns")), runs = int(jnum(it, "runCount")),
		})
	}
}

schedule_changed :: proc(app: ^App) {
	if app.cx.open[.Schedules] { schedules_ask(app) }
}

// (Of the session the form is for: a later one of another session has reset `making`, and this answer was dropped.)
schedule_made :: proc(app: ^App) {
	schedule_form_clear(&app.cx.schedules)
	schedule_changed(app)
}

// What the form sends, once: a second Enter finds the first on its way.
schedule_submit :: proc(app: ^App) {
	s := &app.cx.schedules
	if s.making.state == .Loading { return }
	body, problem := schedule_body(s.session, ui.field_string(&s.prompt), "", ui.field_string(&s.value), s.mode)
	set_text(&s.problem, problem)
	if problem != "" { return }
	remote.begin(&s.making)
	request(app, .Schedule_Made, "POST", "/api/experimental/schedule", body, reading = &s.making)
}

// The body of a schedule; what is missing, if something is.
schedule_body :: proc(session, prompt, name, value: string, mode: When_Mode) -> (body, problem: string) {
	p, n, w := strings.trim_space(prompt), strings.trim_space(name), strings.trim_space(value)
	if p == "" { return "", i18n.tr("Say what to ask") }
	if w == "" { return "", i18n.tr("Say when") }
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"sessionID":%s,`, jquote(session))
	if n != "" { fmt.sbprintf(&b, `"name":%s,`, jquote(n)) }
	fmt.sbprintf(&b, `"when":{{"%s":%s}},"prompt":%s}}`, WHEN_MODES[mode].key, jquote(w), jquote(p))
	return strings.to_string(b), ""
}

// When the next one is, from `now`: minutes, hours or days are enough.
due_text :: proc(due, now: f64) -> string {
	m := int(math.ceil((due - now) / 60000))
	switch {
	case m <= 0:        return i18n.tr("due now")
	case m < 90:        return fmt.tprintf(i18n.tr("in %d min"), m)
	case m < 60 * 36:   return fmt.tprintf(i18n.tr("in %d h"), (m + 30) / 60)
	}
	return fmt.tprintf(i18n.tr((m + 720) / 1440, "in %d day", "in %d days"), (m + 720) / 1440)
}

// A field in its well. `label` and `unit` stay on either side of what is typed: a hint goes with the focus, and an empty box says nothing.
@(private = "file")
field_line :: proc(id: string, f: ^ui.Text_Field, hint: string, em: f32, label := "", unit := "") -> ui.Edit_Result {
	res: ui.Edit_Result
	ui.next({width = ui.fill(), height = ui.px(math.round(em * FIELD_H_EM)), axis = .X, cross = .Center})
	if ui.well(fmt.tprintf("%s_w", id), .X) {
		if label != "" {
			ui.spacer(ui.px(em * 0.6))
			text("l", label, hex(HEX_WEAK), ui.Style_Mod{font_size = math.round(em * FS_NOTE)})
		}
		if ui.tags("bare") {
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * (label != "" ? 0.35 : 0.5)})
			res = ui.line_edit(id, f, hint)
		}
		if unit != "" {
			text("u", unit, hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * FS_CAPTION)})
			ui.spacer(ui.px(em * 0.6))
		}
	}
	return res
}

// As tall as what it holds, as far as the window goes: past that what is planned scrolls, under the form, and nothing is cut at any
// size. (A small thing: no sizes to choose. Its place in layout.dialogs stays: they are read by position.)
schedules_dialog :: proc(app: ^App, em: f32) {
	s := &app.cx.schedules
	if !app.cx.open[.Schedules] { return }
	win := app.state.window_size
	margin := em * ui.MODAL_MARGIN_EM
	w := min(math.round(em * SCHEDULES_W_EM), win.x - 2 * margin)
	if ui.modal("schedules", w, &app.cx.open[.Schedules], SCHEDULES_TOP) {
		dialog_backdrop()
		if ui.dialog_header("sc_head", i18n.tr("Schedules of this session"), {close = true}) {
		}
		ui.spacer(ui.px(em * 0.4))
		// (what it held at the last build: this one is not laid out yet. The title and the gaps are what the window keeps.)
		held := em * SCHEDULES_FIRST_H_EM
		if b := ui.prev_box("###sc_body"); b != nil && b.view_bounds.y > 0 { held = b.view_bounds.y }
		room := win.y - 2 * margin - em * SCHEDULES_HEAD_EM
		ui.next({width = ui.fill(), height = ui.px(max(min(held, room), em * FIELD_H_EM))})
		if ui.scroll_y("###sc_body") {
			// (the margins inside what scrolls: on its edge a field's rim and glow were cut)
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(id = "###sc_lane") {
				ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
				if ui.column(id = "###sc_col") {
					if read_shown(app, "###sc_read", &s.read, em, schedules_ask) {
						schedule_form(app, w - 2 * em * DIALOG_MARGIN_EM, em)
						ui.spacer(ui.px(em * 0.8))
						if len(s.list) == 0 {
							info_line(app, "###sc_none", i18n.tr("Nothing is planned yet."), em)
						} else {
							section_label("sc_list", fmt.tprintf(i18n.tr("PLANNED (%d)"), len(s.list)), em)
						}
						now := f64(now_epoch_ms())
						for &it, i in s.list { schedule_row(app, &it, i, now, w, em) }
					}
				}
				ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
			}
		}
		ui.spacer(ui.px(em * 0.9))
	}
}

// What a schedule does next, at the end of its row.
@(private = "file")
schedule_next :: proc(it: ^Schedule, now: f64) -> string {
	switch it.status {
	case .Paused: return "paused"
	case .Done:   return "done"
	case .Active: if it.next > 0 { return due_text(it.next, now) }
	case .Unknown:
	}
	return ""
}

// When it wakes, how many are left, what it did so far.
schedule_detail :: proc(it: ^Schedule) -> string {
	detail := it.when_text
	if it.remaining > 0 { detail = fmt.tprintf(i18n.tr(it.remaining, "%s · %d left", "%s · %d left"), detail, it.remaining) }
	if it.runs > 0 { detail = it.outcome != "" ? fmt.tprintf(i18n.tr("%s · ran %d (%s)"), detail, it.runs, it.outcome) : fmt.tprintf(i18n.tr("%s · ran %d"), detail, it.runs) }
	return detail
}

@(private = "file")
schedule_row :: proc(app: ^App, it: ^Schedule, i: int, now: f64, w, em: f32) {
	s := &app.cx.schedules
	small := math.round(em * BUTTON_SMALL_H_EM)
	words := w >= em * SCHEDULES_WORDS_MIN_EM   // (narrow: the name needs the room more)
	ui.next({width = ui.fill(), height = ui.px(math.round(em * SCHEDULES_ROW_H_EM)), axis = .X, cross = .Center})
	if ui.row(.Center, id = fmt.tprintf("###scr%d", i)) {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column() {
			text("n", first_line(it.name != "" ? it.name : it.prompt), hex(it.status == .Done ? HEX_WEAK : HEX_TEXT), ui.Style_Mod{font_size = math.round(em * FS_LABEL), height = ui.px(em * 1.4)}, ui.fill())
			text("d", schedule_detail(it), hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_CAPTION), height = ui.px(em * 1.15)}, ui.fill())
		}
		ui.spacer(ui.px(em * 0.5))
		text("x", schedule_next(it, now), hex(it.status == .Active ? HEX_TEXT_SOFT : HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
		ui.spacer(ui.px(em * 0.6))
		if it.id == s.removing {
			if ui.button_icon("###sc_yes", lucide.TRASH_2, i18n.tr("Delete"), .Danger, height = small).clicked {
				request(app, .Schedule_Done, "DELETE", fmt.tprintf("/api/experimental/schedule/%s", url_escape(it.id)))
				set_text(&s.removing, "")
			}
			ui.spacer(ui.px(em * 0.3))
			if ui.button_icon("###sc_no", "", i18n.tr("Keep"), .Cancel, height = small).clicked { set_text(&s.removing, "") }
		} else {
			if it.status == .Active || it.status == .Paused {
				pause := it.status == .Active
				if ui.button_icon("###sc_pause", "", ui.text_shown(pause ? i18n.tr("Pause") : i18n.tr("Resume")), height = small).clicked {
					request(app, .Schedule_Done, "POST", fmt.tprintf("/api/experimental/schedule/%s/%s", url_escape(it.id), pause ? "pause" : "resume"), "{}")
				}
				ui.spacer(ui.px(em * 0.3))
			}
			ui.a11y({role = .Button, name = i18n.tr("Delete")})
			if ui.button_icon("###sc_del", lucide.TRASH_2, ui.text_shown(words ? i18n.tr("Delete") : ""), .Danger, height = small, face = .Ghost).clicked { set_text(&s.removing, it.id) }
		}
	}
}

// What to ask, then when, on one row, the mode beside its value and Plan it at the end. `w`: the room, this frame's. Too narrow for
// that, the modes take a row of their own.
@(private = "file")
schedule_form :: proc(app: ^App, w, em: f32) {
	s := &app.cx.schedules
	go := false
	res := field_line("###sc_prompt", &s.prompt, i18n.tr("what the session does when it wakes"), em, label = i18n.tr("Ask"))
	if s.fresh { ui.set_focus(res.box.key); s.fresh = false }
	if res.committed { go = true }
	ui.spacer(ui.px(em * 0.5))
	one_row := w >= em * SCHEDULES_ONE_ROW_EM
	modes :: proc(s: ^Schedules, width: ui.Size, em: f32) {
		labels: [len(When_Mode)]string
		for m in When_Mode { labels[m] = i18n.tr(WHEN_MODES[m].label) }
		sel := int(s.mode)
		ui.next({width = width, height = ui.px(math.round(em * FIELD_H_EM))})
		if choice("###sc_mode", labels[:], &sel) { s.mode = When_Mode(sel) }
	}
	if !one_row {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###sc_modes") { modes(s, ui.fill(), em) }
		ui.spacer(ui.px(em * 0.5))
	}
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###sc_when") {
		if one_row {
			modes(s, ui.px(math.round(em * SCHEDULES_MODES_W_EM)), em)
			ui.spacer(ui.px(em * 0.5))
		}
		if field_line("###sc_value", &s.value, WHEN_MODES[s.mode].hint, em, unit = i18n.tr(WHEN_MODES[s.mode].unit)).committed { go = true }
		ui.spacer(ui.px(em * 0.5))
		making := s.making.state == .Loading
		if ui.button_icon("###sc_go", lucide.CHECK, ui.text_shown(making ? i18n.tr("Planning…") : i18n.tr("Plan it")), .Success, height = math.round(em * FIELD_H_EM), disabled = making).clicked { go = true }
	}
	if s.problem != "" || remote.failed(&s.making) {
		ui.spacer(ui.px(em * 0.4))
		info_line(app, "###sc_failed", s.problem != "" ? s.problem : s.making.message, em, hex(HEX_RED))
	}
	if go { schedule_submit(app) }
}

////////////////////////////////
// Artifacts

Artifact :: struct { id, title, entry, url, provider: string }
Artifact_File :: struct { path, content: string }

Artifacts :: struct {
	dir:      string,   // the folder (owned)
	read:     remote.Remote,   // the list
	file_read: remote.Remote,  // the files of `shown`: they are its own, or there are none
	removing: string,   // (owned)
	shown:    string,   // the artifact read (owned)
	list:     [dynamic]Artifact,
	arena:    virtual.Arena,
	files:    [dynamic]Artifact_File,
	files_arena: virtual.Arena,
	file:     int,      // the one on screen
	version:  u64,
}

@(private = "file")
artifacts_clear :: proc(a: ^Artifacts) {
	virtual.arena_destroy(&a.arena)
	clear(&a.list)
	set_text(&a.removing, ""); set_text(&a.shown, "")
	artifact_files_clear(a)
	remote.reset(&a.read)
	remote.reset(&a.file_read)
}

artifacts_open :: proc(app: ^App) {
	a := &app.cx.artifacts
	artifacts_clear(a)
	d := chat_dir(app)
	set_text(&a.dir, d != "" ? d : app.chat.new_dir)
	app.cx.open[.Artifacts] = true
	artifacts_ask(app)
}

artifacts_ask :: proc(app: ^App) {
	a := &app.cx.artifacts
	q := location_query(a.dir)
	remote.begin(&a.read)
	request(app, .Artifacts, "GET", fmt.tprintf("/api/experimental/artifacts%s%s", q != "" ? "?" : "", q), reading = &a.read)
}

artifacts_forget :: proc(app: ^App) {
	a := &app.cx.artifacts
	app.cx.open[.Artifacts] = false
	artifacts_clear(a)
	set_text(&a.dir, "")
	app.cx.no_artifacts = false   // (what the next server offers is for it to say: experimental_check)
}

artifacts_load :: proc(app: ^App, v: json.Value) {
	a := &app.cx.artifacts
	al := arena_renew(&a.arena)
	clear(&a.list)
	for it in jarr(v, "data") {
		append(&a.list, Artifact{strings.clone(jstr(it, "id"), al), strings.clone(jstr(it, "title"), al), strings.clone(jstr(it, "entry"), al), strings.clone(jstr(it, "url"), al), strings.clone(jstr(it, "provider"), al)})
	}
}

// A row chosen: what was on the right goes with it, so that the head and the files never say two artifacts.
artifact_show :: proc(app: ^App, id: string) {
	a := &app.cx.artifacts
	set_text(&a.shown, id)
	set_text(&a.removing, "")
	artifact_files_clear(a)
	remote.reset(&a.file_read)
	artifact_read(app)
}

@(private = "file")
artifact_read :: proc(app: ^App) {
	a := &app.cx.artifacts
	q := location_query(a.dir)
	remote.begin(&a.file_read)
	request(app, .Artifact_Read, "GET", fmt.tprintf("/api/experimental/artifacts/%s%s%s", url_escape(a.shown), q != "" ? "?" : "", q), reading = &a.file_read)
}

artifacts_changed :: proc(app: ^App) {
	if app.cx.open[.Artifacts] { artifacts_ask(app) }
	chat_artifacts_ask(app)
}

// The artifacts of the session shown, as cards in its conversation after the message they were made in (an agent makes
// one through a tool, or inside the code of `execute`: the conversation said nothing of it).
Chat_Artifact :: struct { id, title: string, created: f64 }

Chat_Artifacts :: struct {
	of:    string,   // the session they are of (owned)
	list:  [dynamic]Chat_Artifact,
	arena: virtual.Arena,
}

chat_artifacts_ask :: proc(app: ^App) {
	if app.chat.id == "" || app.cx.no_artifacts { return }
	q := location_query(chat_dir(app))
	request(app, .Chat_Artifacts, "GET", fmt.tprintf("/api/experimental/artifacts%s%s", q != "" ? "?" : "", q), tag = app.chat.id)
}

// (`of`: the session asked about; another one shown since, the answer is not its)
chat_artifacts_load :: proc(app: ^App, of: string, v: json.Value) {
	if of != app.chat.id { return }
	c := &app.cx.chat_arts
	al := arena_renew(&c.arena)
	clear(&c.list)
	c.of = strings.clone(of, al)
	for it in jarr(v, "data") {
		if jstr(it, "sessionID") != of { continue }
		append(&c.list, Chat_Artifact{strings.clone(jstr(it, "id"), al), strings.clone(jstr(it, "title"), al), jnum(it, "time", "created")})
	}
}

// The artifacts made from `from` (ms) up to `to` (excluded) of the session shown.
chat_artifacts_between :: proc(app: ^App, from, to: f64) -> []Chat_Artifact {
	c := &app.cx.chat_arts
	if c.of != app.chat.id { return nil }
	out := make([dynamic]Chat_Artifact, context.temp_allocator)
	for a in c.list { if a.created >= from && a.created < to { append(&out, a) } }
	return out[:]
}

// An artifact's card: what it is, its name; a click shows it (the artifacts of the folder, it chosen).
artifact_card :: proc(app: ^App, a: Chat_Artifact, em: f32) {
	ui.spacer(ui.px(em * 0.5))
	ui.next({width = ui.fill(), height = ui.children_sum(), cursor = .Hand})
	if ui.well(fmt.tprintf("###art_%s", a.id), flags = {.Clickable}) {
		card := ui.parent_box()
		ui.a11y({role = .Button, name = fmt.tprintf(i18n.tr("Artifact %s: show it"), a.title)})
		show := ui.signal(card).clicked
		ui.next({width = ui.fill(), height = ui.px(math.round(em * ARTIFACT_CARD_H_EM)), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###line") {
			ui.spacer(ui.px(em * 0.8))
			glyph(lucide.APP_WINDOW, accent(), math.round(em * ICON_REGULAR), em * 1.4)
			ui.spacer(ui.px(em * 0.5))
			text("k", i18n.tr("Artifact"), hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_SMALL)})
			ui.spacer(ui.px(em * 0.6))
			text("n", ellipsize(a.title != "" ? a.title : a.id, ARTIFACT_TITLE_CHARS), hex(HEX_BRIGHT), ui.Style_Mod{font_size = math.round(em * FS_LABEL)}, ui.fill())
			if ui.button_icon("###show", lucide.EYE, i18n.tr("Show"), height = math.round(em * BUTTON_SMALL_H_EM)).clicked { show = true }
			ui.spacer(ui.px(em * 0.6))
		}
		if show {
			artifacts_open(app)
			artifact_show(app, a.id)
		}
	}
}

ARTIFACT_CARD_H_EM :: 2.6
ARTIFACT_TITLE_CHARS :: 90

@(private = "file")
artifact_files_clear :: proc(a: ^Artifacts) {
	virtual.arena_destroy(&a.files_arena)
	clear(&a.files)
	a.file = 0
}

// A file of an artifact, named by an agent, goes under its folder and nowhere else.
artifact_path_safe :: proc(p: string) -> bool {
	if p == "" || p[0] == '/' || p[0] == '\\' || strings.contains_rune(p, ':') { return false }
	rest, _ := strings.replace_all(p, `\`, "/", context.temp_allocator)
	for part in strings.split_iterator(&rest, "/") { if part == ".." { return false } }
	return true
}

// (`entry` first: it is what the artifact is.)
artifact_loaded :: proc(app: ^App, v: json.Value) {
	a := &app.cx.artifacts
	artifact_files_clear(a)
	_ = virtual.arena_init_growing(&a.files_arena)
	al := virtual.arena_allocator(&a.files_arena)
	files, _ := jget(v, "data", "files").(json.Object)
	entry := jstr(v, "data", "info", "entry")
	for path, value in files {
		content, is_text := value.(json.String)
		if !is_text { continue }
		append(&a.files, Artifact_File{strings.clone(path, al), strings.clone(string(content), al)})
		if path == entry {
			last := len(a.files) - 1
			a.files[0], a.files[last] = a.files[last], a.files[0]
		}
	}
	a.version += 1
}

@(private = "file")
artifact_online :: proc(it: ^Artifact) -> bool { return strings.has_prefix(it.url, "http://") || strings.has_prefix(it.url, "https://") }

// Whether Open in the browser has something to open: an address, or this artifact's own files.
artifact_can_open :: proc(a: ^Artifacts, it: ^Artifact) -> bool {
	return artifact_online(it) || (it.id == a.shown && a.file_read.state == .Ready && len(a.files) > 0)
}

// What the server serves itself asks its password, which has no place in an address: the files go in a folder of ours, and that opens.
@(private = "file")
artifact_view :: proc(a: ^Artifacts, it: ^Artifact) {
	if artifact_online(it) { ui.open(it.url, .Url); return }
	if !artifact_can_open(a, it) { return }
	// (the files are written, then opened, by a task: the disk is not the interface's)
	h := runtime.heap_allocator()
	job := new(Artifact_Write, h)
	job.id, job.entry = strings.clone(it.id, h), strings.clone(it.entry, h)
	job.files = make([]Artifact_File, len(a.files), h)
	job.left_out = make([dynamic]string, h)   // (filled on the task's thread, freed on this one)
	for f, i in a.files { job.files[i] = {strings.clone(f.path, h), strings.clone(f.content, h)} }
	ui.task(&the_app.state, artifact_write_work, artifact_write_done, job, artifact_write_free)
}

@(private = "file")
Artifact_Write :: struct { id, entry: string, files: []Artifact_File, left_out: [dynamic]string, failed, no_temp: bool }

@(private = "file")
artifact_write_work :: proc(data: rawptr) {
	job := (^Artifact_Write)(data)
	temp, no_temp := os.temp_directory(context.temp_allocator)
	if no_temp != nil { job.no_temp = true; return }
	root, _ := filepath.join({temp, "opencode-artifacts", file_safe(job.id)}, context.temp_allocator)
	entry := ""
	for f in job.files {
		if !artifact_path_safe(f.path) { append(&job.left_out, f.path); continue }
		path, _ := filepath.join({root, f.path}, context.temp_allocator)
		_ = os.make_directory_all(filepath.dir(path))
		if os.write_entire_file(path, transmute([]u8)f.content) != nil { job.failed = true; return }
		if f.path == job.entry || entry == "" { entry = path }
	}
	if entry != "" { _ = platform.open_path(entry) }
}

@(private = "file")
artifact_write_done :: proc(data: rawptr, _: u64) {
	job := (^Artifact_Write)(data)
	for p in job.left_out { ui.toast(.Warn, i18n.tr("%s was left out: it points outside its folder"), p) }
	if job.no_temp { ui.toast(.Bad, i18n.tr("No temporary folder")) }
	if job.failed { ui.toast(.Bad, i18n.tr("The file could not be written")) }
	artifact_write_free(job)
}

@(private = "file")
artifact_write_free :: proc(data: rawptr) {
	job := (^Artifact_Write)(data)
	h := runtime.heap_allocator()
	for f in job.files { delete(f.path, h); delete(f.content, h) }
	delete(job.files, h)
	delete(job.left_out)
	delete(job.id, h); delete(job.entry, h)
	free(job, h)
}

artifacts_dialog :: proc(app: ^App, em: f32) {
	a := &app.cx.artifacts
	if !app.cx.open[.Artifacts] { return }
	if ui.modal_sized("artifacts", DIALOG_PREFERRED_EM[.Artifacts] * em, &app.cx.dialogs[.Artifacts], &app.cx.open[.Artifacts], DIALOG_MIN_EM[.Artifacts] * em) {
		dialog_backdrop()
		if ui.dialog_header("ar_head", i18n.tr("Artifacts of this folder"), {close = true}) {
		}
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
		if ui.row(id = "###ar_body") {
			ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
			// (a share of the room: at its full width in a small dialog, it left the right side less than its buttons take)
			ui.next({width = ui.px(math.round(min(em * FILES_LIST_W_EM, ui.parent_box().size.x * ARTIFACTS_LIST_SHARE))), height = ui.fill()})
			if ui.scroll_y("###ar_list") {
				if read_shown(app, "###ar_read", &a.read, em, artifacts_ask) {
					if len(a.list) == 0 { info_line(app, "###ar_none", i18n.tr("No artifact here: an agent publishes them."), em) }
					for &it, i in a.list {
						ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.8)), axis = .X, cross = .Center, cursor = .Hand})
						row := ui.build_box({.Clickable}, fmt.tprintf("###arr%d", i))
						if ui.signal(row).clicked { artifact_show(app, it.id) }
						if ui.parent(row) {
							glyph(lucide.FILE, hex(it.id == a.shown ? HEX_BRIGHT : HEX_FAINT), math.round(em * ICON_SMALL), em * 1.1)
							ui.spacer(ui.px(em * 0.3))
							text("n", it.title, hex(it.id == a.shown ? HEX_BRIGHT : HEX_TEXT), ui.Style_Mod{font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.6)}, ui.fill())
						}
					}
				}
			}
			ui.spacer(ui.px(em))
			ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
			if ui.column(id = "###ar_right") { artifact_right(app, em) }
			ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
		}
		ui.spacer(ui.px(em * 0.9))
	}
}

@(private = "file")
artifact_right :: proc(app: ^App, em: f32) {
	a := &app.cx.artifacts
	it: ^Artifact
	for &x in a.list { if x.id == a.shown { it = &x } }
	if it == nil { return }
	small := math.round(em * BUTTON_COMPACT_H_EM)
	words := ui.parent_box().size.x >= em * ARTIFACTS_WORDS_MIN_EM   // (narrow: the buttons by their glyphs, or the last is cut)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###ar_bar") {
		text("p", it.provider, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_CAPTION), height = ui.px(em * 1.6)}, ui.fill())
		if it.id == a.removing {
			if ui.button_icon("###ar_yes", lucide.TRASH_2, i18n.tr("Delete"), .Danger, height = small).clicked {
				q := location_query(a.dir)
				request(app, .Artifact_Done, "DELETE", fmt.tprintf("/api/experimental/artifacts/%s%s%s", url_escape(it.id), q != "" ? "?" : "", q))
				set_text(&a.removing, ""); set_text(&a.shown, "")
				artifact_files_clear(a)
				remote.reset(&a.file_read)
				return
			}
			ui.spacer(ui.px(em * 0.3))
			if ui.button_icon("###ar_no", "", i18n.tr("Keep"), .Cancel, height = small).clicked { set_text(&a.removing, "") }
		} else {
			ui.a11y({role = .Button, name = i18n.tr("Open in the browser")})
			if ui.button_icon("###ar_open", lucide.GLOBE, ui.text_shown(words ? i18n.tr("Open in the browser") : ""), .Primary, height = small, disabled = !artifact_can_open(a, it)).clicked { artifact_view(a, it) }
			ui.spacer(ui.px(em * 0.3))
			ui.a11y({role = .Button, name = i18n.tr("Delete")})
			if ui.button_icon("###ar_del", lucide.TRASH_2, ui.text_shown(words ? i18n.tr("Delete") : ""), .Danger, height = small, face = .Ghost).clicked { set_text(&a.removing, it.id) }
		}
	}
	ui.spacer(ui.px(em * 0.4))
	if !read_shown(app, "###ar_file", &a.file_read, em, artifact_read) { return }
	if len(a.files) == 0 { info_line(app, "###ar_empty", i18n.tr("No text in this artifact."), em); return }
	if len(a.files) > 1 {
		// (they wrap: on one row the last ones went past the edge)
		ui.next({width = ui.fill(), height = ui.children_sum(), gap = {em * 0.3, em * 0.3}})
		if ui.flow({em * 0.3, em * 0.3}, "###ar_files") {
			for f, i in a.files {
				if ui.button_icon(fmt.tprintf("###arf%d", i), "", ui.text_shown(label_safe(f.path)), height = small, face = a.file == i ? .Toggled : .Raised).clicked { a.file = i; a.version += 1 }
			}
		}
		ui.spacer(ui.px(em * 0.4))
	}
	f := a.files[clamp(a.file, 0, len(a.files) - 1)]
	shown, is_text := file_text(f.content)
	if !is_text { info_line(app, "###ar_bin", i18n.tr("Not text."), em); return }
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###ar_view") { code_block("###ar_code", strings.trim_prefix(filepath.ext(f.path), "."), shown, app.mono, version = a.version) }
}

////////////////////////////////
// Plugins

Plugin :: struct {
	id, kind, target, version, error: string,
	outdated, updating, failed: bool,
	features: string,
}

Plugins :: struct {
	read:     remote.Remote,   // the list
	check:    remote.Remote,   // Check for updates, on its way
	builtin:  bool,
	list:     [dynamic]Plugin,
	arena:    virtual.Arena,
}

plugins_ask :: proc(app: ^App) {
	p := &app.cx.plugins
	remote.begin(&p.read)
	request(app, .Plugins, "GET", "/api/plugin", reading = &p.read)
}

plugins_forget :: proc(app: ^App) {
	p := &app.cx.plugins
	virtual.arena_destroy(&p.arena)
	clear(&p.list)
	remote.reset(&p.read)
	remote.reset(&p.check)
}

// Those one chose first: what is built in is the server's own.
plugins_load :: proc(app: ^App, v: json.Value) {
	p := &app.cx.plugins
	a := arena_renew(&p.arena)
	clear(&p.list)
	for pass in 0 ..< 2 {
		for it in jarr(v, "data") {
			kind := jstr(it, "source", "type")
			if (kind == "builtin") != (pass == 1) { continue }
			target := jstr(it, "source", "target")
			if target == "" { target = jstr(it, "source", "path") }
			features := strings.builder_make(context.temp_allocator)
			f := jget(it, "features")
			for name in ([]string{"server", "tui", "rpc", "gui"}) {
				if !jbool(f, name) { continue }
				if strings.builder_len(features) > 0 { strings.write_string(&features, ", ") }
				strings.write_string(&features, name)
			}
			src := jget(it, "source")
			append(&p.list, Plugin{
				id = strings.clone(jstr(it, "id"), a), kind = strings.clone(kind, a), target = strings.clone(target, a), version = strings.clone(jstr(it, "source", "version"), a),
				error = strings.clone(jstr(it, "state", "error"), a), outdated = jbool(src, "outdated"), updating = jbool(src, "updating"),
				failed = jstr(it, "state", "status") == "failed", features = strings.clone(strings.to_string(features), a),
			})
		}
	}
}

// The check says the list as it stands now: a reading on its way, asked before it, would say the older one.
plugins_checked :: proc(app: ^App, v: json.Value) {
	plugins_load(app, v)
	if app.cx.plugins.read.state == .Loading { plugins_ask(app) }
}

// Read again if it was read at all.
plugins_changed :: proc(app: ^App) {
	if app.cx.plugins.read.state != .Idle { plugins_ask(app) }
}

page_plugins :: proc(app: ^App, em: f32) {
	p := &app.cx.plugins
	if p.read.state == .Idle { plugins_ask(app) }
	if !read_shown(app, "###pl_read", &p.read, em, plugins_ask) { return }
	built := 0
	for it in p.list { if it.kind == "builtin" { built += 1 } }
	section(app, fmt.tprintf(i18n.tr("INSTALLED (%d)"), len(p.list) - built), em)
	if len(p.list) == built { info_line(app, "###pl_none", i18n.tr("No plugin but those of the server."), em) }
	for &it, i in p.list {
		if it.kind == "builtin" { continue }
		plugin_row(app, &it, i, em)
	}
	ui.spacer(ui.px(em * 0.5))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###pl_bar") {
		small := math.round(em * BUTTON_COMPACT_H_EM)
		checking := p.check.state == .Loading
		if ui.button_icon("###pl_check", lucide.REFRESH_CW, ui.text_shown(checking ? i18n.tr("Checking…") : i18n.tr("Check for updates")), height = small, disabled = checking).clicked {
			remote.begin(&p.check)
			request(app, .Plugins_Check, "POST", "/api/plugin/check", "{}", reading = &p.check)
		}
		ui.spacer(ui.px(em * 0.4))
		if ui.button_icon("###pl_built", "", ui.text_shown(fmt.tprintf(p.builtin ? i18n.tr("Hide the %d built in") : i18n.tr("Show the %d built in"), built)), height = small, face = .Ghost).clicked { p.builtin = !p.builtin }
	}
	if !p.builtin { return }
	ui.spacer(ui.px(em * 0.5))
	for &it, i in p.list {
		if it.kind == "builtin" { plugin_row(app, &it, i, em) }
	}
}

@(private = "file")
plugin_row :: proc(app: ^App, it: ^Plugin, i: int, em: f32) {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = fmt.tprintf("###plr%d", i)) {
		color: u32 = it.failed ? HEX_RED : it.outdated ? HEX_YELLOW : HEX_FAINT
		glyph(it.failed ? lucide.ALERT_TRIANGLE : lucide.PLUG, hex(color), math.round(em * ICON_SMALL), em * 1.2)
		ui.spacer(ui.px(em * 0.3))
		name := it.id != "" ? it.id : it.target != "" ? it.target : it.kind
		text("n", name, hex(HEX_TEXT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.6)}, ui.fill())
		detail := it.features
		if it.version != "" { detail = fmt.tprintf("%s  %s", it.version, detail) }
		text("d", detail, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_CAPTION), height = ui.px(em * 1.6)})
		if it.outdated && it.target != "" {
			ui.spacer(ui.px(em * 0.4))
			if ui.button_icon("###pl_up", "", ui.text_shown(it.updating ? i18n.tr("Updating…") : i18n.tr("Update")), .Success, height = math.round(em * BUTTON_SMALL_H_EM), disabled = it.updating).clicked {
				request(app, .Plugin_Update, "POST", "/api/plugin/update", fmt.tprintf(`{{"targets":[%s]}}`, jquote(it.target)))
				it.updating = true
			}
		}
	}
	if it.failed { info_line(app, fmt.tprintf("###ple%d", i), it.error, em, hex(HEX_RED)) }
	ui.spacer(ui.px(em * 0.15))
}

////////////////////////////////
// What the answers to its requests do (net.odin REQ_FACTS)

schedules_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { schedules_load(app, v) }

schedule_made_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { schedule_made(app) }

// ("Invalid duration": under the form, with what was typed)
schedule_made_on_fail :: proc(app: ^App, r: ^Request, f: Failure, message: string) -> (told: bool) { return app.cx.open[.Schedules] }

schedule_done_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { schedule_changed(app) }

artifacts_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { artifacts_load(app, v) }

artifact_read_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { artifact_loaded(app, v) }

chat_artifacts_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { chat_artifacts_load(app, r.tag, v) }

artifact_done_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { artifacts_changed(app) }

plugins_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { plugins_load(app, v) }

plugins_check_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { plugins_checked(app, v) }

plugin_update_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { plugins_changed(app) }

plugin_update_on_fail :: proc(app: ^App, r: ^Request, f: Failure, message: string) -> (told: bool) {
	plugins_changed(app)
	return false
}
