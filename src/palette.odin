// The command palette (Ctrl+K, Ctrl+Shift+P): the toolkit's (ui.Command_Palette), the same in every program of the
// family. opencode native gives it its sources (src/md/features/palette.md):
//   >  its commands (COMMANDS, as the toolkit's table), the views' moves (the toolkit's), the server's commands ("Server")
//   @  the root sessions, their answer made on a chore (thousands of them)
//   #  the models and the agents, the one in use marked
//   :  the settings (prefs_page's source on cfg_prefs)
// The toolkit ranks on its chores, remembers the choices (palette_choices.txt) and owns its keys: COMMANDS has no line
// for it. What is chosen in one of ocn's sources is done in palette_build, at the top of the next build.
package ocn

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import prefs_page "gt:prefs_page"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

Palette :: struct {
	pal:      ui.Command_Palette,           // the toolkit's: its field, its sources, its usage memory
	settings: prefs_page.Palette_Settings,  // `:`
	server:   ui.Palette_Source,            // `>` the server's commands (slash_load bumps its version)
	sessions: ui.Palette_Source,            // `@`
	models:   ui.Palette_Source,            // `#`
	agents:   ui.Palette_Source,            // `#`

	// the commands source's table: COMMANDS one for one (a choice's index is a COMMANDS index), in table_arena, made
	// again when the language changes; `disabled` made again when what can act changes, while the palette is open
	table:       []ui.Command,
	disabled:    [dynamic]bool,
	gated:       [dynamic]int,   // the commands that have an `enabled` (read at a build while open: a few dozen)
	enabled:     [dynamic]bool,  // ... what each said at the last look
	// each command's detail: "Session · <title>" for a session's commands (they act on the session shown), "" else;
	// made again when the session shown or its title changes (detail_id, detail_title: owned)
	details:      []string,
	detail_id:    string,
	detail_title: string,
	details_arena: virtual.Arena,
	language:    u32,
	made:        bool,
	version:     u64,
	table_arena: virtual.Arena,

	due:       bool,     // palette_show: opened at the next build (asked from outside one: a page's key, a test)
	due_typed: string,   // (owned) what its field starts with
	due_close: bool,

	// The composer's agent and model buttons: a chooser, a palette of one source (no prefix), made of the same reads
	// as `#`. Its one source is swapped at each opening: a chooser is a palette with exactly one source.
	chooser:        ui.Command_Palette,
	chooser_models: ui.Palette_Source,
	chooser_agents: ui.Palette_Source,
	chooser_pane:   int,                 // the pane whose composer opened it: its marks and its choice are that pane's
	chooser_due:    ^ui.Palette_Source,  // chooser_toggle: opened on it at the next build (nil: nothing asked)
	chooser_close:  bool,
}

// What a composer's button opens the chooser on.
Chooser_Kind :: enum { Agents, Models }

// Once, after app_init's views: the sources (the toolkit's settings source on cfg_prefs, ocn's own), and the commands'.
palette_start :: proc(app: ^App) {
	p := &app.palette
	if ui.palette_has(&p.pal, &p.sessions) { return }
	for c, i in COMMANDS { if c.enabled != nil { append(&p.gated, i) } }
	resize(&p.enabled, len(p.gated))
	palette_table_keep(app)
	palette_commands_give(app)
	prefs_page.palette_settings_add(&p.pal, &p.settings, &app.cfg_prefs, &app.settings.prefs,
		proc(user: rawptr) -> prefs_page.Page_Options { return settings_options((^App)(user)) },
		proc(user: rawptr) { settings_open((^App)(user)) },   // (the setting chosen is already alone on its page)
		app)
	p.server = {
		name = "server_command", title = i18n.later("Server commands"), prefix = .Commands, plain = true, remember = true,
		enter = i18n.later("Write"), read = server_read, user = app, version = 1,
	}
	p.sessions = {
		name = "session", title = i18n.later("Sessions"), prefix = .Go_To, plain = true, remember = true,
		enter = i18n.later("Open"), read = sessions_read, mark = sessions_mark,
		poll = proc(_: ^ui.Command_Palette, src: ^ui.Palette_Source) { src.version = (^App)(src.user).cx.sessions_ver + 1 },
		user = app,
	}
	p.models = models_source(app, .Choose)
	p.agents = agents_source(app, .Choose)
	// (the chooser's: no prefix, listed with nothing typed; added to the chooser when it opens)
	p.chooser_models = models_source(app, .None)
	p.chooser_agents = agents_source(app, .None)
	ui.palette_add(&p.pal, &p.server)
	ui.palette_add(&p.pal, &p.sessions)
	ui.palette_add(&p.pal, &p.models)
	ui.palette_add(&p.pal, &p.agents)
}

