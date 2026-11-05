// What happens without anyone at the keyboard, and what the server keeps beside the sessions: a session's schedules (a prompt that wakes it
// later), the artifacts of a folder (pages an agent published) and the plugins. Schedules and artifacts are experimental on the server,
// off unless its configuration turns them on: the dialogs say what it answers then. A plugin's GUI bundle is CommonJS for the Electron
// app: there is nothing here to run it.
package occ

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "gt:platform"
import "gt:ui"

////////////////////////////////
// Schedules

Schedule :: struct {
	id, name, prompt, when_text, status, outcome: string,
	next:      f64,
	remaining: int,
	runs:      int,
}

When_Mode :: enum u8 { In, Every, At, Cron }

WHEN_MODES := [When_Mode]struct { label, key, hint: string }{
	.In    = {"Once, in", "in", "2 hours"},
	.Every = {"Every", "every", "1 day"},
	.At    = {"Once, at", "at", "2026-12-31T09:00:00"},
	.Cron  = {"Cron", "cron", "0 9 * * 1"},
}

Schedules :: struct {
	open:     bool,
	loading:  bool,
	session:  string,   // (owned)
	refused:  string,   // why there are none: the server's words (owned)
	failed:   string,   // why the last one was not made (owned)
	removing: string,   // the one asked about (owned)
	list:     [dynamic]Schedule,
	arena:    virtual.Arena,
	has_arena: bool,
	mode:     When_Mode,
	prompt, name, value: ui.Text_Field,
}

@(private = "file")
set_text :: proc(s: ^string, value: string) {
	delete(s^)
	s^ = strings.clone(value)
}

schedules_open :: proc(app: ^App, id: string) {
	s := &app.cx.schedules
	set_text(&s.session, id)
	set_text(&s.refused, ""); set_text(&s.failed, ""); set_text(&s.removing, "")
	s.open, s.loading = true, true
	schedules_ask(app)
}

@(private = "file")
schedules_ask :: proc(app: ^App) {
	s := &app.cx.schedules
	request(app, .Schedules, "GET", fmt.tprintf("/api/experimental/schedule?sessionID=%s", url_escape(s.session)), tag = s.session)
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

schedules_load :: proc(app: ^App, id: string, v: json.Value) {
	s := &app.cx.schedules
	if id != s.session { return }
	s.loading = false
	set_text(&s.refused, "")
	if s.has_arena { virtual.arena_destroy(&s.arena) }
	_ = virtual.arena_init_growing(&s.arena)
	s.has_arena = true
	a := virtual.arena_allocator(&s.arena)
	clear(&s.list)
	for it in jarr(v, "data") {
		append(&s.list, Schedule{
			id = strings.clone(jstr(it, "id"), a), name = strings.clone(jstr(it, "name"), a), prompt = strings.clone(jstr(it, "action", "prompt"), a),
			when_text = strings.clone(when_text(jget(it, "when")), a), status = strings.clone(jstr(it, "status"), a), outcome = strings.clone(jstr(it, "lastOutcome"), a),
			next = jnum(it, "nextDueAt"), remaining = int(jnum(it, "remainingRuns")), runs = int(jnum(it, "runCount")),
		})
	}
}

// The list was refused: the option is off.
schedules_refused :: proc(app: ^App, id, message: string) {
	s := &app.cx.schedules
	if id != s.session { return }
	s.loading = false
	set_text(&s.refused, message)
}

schedule_failed :: proc(app: ^App, message: string) {
	set_text(&app.cx.schedules.failed, message)
}

schedule_changed :: proc(app: ^App) {
	s := &app.cx.schedules
	if s.open { schedules_ask(app) }
}

schedule_made :: proc(app: ^App) {
	s := &app.cx.schedules
	ui.field_set(&s.prompt, ""); ui.field_set(&s.name, ""); ui.field_set(&s.value, "")
	set_text(&s.failed, "")
	schedule_changed(app)
}

// The body of a schedule; what is missing, if something is.
schedule_body :: proc(session, prompt, name, value: string, mode: When_Mode) -> (body, problem: string) {
	p, n, w := strings.trim_space(prompt), strings.trim_space(name), strings.trim_space(value)
	if p == "" { return "", "Say what to ask" }
	if w == "" { return "", "Say when" }
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
	case m <= 0:        return "due now"
	case m < 90:        return fmt.tprintf("in %d min", m)
	case m < 60 * 36:   return fmt.tprintf("in %d h", (m + 30) / 60)
	}
	return fmt.tprintf("in %d days", (m + 720) / 1440)
}

