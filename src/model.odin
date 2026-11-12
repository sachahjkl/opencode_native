// What the client knows: the sessions, the open conversation (its messages and their parts), agents, models and the
// pending permission requests. Loaded from the API, then kept current by the event stream.
package ocn

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "gt:config"
import "gt:ui"

Session_Info :: struct {
	id, title, parent, directory, agent, model, provider, outcome, project: string,
	variant:         string,   // how hard its model thinks ("": the model's default)
	created, updated, idle: f64,
	archived:        f64,   // when it was put away (time.archived; 0: it is not): the sidebar's last section, nowhere else
	viewed:          f64,   // the last end of a run someone looked at (idle later than this: not seen, sidebar.odin)
	cost:            f64,
	tokens_in, tokens_out, reasoning, cache_read, cache_write: f64,
	approval:        Approval,   // its own permission rules, as a preset (approval.odin)
	lazy_id:         string,     // its id in the sidebar's lazy column, made once with the list (sessions_changed)
}

// What a sub-agent does while it runs, from the event stream (its session is not the one shown).
Sub_Live :: struct {
	activity:  string,    // its last tool call ("shell: cargo build"), or what it is doing
	tools:     int,       // tool calls seen
	steps:     int,       // model steps seen
	cost:      f64,
	tokens_in, tokens_out: f64,
	last_ms:   f64,       // when it last did something (epoch ms)
}

Tool_Status :: enum u8 { Pending, Running, Done, Error, Unknown }   // (Unknown: a word this client does not know)
Part_Kind :: enum u8 { Text, Reasoning, Tool }

Part :: struct {
	kind:      Part_Kind,
	ordinal:   int,
	text:      [dynamic]u8,   // text and reasoning
	tool_id:   string,
	tool_name: string,
	status:    Tool_Status,
	input:     string,        // JSON text (copied whole; what views read of it is below, read once by tool_set_input)
	subject:   string,        // what the tool works on (a path, a command, a pattern), for its header
	// what the input says, read once (tool_set_input): a build never parses the input again
	command:      string,          // input.command
	command_line: string,          // "$ command", as a well shows it
	background:   bool,            // input.background
	file_path:    string,          // input.filePath, else input.path
	todos:        []Todo,          // input.todos (has_todos: it has that list)
	has_todos:    bool,
	old_text, new_text: string,    // an edit: oldString / old_string, newString / new_string (has_old: it has the old one)
	has_old:      bool,
	content:      string,          // a write: input.content (has_content: it has one)
	has_content:  bool,
	fields:       []Input_Field,   // all of the input as keys and values, by key (input_object: it is an object)
	input_object: bool,
	output:    string,        // (set by tool_set_output: what is read of it goes with it)
	output_numbered: bool,    // it reads as lines of a file (read_view)
	moved_shell: string,      // the server's command the output says the call went on as ("... (shell ID: sh_...)")
	shell_id:  string,        // the command of the server it runs, once it says (output_view.odin)
	done:      bool,
	// a sub-agent launched by this call (tool "subagent")
	sub_session, sub_agent, sub_desc, sub_prompt, sub_model: string,
	sub_background: bool,
	started_ms, ended_ms: f64,
	images:    [dynamic]Image_Ref,   // what a tool handed back as images (screenshots, images read)
	// what a call changed in files (tool_views.odin): the server's patch, else made from its input
	patch:       string,
	patch_tried: bool,
	diff:        Diff,   // the patch read (part_patch_set: again only when the patch changes)
	added, removed: int,
	// what the views made of its texts, kept with the text they were made from (in the chat's arena, as the part)
	output_well:  Well_Kept,   // its output in a well
	command_well: Well_Kept,   // its command_line
	prompt_well:  Well_Kept,   // a sub-agent's prompt
	text_runs:    Link_Runs,   // reasoning: its text with its addresses as links
}

// A key of a tool's input and its value as a line reads it (value_text); `long`: it goes on lines of its own, under its key, in a
// well (`well`: what that made of it).
Input_Field :: struct {
	key, value: string,
	long:       bool,
	well:       Well_Kept,
}

Msg_Kind :: enum u8 { User, Assistant, Synthetic, Shell, Compaction, Idle, Switch, Other }

// What a .Switch message says the session changed (the server's agent-switched, model-switched, location-switched).
Switch_What :: enum u8 { Agent, Model, Location }

Message :: struct {
	id:        string,
	lazy_id:   string,        // its id in the lazy column, once built
	kind:      Msg_Kind,
	created:   f64,
	completed: f64,
	agent, model, provider, finish: string,
	variant:   string,        // how hard the model thought ("": its default)
	text:      string,        // user, synthetic, shell; a switch: what it is now ("opus · high", a folder)
	previous:  string,        // a switch: what it was ("": not said)
	switched:  Switch_What,
	shell_id:  string,        // shell: its command on the server
	text_runs: Link_Runs,     // user: its text with its addresses as links, kept with it
	parts:     [dynamic]Part,
	tokens_in, tokens_out, reasoning, cache_read: f64,
	cost:      f64,
	streaming: bool,
	// a sub-agent's result handed back to this session (a synthetic message whose metadata.source is "subagent")
	sub_child, sub_state, sub_agent, sub_desc: string,
	images:    [dynamic]Image_Ref,   // attached to a user's prompt
	from_page: bool,                 // read from a page (what the stream builds is only pieces)
	touched:   Seq,                  // the stream's clock when it last changed it (a page asked before that is older: chat_load)
}

// The open conversation. Everything in it lives in its arena, dropped when another conversation opens. A page read again
// keeps the messages that are final (chat_load), the sub-agents have an arena of their own: reading does not make it grow.
Chat :: struct {
	id:        string,
	gen:       u64,
	arena:     virtual.Arena,
	alloc:     mem.Allocator,
	messages:  [dynamic]Message,   // oldest first
	older:     string,             // cursor of the page before the first message ("": none)
	loading:   bool,
	loading_older: bool,           // that page is on its way
	older_failed:  f64,            // when it could not be read (ui.now_ms): tried again a little later, on the next scroll
	view_msg:  string,             // the message at the top of the view (of the arena) and how far into it
	view_dy:   f32,
	view_box:  ^ui.Box,            // view_msg's box at the last build (an answer arrives before the next one: begin_build)
	new_dir:   string,             // the folder of the session about to be made
	loaded:    bool,
	busy:      bool,
	cost:      f64,
	tokens_in, tokens_out, cache_read: f64,
	model, provider, agent, variant: string,   // what it used last, as read and as streamed
	chose_agent, chose_model, chose_provider, chose_variant: string,   // what the reader picked for it: goes before that (shown_agent, shown_model)
	seq:       Seq,                        // the stream's clock at the event being applied (Message.touched)
	// the session itself (GET /api/session/:id), its parent, its sub-agents
	self:         Session_Info,
	have_self:    bool,
	parent_title: string,
	children:     [dynamic]Session_Info,   // sessions whose parent is this one (newest first; in children_arena: read often)
	children_arena: virtual.Arena,
	live:         map[string]Sub_Live,     // keyed by child session id (keys and strings in the arena)
	goal:         Goal,                    // its /goal (goal.odin; strings in the arena)
	has_goal:     bool,
	markdown:     map[string]^Md_Doc,      // the blocks of each Markdown text shown, by the id it is built under (md_doc; in the arena)
	// What is made from the messages is kept until one of these moves.
	changes:      u64,                     // any change of the messages or of their parts (chat_changed)
	subs_seq:     u64,                     // a change of what says which session is whose: a page read, a message gone, a call naming its session (subs_changed)
	subs:         Sub_Index,               // what the conversation says of its sub-agents (subagents.odin sub_index; in subs_arena)
	subs_arena:   virtual.Arena,
}