// Before the window's state goes (the last palette writes the usage memory).
palette_destroy :: proc(app: ^App) {
	p := &app.palette
	jump_destroy(app)
	ui.palette_destroy(&p.chooser)
	ui.palette_destroy(&p.pal)
	virtual.arena_destroy(&p.table_arena)
	virtual.arena_destroy(&p.details_arena)
	delete(p.detail_id)
	delete(p.detail_title)
	delete(p.disabled)
	delete(p.gated)
	delete(p.enabled)
	delete(p.due_typed)
	p^ = {}
}

// The palette opened (closed) at the next build, `typed` in its field: from where no build runs (a page's keys, a
// test), and from a menu or a button, the same way.
palette_show :: proc(app: ^App, typed := "") {
	p := &app.palette
	delete(p.due_typed)
	p.due, p.due_close, p.due_typed = true, false, strings.clone(typed)
}

palette_hide :: proc(app: ^App) {
	app.palette.due, app.palette.due_close = false, true
}

// Whether the palette's view is open (between builds too: the main window's state stays the current one).
palette_shown :: proc(app: ^App) -> bool { return ui.palette_is_open(&app.palette.pal) }

// At the top of each build of the main window: the commands given (compared by their version), its keys, the choice.
palette_build :: proc(app: ^App) {
	p := &app.palette
	palette_start(app)   // (once: app_init did it, a test's app may not have)
	if p.due {
		p.due = false
		ui.palette_open(&p.pal, p.due_typed)
	} else if p.due_close {
		p.due_close = false
		ui.palette_close(&p.pal)
	}
	if !p.made || ui.palette_is_open(&p.pal) { palette_table_keep(app) }
	palette_commands_give(app)
	// (an open menu and the file dialog keep the window's keys: their Escape and their letters are theirs)
	if !ui.file_dialog_shown(&app.state) { _ = ui.palette_keys(&p.pal) }
	// (the toolkit's sources act in palette_chosen: a setting, a view's move)
	if c, ok := ui.palette_chosen(&p.pal); ok { palette_run(app, c) }
	jump_build(app)   // (Jump to message: a palette of its own, after this one, whose command may have asked for it)
	chooser_build(app)
}

// The composer's agent or model button: the chooser opened on that list for `pane`, or closed when it shows it already.
chooser_toggle :: proc(app: ^App, pane: ^Chat_Pane, kind: Chooser_Kind) {
	p := &app.palette
	src := kind == .Agents ? &p.chooser_agents : &p.chooser_models
	if chooser_shows(app, kind) {
		p.chooser_due, p.chooser_close = nil, true
		return
	}
	p.chooser_due, p.chooser_close, p.chooser_pane = src, false, pane_index(app, pane)
	// (read again at each opening: a server that has just started lists its agents and models before its plugins and
	// integrations add theirs, and a list read once at the connection would stay that one; the one read shows meanwhile)
	switch kind {
	case .Agents: if !flying(app, .Agents, "") { request(app, .Agents, "GET", "/api/agent") }
	case .Models: if !flying(app, .Models, "") { request(app, .Models, "GET", "/api/model") }
	}
}

// Whether the chooser is open on that list (its button is lit).
chooser_shows :: proc(app: ^App, kind: Chooser_Kind) -> bool {
	p := &app.palette
	src := kind == .Agents ? &p.chooser_agents : &p.chooser_models
	return ui.palette_is_open(&p.chooser) && ui.palette_has(&p.chooser, src)
}