@(private = "file")
field_line :: proc(id: string, f: ^ui.Text_Field, hint: string, em: f32) -> ui.Edit_Result {
	res: ui.Edit_Result
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 2)), axis = .X, cross = .Center})
	if well(fmt.tprintf("%s_w", id), .X, radius = 6) {
		ui.spacer(ui.px(em * 0.5))
		if ui.tags("bare") {
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.3})
			res = ui.line_edit(id, f, hint)
		}
		ui.spacer(ui.px(em * 0.5))
	}
	return res
}

schedules_dialog :: proc(app: ^App, em: f32) {
	s := &app.cx.schedules
	if !s.open { return }
	if ui.modal_sized("schedules", DIALOG_PREFERRED_EM[.Schedules] * em, &app.cx.dialogs[.Schedules], &s.open, DIALOG_MIN_EM[.Schedules] * em) {
		dialog_backdrop()
		ui.spacer(ui.px(em * 0.9))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###sc_head") {
			ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
			text("t", "Schedules of this session", hex(HEX_BRIGHT), ui.Style_Mod{font_size = math.round(em * FS_TITLE), height = ui.px(em * 2)}, ui.fill())
			ui.spacer(ui.px(em * 3))
		}
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
		if ui.row(id = "###sc_body") {
			ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.scroll_y("###sc_list") {
				switch {
				case s.loading:       info_line(app, "###sc_load", "Reading…", em)
				case s.refused != "": info_line(app, "###sc_off", s.refused, em, hex(HEX_YELLOW))
				case:
					if len(s.list) == 0 { info_line(app, "###sc_none", "Nothing is planned: a prompt below will wake this session.", em) }
					now := f64(now_epoch_ms())
					for &it, i in s.list { schedule_row(app, &it, i, now, em) }
					ui.spacer(ui.px(em * 0.7))
					schedule_form(app, em)
				}
			}
			ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
		}
		ui.spacer(ui.px(em * 0.9))
		dialog_close(&s.open)
	}
}

@(private = "file")
schedule_row :: proc(app: ^App, it: ^Schedule, i: int, now: f64, em: f32) {
	s := &app.cx.schedules
	small := math.round(em * BUTTON_SMALL_H_EM)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = fmt.tprintf("###scr%d", i)) {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column() {
			text("n", first_line(it.name != "" ? it.name : it.prompt), hex(HEX_TEXT), ui.Style_Mod{font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.6)}, ui.fill())
			detail := it.when_text
			if it.status == "paused" { detail = fmt.tprintf("%s, paused", detail) }
			if it.status == "done" { detail = fmt.tprintf("%s, done", detail) }
			if it.status == "active" && it.next > 0 { detail = fmt.tprintf("%s, %s", detail, due_text(it.next, now)) }
			if it.remaining > 0 { detail = fmt.tprintf("%s, %d left", detail, it.remaining) }
			if it.runs > 0 { detail = fmt.tprintf("%s, ran %d (%s)", detail, it.runs, it.outcome) }
			text("d", detail, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_CAPTION), height = ui.px(em * 1.4)}, ui.fill())
		}
		if it.id == s.removing {
			if bevel_button("###sc_yes", "Delete", ICO_DELETE, .Danger, height = small).clicked {
				request(app, .Schedule_Done, "DELETE", fmt.tprintf("/api/experimental/schedule/%s", url_escape(it.id)))
				set_text(&s.removing, "")
			}
			ui.spacer(ui.px(em * 0.3))
			if bevel_button("###sc_no", "Keep", "", .Normal, height = small).clicked { set_text(&s.removing, "") }
		} else {
			if it.status != "done" {
				pause := it.status == "active"
				if bevel_button("###sc_pause", pause ? "Pause" : "Resume", "", .Normal, height = small).clicked {
					request(app, .Schedule_Done, "POST", fmt.tprintf("/api/experimental/schedule/%s/%s", url_escape(it.id), pause ? "pause" : "resume"), "{}")
				}
				ui.spacer(ui.px(em * 0.3))
			}
			if bevel_button("###sc_del", "Delete", ICO_DELETE, .Ghost, height = small).clicked { set_text(&s.removing, it.id) }
		}
	}
	ui.spacer(ui.px(em * 0.35))
}