// The messages or their parts changed: what is made from them is made again when next asked (Local_Kept).
chat_changed :: proc(c: ^Chat) { c.changes += 1 }

// Which message is a sub-agent's result, or which session a call names, may have changed: the index of them is read again (sub_index).
// Messages added at the end move no index; a page read or a message gone does.
subs_changed :: proc(c: ^Chat) {
	c.subs_seq += 1
	c.changes += 1
}

Agent_Info :: struct { id, name, description, mode: string }
// (Prices in dollars per million tokens; `priced`: the server gave them, a price of 0 then being free.)
Model_Info :: struct {
	id, provider, name, family: string,
	ctx_len, out_len:           f64,
	priced:                     bool,
	price_in, price_out, price_cached: f64,
	inputs:                     string,   // what it reads: "text, image, pdf"
	efforts:                    string,   // how hard it can think: "low, medium, high"
	status:                     string,
	tools_known, tools:         bool,
	released:                   f64,      // ms since 1970, 0: not said
}
Permission :: struct {
	id, session, action, message: string,
	resources: []string,
	replying:  bool,   // the answer is on its way
	born:      Seq,    // the stream's clock when it came (a list asked before that does not know it: permissions_replace)
}

chat_reset :: proc(c: ^Chat) {
	if c.alloc.procedure != nil { virtual.arena_destroy(&c.arena); virtual.arena_destroy(&c.children_arena) }
	virtual.arena_destroy(&c.subs_arena)   // (zero when nothing asked for the index: destroying it does nothing)
	gen := c.gen
	c^ = {}
	c.gen = gen + 1
	_ = virtual.arena_init_growing(&c.arena)
	c.alloc = virtual.arena_allocator(&c.arena)
}

// The session shown, kept for the next start (general.start = "last"): its id, or LAST_SESSION_HOME for the home page. Not
// before the first list is read (the start's own chat_home would say "home"), nor in a test (no preferences file).
LAST_SESSION_KEY  :: "last_session"
LAST_SESSION_HOME :: "home"

last_session_keep :: proc(app: ^App) {
	if app.prefs_file == "" || !app.opened_first { return }
	id := app.chat.id != "" ? app.chat.id : LAST_SESSION_HOME
	settings_set(app, LAST_SESSION_KEY, id)   // (the same id changes nothing: no write)
}

// The home page, whichever way one gets there: nothing to load.
chat_home :: proc(app: ^App) {
	draft_leave(app)
	chat_reset(&app.chat)
	app.chat.loaded = true
	draft_enter(app)
	last_session_keep(app)
	queue_switch(app)
}

// What the conversation's place shows. (Failed: the first page was not read, and only a retry brings it.)
Chat_View :: enum u8 { Home, Loading, Failed, Shown }

chat_view :: proc(app: ^App) -> Chat_View {
	c := &app.chat
	if c.id == "" { return .Home }
	if c.loaded { return .Shown }
	return c.loading ? .Loading : .Failed
}

// What the composer shows and what a new session takes: the reader's choice, what the session used, on the home page what was
// chosen last.
shown_agent :: proc(app: ^App) -> string {
	c := &app.chat
	if c.chose_agent != "" { return c.chose_agent }
	if c.id == "" { return config.string_of(&app.cfg_prefs, "session.agent") }
	return c.agent
}

shown_model :: proc(app: ^App) -> (model, provider: string) {
	c := &app.chat
	if c.chose_model != "" { return c.chose_model, c.chose_provider }
	if c.id == "" { return config.string_of(&app.cfg_prefs, "session.model"), config.string_of(&app.cfg_prefs, "session.provider") }
	return c.model, c.provider
}

// How hard the model shown thinks: what the reader picked with the model, else what the session uses ("": the model's default).
shown_variant :: proc(app: ^App) -> string {
	c := &app.chat
	if c.chose_model != "" { return c.chose_variant }
	if c.id == "" { return config.string_of(&app.cfg_prefs, "session.variant") }
	return c.variant
}

// The variant of a model reference ({"model": {"id", "providerID", "variant"}}): the server says "default" for none.
variant_of :: proc(v: json.Value) -> string {
	s := jstr(v, "model", "variant")
	return s == "default" ? "" : s
}

// The variants of a model (how hard it can think: "low", "high"...), temp memory; none when it has none or is not known.
model_variants :: proc(app: ^App, model, provider: string) -> []string {
	for m in app.models {
		if m.id == model && m.provider == provider && m.efforts != "" { return strings.split(m.efforts, ", ", context.temp_allocator) }
	}
	return nil
}

// A model as a switch line says it: "opus", "opus · high" (temp memory).
model_word :: proc(model, variant: string) -> string {
	if model == "" { return "" }
	return variant != "" ? fmt.tprintf("%s · %s", model, variant) : model
}

// The body that gives a session its model ("" variant: the model's default).
model_body :: proc(model, provider, variant: string) -> string {
	if variant == "" { return fmt.tprintf(`{{"model":{{"id":%s,"providerID":%s}}}}`, jquote(model), jquote(provider)) }
	return fmt.tprintf(`{{"model":{{"id":%s,"providerID":%s,"variant":%s}}}}`, jquote(model), jquote(provider), jquote(variant))
}

open_chat :: proc(app: ^App, session_id: string) {
	if session_id == app.chat.id { return }
	id := strings.clone(session_id, context.temp_allocator)   // (it may live in the arena chat_reset drops)
	nav_visit(app, app.chat.id, id)
	draft_leave(app)
	chat_reset(&app.chat)
	app.chat.id = strings.clone(id, app.chat.alloc)
	draft_enter(app)
	last_session_keep(app)
	app.chat.loading = true
	chat_view_start(app, ui.now_ms())
	app.chat.busy = app.busy[id] or_else false
	if s := find_session(app, id); s != nil {
		app.chat.model = strings.clone(s.model, app.chat.alloc)
		app.chat.provider = strings.clone(s.provider, app.chat.alloc)
		app.chat.variant = strings.clone(s.variant, app.chat.alloc)
		app.chat.agent = strings.clone(s.agent, app.chat.alloc)
		app.chat.cost = s.cost
		app.chat.tokens_in, app.chat.tokens_out, app.chat.cache_read = s.tokens_in, s.tokens_out, s.cache_read
		if !app.chat.busy { session_seen(app, s) }
	}
	app.chat.live = make(map[string]Sub_Live, allocator = app.chat.alloc)
	chat_shown_changed(app)
}

// What follows the session shown, whichever way it changed: one door. (Read before outgoing_return: the queue's change gives the composer what it
// held, and what failed goes on top of that.)
chat_shown_changed :: proc(app: ^App) {
	activity_reset(app)
	find_chat_changed(app)
	if app.chat.id != "" { chat_read(app); goal_read(app) }
	outgoing_return(app)
}

// (by the index sessions_changed keeps: some thirty places ask it, some at every build)
find_session :: proc(app: ^App, id: string) -> ^Session_Info {
	if i, ok := app.session_at[id]; ok { return &app.sessions[i] }
	return nil
}

// The list of sessions changed (read, or made by a test): its index by id made again, and the id of each row in the sidebar's lazy column,
// once. What the sidebar keeps of it is made again (Side_Kept). Every change of app.sessions comes through here.
sessions_changed :: proc(app: ^App) {
	a := virtual.arena_allocator(&app.sess_arena)
	app.session_at = make(map[string]int, len(app.sessions), a)
	for &s, i in app.sessions {
		app.session_at[s.id] = i
		if s.lazy_id == "" { s.lazy_id = fmt.aprintf("###ls_%s", s.id, allocator = a) }
	}
	app.cx.sessions_ver += 1
}