// At each build of the main window: opened or closed as asked, its choice taken for the pane that opened it.
@(private = "file")
chooser_build :: proc(app: ^App) {
	p := &app.palette
	if src := p.chooser_due; src != nil {
		p.chooser_due = nil
		ui.palette_remove(&p.chooser, src == &p.chooser_models ? &p.chooser_agents : &p.chooser_models)
		ui.palette_add(&p.chooser, src)
		ui.palette_close(&p.chooser)   // (closed first: an opening on the other list starts from an empty field)
		ui.palette_open(&p.chooser)
	} else if p.chooser_close {
		p.chooser_close = false
		ui.palette_close(&p.chooser)
	}
	if c, ok := ui.palette_chosen(&p.chooser); ok { choice_take(app, &app.panes[p.chooser_pane], c) }
}

// The commands' table kept: made again when the language changed (the keys' texts are said in it), `disabled` when a
// gated command can act or no longer. Either bumps the version the palette compares.
@(private = "file")
palette_table_keep :: proc(app: ^App) {
	pane := main_pane(app)
	p := &app.palette
	changed := false
	if language := i18n.version(); !p.made || language != p.language {
		p.made, p.language, changed = true, language, true
		virtual.arena_free_all(&p.table_arena)
		a := virtual.arena_allocator(&p.table_arena)
		table := make([]ui.Command, len(COMMANDS), a)
		for &c, i in COMMANDS {
			// (in English: the palette says them in the language in use, and finds them by their English too)
			// (a command with a state on or off is a switch: its row has the mark, and choosing it keeps the palette)
			// (its id: the usage memory's key, and the toolkit's for the person's own key)
			table[i] = {id = c.id, label = c.title, group = c.group, icon = c.icon, tags = strings.fields(c.tags, a), scope = c.scope, toggle = c.checked != nil}
			if c.key != .None { table[i].keys = slice_of_one(ui.Chord{c.key, c.mods}, a) }
		}
		p.table = table
		resize(&p.disabled, len(COMMANDS))
	}
	for ci, k in p.gated {
		on := COMMANDS[ci].enabled(app)
		if p.enabled[k] != on || changed {
			p.enabled[k] = on
			p.disabled[ci] = !on
			changed = true
		}
	}
	// the session a session's command acts on: the one shown, by its title (one lookup; the details made on a change)
	title := ""
	if s := find_session(app, pane.chat.id); s != nil { title = s.title != "" ? s.title : i18n.tr("Untitled") }
	if changed || p.details == nil || pane.chat.id != p.detail_id || title != p.detail_title {
		delete(p.detail_id)
		delete(p.detail_title)
		p.detail_id, p.detail_title = strings.clone(pane.chat.id), strings.clone(title)
		virtual.arena_free_all(&p.details_arena)
		a := virtual.arena_allocator(&p.details_arena)
		p.details = make([]string, len(COMMANDS), a)
		if title != "" {
			said := fmt.aprintf(i18n.tr("Session · %s"), ellipsize(title, PALETTE_SESSION_CHARS), allocator = a)
			for &c, i in COMMANDS { if c.group == "Session" { p.details[i] = said } }
		}
		changed = true
	}
	if changed { p.version += 1 }
}

// The commands source given its table (compared by the version), the switches' marks and the details.
@(private = "file")
palette_commands_give :: proc(app: ^App) {
	p := &app.palette
	ui.palette_commands(&p.pal, p.table, p.disabled[:], {
		details = p.details, version = p.version, user = app,
		// (read for the rows in view, at each build: a switch's state is not versioned)
		checked = proc(user: rawptr, index: int) -> bool {
			if index < 0 || index >= len(COMMANDS) { return false }
			c := &COMMANDS[index]
			return c.checked != nil && c.checked((^App)(user))
		},
	})
}

@(private = "file")
slice_of_one :: proc(c: ui.Chord, a: runtime.Allocator) -> []ui.Chord {
	s := make([]ui.Chord, 1, a)
	s[0] = c
	return s
}