@(private = "file")
schedule_form :: proc(app: ^App, em: f32) {
	s := &app.cx.schedules
	section("A NEW ONE", em)
	go := false
	if field_line("###sc_prompt", &s.prompt, "What to ask the session", em).committed { go = true }
	ui.spacer(ui.px(em * 0.35))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###sc_modes") {
		for m in When_Mode {
			if bevel_button(fmt.tprintf("###sc_m%d", int(m)), WHEN_MODES[m].label, "", s.mode == m ? .Toggled : .Normal, height = math.round(em * BUTTON_COMPACT_H_EM)).clicked { s.mode = m }
			ui.spacer(ui.px(em * 0.3))
		}
	}
	ui.spacer(ui.px(em * 0.35))
	if field_line("###sc_value", &s.value, WHEN_MODES[s.mode].hint, em).committed { go = true }
	ui.spacer(ui.px(em * 0.35))
	if field_line("###sc_name", &s.name, "A name for it (optional)", em).committed { go = true }
	ui.spacer(ui.px(em * 0.4))
	if s.failed != "" {
		info_line(app, "###sc_failed", s.failed, em, hex(HEX_RED))
		ui.spacer(ui.px(em * 0.3))
	}
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###sc_foot") {
		ui.spacer(ui.fill())
		if bevel_button("###sc_go", "Plan it", ICO_CHECK, .Accent).clicked { go = true }
	}
	if go {
		body, problem := schedule_body(s.session, ui.field_string(&s.prompt), ui.field_string(&s.name), ui.field_string(&s.value), s.mode)
		if problem != "" { set_text(&s.failed, problem); return }
		request(app, .Schedule_Made, "POST", "/api/experimental/schedule", body)
	}
}

////////////////////////////////
// Artifacts

Artifact :: struct { id, title, entry, url, provider: string }
Artifact_File :: struct { path, content: string }

Artifacts :: struct {
	open:     bool,
	loading:  bool,
	dir:      string,   // the folder (owned)
	refused:  string,   // (owned)
	removing: string,   // (owned)
	shown:    string,   // the artifact read (owned)
	list:     [dynamic]Artifact,
	arena:    virtual.Arena,
	has_arena: bool,
	files:    [dynamic]Artifact_File,
	files_arena: virtual.Arena,
	has_files: bool,
	file:     int,      // the one on screen
	version:  u64,
}

@(private = "file")
artifact_location :: proc(a: ^Artifacts) -> string {
	return a.dir != "" ? fmt.tprintf("location[directory]=%s", url_escape(a.dir)) : ""
}

artifacts_open :: proc(app: ^App) {
	a := &app.cx.artifacts
	d := chat_dir(app)
	set_text(&a.dir, d != "" ? d : app.chat.new_dir)
	set_text(&a.refused, ""); set_text(&a.removing, ""); set_text(&a.shown, "")
	artifact_files_clear(a)
	a.open, a.loading = true, true
	artifacts_ask(app)
}

