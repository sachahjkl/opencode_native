// A prompt on its way, from the moment it leaves the composer until the server has it: it owns its text, its images and its
// mentions, so that nothing typed after it can touch them. A first prompt makes its session first, and that session takes the
// agent and the model chosen last: one request after the other (they go on threads of their own, a prompt must not overtake them).
//
// While a session is being started from a composer, that composer holds what is typed (composer_held): Send is off, nothing is
// lost, nothing queues. A prompt to a session that exists leaves at once; several may be on their way.
//
// What fails comes back to the composer of the session it was for. If that session is not the one shown, it waits for it, here
// (outgoing_return); it never lands in another session's composer. A first prompt belongs to the home page.
package ocn

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "gt:config"
import "gt:ui"

Out_Stage :: enum u8 {
	Creating,   // POST /api/session on its way
	Agent,      // the new session takes the agent ...
	Model,      // ... and the model
	Catalog,    // "/name ...": waits for the server's commands, which say whether it is one (outgoing_catalog)
	Taking,     // the pending message it replaces leaves the inbox first (queue.odin)
	Sending,    // the prompt's own POST on its way
	Returned,   // it failed: waits for the composer of its session
}

Outgoing :: struct {
	id:       u64,                 // what its requests carry (Request.out)
	stage:    Out_Stage,
	session:  string,              // "": not made yet, or the home page's (owned)
	text:     string,              // as it comes back to the composer (owned)
	files:    [dynamic]Attachment,
	mentions: [dynamic]Mention,
	path, body: string,            // what goes when it is not a prompt of the composer: a command, one out of the inbox (owned, "": built)
	fields:   string,              // more for the prompt's JSON: how it is delivered (not owned: a literal)
}

// Starting a session from the composer shown: nothing more goes from it until that is done.
composer_held :: proc(app: ^App) -> bool {
	for o in app.cx.outgoing {
		if o.stage <= .Model && o.session == app.chat.id { return true }
	}
	return false
}

@(private = "file")
outgoing_new :: proc(app: ^App, stage: Out_Stage, session, text: string) -> ^Outgoing {
	o := new(Outgoing)
	app.cx.outgoing_last += 1
	o.id, o.stage = app.cx.outgoing_last, stage
	o.session, o.text = strings.clone(session), strings.clone(text)
	append(&app.cx.outgoing, o)
	return o
}

@(private = "file")
outgoing_find :: proc(app: ^App, id: u64) -> ^Outgoing {
	if id == 0 { return nil }
	for o in app.cx.outgoing { if o.id == id { return o } }
	return nil
}

@(private = "file")
outgoing_free :: proc(app: ^App, o: ^Outgoing) {
	for x, i in app.cx.outgoing { if x == o { ordered_remove(&app.cx.outgoing, i); break } }
	delete(o.session); delete(o.text); delete(o.path); delete(o.body)
	for a in o.files { delete(a.name); delete(a.uri) }
	for m in o.mentions { delete(m.text); delete(m.target); delete(m.name) }
	delete(o.files); delete(o.mentions)
	free(o)
}

// What is in the composer leaves it for good: from here on it is the prompt's.
@(private = "file")
outgoing_takes_composer :: proc(app: ^App, o: ^Outgoing) {
	append(&o.files, ..app.cx.attachments[:])
	clear(&app.cx.attachments)
	append(&o.mentions, ..app.cx.mentions.chosen[:])
	clear(&app.cx.mentions.chosen)
}

@(private = "file")
outgoing_send :: proc(app: ^App, o: ^Outgoing) {
	o.stage = .Sending
	path := o.path != "" ? o.path : fmt.tprintf("/api/session/%s/prompt", o.session)
	body := o.body != "" ? o.body : fmt.tprintf(`{{"text":%s%s%s}}`, jquote(o.text), prompt_fields(o.files[:], o.mentions[:], o.text), o.fields)
	request(app, .Prompt, "POST", path, body, o.session, out = o.id)
}

// The composer's prompt, to the session shown, or to a new one in `directory` from the home page. (`fields`: send_as_fields)
outgoing_composer :: proc(app: ^App, text, directory: string, fields := "") {
	if app.chat.id == "" {
		o := outgoing_new(app, .Creating, "", text)
		outgoing_takes_composer(app, o)
		request(app, .Created, "POST", "/api/session", new_session_body(app, directory), out = o.id)
		return
	}
	o := outgoing_new(app, .Sending, app.chat.id, text)
	o.fields = fields
	outgoing_takes_composer(app, o)
	outgoing_send(app, o)
}