// What deals a session into a section of the sidebar, or lights its row, changed: a run started or ended, a wait came or went, an end
// was seen, it was archived. (What the list says comes through sessions_changed.)
marks_changed :: proc(app: ^App) { app.cx.marks_ver += 1 }

////////////////////////////////
// Loading

session_from_json :: proc(it: json.Value, a: mem.Allocator) -> Session_Info {
	return {
		id = strings.clone(jstr(it, "id"), a), title = strings.clone(jstr(it, "title"), a),
		parent = strings.clone(jstr(it, "parentID"), a), directory = strings.clone(jstr(it, "location", "directory"), a),
		agent = strings.clone(jstr(it, "agent"), a), model = strings.clone(jstr(it, "model", "id"), a),
		provider = strings.clone(jstr(it, "model", "providerID"), a), outcome = strings.clone(jstr(it, "outcome"), a),
		variant = strings.clone(variant_of(it), a),
		project = strings.clone(jstr(it, "projectID"), a),
		created = jnum(it, "time", "created"), updated = jnum(it, "time", "updated"), idle = jnum(it, "time", "idle"), viewed = jnum(it, "time", "viewed"), archived = jnum(it, "time", "archived"),
		cost = jnum(it, "cost"), tokens_in = jnum(it, "tokens", "input"), tokens_out = jnum(it, "tokens", "output"),
		reasoning = jnum(it, "tokens", "reasoning"), cache_read = jnum(it, "tokens", "cache", "read"), cache_write = jnum(it, "tokens", "cache", "write"),
		approval = approval_of(jget(it, "permissions")),
	}
}

// A project's logo (Project.icon: an image as a data URL, the user's override first) and its colour.
Project_Logo :: struct { ref: Image_Ref, has_ref: bool, color: string, worktree: string, overridden: bool }   // (overridden: the user's own icon)

projects_load :: proc(app: ^App, v: json.Value) {
	a := arena_renew(&app.proj_arena)
	app.projects = make(map[string]Project_Logo, allocator = a)
	list, _ := v.(json.Array)
	if list == nil { list = jarr(v, "data") }
	for it in list {
		icon := jget(it, "icon")
		url := jstr(icon, "override")
		overridden := strings.has_prefix(url, "data:")
		if !overridden { url = jstr(icon, "url") }
		p := Project_Logo{color = strings.clone(jstr(icon, "color"), a), worktree = strings.clone(jstr(it, "worktree"), a), overridden = overridden}
		if strings.has_prefix(url, "data:image/") {
			p.ref = image_ref(strings.clone(url, a), .Data_Url, "image", strings.clone(base_name(p.worktree), a))
			p.has_ref = true
		}
		app.projects[strings.clone(jstr(it, "id"), a)] = p
	}
}

// The logo of a project (nil: none).
project_logo :: proc(app: ^App, project: string) -> ^Image_Ref {
	if project == "" { return nil }
	if p, ok := &app.projects[project]; ok && p.has_ref { return &p.ref }
	return nil
}

// The project of the session shown.
chat_project :: proc(app: ^App) -> string {
	if app.chat.have_self { return app.chat.self.project }
	if s := find_session(app, app.chat.id); s != nil { return s.project }
	return ""
}

// The session shown, as the server describes it (its parent, its outcome, its totals).
self_load :: proc(app: ^App, v: json.Value, asked_at: Seq) {
	c := &app.chat
	c.self = session_from_json(jget(v, "data"), c.alloc)
	c.have_self = true
	if revert := jget(v, "data", "revert"); revert != nil { revert_found(app, c.id, revert, asked_at) }
	if c.self.parent != "" {
		if p := find_session(app, c.self.parent); p != nil {
			c.parent_title = strings.clone(p.title, c.alloc)
		} else {
			request(app, .Parent, "GET", strings.concatenate({"/api/session/", c.self.parent}, context.temp_allocator), tag = c.id)
		}
	}
}

parent_load :: proc(app: ^App, v: json.Value) {
	app.chat.parent_title = strings.clone(jstr(v, "data", "title"), app.chat.alloc)
}

// The sub-agents of the session shown (its children), newest first.
children_load :: proc(app: ^App, v: json.Value) {
	c := &app.chat
	a := arena_renew(&c.children_arena)
	c.children = make([dynamic]Session_Info, a)
	for it in jarr(v, "data") { append(&c.children, session_from_json(it, a)) }
}

find_child :: proc(c: ^Chat, id: string) -> ^Session_Info {
	for &s in c.children { if s.id == id { return &s } }
	return nil
}

load_children :: proc(app: ^App) {
	if app.chat.id == "" { return }
	request(app, .Children, "GET", strings.concatenate({"/api/session?limit=" + SESSIONS_LIMIT + "&parentID=", app.chat.id}, context.temp_allocator), tag = app.chat.id)
}

sessions_load :: proc(app: ^App, v: json.Value) {
	a := arena_renew(&app.sess_arena)
	app.sessions = make([dynamic]Session_Info, a)
	for it in jarr(v, "data") { append(&app.sessions, session_from_json(it, a)) }
	slice.sort_by(app.sessions[:], proc(x, y: Session_Info) -> bool { return x.updated > y.updated })
	sessions_changed(app)
	app.sessions_loaded = true
	sessions_seen_shown(app)
	if app.cx.reopen.id != "" {
		// this computer's server came back elsewhere: its list says whether it is the same one
		p := app.cx.reopen
		if app.chat.id == "" && find_session(app, p.id) != nil {
			app.opened_first = true
			open_chat(app, p.id)
			if !p.bottom { chat_scroll_event(app, Scroll_Restore{p.msg, p.dy}) }   // (no message: nothing to go back to)
		}
		reopen_clear(app)
	}
	if app.chat.id == "" && len(app.sessions) > 0 && !app.opened_first {
		app.opened_first = true
		last := settings_get(app, LAST_SESSION_KEY)
		switch {
		case app.start_session != "":   // --session=<id>
			open_root(app, app.start_session)
		case app.prefs.start != "last" || last == LAST_SESSION_HOME:
		case last != "" && find_session(app, last) != nil:   // the one shown when the window closed (still there)
			open_root(app, last)
		case:
			for s in app.sessions { if s.parent == "" { open_chat(app, s.id); break } }
		}
	}
}

agents_clear :: proc(app: ^App) {
	for a in app.agents { delete(a.id); delete(a.name); delete(a.description); delete(a.mode) }
	clear(&app.agents)
}

models_clear :: proc(app: ^App) {
	for m in app.models { delete(m.id); delete(m.provider); delete(m.name); delete(m.family); delete(m.status); delete(m.inputs); delete(m.efforts) }
	clear(&app.models)
}

// (read again at each reconnection and each change of what is connected: an answer replaces the list)
agents_load :: proc(app: ^App, v: json.Value) {
	agents_clear(app)
	for it in jarr(v, "data") {
		if jbool(it, "hidden") { continue }
		append(&app.agents, Agent_Info{
			id = strings.clone(jstr(it, "id")), name = strings.clone(jstr(it, "name")),
			description = strings.clone(jstr(it, "description")), mode = strings.clone(jstr(it, "mode")),
		})
	}
}