@(private = "file")
artifacts_ask :: proc(app: ^App) {
	a := &app.cx.artifacts
	q := artifact_location(a)
	request(app, .Artifacts, "GET", fmt.tprintf("/api/experimental/artifacts%s%s", q != "" ? "?" : "", q))
}

artifacts_load :: proc(app: ^App, v: json.Value) {
	a := &app.cx.artifacts
	a.loading = false
	set_text(&a.refused, "")
	if a.has_arena { virtual.arena_destroy(&a.arena) }
	_ = virtual.arena_init_growing(&a.arena)
	a.has_arena = true
	al := virtual.arena_allocator(&a.arena)
	clear(&a.list)
	for it in jarr(v, "data") {
		append(&a.list, Artifact{strings.clone(jstr(it, "id"), al), strings.clone(jstr(it, "title"), al), strings.clone(jstr(it, "entry"), al), strings.clone(jstr(it, "url"), al), strings.clone(jstr(it, "provider"), al)})
	}
}

artifacts_refused :: proc(app: ^App, message: string) {
	a := &app.cx.artifacts
	a.loading = false
	set_text(&a.refused, message)
}

artifacts_changed :: proc(app: ^App) {
	a := &app.cx.artifacts
	if a.open { artifacts_ask(app) }
}

@(private = "file")
artifact_files_clear :: proc(a: ^Artifacts) {
	if a.has_files { virtual.arena_destroy(&a.files_arena) }
	a.has_files = false
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
artifact_loaded :: proc(app: ^App, id: string, v: json.Value) {
	a := &app.cx.artifacts
	if id != a.shown { return }
	artifact_files_clear(a)
	_ = virtual.arena_init_growing(&a.files_arena)
	a.has_files = true
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

// What the server serves itself asks its password, which has no place in an address: the files go in a folder of ours, and that opens.
@(private = "file")
artifact_view :: proc(a: ^Artifacts, it: ^Artifact) {
	if strings.has_prefix(it.url, "http://") || strings.has_prefix(it.url, "https://") { _ = platform.open_url(it.url); return }
	if it.id != a.shown || len(a.files) == 0 { return }
	context.allocator = context.temp_allocator
	temp, no_temp := os.temp_directory(context.temp_allocator)
	if no_temp != nil { ui.toast(.Bad, "No temporary folder"); return }
	root, _ := filepath.join({temp, "opencode-artifacts", file_safe(it.id)}, context.temp_allocator)
	entry := ""
	for f in a.files {
		if !artifact_path_safe(f.path) { ui.toast(.Warn, "%s was left out: it points outside its folder", f.path); continue }
		path, _ := filepath.join({root, f.path}, context.temp_allocator)
		_ = os.make_directory_all(filepath.dir(path))
		if os.write_entire_file(path, transmute([]u8)f.content) != nil { ui.toast(.Bad, "The file could not be written"); return }
		if f.path == it.entry || entry == "" { entry = path }
	}
	if entry != "" { _ = platform.open_path(entry) }
}

artifacts_dialog :: proc(app: ^App, em: f32) {
	a := &app.cx.artifacts
	if !a.open { return }
	if ui.modal_sized("artifacts", DIALOG_PREFERRED_EM[.Artifacts] * em, &app.cx.dialogs[.Artifacts], &a.open, DIALOG_MIN_EM[.Artifacts] * em) {
		dialog_backdrop()
		ui.spacer(ui.px(em * 0.9))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###ar_head") {
			ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
			text("t", "Artifacts of this folder", hex(HEX_BRIGHT), ui.Style_Mod{font_size = math.round(em * FS_TITLE), height = ui.px(em * 2)}, ui.fill())
			ui.spacer(ui.px(em * 3))
		}
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
		if ui.row(id = "###ar_body") {
			ui.spacer(ui.px(em * DIALOG_MARGIN_EM))
			ui.next({width = ui.px(math.round(em * FILES_LIST_W_EM)), height = ui.fill()})
			if ui.scroll_y("###ar_list") {
				switch {
				case a.loading:       info_line(app, "###ar_load", "Reading…", em)
				case a.refused != "": info_line(app, "###ar_off", a.refused, em, hex(HEX_YELLOW))
				case len(a.list) == 0: info_line(app, "###ar_none", "No artifact here: an agent publishes them.", em)
				case:
					for &it, i in a.list {
						ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.8)), axis = .X, cross = .Center, cursor = .Hand})
						row := ui.build_box({.Clickable}, fmt.tprintf("###arr%d", i))
						if ui.signal(row).clicked {
							set_text(&a.shown, it.id)
							set_text(&a.removing, "")
							q := artifact_location(a)
							request(app, .Artifact_Read, "GET", fmt.tprintf("/api/experimental/artifacts/%s%s%s", url_escape(it.id), q != "" ? "?" : "", q), tag = it.id)
						}
						if ui.parent(row) {
							glyph(ICO_DOC, hex(it.id == a.shown ? HEX_BRIGHT : HEX_FAINT), math.round(em * ICON_SMALL), em * 1.1)
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
		dialog_close(&a.open)
	}
}

@(private = "file")
artifact_right :: proc(app: ^App, em: f32) {
	a := &app.cx.artifacts
	it: ^Artifact
	for &x in a.list { if x.id == a.shown { it = &x } }
	if it == nil { return }
	small := math.round(em * BUTTON_COMPACT_H_EM)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###ar_bar") {
		text("p", it.provider, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_CAPTION), height = ui.px(em * 1.6)}, ui.fill())
		if it.id == a.removing {
			if bevel_button("###ar_yes", "Delete", ICO_DELETE, .Danger, height = small).clicked {
				q := artifact_location(a)
				request(app, .Artifact_Done, "DELETE", fmt.tprintf("/api/experimental/artifacts/%s%s%s", url_escape(it.id), q != "" ? "?" : "", q))
				set_text(&a.removing, ""); set_text(&a.shown, "")
				artifact_files_clear(a)
				return
			}
			ui.spacer(ui.px(em * 0.3))
			if bevel_button("###ar_no", "Keep", "", .Normal, height = small).clicked { set_text(&a.removing, "") }
		} else {
			if bevel_button("###ar_open", "Open in the browser", ICO_GLOBE, .Accent, height = small).clicked { artifact_view(a, it) }
			ui.spacer(ui.px(em * 0.3))
			if bevel_button("###ar_del", "Delete", ICO_DELETE, .Ghost, height = small).clicked { set_text(&a.removing, it.id) }
		}
	}
	ui.spacer(ui.px(em * 0.4))
	if len(a.files) == 0 { return }
	if len(a.files) > 1 {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center, id = "###ar_files") {
			for f, i in a.files {
				if bevel_button(fmt.tprintf("###arf%d", i), label_safe(f.path), "", a.file == i ? .Toggled : .Normal, height = small).clicked { a.file = i; a.version += 1 }
				ui.spacer(ui.px(em * 0.3))
			}
		}
		ui.spacer(ui.px(em * 0.4))
	}
	f := a.files[clamp(a.file, 0, len(a.files) - 1)]
	shown, is_text := file_text(f.content)
	if !is_text { info_line(app, "###ar_bin", "Not text.", em); return }
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###ar_view") { code_block("###ar_code", strings.trim_prefix(filepath.ext(f.path), "."), shown, version = a.version) }
}