// The composer's prompt in the place of pending message `item`: that one leaves the inbox first (queue_replaced).
outgoing_replace :: proc(app: ^App, text, item, fields: string) {
	o := outgoing_new(app, .Taking, app.chat.id, text)
	o.fields = fields
	outgoing_takes_composer(app, o)
	request(app, .Queue_Replace, "DELETE", fmt.tprintf("/api/session/%s/inbox/%s", o.session, item), tag = item, out = o.id)
}

// The DELETE said yes, which it also says of what was delivered, and the stream may be late or down: only a message stored says that it left
// that way. (Waiting, an item is not one: this asks about nothing else.)
outgoing_check :: proc(app: ^App, out: u64, item: string) {
	o := outgoing_find(app, out)
	if o == nil { return }
	request(app, .Queue_Check, "GET", fmt.tprintf("/api/session/%s/message/%s", o.session, item), tag = item, out = out)
}

// `go`: it is out, the prompt goes. Otherwise it had just been delivered: what was written comes back.
outgoing_replaced :: proc(app: ^App, out: u64, go: bool) {
	o := outgoing_find(app, out)
	if o == nil { return }
	if go { outgoing_send(app, o); return }
	o.stage = .Returned
	outgoing_return(app)
	ui.toast(.Warn, "That message was delivered meanwhile: what you wrote is in the composer")
}

// "/name what follows": its text comes back if it fails, what is attached stays in the composer (a command does not take it).
outgoing_command :: proc(app: ^App, text, name, rest: string, fields := "") {
	o := outgoing_new(app, .Sending, app.chat.id, text)
	command_set(o, name, rest, fields)
	outgoing_send(app, o)
}

@(private = "file")
command_set :: proc(o: ^Outgoing, name, rest, fields: string) {
	delete(o.path); delete(o.body)
	o.path = fmt.aprintf("/api/session/%s/command", o.session)
	o.body = fmt.aprintf(`{{"name":%s,"text":%s%s}}`, jquote(name), jquote(rest), fields)
}

// "/name what follows" before the server's commands are read (they are read again when the stream comes back, dropped when a
// server leaves): it waits for them, they are asked for. What is attached goes with it, as with a prompt.
outgoing_slash_wait :: proc(app: ^App, text, fields: string) {
	o := outgoing_new(app, .Catalog, app.chat.id, text)
	o.fields = fields
	outgoing_takes_composer(app, o)
	if !flying(app, .Slash, "") { request(app, .Slash, "GET", "/api/command") }
}

// The commands are read, or could not be: what waited for them goes. A name the server has is a command (what was attached
// comes back to the composer of its session: a command does not take it); any other, a prompt, as it was written.
outgoing_catalog :: proc(app: ^App) {
	waiting := make([dynamic]^Outgoing, context.temp_allocator)
	for o in app.cx.outgoing { if o.stage == .Catalog { append(&waiting, o) } }
	for o in waiting {
		name, rest, ok := slash_split(o.text)
		if !ok || !slash_known(app, name) { outgoing_send(app, o); continue }
		command_set(o, name, rest, o.fields)
		if len(o.files) > 0 || len(o.mentions) > 0 {
			back := outgoing_new(app, .Returned, o.session, "")
			append(&back.files, ..o.files[:])
			append(&back.mentions, ..o.mentions[:])
			clear(&o.files)
			clear(&o.mentions)
		}
		outgoing_send(app, o)
	}
	outgoing_return(app)
}

// A prompt out of the inbox (net.odin inbox_send): `body` goes as it is, what it says is what would come back.
outgoing_inbox :: proc(app: ^App, session, body: string) {
	v, _ := json.parse_string(body, parse_integers = true, allocator = context.temp_allocator)
	o := outgoing_new(app, .Sending, session, jstr(v, "text"))
	o.body = strings.clone(body)
	prompt_parts(v, &o.files, &o.mentions)
	outgoing_send(app, o)
}