// A choice of one of ocn's sources (the toolkit's acted already).
@(private = "file")
palette_run :: proc(app: ^App, c: ui.Palette_Choice) {
	pane := main_pane(app)
	p := &app.palette
	if _, is := ui.palette_chosen_command(&p.pal, c); is {
		// (by its id: the table may have been made again since it was ranked)
		if cmd := command_find(c.id); cmd != nil { command_run(app, cmd) }
		return
	}
	if c.source == &p.server {
		ui.text_edit_set(&pane.composer.area, fmt.tprintf("/%s ", c.id))
		pane.composer.focus_next = true
	} else if c.source == &p.sessions {
		open_root(app, c.id)
	} else {
		choice_take(app, pane, c)
	}
}

// A model or an agent chosen, in `#` or in the chooser: `pane` takes it.
@(private = "file")
choice_take :: proc(app: ^App, pane: ^Chat_Pane, c: ui.Palette_Choice) {
	switch c.source.name {
	case "model":
		for m in app.models {
			if model_key(m.provider, m.id) == c.id { choose_model(app, pane, m); break }
		}
	case "agent":
		choose_agent(app, pane, c.id)
	}
}

////////////////////////////////
// `>` The server's commands

// The commands the server gave (read at the connection: stream_up), under their group "Server": a few dozen, at once.
@(private = "file")
server_read :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, q: ui.Palette_Question) {
	app := (^App)(src.user)
	a: ui.Palette_Answer
	al := ui.palette_answer_allocator(&a)
	a.items = make([]ui.Palette_Item, len(app.cx.slash), al)
	group := i18n.tr("Server")
	for s, i in app.cx.slash {
		a.items[i] = ui.palette_item_clone({id = s.name, title = fmt.tprintf("/%s", s.name), detail = s.description, icon = lucide.SQUARE_TERMINAL, group = group}, al)
	}
	ui.palette_answer(q, &a)
}

////////////////////////////////
// `@` The sessions

// What an item is made from, copied on the interface's thread (the sessions change under a chore).
@(private = "file")
Session_Line :: struct { id, title, directory: string }

@(private = "file")
Sessions_Job :: struct {
	q:        ui.Palette_Question,
	lines:    []Session_Line,
	untitled: string,   // translated on the interface's thread
	answer:   ui.Palette_Answer,
}

// The root sessions (not a sub-agent's), copied in the answer's arena once per version (sessions_ver); the items made on
// a chore. Thousands of them: their copy is the work of a change of the list, not of a frame.
@(private = "file")
sessions_read :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, q: ui.Palette_Question) {
	app := (^App)(src.user)
	job := new(Sessions_Job)
	job.q = q
	al := ui.palette_answer_allocator(&job.answer)
	job.untitled = strings.clone(i18n.tr("Untitled"), al)
	lines := make([dynamic]Session_Line, 0, len(app.sessions), al)
	for &s in app.sessions {
		if s.parent != "" { continue }
		append(&lines, Session_Line{strings.clone(s.id, al), strings.clone(s.title, al), strings.clone(s.directory, al)})
	}
	job.lines = lines[:]
	ui.task(&app.state, sessions_work, sessions_done, job, sessions_lost)
}

// (on a chore) The items, in the answer's arena.
@(private = "file")
sessions_work :: proc(data: rawptr) {
	job := (^Sessions_Job)(data)
	al := ui.palette_answer_allocator(&job.answer)
	items := make([]ui.Palette_Item, len(job.lines), al)
	for l, i in job.lines {
		items[i] = {id = l.id, title = l.title != "" ? l.title : job.untitled, detail = base_name(l.directory), icon = lucide.MESSAGE_SQUARE}
	}
	job.answer.items = items
}

// (on the interface's thread) The palette takes the arena whole, or drops it (a newer question).
@(private = "file")
sessions_done :: proc(data: rawptr, _: u64) {
	job := (^Sessions_Job)(data)
	_ = ui.palette_answer(job.q, &job.answer)
	free(job)
}

// The window went before the answer came: the question ends with none (from any thread).
@(private = "file")
sessions_lost :: proc(data: rawptr) {
	job := (^Sessions_Job)(data)
	ui.palette_answer_free(&job.answer)
	ui.palette_question_drop(job.q)
	free(job)
}