////////////////////////////////
// Plugins

Plugin :: struct {
	id, kind, target, version, error: string,
	outdated, updating, failed: bool,
	features: string,
}

Plugins :: struct {
	asked, loaded, builtin, checking: bool,
	list:     [dynamic]Plugin,
	arena:    virtual.Arena,
	has_arena: bool,
}

plugins_ask :: proc(app: ^App) {
	app.cx.plugins.asked = true
	request(app, .Plugins, "GET", "/api/plugin")
}

@(private = "file")
json_on :: proc(v: json.Value, key: string) -> bool {
	b, _ := jget(v, key).(json.Boolean)
	return bool(b)
}

// Those one chose first: what is built in is the server's own.
plugins_load :: proc(app: ^App, v: json.Value) {
	p := &app.cx.plugins
	p.checking = false
	if p.has_arena { virtual.arena_destroy(&p.arena) }
	_ = virtual.arena_init_growing(&p.arena)
	p.has_arena = true
	a := virtual.arena_allocator(&p.arena)
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
				if !json_on(f, name) { continue }
				if strings.builder_len(features) > 0 { strings.write_string(&features, ", ") }
				strings.write_string(&features, name)
			}
			src := jget(it, "source")
			append(&p.list, Plugin{
				id = strings.clone(jstr(it, "id"), a), kind = strings.clone(kind, a), target = strings.clone(target, a), version = strings.clone(jstr(it, "source", "version"), a),
				error = strings.clone(jstr(it, "state", "error"), a), outdated = json_on(src, "outdated"), updating = json_on(src, "updating"),
				failed = jstr(it, "state", "status") == "failed", features = strings.clone(strings.to_string(features), a),
			})
		}
	}
	p.loaded = true
}