models_load :: proc(app: ^App, v: json.Value) {
	models_clear(app)
	for it in jarr(v, "data") {
		if jstr(it, "type") != "" && jstr(it, "type") != "chat" { continue }
		if _, has := jget(it, "enabled").(json.Boolean); has && !jbool(it, "enabled") { continue }
		m := Model_Info{
			id = strings.clone(jstr(it, "id")), provider = strings.clone(jstr(it, "providerID")),
			name = strings.clone(jstr(it, "name")), family = strings.clone(jstr(it, "family")),
			ctx_len = jnum(it, "limit", "context"), out_len = jnum(it, "limit", "output"),
			status = strings.clone(jstr(it, "status")), released = jnum(it, "time", "released"),
		}
		if prices := jarr(it, "cost"); len(prices) > 0 {
			m.priced = true
			m.price_in, m.price_out, m.price_cached = jnum(prices[0], "input"), jnum(prices[0], "output"), jnum(prices[0], "cache", "read")
		}
		if _, known := jget(it, "capabilities", "tools").(json.Boolean); known { m.tools_known, m.tools = true, jbool(it, "capabilities", "tools") }
		words := make([dynamic]string, context.temp_allocator)
		for w in jarr(it, "capabilities", "input") { if s, is := w.(json.String); is { append(&words, string(s)) } }
		m.inputs = strings.join(words[:], ", ")
		clear(&words)
		for variant in jarr(it, "variants") { append(&words, jstr(variant, "id")) }
		m.efforts = strings.join(words[:], ", ")
		append(&app.models, m)
	}
	slice.sort_by(app.models[:], proc(x, y: Model_Info) -> bool {
		if x.provider != y.provider { return x.provider < y.provider }
		return x.name < y.name
	})
}

// The sessions running now (the stream only tells about runs that start after it connected). What the stream said since this
// list was asked for is newer than it: a run that started is not stopped by it, one that ended does not start again.
active_load :: proc(app: ^App, v: json.Value, asked_at := max(Seq)) {
	cx := &app.cx
	obj, _ := jget(v, "data").(json.Object)
	busy_newer :: proc(cx: ^App_Context, id: string, asked_at: Seq) -> bool { return newer(cx.busy_seq[id] or_else 0, asked_at) }
	over := make([dynamic]string, context.temp_allocator)
	for id in app.busy { if id not_in obj && !busy_newer(cx, id, asked_at) { append(&over, strings.clone(id, context.temp_allocator)) } }
	for id in over { set_busy(app, id, false) }
	if len(over) > 0 { sessions_seen_shown(app) }   // (an end the stream missed, in the session on screen: seen all the same)
	// What a session waits on is the stream's to say, once it is up: what is read is what it could not have said. (A session that ends with
	// something showing, below, is how a word it missed goes.)
	for id in obj {
		unsaid := cx.waits_unread || !(app.busy[id] or_else false)
		if !busy_newer(cx, id, asked_at) { set_busy(app, id, true) }
		if unsaid { session_waits_load(app, id) }
	}
	cx.waits_unread = false
	// (one that does not run waits for nobody: what shows for it is reconciled too)
	for id in waits_sessions(app) { if id not_in obj { session_waits_load(app, id) } }
	// what this list is newer than has nothing more to say
	old := make([dynamic]string, context.temp_allocator)
	for id, at in cx.busy_seq { if !newer(at, asked_at) { append(&old, id) } }
	for id in old { key, _ := delete_key(&cx.busy_seq, id); delete(key) }
}

busy_forget :: proc(app: ^App) {
	for k in app.busy { delete(k) }
	clear(&app.busy)
	for k in app.cx.busy_seq { delete(k) }
	clear(&app.cx.busy_seq)
	marks_changed(app)
}

// The stream says a session started or ended.
@(private = "file")
busy_event :: proc(app: ^App, id: string, busy: bool) {
	if id == "" { return }
	cx := &app.cx
	if id not_in cx.busy_seq { cx.busy_seq[strings.clone(id)] = cx.stream_seq } else { cx.busy_seq[id] = cx.stream_seq }
	set_busy(app, id, busy)
}

permissions_clear :: proc(app: ^App) {
	for p in app.permissions { permission_free(p) }
	clear(&app.permissions)
	marks_changed(app)
}

permission_free :: proc(p: Permission) {
	delete(p.id); delete(p.session); delete(p.action); delete(p.message)
	for r in p.resources { delete(r) }
	delete(p.resources)
}

permission_add :: proc(app: ^App, v: json.Value) {
	id := jstr(v, "id")
	if id == "" || waits_were_answered(app, id) { return }
	for p in app.permissions { if p.id == id { return } }
	res := jarr(v, "resources")
	list := make([]string, len(res))
	for r, i in res { if s, ok := r.(json.String); ok { list[i] = strings.clone(string(s)) } }
	append(&app.permissions, Permission{
		id = strings.clone(id), session = strings.clone(jstr(v, "sessionID")), action = strings.clone(jstr(v, "action")),
		message = strings.clone(jstr(v, "message")), resources = list, born = app.cx.stream_seq,
	})
	marks_changed(app)
}

// What the server says a session waits for: it replaces what is shown for that session, so that a card whose event was missed
// goes. Not a card that came since this list was asked for, and not one being answered: those are newer than the list.
permissions_replace :: proc(app: ^App, session: string, list: json.Array, asked_at: Seq) {
	for i := len(app.permissions) - 1; i >= 0; i -= 1 {
		p := app.permissions[i]
		if p.session != session || p.replying || newer(p.born, asked_at) { continue }
		listed := false
		for it in list { if jstr(it, "id") == p.id { listed = true; break } }
		if !listed { permission_free(p); ordered_remove(&app.permissions, i); marks_changed(app) }
	}
	for it in list { permission_add(app, it) }
}

// A permission or a form answered, here or elsewhere: a list read before that still has it.
waits_gone :: proc(app: ^App, id: string) { gone_add(&app.cx.waits_gone, id, app.cx.stream_seq, WAITS_GONE_MAX) }

waits_were_answered :: proc(app: ^App, id: string) -> bool { return gone_find(&app.cx.waits_gone, id) != nil }

waits_forget :: proc(app: ^App) { gone_clear(&app.cx.waits_gone) }

// The sessions something shows a wait for.
waits_sessions :: proc(app: ^App) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	add :: proc(out: ^[dynamic]string, id: string) {
		for s in out { if s == id { return } }
		append(out, strings.clone(id, context.temp_allocator))
	}
	for p in app.permissions { add(&out, p.session) }
	for f in app.cx.forms { add(&out, f.session) }
	return out[:]
}

permission_remove :: proc(app: ^App, id: string) {
	for p, i in app.permissions {
		if p.id == id { permission_free(p); ordered_remove(&app.permissions, i); marks_changed(app); return }
	}
}