// The session shown.
@(private = "file")
sessions_mark :: proc(src: ^ui.Palette_Source, id: string) -> bool { return id == main_pane((^App)(src.user)).chat.id }

////////////////////////////////
// `#` The models and the agents

// A model's id in the palette: its provider and its id.
model_key :: proc(provider, id: string) -> string { return fmt.tprintf("%s/%s", provider, id) }

// The models' source under `prefix`: `#` in the palette, .None in the chooser. One read and one mark for both.
@(private = "file")
models_source :: proc(app: ^App, prefix: ui.Palette_Prefix) -> ui.Palette_Source {
	return {
		name = "model", title = i18n.later("Models"), prefix = prefix, plain = prefix != .None, remember = prefix != .None,
		listed = prefix == .None, enter = i18n.later("Use"), read = models_read, mark = models_mark, poll = catalog_poll,
		user = app,
	}
}

@(private = "file")
agents_source :: proc(app: ^App, prefix: ui.Palette_Prefix) -> ui.Palette_Source {
	return {
		name = "agent", title = i18n.later("Agents"), prefix = prefix, plain = prefix != .None, remember = prefix != .None,
		listed = prefix == .None, enter = i18n.later("Use"), read = agents_read, mark = agents_mark, poll = catalog_poll,
		user = app,
	}
}

// (read again when the server's lists change: never at a frame)
@(private = "file")
catalog_poll :: proc(_: ^ui.Command_Palette, src: ^ui.Palette_Source) { src.version = (^App)(src.user).cx.catalog_version + 1 }

// The pane a source's mark is about: the chooser's is the composer's that opened it; the palette's, the main view.
@(private = "file")
source_pane :: proc(src: ^ui.Palette_Source) -> ^Chat_Pane {
	app := (^App)(src.user)
	if src.prefix == .None { return &app.panes[app.palette.chooser_pane] }
	return main_pane(app)
}

// The models under their provider (a heading with nothing typed, said after the name while something is, and searched),
// their context size beside them.
@(private = "file")
models_read :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, q: ui.Palette_Question) {
	app := (^App)(src.user)
	a: ui.Palette_Answer
	al := ui.palette_answer_allocator(&a)
	a.items = make([]ui.Palette_Item, len(app.models), al)
	for m, i in app.models {
		size := ""
		if m.ctx_len > 0 { size, _ = strings.replace(kfmt(m.ctx_len), ".0", "", 1, context.temp_allocator) }   // (1M, 128k)
		a.items[i] = ui.palette_item_clone({id = model_key(m.provider, m.id), title = m.name != "" ? m.name : m.id, detail = size, icon = lucide.CPU, group = m.provider}, al)
	}
	ui.palette_answer(q, &a)
}

// The model in use: the session's, or the one chosen for it.
@(private = "file")
models_mark :: proc(src: ^ui.Palette_Source, id: string) -> bool {
	model, provider := shown_model((^App)(src.user), source_pane(src))
	return model != "" && model_key(provider, model) == id
}

// The agents one can choose (a sub-agent is the server's to launch). No group: in `#` they are under the source's
// title, "Agents"; in the chooser they are alone.
@(private = "file")
agents_read :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, q: ui.Palette_Question) {
	app := (^App)(src.user)
	a: ui.Palette_Answer
	al := ui.palette_answer_allocator(&a)
	items := make([dynamic]ui.Palette_Item, 0, len(app.agents), al)
	for ag in app.agents {
		if ag.mode == "subagent" { continue }
		append(&items, ui.palette_item_clone({id = ag.id, title = ag.name != "" ? ag.name : ag.id, detail = ag.description, icon = lucide.BOT}, al))
	}
	a.items = items[:]
	ui.palette_answer(q, &a)
}

// The agent in use; with none chosen, the server's default, "build" (as the composer's button says).
@(private = "file")
agents_mark :: proc(src: ^ui.Palette_Source, id: string) -> bool {
	agent := shown_agent((^App)(src.user), source_pane(src))
	return id == (agent != "" ? agent : "build")
}