plugins_changed :: proc(app: ^App) {
	if app.cx.plugins.asked { plugins_ask(app) }
}

plugins_failed :: proc(app: ^App) { app.cx.plugins.checking = false }

page_plugins :: proc(app: ^App, em: f32) {
	p := &app.cx.plugins
	if !p.asked { plugins_ask(app) }
	if !p.loaded && loading(app, em) { return }
	built := 0
	for it in p.list { if it.kind == "builtin" { built += 1 } }
	section(fmt.tprintf("INSTALLED (%d)", len(p.list) - built), em)
	if len(p.list) == built { info_line(app, "###pl_none", "No plugin but those of the server.", em) }
	for &it, i in p.list {
		if it.kind == "builtin" { continue }
		plugin_row(app, &it, i, em)
	}
	ui.spacer(ui.px(em * 0.5))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
	if ui.row(.Center, id = "###pl_bar") {
		small := math.round(em * BUTTON_COMPACT_H_EM)
		if bevel_button("###pl_check", p.checking ? "Checking…" : "Check for updates", ICO_REFRESH, .Normal, height = small, disabled = p.checking).clicked {
			p.checking = true
			request(app, .Plugins, "POST", "/api/plugin/check", "{}")
		}
		ui.spacer(ui.px(em * 0.4))
		if bevel_button("###pl_built", fmt.tprintf("%s the %d built in", p.builtin ? "Hide" : "Show", built), "", .Ghost, height = small).clicked { p.builtin = !p.builtin }
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
		glyph(it.failed ? ICO_WARN : ICO_PLUG, hex(color), math.round(em * ICON_SMALL), em * 1.2)
		ui.spacer(ui.px(em * 0.3))
		name := it.id != "" ? it.id : it.target != "" ? it.target : it.kind
		text("n", name, hex(HEX_TEXT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL), height = ui.px(em * 1.6)}, ui.fill())
		detail := it.features
		if it.version != "" { detail = fmt.tprintf("%s  %s", it.version, detail) }
		text("d", detail, hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_CAPTION), height = ui.px(em * 1.6)})
		if it.outdated && it.target != "" {
			ui.spacer(ui.px(em * 0.4))
			if bevel_button("###pl_up", it.updating ? "Updating…" : "Update", "", .Accent, height = math.round(em * BUTTON_SMALL_H_EM), disabled = it.updating).clicked {
				request(app, .Plugin_Update, "POST", "/api/plugin/update", fmt.tprintf(`{{"targets":[%s]}}`, jquote(it.target)))
				it.updating = true
			}
		}
	}
	if it.failed { info_line(app, fmt.tprintf("###ple%d", i), it.error, em, hex(HEX_RED)) }
	ui.spacer(ui.px(em * 0.15))
}