// A page of messages (newest first in the answer). `older`: it goes before the ones already shown; without it, it replaces
// the newest ones (and what the stream had added to them), and the pages read before them stay.
// `asked_at`: when the page was asked for (Request.asked_at). What the stream said since is newer than it and stays.
chat_load :: proc(app: ^App, v: json.Value, older: bool, asked_at := max(Seq)) {
	c := &app.chat
	a := c.alloc
	c.loading = false
	c.loaded = true
	page := make([dynamic]Message, a)
	items := jarr(v, "data")
	#reverse for it in items {
		id := jstr(it, "id")
		if queue_holds(app, id) { continue }   // (it waits: it has not been sent)
		old := id != "" ? find_message(c, id) : nil
		if older && old != nil { continue }
		// (what is final stays as it is: cloned at each reading, images and all, it would pile up in the arena)
		m := old != nil && message_final(old, it) ? old^ : message_from_json(it, a)
		if old != nil && newer(old.touched, asked_at) { message_keep_newer(&m, old) }
		if m.kind == .Idle && len(page) > 0 && page[len(page) - 1].kind == .Idle { continue }
		append(&page, m)
	}
	cursor := strings.clone(jstr(v, "cursor", "next"), a)
	if older {
		c.loading_older = false
		c.older = cursor
		// the view stays on the message it shows at its top (scroll.odin). The lazy column does not: what it builds is reckoned
		// where the view now stands, in the new page, and the message it was on is not among it; a wheel turned up past the top
		// went on to the top of the new page.
		chat_scroll_event(app, Scroll_Older_Page{c.view_msg})
		inject_at(&page, len(page), ..c.messages[:])
		c.messages = page
		find_page_added(app)   // (text a find has not read)
	} else {
		// (what the stream began after this page was asked for is not in it)
		for m in c.messages {
			if !newer(m.touched, asked_at) { continue }
			there := false
			for p in page { if p.id == m.id { there = true; break } }
			if !there { append(&page, m) }
		}
		kept := -1
		if len(page) > 0 { for m, i in c.messages { if m.id == page[0].id { kept = i; break } } }
		if kept > 0 { inject_at(&page, 0, ..c.messages[:kept]) } else { c.older = cursor }
		c.messages = page
	}
	// (what it uses: the last answer's, or what was chosen since)
	for m in c.messages {
		if m.kind == .Assistant && m.model != "" {
			c.model, c.provider, c.agent, c.variant = m.model, m.provider, m.agent, m.variant
		}
		if m.kind == .Switch && m.switched == .Model && m.model != "" { c.model, c.provider, c.variant = m.model, m.provider, m.variant }
		if m.kind == .Switch && m.switched == .Agent && m.agent != "" { c.agent = m.agent }
	}
	subs_changed(c)   // (a page: messages before the others, results of sub-agents, calls with their sessions)
}

// `m` was read from a page, `old` was streamed into since it was asked for: each part keeps the further along of the two (the
// page may also know more: a stream joined in the middle of a run).
@(private = "file")
message_keep_newer :: proc(m, old: ^Message) {
	rank :: proc(s: Tool_Status) -> int {
		switch s {
		case .Unknown, .Pending: return 0
		case .Running:           return 1
		case .Done, .Error:      return 2
		}
		return 0
	}
	for &op in old.parts {
		np: ^Part
		for &p in m.parts { if p.kind == op.kind && (op.kind == .Tool ? p.tool_id == op.tool_id : p.ordinal == op.ordinal) { np = &p; break } }
		if np == nil {
			append(&m.parts, op)
		} else if op.kind == .Tool {
			if rank(op.status) > rank(np.status) { np^ = op }
		} else if len(op.text) > len(np.text) || (op.done && len(op.text) == len(np.text)) {
			np.text, np.done = op.text, op.done
		}
	}
	m.touched = old.touched
	m.streaming = m.streaming && old.streaming
}

// `m`, read from a page, is what the server says of `it` now: only an assistant's message changes, until it is completed.
@(private = "file")
message_final :: proc(m: ^Message, it: json.Value) -> bool {
	if !m.from_page { return false }
	return m.kind != .Assistant || (m.completed > 0 && m.completed == jnum(it, "time", "completed"))
}

message_from_json :: proc(it: json.Value, a: mem.Allocator) -> Message {
	m: Message
	m.from_page = true
	m.id = strings.clone(jstr(it, "id"), a)
	m.created = jnum(it, "time", "created")
	m.completed = jnum(it, "time", "completed")
	m.parts = make([dynamic]Part, a)
	switch jstr(it, "type") {
	case "user":
		m.kind = .User
		m.text = strings.clone(jstr(it, "text"), a)
		message_images(&m, jarr(it, "files"), a)
	case "assistant":
		m.kind = .Assistant
		m.agent = strings.clone(jstr(it, "agent"), a)
		m.model = strings.clone(jstr(it, "model", "id"), a)
		m.provider = strings.clone(jstr(it, "model", "providerID"), a)
		m.variant = strings.clone(variant_of(it), a)
		m.finish = strings.clone(jstr(it, "finish"), a)
		m.cost = jnum(it, "cost")
		m.tokens_in = jnum(it, "tokens", "input")
		m.tokens_out = jnum(it, "tokens", "output")
		m.reasoning = jnum(it, "tokens", "reasoning")
		m.cache_read = jnum(it, "tokens", "cache", "read")
		m.streaming = m.completed == 0
		ord := [Part_Kind]int{}
		for p in jarr(it, "content") {
			part: Part
			switch jstr(p, "type") {
			case "text":      part.kind = .Text
			case "reasoning": part.kind = .Reasoning
			case "tool":      part.kind = .Tool
			case: continue
			}
			part.ordinal = ord[part.kind]
			ord[part.kind] += 1
			part.done = true   // (the last one of a message that runs is not: after this loop)
			if part.kind == .Tool {
				part.tool_id = strings.clone(jstr(p, "id"), a)
				part.tool_name = strings.clone(jstr(p, "name"), a)
				st := jget(p, "state")
				switch jstr(st, "status") {
				case "streaming", "pending": part.status = .Pending
				case "running":   part.status = .Running
				case "completed": part.status = .Done
				case "error":     part.status = .Error
				case:             part.status = .Unknown   // (it says nothing of a run: it must not animate)
				}
				tool_set_input(&part, jget(st, "input"), a)
				tool_set_meta(&part, jget(st, "metadata"), a)
				part.started_ms = jnum(p, "time", "created")
				part.ended_ms = jnum(p, "time", "completed")
				if part.status == .Error {
					tool_set_output(&part, error_text(jget(st, "error")), a)
				} else {
					tool_set_output(&part, content_text(jarr(st, "content")), a)
					content_images(&part, jarr(st, "content"), a)
				}
			} else {
				part.text = make([dynamic]u8, a)
				append(&part.text, jstr(p, "text"))
				if part.kind == .Reasoning && len(part.text) == 0 { continue }   // (signed, empty: the provider hides it)
			}
			append(&m.parts, part)
		}
		if n := len(m.parts); m.streaming && n > 0 && m.parts[n - 1].kind != .Tool { m.parts[n - 1].done = false }
	case "synthetic":
		m.kind = .Synthetic
		m.text = strings.clone(jstr(it, "text"), a)
		if jstr(it, "metadata", "source") == "subagent" {
			m.sub_child = strings.clone(jstr(it, "metadata", "childID"), a)
			m.sub_state = strings.clone(jstr(it, "metadata", "state"), a)
			m.sub_agent = strings.clone(jstr(it, "metadata", "agent"), a)
			m.sub_desc = strings.clone(jstr(it, "description"), a)
			m.text = strings.clone(subagent_body(jstr(it, "text")), a)
		}
	case "shell":
		m.kind = .Shell
		m.text = strings.clone(jstr(it, "command"), a)
		m.shell_id = strings.clone(jstr(it, "shellID"), a)
	case "compaction":
		m.kind = .Compaction
	case "idle":
		m.kind = .Idle
		m.finish = strings.clone(jstr(it, "outcome"), a)
	case "agent-switched":
		m.kind, m.switched = .Switch, .Agent
		m.agent = strings.clone(jstr(it, "agent"), a)
		m.text, m.previous = m.agent, strings.clone(jstr(it, "previous"), a)
	case "model-switched":
		m.kind, m.switched = .Switch, .Model
		m.model, m.provider = strings.clone(jstr(it, "model", "id"), a), strings.clone(jstr(it, "model", "providerID"), a)
		m.variant = strings.clone(variant_of(it), a)
		m.text = strings.clone(model_word(m.model, m.variant), a)
		if prev := jget(it, "previous"); prev != nil {
			m.previous = strings.clone(model_word(jstr(prev, "id"), jstr(prev, "variant") == "default" ? "" : jstr(prev, "variant")), a)
		}
	case "location-switched":
		m.kind, m.switched = .Switch, .Location
		m.text = strings.clone(jstr(it, "location", "directory"), a)
		m.previous = strings.clone(jstr(it, "previous", "location", "directory"), a)
	case:
		m.kind = .Other
		m.text = strings.clone(jstr(it, "type"), a)
	}
	return m
}