// What goes with a prompt's JSON, as the composer holds it.
prompt_parts :: proc(v: json.Value, files: ^[dynamic]Attachment, mentions: ^[dynamic]Mention) {
	for f in jarr(v, "files") {
		uri, name := jstr(f, "uri"), jstr(f, "name")
		if mention := jget(f, "mention"); mention != nil {
			append(mentions, Mention{.File, strings.clone(jstr(mention, "text")), strings.clone(uri), strings.clone(name)})
		} else {
			append(files, attachment_of(uri, name))
		}
	}
	for g in jarr(v, "agents") { append(mentions, Mention{.Agent, strings.clone(jstr(g, "mention", "text")), strings.clone(jstr(g, "name")), strings.clone("")}) }
}

// The session is made. Whoever went elsewhere meanwhile stays there: the prompt goes on without them.
outgoing_created :: proc(app: ^App, r: ^Request, id: string) {
	refresh_sessions(app)
	if r.gen == app.chat.gen {
		open_chat(app, id)
		preview_adopt(app, id)
	}
	o := outgoing_find(app, r.out)
	if o == nil { return }
	delete(o.session)
	o.session = strings.clone(id)
	outgoing_setup(app, o.id, .Agent)
}

// The steps of a new session from `next` on, then its prompt. (A step that failed goes on all the same, with what the session has.)
outgoing_setup :: proc(app: ^App, out: u64, next: Out_Stage) {
	o := outgoing_find(app, out)
	if o == nil || o.stage >= .Sending { return }
	p := &app.cfg_prefs
	c := &app.chat
	shown := o.session == c.id
	if next == .Agent {
		if agent := config.string_of(p, "session.agent"); agent != "" {
			o.stage = .Agent
			request(app, .Session_Agent, "POST", fmt.tprintf("/api/session/%s/agent", o.session), fmt.tprintf(`{{"agent":%s}}`, jquote(agent)), o.session, out = o.id)
			if shown { c.chose_agent = strings.clone(agent, c.alloc) }
			return
		}
	}
	if next <= .Model {
		if model := config.string_of(p, "session.model"); model != "" {
			provider, variant := config.string_of(p, "session.provider"), config.string_of(p, "session.variant")
			o.stage = .Model
			request(app, .Session_Model, "POST", fmt.tprintf("/api/session/%s/model", o.session), model_body(model, provider, variant), o.session, out = o.id)
			if shown { c.chose_model, c.chose_provider, c.chose_variant = strings.clone(model, c.alloc), strings.clone(provider, c.alloc), strings.clone(variant, c.alloc) }
			return
		}
	}
	outgoing_send(app, o)
}

// How its session's making or its own POST ended. (Also for a server left since: the prompt was on its way.)
outgoing_answered :: proc(app: ^App, r: ^Request, delivered: bool) {
	o := outgoing_find(app, r.out)
	if o == nil { return }
	if delivered { outgoing_free(app, o); return }
	o.stage = .Returned
	outgoing_return(app)
	if outgoing_find(app, r.out) != nil { ui.toast(.Warn, "A prompt was not sent: it waits in the composer of its session") }
}

// What failed for the session now shown comes back to its composer, the oldest first. (A session opened, the home page reached.)
outgoing_return :: proc(app: ^App) {
	list := &app.cx.outgoing
	for i := len(list) - 1; i >= 0; i -= 1 {
		o := list[i]
		if o.stage != .Returned || o.session != app.chat.id { continue }
		prompt_restore(app, o.text)
		append(&app.cx.attachments, ..o.files[:])
		clear(&o.files)
		append(&app.cx.mentions.chosen, ..o.mentions[:])
		clear(&o.mentions)
		outgoing_free(app, o)
	}
}

// Its session was deleted: it will not come back, the home page takes what was for it.
outgoing_session_gone :: proc(app: ^App, id: string) {
	for o in app.cx.outgoing {
		if o.session != id { continue }
		delete(o.session)
		o.session = ""
		if o.stage < .Sending { o.stage = .Returned }
	}
	outgoing_return(app)
}

// The server left. What had not gone yet is the home page's again: its session, if made, is of the server left. What is in the
// air stays: its answer says how it ended (answer), and what failed waits for its session, whose id no other server has.
outgoing_forget :: proc(app: ^App) {
	for o in app.cx.outgoing {
		if o.stage >= .Sending { continue }
		delete(o.session)
		o.session = ""
		o.stage = .Returned
	}
	outgoing_return(app)
}