// The images among the files of a prompt.
message_images :: proc(m: ^Message, files: json.Array, a: mem.Allocator) {
	for f in files {
		mime := jstr(f, "mime")
		if !strings.has_prefix(mime, "image/") { continue }
		if m.images == nil { m.images = make([dynamic]Image_Ref, a) }
		if src := jstr(f, "source", "uri"); jstr(f, "data") == "" && strings.has_prefix(src, "data:") {
			append(&m.images, image_ref(strings.clone(src, a), .Data_Url, strings.clone(mime, a), strings.clone(jstr(f, "name"), a)))
		} else {
			append(&m.images, image_ref(strings.clone(jstr(f, "data"), a), .Base64, strings.clone(mime, a), strings.clone(jstr(f, "name"), a)))
		}
	}
}

error_text :: proc(v: json.Value) -> string {
	#partial switch x in v {
	case json.String: return string(x)
	case json.Object: return jstr(v, "message")
	}
	return ""
}

// The images among a tool's content (`{type: "file", uri: "data:image/...;base64,...", mime, name}`).
content_images :: proc(p: ^Part, list: json.Array, a: mem.Allocator) {
	for c in list {
		if jstr(c, "type") != "file" { continue }
		mime, uri := jstr(c, "mime"), jstr(c, "uri")
		if !strings.has_prefix(mime, "image/") && !strings.has_prefix(uri, "data:image/") { continue }
		if p.images == nil { p.images = make([dynamic]Image_Ref, a) }
		if strings.has_prefix(uri, "data:") {
			append(&p.images, image_ref(strings.clone(uri, a), .Data_Url, strings.clone(mime, a), strings.clone(jstr(c, "name"), a)))
		} else if d := jstr(c, "data"); d != "" {
			append(&p.images, image_ref(strings.clone(d, a), .Base64, strings.clone(mime, a), strings.clone(jstr(c, "name"), a)))
		}
	}
}

content_text :: proc(list: json.Array) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in list {
		if t := jstr(c, "text"); t != "" {
			if strings.builder_len(b) > 0 { strings.write_byte(&b, '\n') }
			strings.write_string(&b, t)
		}
	}
	return strings.to_string(b)
}

// The text of a sub-agent's result without its envelope: `<subagent sessionID=".." state=".." description="..">text</subagent>`.
subagent_body :: proc(s: string) -> string {
	t := strings.trim_space(s)
	if strings.has_prefix(t, "<subagent") {
		if i := strings.index_byte(t, '>'); i >= 0 { t = t[i + 1:] }
	}
	t = strings.trim_suffix(strings.trim_space(t), "</subagent>")
	return strings.trim_space(t)
}

// What the server says of a tool call as it runs (a sub-agent's session).
tool_set_meta :: proc(p: ^Part, meta: json.Value, a: mem.Allocator) {
	if sid := jstr(meta, "sessionID"); sid != "" && p.sub_session == "" { p.sub_session = strings.clone(sid, a) }
	if id := jstr(meta, "shellID"); id != "" && p.shell_id == "" { p.shell_id = strings.clone(id, a) }
	if files := jarr(meta, "files"); len(files) > 0 {
		b := strings.builder_make(context.temp_allocator)
		for f in files { strings.write_string(&b, jstr(f, "patch")) }
		// (each progress event says it again: the same patch is not read again)
		if patch := strings.to_string(b); patch != "" && patch != p.patch { part_patch_set(p, strings.clone(patch, a), a) }
	}
}

// What a call handed back, and the server's command it names when it went on in the background: read here once, not at each build.
tool_set_output :: proc(p: ^Part, output: string, a: mem.Allocator) {
	p.output = strings.clone(output, a)
	p.output_numbered = read_lines_in(p.output)
	p.moved_shell = ""
	if at := strings.index(p.output, "(shell ID: "); at >= 0 {
		rest := p.output[at + len("(shell ID: "):]
		if end := strings.index_byte(rest, ')'); end > 0 { p.moved_shell = rest[:end] }
	}
}

// The input of a tool, the one thing it is about (shown in its header), and the fields the views read: read here once, a build
// never parses the input.
tool_set_input :: proc(p: ^Part, input: json.Value, a: mem.Allocator) {
	if input == nil { return }
	p.input = strings.clone(jtext(input), a)
	p.fields, p.input_object = nil, false
	if obj, is := input.(json.Object); is {
		p.input_object = true
		p.fields = make([]Input_Field, len(obj), a)
		i := 0
		for k, v in obj {
			s := value_text(v)
			p.fields[i] = {key = strings.clone(k, a), value = strings.clone(s, a), long = strings.index_byte(s, '\n') >= 0 || len(s) > TOOL_LINE_CHARS}
			i += 1
		}
		slice.sort_by(p.fields, proc(x, y: Input_Field) -> bool { return x.key < y.key })
	}
	// The first of `keys` whose value is a string: the field's own text (a write's content is not copied again). Only a string
	// counts: what an edit or a write made is made from it (part_patch).
	text_of :: proc(p: ^Part, v: json.Value, keys: ..string) -> (s: string, ok: bool) {
		for k in keys {
			if _, is := jget(v, k).(json.String); !is { continue }
			for f in p.fields { if f.key == k { return f.value, true } }
		}
		return
	}
	p.command, _ = text_of(p, input, "command")
	p.command_line = ""
	if p.command != "" { p.command_line = strings.concatenate({"$ ", p.command}, a) }
	p.background = jbool(input, "background")
	p.file_path, _ = text_of(p, input, "filePath")
	if p.file_path == "" { p.file_path, _ = text_of(p, input, "path") }
	p.todos, p.has_todos = nil, false
	if list := jarr(input, "todos"); list != nil {
		p.todos = make([]Todo, len(list), a)
		for t, i in list { p.todos[i] = Todo{strings.clone(jstr(t, "content"), a), strings.clone(jstr(t, "status"), a)} }
		p.has_todos = true
	}
	p.old_text, p.has_old = text_of(p, input, "oldString", "old_string")
	p.new_text, _ = text_of(p, input, "newString", "new_string")
	p.content, p.has_content = text_of(p, input, "content")
	if p.tool_name == "subagent" || (jstr(input, "agent") != "" && jstr(input, "prompt") != "") {
		p.sub_agent = strings.clone(jstr(input, "agent"), a)
		p.sub_desc = strings.clone(jstr(input, "description"), a)
		p.sub_prompt = strings.clone(jstr(input, "prompt"), a)
		p.sub_model = strings.clone(jstr(input, "model"), a)
		p.sub_background = jbool(input, "background")
		if sid := jstr(input, "sessionID"); sid != "" { p.sub_session = strings.clone(sid, a) }   // (a sub-agent resumed)
	}
	for k in ([]string{"description", "command", "filePath", "path", "pattern", "query", "url", "prompt", "name"}) {
		if s := jstr(input, k); s != "" {
			s := s
			if i := strings.index_byte(s, '\n'); i >= 0 { s = s[:i] }
			p.subject = strings.clone(s, a)
			return
		}
	}
}

////////////////////////////////
// The event stream

find_message :: proc(c: ^Chat, id: string) -> ^Message {
	#reverse for &m in c.messages { if m.id == id { return &m } }
	return nil
}

// Out of the conversation: it has not been sent, or it no longer will be.
chat_drop :: proc(c: ^Chat, id: string) {
	for m, i in c.messages {
		if m.id == id { ordered_remove(&c.messages, i); subs_changed(c); return }
	}
}

// The conversation shows it as sent already, from the stream: it left the composer while nothing ran.
queue_shown_as_sent :: proc(app: ^App, id: string) -> bool {
	m := find_message(&app.chat, id)
	return m != nil && !m.from_page
}

// A message as the stream says it, before the stored page.
@(private = "file")
user_message_add :: proc(c: ^Chat, id, text: string, files: json.Array, created: f64) {
	a := c.alloc
	append(&c.messages, Message{id = strings.clone(id, a), kind = .User, text = strings.clone(text, a), created = created, parts = make([dynamic]Part, a), touched = c.seq})
	message_images(&c.messages[len(c.messages) - 1], files, a)
}

// It is delivered: here it takes its place in the conversation, once, after what the model has said so far.
@(private = "file")
queue_delivered :: proc(app: ^App, id: string, created: f64) {
	c := &app.chat
	if it := queue_find(app, id); it != nil && find_message(c, id) == nil {
		v, _ := json.parse_string(it.payload, parse_integers = true, allocator = context.temp_allocator)
		user_message_add(c, id, it.text, jarr(v, "files"), created)
	}
	queue_gone(app, id, true, c.seq)
}

// The message an event of the stream is about: every part of it that the stream changes goes through here.
@(private = "file")
assistant :: proc(c: ^Chat, id: string) -> ^Message {
	if m := find_message(c, id); m != nil { m.touched = c.seq; return m }
	append(&c.messages, Message{id = strings.clone(id, c.alloc), kind = .Assistant, streaming = true, parts = make([dynamic]Part, c.alloc), touched = c.seq})
	return &c.messages[len(c.messages) - 1]
}

@(private = "file")
text_part :: proc(c: ^Chat, m: ^Message, kind: Part_Kind, ordinal: int) -> ^Part {
	for &p in m.parts { if p.kind == kind && p.ordinal == ordinal { return &p } }
	append(&m.parts, Part{kind = kind, ordinal = ordinal, text = make([dynamic]u8, c.alloc)})
	return &m.parts[len(m.parts) - 1]
}

@(private = "file")
tool_part :: proc(c: ^Chat, m: ^Message, id: string) -> ^Part {
	for &p in m.parts { if p.kind == .Tool && p.tool_id == id { return &p } }
	n := 0
	for p in m.parts { if p.kind == .Tool { n += 1 } }
	append(&m.parts, Part{kind = .Tool, ordinal = n, tool_id = strings.clone(id, c.alloc)})
	return &m.parts[len(m.parts) - 1]
}

apply_event :: proc(app: ^App, ev: json.Value) {
	kind := jstr(ev, "type")
	d := jget(ev, "data")
	sid := jstr(d, "sessionID")
	c := &app.chat
	mine := sid != "" && sid == c.id
	a := c.alloc
	app.cx.stream_seq += 1
	c.seq = app.cx.stream_seq

	switch kind {
	case "session.execution.started":
		busy_event(app, sid, true)
	case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted", "session.idle":
		if app.busy[sid] or_else false {
			word := strings.trim_prefix(kind, "session.execution.")
			notify_finished(app, sid, word)
			session_ended(app, sid, word == "failed" ? "failed" : word == "interrupted" ? "interrupted" : "succeeded")
		}
		busy_event(app, sid, false)
		if kind == "session.execution.interrupted" { inbox_resume(app, sid) }
		if mine {
			load_messages(app, sid)   // the stored page: the stream only gave the pieces
			stats_context_soon(app)
			if kind == "session.execution.failed" { ui.toast(.Bad, "The run failed") }
		}
		refresh_soon(app)
	case "session.viewed":
		session_viewed(app, sid, jnum(d, "idle"))
		refresh_soon(app)   // (what is seen is the server's to say: its list has the last word)
	case "shell.created", "shell.exited", "shell.deleted":
		activity_poke(app)
		background_read(app)
	case "project.updated", "project.created":
		request(app, .Projects, "GET", "/api/project")   // (a new logo)
	case "session.created", "session.renamed", "session.deleted", "session.updated", "session.archived", "session.moved", "session.metadata.updated":
		if kind == "session.deleted" && sid != "" {
			nav_forget(app, sid)
			outgoing_session_gone(app, sid)
			preview_session_gone(app, sid)
			if mine {   // (elsewhere: what is shown no longer is)
				ui.toast(.Warn, "This session was deleted")
				append(&app.nav_steps, Nav_Step{kind = .Gone})
			}
		}
		if kind == "session.moved" && mine { request(app, .Self, "GET", strings.concatenate({"/api/session/", sid}, context.temp_allocator), tag = sid) }
		refresh_soon(app)
		children_soon(app)
	case GOAL_EVENT:
		goal_set(app, sid, jget(d, "goal"))
	case "session.agent.selected", "session.model.selected":
		// (from here or elsewhere: the composer says it now, the page read again brings its line into the conversation)
		if !mine { return }
		if kind == "session.agent.selected" {
			c.agent = strings.clone(jstr(d, "agent"), a)
		} else {
			c.model, c.provider = strings.clone(jstr(d, "model", "id"), a), strings.clone(jstr(d, "model", "providerID"), a)
			c.variant = strings.clone(variant_of(d), a)
		}
		refresh_soon(app)
	case "artifact.updated":
		artifacts_changed(app)
	case "plugin.updated":
		plugins_changed(app)
	case "integration.updated", "credential.updated", "credential.switched":
		integrations_changed(app)
	case "session.revert.staged":
		if mine { request(app, .Self, "GET", strings.concatenate({"/api/session/", sid}, context.temp_allocator), tag = sid) }
	case "session.revert.committed", "session.revert.cleared":
		revert_gone(app, sid)
		if mine && kind == "session.revert.committed" { load_messages(app, sid) }
		refresh_soon(app)
	case "permission.asked":
		req := jget(d, "request")
		if req == nil { req = d }
		permission_add(app, req)
		asker := jstr(req, "sessionID")
		detail := permission_words(req)
		if asker != c.id { toast_session(app, .Warn, asker, "Permission", detail) }
		notify_waiting(app, asker, "Permission", detail)
	case "session.permissions":   // (a session's approval mode, set here or by another client)
		approval_seen(app, sid, approval_of(jget(d, "permissions")))
	case "permission.replied":
		id := jstr(d, "id")
		if id == "" { id = jstr(d, "requestID") }
		waits_gone(app, id)
		permission_remove(app, id)
	case "form.created":
		form := jget(d, "form")
		form_add(app, form)
		asker := jstr(form, "sessionID")
		detail := form_words(form)
		if asker != "" && asker != c.id && !is_child(c, asker) { toast_session(app, .Warn, asker, "Question", detail) }   // (no session: shown in the conversation, no toast)
		notify_waiting(app, asker, "Question", detail)
	case "form.replied", "form.cancelled":
		waits_gone(app, jstr(d, "id"))
		form_remove(app, jstr(d, "id"))
	}
	if sid != "" && !mine && is_child(c, sid) {
		child_event(app, kind, sid, d, ev)
		return
	}
	if !mine { return }
	chat_changed(c)   // (what follows changes the messages, or their parts)

	mid := jstr(d, "assistantMessageID")
	switch kind {
	case "session.inbox.enqueued":
		item := jget(d, "item")
		id := jstr(d, "inboxID")
		if jstr(item, "type") == "user" {
			if !c.busy && delivery_of(jstr(item, "delivery")) == .Steer {
				// (nothing runs: it does not wait, it goes. The bottom is followed if it was: this does not fetch a reader who went up. Sending it did, submit_prompt)
				if find_message(c, id) == nil { user_message_add(c, id, jstr(item, "payload", "text"), jarr(item, "payload", "files"), jnum(ev, "created")) }
			} else {
				queue_add(app, id, item, c.seq)
			}
		}
	case "session.inbox.delivered":
		queue_delivered(app, jstr(d, "inboxID"), jnum(ev, "created"))
	case "session.inbox.cancelled":
		id := jstr(d, "inboxID")
		if queue_shown_as_sent(app, id) { chat_drop(c, id) }
		queue_gone(app, id, false, c.seq)
	case "session.inbox.delivery.changed":
		queue_delivery_changed(app, jstr(d, "inboxID"), delivery_of(jstr(d, "delivery")), c.seq)
	case "session.step.started":
		m := assistant(c, mid)
		m.agent = strings.clone(jstr(d, "agent"), a)
		m.model = strings.clone(jstr(d, "model", "id"), a)
		m.provider = strings.clone(jstr(d, "model", "providerID"), a)
		m.variant = strings.clone(variant_of(d), a)
		m.created = jnum(d, "started")
		m.streaming = true
		c.model, c.provider, c.agent, c.variant = m.model, m.provider, m.agent, m.variant
	case "session.text.started", "session.reasoning.started":
		_ = text_part(c, assistant(c, mid), kind == "session.text.started" ? .Text : .Reasoning, int(jnum(d, "ordinal")))
	case "session.text.delta", "session.reasoning.delta":
		p := text_part(c, assistant(c, mid), kind == "session.text.delta" ? .Text : .Reasoning, int(jnum(d, "ordinal")))
		append(&p.text, jstr(d, "delta"))
	case "session.text.ended", "session.reasoning.ended":
		m := assistant(c, mid)
		k := kind == "session.text.ended" ? Part_Kind.Text : .Reasoning
		t := jstr(d, "text")
		if k == .Reasoning && t == "" {
			// nothing to show (a hidden chain of thought): drop the empty part
			for p, i in m.parts { if p.kind == k && p.ordinal == int(jnum(d, "ordinal")) && len(p.text) == 0 { ordered_remove(&m.parts, i); break } }
			return
		}
		p := text_part(c, m, k, int(jnum(d, "ordinal")))
		// (another text than the deltas made: another buffer. What was read from a text is kept by its place and its length, and a
		// text only grows in its buffer: md_read, link_runs)
		if string(p.text[:]) != t {
			p.text = make([dynamic]u8, 0, len(t), a)
			append(&p.text, t)
		}
		p.done = true
	case "session.tool.input.started":
		p := tool_part(c, assistant(c, mid), jstr(d, "id"))
		p.tool_name = strings.clone(jstr(d, "name"), a)
		p.status = .Pending
	case "session.tool.called":
		p := tool_part(c, assistant(c, mid), jstr(d, "id"))
		had := p.sub_session
		tool_set_input(p, jget(d, "input"), a)
		if p.sub_session != had { subs_changed(c) }   // (a sub-agent resumed: its session is named)
		p.status = .Running
		p.started_ms = jnum(ev, "created")
	case "session.tool.progress":
		p := tool_part(c, assistant(c, mid), jstr(d, "id"))
		had := p.sub_session
		tool_set_meta(p, jget(d, "metadata"), a)
		if p.sub_session != had { subs_changed(c) }
		if p.sub_session != "" { children_soon(app) }
	case "session.tool.success":
		p := tool_part(c, assistant(c, mid), jstr(d, "id"))
		p.status = .Done
		p.done = true
		tool_set_output(p, content_text(jarr(d, "content")), a)
		content_images(p, jarr(d, "content"), a)
		p.ended_ms = jnum(ev, "created")
		had := p.sub_session
		tool_set_meta(p, jget(d, "metadata"), a)
		if p.sub_session != had { subs_changed(c) }
		if p.sub_session != "" { children_soon(app) }
	case "session.tool.failed":
		p := tool_part(c, assistant(c, mid), jstr(d, "id"))
		p.status = .Error
		p.done = true
		tool_set_output(p, error_text(jget(d, "error")), a)
	case "session.step.ended":
		m := assistant(c, mid)
		m.streaming = false
		m.finish = strings.clone(jstr(d, "finish"), a)
		m.cost = jnum(d, "cost")
		m.tokens_in = jnum(d, "tokens", "input")
		m.tokens_out = jnum(d, "tokens", "output")
		m.reasoning = jnum(d, "tokens", "reasoning")
		m.cache_read = jnum(d, "tokens", "cache", "read")
		stats_context_soon(app)
	case "session.compaction.ended":
		stats_context_soon(app)
	case "session.usage.updated":
		c.cost = jnum(d, "cost")
		c.tokens_in = jnum(d, "tokens", "input")
		c.tokens_out = jnum(d, "tokens", "output")
		c.cache_read = jnum(d, "tokens", "cache", "read")
	}
}

// A session the shown one launched: one of its children, or the session of one of its sub-agent calls.
is_child :: proc(c: ^Chat, sid: string) -> bool {
	if sid == "" { return false }
	return find_child(c, sid) != nil || sid in sub_index(c).claimed
}

// An event of a sub-agent of the session shown: what it is doing now, what it has cost.
child_event :: proc(app: ^App, kind, sid: string, d, ev: json.Value) {
	c := &app.chat
	a := c.alloc
	key := sid
	live, has := c.live[sid]
	if !has { key = strings.clone(sid, a) }
	now := jnum(ev, "created")
	if now == 0 { now = now_epoch_ms() }
	switch kind {
	case "session.step.started":
		live.steps += 1
		live.activity = "thinking"
	case "session.reasoning.started":
		live.activity = "thinking"
	case "session.text.started", "session.text.delta":
		live.activity = "writing"
	case "session.tool.input.started":
		live.activity = strings.clone(jstr(d, "name"), a)
	case "session.tool.called":
		live.tools += 1
		tmp: Part
		tmp.tool_name = live.activity
		tool_set_input(&tmp, jget(d, "input"), context.temp_allocator)
		live.activity = tmp.subject != "" ? strings.clone(strings.concatenate({live.activity, ": ", tmp.subject}, context.temp_allocator), a) : live.activity
	case "session.usage.updated":
		live.cost = jnum(d, "cost")
		live.tokens_in = jnum(d, "tokens", "input") + jnum(d, "tokens", "cache", "read")
		live.tokens_out = jnum(d, "tokens", "output")
	case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted", "session.idle":
		live.activity = ""
		children_soon(app)
	case:
		return
	}
	live.last_ms = now
	c.live[key] = live
}

set_busy :: proc(app: ^App, id: string, busy: bool) {
	if id == "" { return }
	if busy {
		if id not_in app.busy { app.busy[strings.clone(id)] = true; marks_changed(app) }
	} else if id in app.busy {
		key, _ := delete_key(&app.busy, id)
		delete(key)
		marks_changed(app)
	}
	if id == app.chat.id { app.chat.busy = busy }
}
